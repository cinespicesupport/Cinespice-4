# Next Cinespice upgrades

Planning only. These features are not implemented by this player update.

## 1. Turn the Telegram library into a movie and TV catalogue

Keep selected Telegram channels/groups as the source of playable videos. Match
filenames and captions to metadata and present one movie/show card with official
artwork, title, year, synopsis and a Watch/Continue button.

- Evaluate TMDb first for movie, TV, season and episode metadata; optionally use
  OMDb/IMDb identifiers for matching. Verify provider access, attribution and
  caching requirements before implementation. IMDb is an identifier/reference,
  not an assumed freely accessible API.
- Parse likely title/year/season/episode and edition from filenames and captions.
  Auto-match only confident candidates; provide Identify title / Change match.
- Persist stable provider IDs, matches and artwork locally. Keep unmatched files
  accessible under their original filenames.
- Group alternate qualities from selected sources under the title/episode:
  original filename, channel, size, resolution and codec when known. Mark details
  inferred from filenames; verify actual media details when available.
- Keep different cuts/editions separate. Switching versions must account for
  differing runtimes before carrying over watch progress.
- TV layout: show → season → episode → available versions.
- Search both matched titles and original filenames, including Telegram search
  for files not yet cached.
- Start with one replaceable metadata provider. Evaluate catalogue addon protocol
  compatibility later; arbitrary executable plugin code is not required.

Open discussion: show only locally available Telegram titles on Home, or also
show discovery titles with no available file? The user has not chosen yet.

## 2. More of VLC's options

The common controls are implemented; exact parity with the VLC application is
not claimed. Its current app includes features beyond the pinned MobileVLCKit
integration. See [the inspected option map](docs/VLC-PLAYER.md).

Suggestions, ordered after the current close/loading/subtitle checks:

1. Brightness and volume gestures with a clear on-screen value, optional haptics,
   and an accessibility alternative. Restore display brightness on exit.
2. Chapter selection for files that expose chapters, jump to time, and a sleep
   timer that handles backgrounding and pauses at the chosen deadline.
3. Equalizer, video filters and A–B repeat using verified pinned VLCKit APIs.
4. Persistent bookmarks; optional play-next queue tied to the catalogue's episodes.
5. Subtitle font/color/bold settings and a small preview. Keep bitmap/styled-subtitle
   limitations visible. Investigate online subtitle lookup separately.
6. Picture in Picture, AirPlay/casting and dual subtitles only after confirming
   framework/version support and real streamed-file behavior on iPhone/iPad.

## 3. Measure startup and streaming

- Record local timings for tap → message ready → server ready → VLC playing →
  first frame. Keep diagnostics opt-in and on device, without credentials or
  tokenized stream URLs.
- Compare fresh searches, cached files, downloaded files, MKV/MP4 and large files
  on the same account/network. Tune buffering from measurements.
- Investigate prioritizing a small initial read without disrupting random seeks
  or TDLib's single active download window per file.
- Further reduce whole-library snapshot work for individual metadata/history
  updates if profiling shows it causes UI stalls in large collections.
- Consider pausing playback after a prolonged opening failure, with Retry and
  Download first actions; establish a reasonable timeout using device evidence.

## Current update acceptance checks

Before expanding the catalogue, verify on the actual signed app:

- Tap a searched file once: feedback appears immediately and only one player opens.
- Cancel during preparation, then open another file: no late unwanted playback.
- Close using the down arrow while opening, buffering, playing, paused and in
  locked landscape. The library/search state should still be there.
- Change each subtitle size during text-subtitle playback; close/reopen another
  file and confirm the choice persists. Test external SRT and styled/bitmap tracks.
- Test compact iPhone, landscape with camera cutout, iPad and larger accessibility
  text sizes. Confirm menus scroll and the close button remains reachable.

## UI follow-ups after the October redesign

Implemented now: two persistent saved lists, four themes, filename-year sorting,
Downloads page, compact navigation/player panels, seven hero positions. See
[UI specification](docs/UI-README.md) and [Android guide](docs/ANDROID-UI.md).

Next, after native/device acceptance:

- Connect a verified catalogue trending feed for the four reserved hero slots.
  OMDb metadata alone must not be assumed to provide a trending feed.
- Resolve catalogue dates over filename hints; expose corrections for ambiguous
  years/title matches. Persist last-search recommendations only if desired.
- Consider custom named lists and optional automatic removal from Watchlist after
  completion; current Favorites/Watchlist remain independent of watching history.
- Define Request feature destination and privacy before adding actual submission.
- Reconcile interrupted download queues after relaunch; investigate supported
  background execution before promising background downloads.
- Adopt native Liquid Glass APIs only with an updated, verified SDK and deployment
  fallbacks; retain readable nontransparent rendering for accessibility.
