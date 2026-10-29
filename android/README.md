# Cinespice for Android

Native Kotlin/Compose + Java Android port of the Swift app, with TDLib and embedded libVLC.
Package: `app.cinespice.android`. Android **8.0 or later** (API 26+).
The iOS project remains at the repository root; the Android project is self-contained here.

## Install

In GitHub Actions download **Cinespice-Android-arm64-v8a** for most modern
phones/tablets, **Cinespice-Android-armeabi-v7a** for older 32-bit ARM devices,
or **Cinespice-Android-x86_64** for an emulator. Extract the artifact ZIP and
install its `app-<architecture>-optimized.apk`.
These are separate complete APKs; install only the one matching your device.
Allow your browser/file manager to install unknown apps when Android prompts.
Open Cinespice and sign in with your account phone/code, two-step verification
password (when requested), or requested email verification. API configuration is
injected at build time; users are not asked for API keys.
Open **Channels** in the header to choose channels/groups. Tap a selected source's
browse arrow to load its collection, then tap a poster to play. Credentials are entered on-device; never put them in Git or send
login codes to another person.

The current build uses Android's **debug signing certificate** and is directly
installable; it is not a Play Store release. Subsequent builds must use the same
signing key to update an existing installation. CI creates a new debug key on a
fresh runner; APKs from unrelated CI runs may require uninstalling the earlier
build, which erases local session/history. For permanent releases configure your
own private release key outside Git before distributing updates.

## Build

Requirements: JDK 17, Android SDK platform 35 and build-tools 35.0.0, Bash,
curl, tar, sha256sum, and Internet access. Android Studio can open this directory.
Gradle 8.9, Android Gradle Plugin 8.7.3, TDLib 1.8.65 and libVLC 3.6.5 are pinned.
The Gradle distribution and TDLib archive have pinned SHA-256 checksums.

```bash
export ANDROID_HOME=/path/to/android/sdk
# With Google's SDK command-line tools:
sdkmanager 'platforms;android-35' 'build-tools;35.0.0' 'platform-tools' 'ndk;27.2.12479018'
./prepare-tdlib.sh
./gradlew :app:testDebugUnitTest :app:lintOptimized :app:assembleOptimized
```

Find optimized signed installable APKs in `app/build/outputs/apk/optimized/`.
Use `adb install -r app/build/outputs/apk/optimized/app-arm64-v8a-optimized.apk` for a
connected ARM64 device. `./gradlew :app:connectedDebugAndroidTest` additionally
runs the channel selection, search focus/keyboard/recreation, storage, JNI,
HTTP range transfer, and local VLC playback checks on a
connected Android device/emulator. Test fixtures are synthetic; no account
credentials are required for those tests.

GitHub Actions → **Build Cinespice Android APK** builds all three APKs and uploads
one artifact per architecture. Download only the one matching your device.
The previous combined artifact was about 114 MiB because it contained all three
APKs; that was not the size of a single installed package. This workflow also
runs on Android branch pushes and pull requests affecting this project.

Measured APK download sizes for version 1.1.1 (not installed storage):

| Architecture | Previous debug APK | Optimized APK |
| --- | ---: | ---: |
| ARM64 | 39.8 MiB | 32.4 MiB |
| ARMv7 | 35.6 MiB | 30.9 MiB |
| x86_64 | 42.1 MiB | 34.1 MiB |


The `optimized` build uses R8 code optimization, resource shrinking, and NDK
27.2.12479018 native symbol stripping. JNI entry points for TDLib and libVLC are
preserved. The full Telegram engine and VLC codecs remain available. The
`debug` build remains available with `./gradlew :app:assembleDebug`. To run
device checks against the optimized build use:

```bash
./gradlew -PdeviceTestBuildType=optimized :app:connectedOptimizedAndroidTest
```

`./gradlew :app:assembleRelease` creates optimized unsigned release APKs. Sign them using
your own keystore and `apksigner`, then verify with `apksigner verify`.
Never commit a keystore or its passwords. See [third party notices](THIRD_PARTY.md)
for dependency sources and licenses before distributing.

## Implemented flows

- Telegram personal account login, code, two-step password, email verification,
  encrypted session restore and sign out. AES-GCM credentials/database key in
  Android Keystore; cloud backup and device transfer excluded.
- Main/archive channel and group discovery in batches of 30, owned channels
  first, persistent source selection, source title filter and Telegram search.
  A single header Channels picker shows discovery and independent selection/browse actions. Search
  fields retain focus and text while results update, including background batches.
  Private chats and Saved Messages are excluded.
- Account-specific SQLite metadata, per-filter pagination cursors and history.
  Each collection requests up to 30 videos and 30 documents; document filtering
  accepts video MIME types/extensions. Load more and retry retain cursors.
- Cached title/filename/caption search plus Telegram search within selected
  sources, bounded to four requests per batch with source/filter rotation.
- Cancellable opening, refreshed message/file state, loopback HTTP range bridge
  with random URL token, HEAD/suffix/seek ranges, serialized per-file reads,
  1 MB chunks and 8 MB read-ahead; downloaded files play directly.
- Full downloads, cancel, progress, and save completed media through Android's
  system file picker. Cleanup does not delete Telegram cloud messages.
- Embedded VLC with play/pause, timeline, ±10 seconds, double tap seeking,
  speed 0.25×–4×, audio/subtitle tracks/off, external tracks, delays ±30 seconds,
  five saved subtitle sizes, fit/fill/aspect choices, screen edges, manual
  portrait/landscape, control lock and auto hide.
- Periodic progress, Continue Watching, resume/from beginning, mark watched,
  remove/clear history, pause when backgrounded and resume on return.

## Android differences and device checks

This is an Android UI using the same app's library/player model. SwiftUI and
MobileVLCKit cannot run on Android. Android uses libVLC's public controls and
system document pickers. Subtitle size changes reopen the video at its saved
position; bitmap or styled subtitles may ignore text size. Reopening also resets
external tracks, delay/speed and picture choices. External IDX/SUB companion
pairs require device verification; this importer selects one track file at a time.
Artwork starts with embedded minithumbnails, then loads visible thumbnail files.
The local artwork cache has a 40 MB disk and 32 MB decoded-image memory budget.

Downloads/streams are foreground work; Android process termination can interrupt
them. This port does not include a foreground download service or background
playback. Keep the app open to finish downloads. No broad storage permission is
requested. There is no backend, WebView wrapper, subscription, or analytics SDK.

Authenticated Telegram streaming, channel permissions, large libraries, external
tracks, physical touch, codecs and ARM-device playback still need checking on a
real device. Automated synthetic tests do not establish those results. The
loopback server is private to the device and bound to 127.0.0.1; Telegram uses
TDLib's MTProto transport with no application HTTP endpoint override.

## October 2026 Compose redesign (1.2.0)

Implements [UI specification](../docs/UI-README.md) and
[Android translation](../docs/ANDROID-UI.md): opaque Cinespice Glass/Cinespice Dark/Crimson Cinema/Silver Screen
palettes, compact header, five destinations, adaptive grid/rail, seven manual
hero positions, Continue Watching, Favorites/Watchlist, sorting, and compact dark
VLC options. Catalogue slots explicitly say the catalogue is not connected.
No poster/trending provider is configured; artwork uses Telegram thumbnails.
The optimized 1.2.0 APK measures about 33.7 MiB on ARM64 (32.2 MiB ARMv7,
35.3 MiB x86_64); it retains separate architecture downloads and native stripping.

Page/query/collection/list state uses a ViewModel and SavedStateHandle. Each page
has separate grid state; changing destinations starts at the top, returning from
playback retains the underlying composition. Search starts empty and debounces
selected-source Telegram work. Sorting applies to loaded metadata; filename years
are hints, not verified release dates. Unknown years follow known years.

Existing account-specific SQLite metadata/history/cursors remain intact, with no
destructive migration or key changes. New list memberships use scoped `chat:message`
keys in an additional account-specific Room database (`saved_<account>.db`). They
are independent of history, media cleanup and source selection. Full-download
intent/completion is persisted there and refreshed against TDLib on reopen;
active work remains Downloading and interrupted work exposes Retry rather than silently restarting. There is no
background transfer service. Exports use Android's document picker.

Automated UI checks use the debug variant (`:app:connectedDebugAndroidTest`);
optimized native/playback checks can use `-PdeviceTestBuildType=optimized`.
Physical tablet/foldable/cutout/TalkBack coverage and live Telegram streaming
remain device acceptance work; emulator results do not establish those behaviors.

### Current UI and build configuration

The four themes now match iOS: Cinespice Glass, Cinespice Dark (default), Crimson
Cinema and Silver Screen. Navigation is Home, Search, Library and Downloads;
Library includes New Releases, Favorites, Watchlist and History. Channel rows
contain up to 15 portrait posters. Details offers Play, Heart and Plus and retains
the original filename. The player uses the existing VLC engine with native icon
controls; Play/Pause has no waveform.

Builds require `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` (the same GitHub secrets
as iOS). For local builds, an ignored `android/telegram-config.local.json` file
can provide `apiID` and `apiHash`; `CINESPICE_TELEGRAM_CONFIG` can point to a private
file elsewhere. The Gradle build rejects invalid IDs/hashes. Credentials are
packaged into the application; account sessions remain device-local. Login no
longer asks users to supply API credentials.

Library reads and derived home rows run on the IO dispatcher; player progress
writes use a serial background executor. Optimized builds retain R8, resource
shrinking and one APK per ABI. No additional UI framework was added.

### Account session and sign-out

Normal app restarts restore the encrypted TDLib session; this is not a saved
password. Cinespice never persists login codes or cloud passwords. The password
field uses password keyboard input, is not included in saved activity state, and
is cleared on submission. The server decides when two-step verification is needed.

Sign out and Back to sign in both revoke authorization through `logOut`, wait for
`authorizationStateClosed`, then remove the TDLib session directory (including
downloaded media) and encrypted database key before starting a fresh client.
Account-specific library/history and saved lists remain. A durable pending flag
prevents account access after an interrupted sign-out; errors offer Retry sign-out.
Normal client closure without a sign-out request preserves the session.

Check on a device: sign out, close/reopen the app during sign-out, retry after a
network failure, and sign in again with an account that has two-step verification.
Confirm its requested password screen appears, a submitted password is cleared,
and activity recreation never restores the password field. Routine app reopening
should stay signed in until sign-out. Unit tests cover sign-out persistence and
cleanup; they do not establish live service authorization behavior.

Existing-feature fixes and phone acceptance steps: [Reliability checks](../docs/RELIABILITY-CHECKS.md).
