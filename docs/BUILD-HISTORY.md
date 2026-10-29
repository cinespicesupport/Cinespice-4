# Historical build repairs

These notes describe earlier revisions, not the current deployment target or validation status. The current minimum is iOS 16.

### Latest build repair and OS compatibility

[Run 38809966649](https://github.com/Thinkmasalablog/Tevee/actions/runs/38809966649), at commit `3219ad5`, failed because `.tracking` was applied after `.lineLimit`, selecting the iOS 16 `View` API while the minimum target is iOS 15. Tracking is now applied directly to `Text`; the channel badge and VLC label also keep text-only modifiers before view modifiers.

[Run 38813049090](https://github.com/Thinkmasalablog/Tevee/actions/runs/38813049090), at commit `bd3d901`, then failed in the VLC speed label: `specifier:` interpolation is supported by SwiftUI localized text, but the `tool` helper takes a plain `String`. Both speed labels now use Foundation `String(format:)`, preserving values such as 1.25× and 1.75× without rounding to two significant digits. This correction still needs a fresh macOS build.

That run selected Xcode 16.4 with the iOS 18.5 SDK. That repair kept iOS 15; the current update raises the minimum to iOS 16 for manual scene rotation. The minimum is a lower bound, not the newest supported iPhone OS. Installing on iOS 27 and building against its SDK still require verification with a suitable Xcode toolchain; this patch does not claim either check passed. No unverified Xcode 27 path or runner image is hardcoded.

Cinespice now has an opaque ember C/play app icon in `Resources/Assets.xcassets`, configured as `AppIcon`. Its editable vector is `Design/AppIcon.svg`. Committed PNGs require no extra build dependency. To regenerate them, run `python3 scripts/generate-app-icon.py` with FFmpeg built with the librsvg decoder.

### Why the initial build failed

[The initial run](https://github.com/Thinkmasalablog/Tevee/actions/runs/38781890878) failed with Xcode exit code 65 during Swift compilation. The deployment target is iOS 15, but the code used iOS 16 APIs: `Task.sleep(for:)`, `NavigationStack`, `.toolbar(.hidden, for:)`, and `.scrollContentBackground`. The VLC view also used an identity comparison on `drawable`, which imports as `Any`.

Commit `55fe388` replaces or guards those calls and assigns the VLC drawable directly. [Its build succeeded and uploaded an IPA](https://github.com/Thinkmasalablog/Tevee/actions/runs/38782853529). That confirms compilation and packaging; device playback still needs verification.

CI also builds pull requests targeting `main` or `master`. For future failures, check the first compiler `error:` in the **Build unsigned app** log. The **Cinespice-build-diagnostics** artifact retains the build log, Xcode result bundle, and available dependency resolution files for seven days, including on build failure.
