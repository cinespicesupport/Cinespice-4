# Build warning cleanup

## Android lint

The optimized lint baseline had 14 warnings: legacy backup rules (1), a redundant
API26 resource directory (1), unused navigation drawables (3), missing themed
launcher icon (1), indirect gesture accessibility click handling (1), player text
formatting/localization (6), and fixed right alignment (1).

- Older-Android backup exclusions now match the Android12+ exclusions.
  `allowBackup=false` remains in effect; no session/database backup is enabled.
- The adaptive launcher icon lives in `mipmap-anydpi`, since minSdk is26. Its
  monochrome mark uses the existing brand geometry with a transparent background.
- Removed navigation drawables had no source/resource references. Compose uses its
  existing vector icons instead.
- The player gesture View now owns its touch handling and explicitly implements
  `performClick`. Single tap still calls that click; double tap still seeks10s;
  accessibility click still toggles controls. A documented suppression on this
  method covers lint's inability to follow the asynchronous confirmed-tap callback;
  it prevents an extra click on the first half of a double tap. Verify on a phone
  with TalkBack.
- Player remaining time/import/error messages use resource strings and placeholders.
  Remaining-time alignment uses END for right-to-left layouts.

No lint baseline or global warning suppression is introduced. The one local
accessibility suppression covers an existing, explicit `performClick` callback.
Compiler diagnostics and binary strip notices are separate from lint results.

## iOS

The last successful IPA build at357071a showed a deprecated locale language accessor
and MobileVLCKit's source target still declaring iOS9. The app already requires
iOS16. The locale accessor now uses the iOS16 language API. A CocoaPods post-install
hook raises pod source targets below16 to16, preserving any newer target and the
pinned MobileVLCKit3.7.4 dependency.

Xcode also printed `Metadata extraction skipped. No AppIntents.framework dependency
found.` Cinespice does not currently declare AppIntents. No unused framework or
unverified build flag was added to silence that metadata-tool diagnostic.
The current patch still needs a macOS/Xcode build; Linux syntax checks cannot
establish that all native compiler warnings have disappeared.

## GitHub Actions and Node.js

Actual IPA run40861619850 reported that upload-artifact@v4 declared Node20, then
ran under forced Node24 and emitted transitive deprecation messages. Workflows now
use inspected Node24 releases of artifact upload, Java/Python/Android setup and
Gradle setup. Checkout@v5 already targets Node24. Existing app JDK17/Python3.12,
artifact names, archive defaults, access configuration and build commands remain.

Tagged action manifests and configured inputs are checked with workflow linting.
A subsequent hosted run must verify artifact uploads and whether any upstream
transitive Node deprecation remains. No Node-warning suppression environment
variables are used.
