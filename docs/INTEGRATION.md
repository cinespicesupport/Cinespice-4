# Player follow-up — 2026-10-16

The current close/loading/subtitle changes are described in [VLC player inspection](VLC-PLAYER.md).
They supersede the player UI notes below. The catalogue plan remains in
[nextupdare.md](../nextupdare.md). Real streaming is user-reported working;
Actions run 38937494876 succeeded at 41e002f. This follow-up still needs a native
build and device checks.

---

# Cinespice update — 2026-10-16

This section supersedes the historical Tevee implementation notes below.

## Evidence and integration choices

The user reports real streaming works; Actions run 38814477919 succeeded for 6949710. New changes still need a native build and device testing.

Inspected VideoLAN VLC-iOS 749cf8be5f3abe0a044f1680a471999d714eb9e3 (`Sources/Playback/Control/VLCPlaybackService.m`, `Sources/Playback/Player/VideoPlayer-iOS/VideoPlayerViewController.swift`, UIKit orientation extensions, COPYING). VLC's application coordinates a large media library/service layer; supported MobileVLCKit APIs are the practical embedded playback interface. Its GPLv2-or-later/MPLv2 application code is not copied. Pinned VLCKit 3.7.4 exposes `videoAspectRatio`, `videoCropGeometry`, `scaleFactor`, track IDs and timing controls. Cinespice supplies its own control panels and uses these APIs.

Inspected TeleSpeed d93462a15d1e9b8ee0c5fc1dd9c138f31a29aa4c, GPLv3, including `app/src/main/java/io/github/tehcneko/telespeed/SpeedHook.java`. Its average/extreme profiles set 512 KB/1 MB chunks and 8/12 parallel requests by hooking Telegram Android private Java fields. TDLib on iOS does not expose those fields. Current improvement uses supported offset/limit download requests with an 8 MB window and 1 MB reads, retaining an active window across sequential reads. A seek outside the window retargets it. The per-file reader remains serialized because TDLib has one active range per file. Maximum priority 32 changes scheduling; server/account/network constraints remain.

## Implemented changes

- Cinespice identity and universal iPhone/iPad icons; creator and VideoLAN credits. Bundle ID, Keychain service and database paths remain stable for upgrade continuity.
- iOS 16 minimum for scene geometry requests; fullscreen iPad. Explicit portrait/landscape switch locks orientation, with failures surfaced. Fit uses safe areas by default, Fill crops and aspect overrides use VLCKit. Edge-to-edge playback is opt-in. Translucent SwiftUI materials are supported by the existing SDK; no iOS 27-specific API claim.
- Custom playback settings panels; spinner appears only after two seconds without progress, never solely from VLC's buffering flag. Backgrounding pauses while retaining the player and navigation state; returning resumes previously playing media. Terminated processes cannot retain in-memory UI, but watch history/session remain on disk.
- Channel/group metadata scans in batches of 30 while the picker is visible; owner-first ordering and selected-source filtering. Private chats are excluded. Video/document searches use up to 30 results each, discard non-video content, persist separate cursors and load near the visible end. Short/sparse pages retain server cursors; errors stop automatic paging and expose retry.
- Server video search across selected sources only: at most four requests per batch, fair source/filter queue, retry preserves successful partial results, merges with cached matches. It follows Telegram's search semantics, not unrestricted local substring search over unknown remote filenames.
- Full-file downloads at priority 32; completed files can be exported to Files with their original filename. Export creates a temporary hardlink, or copies on a worker if linking is unavailable; cancellation/dismissal removes the staging entry. Large copies may need additional free storage.

## Verification and open work

Local checks cover the portable core and syntax; they do not compile SwiftUI/UIKit/MobileVLCKit. A macOS build is still required. Device checklist:

1. Upgrade the same bundle on iPhone 17: verify login/history preserved, new icon/name, small and large text sizes. Test an iPad as well.
2. Play video, tap Rotate while lying down; confirm orientation stays fixed. Cycle Fit/Fill/16:9/4:3/21:9 and screen edges; verify camera/home indicator clearance.
3. Background and foreground during playing and paused states; confirm same player/position and appropriate resume. Force-quit/reopen; confirm fresh navigation and saved watch progress. Simulate network loss while suspended.
4. Confirm an advancing video never displays the buffering spinner, but a genuine stall does; test resume, seek, tracks and imported subtitles.
5. Open a channel with many non-video documents, scroll through several video pages, and search an unindexed filename in multiple selected groups. Confirm private/nonselected chats are absent. Verify errors/retries.
6. Download a large file and export it to local/iCloud Files. Check exact filename, contents, cancellation and disk-space errors. Measure time-to-first-frame and throughput against the old build on the same network/account before claiming a speed increase.

## Supplied references resolved — 2026-10-16

Inspected [NuvioMobile-Enhanced](https://github.com/luqmanfadlli/NuvioMobile-Enhanced) at `a0c06d5f0ed886a6f11f1f28e8d6be947653260f` (GPLv3, Kotlin Multiplatform/Compose). No upstream code copied.

- `composeApp/src/iosMain/kotlin/com/nuvio/app/features/downloads/DownloadsPlatformDownloader.ios.kt`: background URLSession, resume data, HTTP Range, partial-response handling and retry from zero after HTTP 416. These require an actual HTTP origin. Feeding Cinespice’s local HTTP server to a background session would not keep TDLib or that server alive after iOS suspends the process.
- `composeApp/src/iosFull/kotlin/com/nuvio/app/features/p2p/P2pStreamingEngine.ios.kt`: prepares torrent streams via `nuvio_engine_prepare_stream`, consumes an engine-provided URL, and tracks contiguous ready bytes separately from delivered/verified bytes. `composeApp/build.gradle.kts` expects a sibling `../nuvio-engine/platform/apple/NuvioEngine.xcframework`; its engine implementation is not in the supplied checkout. No engine internals or throughput claims are inferred from the bridge.
- `composeApp/src/iosMain/kotlin/com/nuvio/app/features/player/PlayerEngine.ios.kt`: passes the source URL to an mpv bridge. This is not a Telegram downloader or a VLC integration to transplant.

Cinespice keeps supported TDLib offset/limit requests, contiguous-prefix checks and the local HTTP range adapter into MobileVLCKit. The previous update already adds bounded readahead and avoids restarting an active sequential download window. Further concurrency/cache tuning needs real-device measurements; no speed multiplier or background download survival is claimed. Nuvio’s separate transfer/readiness measurements are useful future diagnostics, not evidence that buffered percentages alone should control the player spinner.

Screenshot diagnosis verified against [LiveContainer](https://github.com/LiveContainer/LiveContainer) `4dbe0f9a626de801184a42c0be8d2cb105058e3d`: `LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerView.swift` renders version plus bundle ID. `Models/LCAppInfo.m` reads `CFBundleShortVersionString`, falls back to `CFBundleVersion`, then returns “Unknown”. It is not author/signing metadata. The project explicitly generates both version fields; `scripts/verify-app-metadata.py` validates the actual built plist before packaging. The screenshot is from the older Tevee installation. The new IPA must be installed to verify the corrected display; retaining the bundle ID protects existing app identity.

---

# Tevee integration audit and playback gate

## Scope and evidence (2026-10-15)

Only Tevee was supplied in this workspace; `inputs/` is empty. The following official repositories were inspected as read-only references. No upstream implementation was copied into Tevee.

| Component | Inspected revision | Relevant source |
| --- | --- | --- |
| Telegram-iOS | `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838` | `submodules/MediaPlayer/Sources/FFMpegMediaFrameSourceContext.swift`, `submodules/Postbox/Sources/MediaBox.swift`, `submodules/TelegramCore/Sources/Network/MultipartFetch.swift` |
| TDLib | `c15d3f5a5de6e3ba5839822c451152e5e18bb700` (the commit pinned by Tevee's TDLibFramework 1.8.68-c15d3f5a) | `td/generate/scheme/td_api.tl`, `td/telegram/files/FileDownloader.cpp`, `td/telegram/files/FileManager.cpp` |
| VLCKit | tag `3.7.4`, commit `54bba6d95502d0f3f7a9da581727935b21d55fb2` (version installed in Tevee's successful CI run) | `Headers/Public/VLCMedia.h`, `Sources/VLCMedia.m` |
| TDLibFramework | tag `1.8.68-c15d3f5a` | `Package.swift`, `README.md`, `LICENSE` |

Permanent source links:

- [Telegram read and seek callbacks](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/submodules/MediaPlayer/Sources/FFMpegMediaFrameSourceContext.swift)
- [Telegram multipart fetch scheduling](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/submodules/TelegramCore/Sources/Network/MultipartFetch.swift)
- [Pinned TDLib API schema](https://github.com/tdlib/td/blob/c15d3f5a5de6e3ba5839822c451152e5e18bb700/td/generate/scheme/td_api.tl)
- [Pinned TDLib cache read implementation](https://github.com/tdlib/td/blob/c15d3f5a5de6e3ba5839822c451152e5e18bb700/td/telegram/files/FileManager.cpp)
- [VLCKit stream callbacks](https://github.com/videolan/vlckit/blob/54bba6d95502d0f3f7a9da581727935b21d55fb2/Sources/VLCMedia.m)

## What Telegram's iOS player actually does

`readPacketCallback` requests the exact `readingOffset..<readingOffset+readCount` from `postbox.mediaBox.resourceData(..., mode: .complete)`. Its FFmpeg worker waits for the requested range, rather than using a public media URL. `seekCallback` changes the offset and fetch priority. MediaBox tracks available intervals; MultipartFetch schedules missing parts and revalidates media references.

This is a useful architecture, but not a standalone reader library. It depends on Postbox, TelegramCore, SwiftSignalKit, TelegramApi, MtProtoKit, resource references, account state and Telegram's build graph. Importing that graph into the current XcodeGen/CocoaPods app would replace much of the integration. Tevee will use supported TDLib range APIs to implement the same read-at-offset model.

## What VLC actually supports

VLCKit 3.7.4 publicly exposes `initWithStream:` (`VLCMedia(stream:)` in Swift). Its wrapper uses `libvlc_media_new_callbacks`; `read_cb` calls `NSInputStream.read`, and `seek_cb` sets `NSStreamFileCurrentOffsetKey`. A seekable custom InputStream is therefore possible. The earlier README's suggestion that only a URL input was practical was incomplete.

However, this wrapper's `open_cb` always sets `*sizep = UINT64_MAX`, and its close callback transfers ownership of the stream. A custom stream needs careful worker-thread blocking, cancellation, error, EOF and reopen behavior; unknown-length demuxer support must be verified. Calling raw libVLC callbacks to supply length would add a C/Objective-C integration surface or wrapper changes. Neither route is proven on an iPhone here.

## Selected prototype bridge

`VLC URL input -> loopback HTTP GET/HEAD + byte ranges -> per-file read queue -> TDLib cache availability -> bounded TDLib download -> TDLib readFilePart -> VLC`

- No remote playable URL is assumed. The endpoint exists only on 127.0.0.1 with a fresh session path.
- A known positive media size is required. Otherwise offer download first.
- Check `getFileDownloadedPrefixSize` at the actual requested offset. `downloaded_size` and file length do not prove that an interval contains valid bytes.
- Use `downloadFile(offset, limit)` only for missing bytes, and serialize operations per file: another offset/limit request changes that file's download window.
- Use supported `readFilePart` for the first correctness prototype. TDLib validates coverage and handles cache-file moves. Its JSON/base64 overhead is a known cost; profile before replacing it with worker-thread `pread` at absolute offsets.
- TDLib's `FileDownloader.cpp` uses `pwrite(..., part.offset)`. The old heuristic that subtracted `download_offset` based on disk length was unjustified and could read unrelated bytes or holes.
- Bound response waits, cancel stale sessions, use HTTP 416 for unsatisfiable ranges, send no body for HEAD, and close a started response on failure. Never append a second HTTP response inside a media body.
- Fully cached files use local-file playback and are labelled as downloaded. Streaming remains experimental until actual device playback is observed.

The loopback bridge is selected for its known-length HTTP interface and smallest change to the existing player. This is an implementation choice, not a claim that direct callbacks are impossible or that VLC HTTP seeking has been verified.

## Compatibility and licenses

Tevee targets iOS 15 and Swift 5 language mode with SwiftUI, Network, TDLibFramework and MobileVLCKit. Existing commit `55fe388` built with Xcode 16.4 / iOS 18.5 SDK on macos-15. That result does not validate subsequent changes. Keep iOS 16-only UI/concurrency calls guarded or use iOS 15 equivalents.

TDLib is Boost Software License 1.0; the Swiftgram framework packaging is MIT. VLCKit source headers specify LGPL 2.1 or later and its `COPYING` contains LGPL 2.1; bundled libVLC, codecs and third-party notices also need retention/review if distributing. Telegram-iOS's inspected tree has no top-level LICENSE file; its README explicitly asks derivatives to publish source to comply with its licenses. No license permission is inferred for copying its player. Reuse the architecture through TDLib APIs, not Telegram source. Personal use is the deployment scope; it does not change third-party license texts.

## Milestone status

| Milestone | Status |
| --- | --- |
| Audit and integration selection | Source audit performed; decision above |
| Small real-data prototype | Existing auth/chat/VLC code is present; repairs implemented with synthetic protocol/model tests; actual login and video discovery unverified |
| 5: streaming proof | NOT VERIFIED: requires a signed app on an iPhone and user-controlled Telegram login |
| 6: full library experience | Implemented under the later request to build the missing features; native build and device verification outstanding |
| 7: reliability | 24 core tests passed; account/session guards, bounded caches and lifecycle handling implemented; device/scale checks outstanding |
| 8: build/install | Previous commit has a successful unsigned IPA; current patch requires a new macOS build and signing |

Do not enter Telegram codes, API hashes, database keys or session files in repository fixtures, CI, task chat or logs. Enter credentials only in the installed app. Synthetic fixtures are permitted only in tests and must be identified as such.

## Real-iPhone verification protocol

Use the same final commit for the build and results. Download its IPA artifact from GitHub Actions and sign with SideStore. The app has no backend. Use a non-sensitive video you own in Saved Messages, then one private channel/group you can access.

Record file format, file size, network conditions, device/iOS, build SHA, result and observed limitations, without chat titles, messages, filenames or credentials:

1. Sign in, open Saved Messages and a private collection, and confirm real videos appear, including a video uploaded as a document and one older than the most recent 100 chat messages.
2. With the media absent from TDLib's cache, start experimental streaming. Record the moment VLC renders/plays and compare the player’s Downloaded counter with total size at that time. An HTTP response or a ready listener alone is not playback proof. A completely cached file cannot prove streaming.
3. Seek forward to an uncached part and backwards to a cached part. Observe the requested offset and whether buffering ends and playback resumes. Confirm tail metadata reads for MP4/MKV as applicable.
4. Verify audio output, alternate audio and subtitle tracks where the fixture includes them, playback speed, pause and resume.
5. Interrupt Wi-Fi, restore it, dismiss during buffering, reopen, and try another video. Confirm there is no indefinite spinner, stale connection, incorrect video, or bytes from another session.
6. Use Download first after a stream failure. Confirm completion before local playback; do not label this streaming. Confirm cache-only playback works offline after complete download.
7. Repeat with large files and simultaneous VLC range requests. Document any format that requires full download.

Actual results: **not run**. This Linux sandbox has no Apple SDKs, iPhone, or authenticated Telegram app session. Automated protocol/synthetic tests cannot replace the above. An emulator cannot prove MTProto delivery, MobileVLCKit decoding or real account media access.

## Checkpoint reports

### Audit and integration decision

- Files: this audit; README integration corrections; exact MobileVLCKit 3.7.4 pin in Podfile.
- Work: inspected Telegram read/seek, MediaBox/MultipartFetch, pinned TDLib cache behavior, VLC public input APIs, licenses and the existing Xcode build.
- Verification: read source at the revisions listed above; previous CI used MobileVLCKit 3.7.4 and Xcode 16.4. No upstream sources copied or modified.
- Build: previous commit only; no new iOS build confirmed.
- Limits: a custom InputStream is supported by VLCKit, but neither it nor the HTTP bridge has real-device playback proof here.

### Small prototype repairs, before milestone 5

- Files: `Sources/TelegramClient.swift`, `Sources/TelegramRangeServer.swift`, `Sources/HTTPVideoRequest.swift`, `Sources/TelegramRangeReader.swift`, `Sources/TelegramMedia.swift`, `Sources/TelegramLibraryView.swift`, `Sources/VLCPlaybackView.swift`, `Package.swift`, `Tests/StreamingTests.swift`, `.github/workflows/ios-ipa.yml`, `.gitignore`, README.
- Work: use `createPrivateChat` for Saved Messages; load chats before listing; search native videos and video documents with separate pagination cursors; ignore old collection responses; use chat-scoped message identities; queue reads per file; check actual cache coverage and use TDLib cache reads; bound response waits; isolate HTTP sessions and cancel obsolete connections; support GET/HEAD/206/416; show errors and download-first fallback in the player; display VLC buffering/error state; preserve scrubber position while dragging; pair track names with their actual IDs. Secure storage and random-key generation failures now stop configuration rather than silently creating an unpersisted database key.
- Tests: **13 XCTest tests passed** in Swift 6.0.3 Linux, Swift 5 language mode: six HTTP framing/range tests, three range queue/cancellation/error recovery tests, four media-decoding tests. Fixtures are synthetic and test-only. Syntax parsing and workflow validation are recorded separately in workspace validation context. CI now runs the SwiftPM tests before building the app.
- Build: dispatch through `gh workflow run ios-ipa.yml --repo Thinkmasalablog/Tevee --ref coderabbit/diagnose-build-project/bf43198d` was rejected by task policy (`CODERABBIT_AGENT_RUNTIME_OWNS_GIT_DELIVERY`). No native build was started by that command. Local syntax parsing is not an Apple SDK type check. After the current patch is published, run **Build Tevee IPA** manually on that branch in GitHub Actions, then sign the resulting IPA with SideStore. The older IPA does not contain these fixes.
- Remaining limits at this checkpoint: real Telegram login, real videos appearing, HTTP/VLC playback, uncached seeks, track switching, interruptions and fallback were not run. The subsequent library work below replaces the earlier list of unimplemented library features.

### Milestone 5 — streaming proof remains outstanding

- Files: the range bridge and queue remain in `Sources/TelegramRangeServer.swift` and `Sources/TelegramRangeReader.swift`; `Sources/TelegramClient.swift` now also checks the account session during range access. The revised player displays buffering, a bounded resume/seek failure warning and explicit download-first fallback.
- Actual results: **no real Telegram/VLC playback observed**. Starting a loopback listener and passing synthetic range tests do not establish playback before full download, uncached seeking, audio/subtitle decoding or interruption recovery.
- Build: no native build of the current patch. macOS/Apple SDKs and a signed device are required.
- Limitations: unknown-size files use download-first; JSON/base64 copying needs device profiling; some containers may require full download. Seamless network reconnection and format support are not claimed.

### Milestone 6 — library and media experience implemented

The latest request to build the missing features authorized this implementation while the milestone 5 device gate remains outstanding. It does not replace that verification.

- Files: `Sources/LibraryDatabase.swift`, `LibraryStore.swift`, `TelegramMedia.swift`, `ThumbnailCache.swift`, `SecureStore.swift`, `TelegramClient.swift`, `TeveeApp.swift`, `LibraryComponents.swift`, `TelegramLibraryView.swift`, `LibrarySettingsView.swift`, `PlaybackController.swift`, `VLCPlaybackView.swift`; `Support/CSQLite/`, `Package.swift`, `project.yml`, `Tests/LibraryTests.swift`, README and this report.
- Features: account-specific SQLite metadata/selections/history; Keychain credential restore using the existing TDLib database key; Saved Messages and main/archive chat pagination; video/document pagination; real thumbnail-only fetch with minithumbnail fallback; dark home/collections/search/history screens; Continue Watching; VLC position resume, seek controls, speed and track menus; download progress/cancel and clear media/artwork/history controls. No fake catalog or backend is introduced.
- Storage: `Application Support/Tevee/Library/<accountID>/library.sqlite` and its SQLite WAL files hold metadata/history; `Caches/Tevee/Thumbnails/<accountID>` holds up to 40 MB of image data. TDLib keeps its encrypted session under the existing `Application Support/Tevee/TDLib` directory. API credentials and the existing encryption key are in Keychain with after-first-unlock, this-device-only accessibility. Codes/passwords are transient. The library DB relies on the iOS app container/data protection; it is not separately encrypted with SQLCipher.
- Tests: **24 XCTest tests passed**, Swift 6.0.3 on Linux in Swift 5 language mode, using synthetic fixtures. Includes 13 existing protocol/queue/model tests and 11 persistence/progress/thumbnail tests. All Swift sources pass grammar parsing; this is not an Apple SDK type check.
- Build: iOS target now links system `libsqlite3.tbd`. TDLib and MobileVLCKit version pins are unchanged. Current native compilation, linking and UI behavior remain unverified.
- Limitations: search covers indexed selected titles; pagination must be requested for older videos; full snapshots are decoded after metadata/history writes and need profiling for very large libraries. Metadata refresh merges pages and does not continuously reconcile cloud deletion/edit events. Playback refreshes the actual message/file before trusting a stored cache path. QR authentication is unsupported. UI appearance/accessibility and audio/subtitle menu behavior need device inspection.

### Milestone 7 — reliability foundations, device tests outstanding

- Files: `LibraryDatabase.swift`, `LibraryStore.swift`, `ThumbnailCache.swift`, `TelegramClient.swift`, `PlaybackController.swift`, `VLCPlaybackView.swift`, `Tests/LibraryTests.swift`.
- Features: SQLite transactions/bound parameters and schema checks; preserve a damaged DB and show an error; account/session guards on async callbacks; batch chat persistence; stale progress protection; bounded thumbnail cache; refreshed media state before play; explicit cancellation and visible errors; idempotent player teardown; pause on interruption/headphone removal; pause/save/dismiss on background. Progress saves every five seconds and on pause/stop/end. A failed seek/resume avoids overwriting the previous saved position.
- Tests: database reopen, collection-selection preservation, account/chat separation, cache clearing with history preservation, corrupted DB preservation, delayed older progress, progress normalization, thumbnail metadata roundtrip, cache budget/traversal/oversize rejection passed. Existing range tests also passed.
- Build: current native build outstanding.
- Limitations: force termination can lose the most recent unsaved seconds. Resume/seek completion depends on VLC reporting the requested time and has a 60-second failure message. Large video/collection memory/performance, Wi-Fi interruptions, audio sessions, background persistence and reopening on a real iPhone remain untested. Completed-download flags are refreshed before local playback, but cache eviction can still cause a visible playback error requiring retry.

### Milestone 8 — current build and installation outstanding

- Files: `project.yml` adds the system SQLite library; `Package.swift` includes the storage/cache core and a portable SQLite module. The existing `.github/workflows/ios-ipa.yml` is retained and runs `swift test` before the app build. README documents current installation steps.
- Tests: core tests and syntax parse passed; prior workflow lint is reused because the workflow is unchanged.
- Build status: **no current IPA**. The historical build at `55fe388` succeeded with Xcode 16.4; it does not validate this patch. This Linux sandbox cannot run Xcode, and the earlier dispatch was rejected with `CODERABBIT_AGENT_RUNTIME_OWNS_GIT_DELIVERY`. No alternative remote write path was attempted.
- Next gate: publish this patch through the task workflow, run **Build Tevee IPA** for that branch on GitHub Actions, repair any native compiler errors, download `Tevee-unsigned-ipa`, sign with SideStore and run the device protocol above. No credentials belong in Actions or the repository.

## Additional device acceptance checks

1. Force-close/reopen after watching at least 30 seconds: confirm login, selected collections, metadata and resume survive. Confirm a revoked Telegram session requests login.
2. Seek to a distant position, immediately close, then reopen. Confirm a failed/incomplete seek does not erase the prior resume point.
3. Index multiple pages and archived collections. Check search finds indexed titles and preserves selections after refresh.
4. Complete a download, confirm its badge, then play locally. Cancel another download and retry. Clear local media; confirm metadata/history and Telegram cloud messages remain.
5. Clear artwork and history independently. Artwork should refetch without full-video downloads. History removal should affect Continue Watching.
6. Interrupt audio, unplug headphones, background while buffering/playing, reopen, and switch accounts. Confirm playback stops and no old account artwork, requests or history appears in the new account.
7. Profile a large collection and multi-gigabyte files. Record memory, cache growth and responsiveness; no performance claim has been verified here.


## Owner channels, cache reuse and cinema redesign — current follow-up

### API findings and channel behavior

- The previous picker only filtered persisted titles; it never queried Telegram for the entered text and never loaded ownership status. The new `TelegramDiscovery` uses `searchChatsOnServer` plus `searchChats`, verifies `chatMemberStatusCreator` using `getSupergroup`/`getBasicGroup`, and keeps administrators separate from owners. My channels searches use `searchChatTypeFilterChannel`; other scopes may include groups/Saved Messages. Both title and username matches remain visible.
- There is no private-owner-only discovery endpoint in the pinned schema. `getCreatedPublicChats` only addresses public chats and would miss the requested private channels. Manual discovery therefore checks a bounded batch of chat metadata, alternating main/archive lists, at most 30 resolved chats per action. No messages/files are downloaded during that scan. A short load response does not mean the list has ended. Cached, resolved chats are not fetched again during subsequent scans; server search can explicitly refresh a match.
- Owner channels sort oldest Telegram `supergroup.date` first, unknown dates last. The pinned schema documents this as join time for a current member, creation time otherwise. It is not proof of original creation for transferred/rejoined owners. No guessed creation date is stored.
- Selections persist. Fresh accounts no longer auto-select Saved Messages; prior choices are preserved. Only selected sources appear in home, channel pages, filename search and history. The picker defaults to My channels; media loading starts when opening a selection/initial home channel, not for every picker row.

### Persistence and limits

- `CollectionIndex` persists independent cursors for video, document and audio filters. Each action requests up to 10 hits/filter, 30 total, through one indexing worker. Reopening a cached collection does not advance the cursor; loading another page is explicit. Refresh merges the newest page and retains the older paging position.
- SQLite schema 2 adds `collection_indexes` without deleting existing metadata/selections/history. Page metadata and its cursor commit in one transaction. Old JSON rows decode with optional ownership/filename/remote fields absent. A failed discovery save keeps its pending page for retry instead of losing an exhausted batch.
- Actual filenames take precedence over captions. Remote unique IDs, persistent thumbnail remote handles, chat/message identities, original captions and format/date metadata are retained. Thumbnail keys prefer stable remote identity, so changed local thumbnail IDs reuse cached bytes. A cache miss resolves `getRemoteFile` or refreshes a legacy message before trusting IDs that can change after logout. `prepare` still refreshes the actual message/file before playback; a cache is not permission or availability proof.
- Search results and picker rendering are limited, with explicit scan/show-more actions. Earlier uploads are loaded newest-page-first by TDLib; Oldest first orders the cached subset. No full-history scan is performed to claim global oldest-media ordering.

### Interface and VLC

- Full-width real artwork hero, compact overlaid navigation, red Tevee identity, poster rows, channel cover tiles, file details, video/audio filters and selected-channel pages replace row-based collection browsing. No production sample catalog or generated movie art is introduced.
- VLC now fills the player surface with controls over the video, supports ten-second double taps, control lock, selected-track indicators, speed choices, subtitle off, and audio/subtitle delay controls. The current 3.7.4 header exposes `addPlaybackSlave:type:enforce:`, `currentVideoSubTitleDelay` and `currentAudioPlaybackDelay`; delays use microseconds. Files imports attach temporary sandbox copies as subtitle/audio slaves; I/O runs off the main actor. Up to eight attachments/import and a 20 MB limit for each subtitle bound imports. Errors are shown.
- Native Telegram audio messages, album-cover thumbnails and common audio/video documents are recognized. This is a VLC-backed player, not the separate VLC app or a promise that every container/codec will decode. Paired SUB/IDX, encoding, all track switches, the Files picker and timing adjustments require actual device verification. Background behavior remains pause/save/dismiss, not background playback.

### Files, validation, build and limits

- Files: new `Sources/TelegramDiscovery.swift`, `Sources/LibraryPaging.swift`, `Tests/DiscoveryTests.swift`; changes in `TelegramClient`, `TelegramMedia`, `LibraryDatabase`, `LibraryStore`, `ThumbnailCache`, `TelegramLibraryView`, `LibraryComponents`, `LibrarySettingsView`, `PlaybackController`, `VLCPlaybackView`, `Tests/StreamingTests.swift`, `Tests/LibraryTests.swift`, `Package.swift`, README and this report. Dependency pins and the Xcode/Actions build configuration are unchanged.
- Tests: **36 core XCTest tests pass**. New cases cover bounded metadata-only discovery, ownership vs administrator status, main/archive paging without resolving cached chats again, server search of an unscanned owned channel, username filtering, short pages/retries, filename priority, audio formats, stable thumbnail cache reuse, saved cursors/deduplication/history, legacy JSON, SQLite version-1 migration, and history writes preserving refreshed file metadata. One earlier assertion expected caption priority; it was updated for the user's explicit filename requirement, and subsequent suites passed. All fixtures are synthetic. Swift grammar parsing and a narrow compile-only integration check are recorded separately; neither is an Apple SDK build.
- Build: no current native build or IPA. The Linux/Apple SDK and prior workflow-dispatch policy gates remain. The previous IPA does not verify this redesign. No new dependencies or upstream modifications were introduced.
- Remaining verification: confirm your real owned/private and archived channels appear through search and scan; selections survive restart; only chosen channels load; no repeated indexing on reopen; oldest ordering reflects the available date; real filenames/artwork are shown. Inspect portrait/landscape, safe areas, scrolling and accessibility. Test native audio, multiple video containers, embedded/external tracks, paired subtitle files, time offsets, control lock, seeking and fallback on the same signed build. No live account access, visual screenshots or real playback was observed here.
