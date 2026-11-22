#!/usr/bin/env bash
# Builds the Minion-patched Impeller interop SDK (impeller_sdk.zip) for Android.
#
# Usage: ./build.sh [sync|build|all] [abi...]
#   sync   fetch depot_tools, check out flutter/flutter at $REVISION and run gclient sync
#   build  apply patches/interop.patch, build the interop SDK for each ABI and package it
#   all    sync, then build (default)
#
# ABIs: arm64-v8a armeabi-v7a x86_64 (default: all three).
#
# Environment:
#   IMPELLER_SDK_WORK  checkout and build directory (default: $HOME/impeller-sdk-work)
#   IMPELLER_SDK_OUT   where the release zips and SHA256SUMS are written (default: ./out)
#   MINION_RELEASE     the <n> in the <revision>-minion.<n> release tag (default: from ./RELEASE)
#   JOBS               ninja parallelism (default: nproc)

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REVISION=$(tr -d '[:space:]' < "$ROOT/REVISION")
MINION_RELEASE=${MINION_RELEASE:-$(tr -d '[:space:]' < "$ROOT/RELEASE")}
WORK=${IMPELLER_SDK_WORK:-$HOME/impeller-sdk-work}
OUT=${IMPELLER_SDK_OUT:-$ROOT/out}
JOBS=${JOBS:-$(nproc)}
PATCH=$ROOT/patches/interop.patch
FLUTTER=$WORK/flutter
ENGINE=$FLUTTER/engine/src

export PATH=$WORK/depot_tools:$PATH
export DEPOT_TOOLS_METRICS=0
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

log() {
    printf '\n[%(%H:%M:%S)T] %s\n' -1 "$*"
}

# Maps an Android ABI to the engine's --android-cpu value.
android_cpu() {
    case $1 in
        arm64-v8a) echo arm64 ;;
        armeabi-v7a) echo arm ;;
        x86_64) echo x64 ;;
        *)
            echo "Unsupported ABI: $1" >&2
            exit 1
            ;;
    esac
}

fetch_depot_tools() {
    if [[ -d $WORK/depot_tools/.git ]]; then
        return
    fi

    log "Cloning depot_tools"
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "$WORK/depot_tools"
}

checkout_flutter() {
    mkdir -p "$FLUTTER"
    cd "$FLUTTER"

    if [[ ! -d .git ]]; then
        git init -q
        git remote add origin https://github.com/flutter/flutter.git
    fi

    if [[ $(git rev-parse -q --verify HEAD || true) != "$REVISION" ]]; then
        log "Fetching flutter/flutter@$REVISION"
        git fetch --depth 1 origin "$REVISION"
        git checkout -q --force "$REVISION"
    fi

    # The flutter checkout itself is unmanaged; gclient only syncs the engine dependencies.
    cat > .gclient <<'EOF'
solutions = [
  {
    "name": ".",
    "url": "https://github.com/flutter/flutter.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "setup_githooks": False,
      "download_esbuild": False,
    },
  },
]
EOF
}

sync() {
    mkdir -p "$WORK"
    fetch_depot_tools
    checkout_flutter

    log "gclient sync"
    cd "$FLUTTER"
    gclient sync --no-history --shallow --force --reset -j "$JOBS"
}

# Restores the pristine sources of the pinned revision, then applies the Minion patch.
apply_patch() {
    cd "$FLUTTER"
    git reset -q --hard "$REVISION"
    git apply --whitespace=nowarn "$PATCH"
    log "Applied $(basename "$PATCH")"
}

build_abi() {
    local abi=$1
    local cpu

    cpu=$(android_cpu "$abi")
    local target_dir=minion_android_$cpu
    local out_dir=$ENGINE/out/$target_dir

    log "Configuring $abi ($target_dir)"
    cd "$ENGINE"
    # Same configuration as Flutter's CI uses for the published android-* impeller_sdk.zip,
    # without remote build execution.
    python3 flutter/tools/gn \
        --target-dir "$target_dir" \
        --android \
        --android-cpu "$cpu" \
        --no-lto \
        --no-rbe

    local ninja=$FLUTTER/third_party/ninja/ninja
    local patched

    # Compile the interop library sources first so a broken patch fails before the long build.
    # The examples in the same directory are not part of the SDK and need desktop GL headers.
    mapfile -t patched < <("$ninja" -C "$out_dir" -t targets all |
        grep -oE '^obj/flutter/impeller/toolkit/interop/interop(_api|_base)?\.[a-z_]+\.o' |
        sort -u)

    if [[ ${#patched[@]} -gt 0 ]]; then
        log "Compiling ${#patched[@]} interop objects for $abi"
        "$ninja" -C "$out_dir" -j "$JOBS" "${patched[@]}"
    fi

    log "Building $abi"
    "$ninja" -C "$out_dir" -j "$JOBS" flutter/impeller/toolkit/interop:sdk

    package_abi "$abi" "$cpu" "$out_dir"
}

package_abi() {
    local abi=$1
    local cpu=$2
    local out_dir=$3
    local source=$out_dir/zip_archives/android-$cpu/impeller_sdk.zip
    local archive=$OUT/impeller-sdk-android-$abi.zip
    local extra

    mkdir -p "$OUT"
    cp "$source" "$archive"

    extra=$(mktemp -d)
    cp "$ENGINE/flutter/LICENSE" "$extra/LICENSE"
    cp "$ENGINE/flutter/sky/packages/sky_engine/LICENSE" "$extra/THIRD_PARTY_LICENSES"
    cp "$PATCH" "$extra/interop.patch"
    # Flutter's CI adds LICENSE.sdk.md to the published SDK zips; this is the same pointer.
    cat > "$extra/LICENSE.sdk.md" <<EOF
# Minion Impeller SDK

This bundle is the Impeller interop SDK from the Flutter engine, built by
[minion-js/impeller-sdk](https://github.com/minion-js/impeller-sdk) with \`interop.patch\` applied.

The source code is hosted at [flutter/flutter/engine/src/flutter/impeller/toolkit/interop](https://github.com/flutter/flutter/tree/$REVISION/engine/src/flutter/impeller/toolkit/interop).
The Flutter engine license is in \`LICENSE\` (BSD 3-Clause). The licenses of the bundled third-party
code are in \`THIRD_PARTY_LICENSES\`, a copy of [sky_engine/LICENSE](https://github.com/flutter/flutter/tree/$REVISION/engine/src/flutter/sky/packages/sky_engine/LICENSE).
EOF
    cat > "$extra/MINION.md" <<EOF
# Minion Impeller SDK

Impeller interop SDK built from flutter/flutter@$REVISION for Android $abi
with the Minion interop extensions applied (\`interop.patch\`).

Release: $REVISION-minion.$MINION_RELEASE

The patched header defines \`IMPELLER_MINION_EXTENSIONS\`. The libraries and headers are
Flutter engine code under the BSD-3-Clause license in \`LICENSE\`.
EOF
    (cd "$extra" && zip -q "$archive" LICENSE LICENSE.sdk.md THIRD_PARTY_LICENSES interop.patch MINION.md)
    rm -rf "$extra"

    log "Packaged $archive"
}

write_checksums() {
    cd "$OUT"
    sha256sum impeller-sdk-android-*.zip > SHA256SUMS
    log "Checksums ($OUT/SHA256SUMS)"
    cat SHA256SUMS
}

build() {
    local abis=("$@")

    if [[ ${#abis[@]} -eq 0 ]]; then
        abis=(arm64-v8a armeabi-v7a x86_64)
    fi

    apply_patch

    for abi in "${abis[@]}"; do
        build_abi "$abi"
    done

    write_checksums
}

command=${1:-all}

if [[ $# -gt 0 ]]; then
    shift
fi

case $command in
    sync) sync ;;
    build) build "$@" ;;
    all)
        sync
        build "$@"
        ;;
    *)
        sed -n '2,16p' "$0"
        exit 1
        ;;
esac
