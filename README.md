# Minion Impeller SDK

Builds of Flutter's [Impeller interop SDK](https://github.com/flutter/flutter/tree/master/engine/src/flutter/impeller/toolkit/interop)
(`impeller_sdk.zip`) for Android, with a small patch that exposes typography features Minion
needs. The patch only adds thin C wrappers over features the engine's text stack (`txt` /
SkParagraph) already implements; nothing in Impeller's rendering changes.

- Engine: flutter/flutter at the commit in [`REVISION`](REVISION)
  (`685f4cfaa9d07d1504a7d1bf8a8daa8573000d57`), the revision Minion pins.
- ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`. No host builds.
- Releases: `<revision>-minion.<n>`, where `<n>` is [`RELEASE`](RELEASE).

## What the patch adds

`include/impeller.h` defines `IMPELLER_MINION_EXTENSIONS` (currently `1`). Guard every use so the
same code still compiles against the stock SDK:

```c
#if defined(IMPELLER_MINION_EXTENSIONS) && IMPELLER_MINION_EXTENSIONS >= 1
ImpellerParagraphStyleSetLetterSpacing(style, 1.5f);
#endif
```

`IMPELLER_VERSION` is unchanged.

| Feature | API |
| --- | --- |
| Letter spacing | `ImpellerParagraphStyleSetLetterSpacing` |
| Word spacing | `ImpellerParagraphStyleSetWordSpacing` |
| Even leading for line height | `ImpellerParagraphStyleSetHalfLeading` |
| OpenType features (`tnum`, `liga`, `smcp`, …) | `ImpellerParagraphStyleSetFontFeature`, `ImpellerParagraphStyleClearFontFeatures` |
| Variable font axes (`wght`, `wdth`, `opsz`, …) | `ImpellerParagraphStyleSetFontVariationAxis`, `ImpellerParagraphStyleClearFontVariationAxes` |
| Text shadows | `ImpellerTextShadow`, `ImpellerParagraphStyleAddTextShadow`, `ImpellerParagraphStyleClearTextShadows` |
| Inline placeholders | `ImpellerPlaceholderStyle`, `ImpellerParagraphBuilderAddPlaceholder`, `ImpellerParagraphGetPlaceholderRects` |
| Boxes for a text range | `ImpellerParagraphGetRectsForRange` |

Decoration color and style need no patch: the stock `ImpellerTextDecoration` already carries
`color`, `style` (solid, double, dotted, dashed, wavy) and `thickness_multiplier`.

The rect queries fill a caller buffer and return the total count. Pass `NULL` and `0` to count
first, or a buffer that is usually large enough and retry when the count is larger:

```c
ImpellerRect rects[16];
uint32_t count = ImpellerParagraphGetPlaceholderRects(paragraph, rects, 16);
```

A placeholder is one U+FFFC character (one UTF-16 code unit) in every index the paragraph
reports. Placeholders cut off by `ImpellerParagraphStyleSetMaxLines` are missing from the end of
the placeholder rects. `impeller.hpp` has matching C++ wrappers. The header comments in
[`patches/interop.patch`](patches/interop.patch) document every parameter.

## Release assets

```
https://github.com/minion-js/impeller-sdk/releases/download/<revision>-minion.<n>/impeller-sdk-android-arm64-v8a.zip
https://github.com/minion-js/impeller-sdk/releases/download/<revision>-minion.<n>/impeller-sdk-android-armeabi-v7a.zip
https://github.com/minion-js/impeller-sdk/releases/download/<revision>-minion.<n>/impeller-sdk-android-x86_64.zip
https://github.com/minion-js/impeller-sdk/releases/download/<revision>-minion.<n>/SHA256SUMS
```

Each zip has the stock `impeller_sdk.zip` layout (`include/impeller.h`, `include/impeller.hpp`,
`lib/libimpeller.so`, `lib/libimpeller.a`, `README.md`, `examples/`, `LICENSE.sdk.md`) plus
`LICENSE` (Flutter's BSD-3-Clause license), `THIRD_PARTY_LICENSES` (the engine's license list for
bundled third-party code), `MINION.md` and `interop.patch`. Like the stock SDK, the libraries keep
their debug symbols; strip them when packaging an app.

## Building

Android targets need a Linux x64 host (WSL 2 works). Expect a ~30 GB checkout and ~10 GB of
build output per ABI.

```sh
./build.sh sync                 # depot_tools, flutter/flutter at REVISION, gclient sync
./build.sh build                # patch, build all three ABIs, package, SHA256SUMS
./build.sh build arm64-v8a      # one ABI
./build.sh all                  # sync + build
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `IMPELLER_SDK_WORK` | `~/impeller-sdk-work` | depot_tools, the flutter checkout and build directories |
| `IMPELLER_SDK_OUT` | `./out` | release zips and `SHA256SUMS` |
| `MINION_RELEASE` | `RELEASE` | `<n>` written into `MINION.md` |
| `JOBS` | `nproc` | ninja parallelism |

`build` resets the flutter checkout to `REVISION` before applying the patch, so it can be rerun
after editing the patch; ninja only recompiles what changed. Each ABI is configured like
Flutter's own `android-*` SDK builds (`flutter/tools/gn --android --android-cpu=<cpu> --no-lto`)
and builds the `flutter/impeller/toolkit/interop:sdk` target.

### GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on manual dispatch: one job per
ABI uploads its zip as an artifact, and with `release` checked a final job creates (or updates)
the `<revision>-minion.<n>` release with the three zips and `SHA256SUMS`. A full engine build is
long on standard 4-core runners; the `runner` input accepts a larger runner label.

## Changing the patch

1. Edit the files under `engine/src/flutter/impeller/toolkit/interop` in the synced checkout
   (`$IMPELLER_SDK_WORK/flutter`) and regenerate the patch from the flutter root with
   `git diff > patches/interop.patch`.
2. Bump `IMPELLER_MINION_EXTENSIONS` in the patched header when the API changes, and `RELEASE`
   for every new release on the same engine revision.
3. Moving to a new engine revision means updating `REVISION`, resetting `RELEASE` to `1` and
   rebasing the patch.

## License

The scripts, workflow and documentation here are MIT licensed ([`LICENSE`](LICENSE)). The patch
and all SDK builds are Flutter engine code under Flutter's BSD 3-Clause license, with bundled
third-party code under its own licenses; see [`NOTICE`](NOTICE).
