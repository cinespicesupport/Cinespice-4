# Existing-feature reliability checks

These changes preserve signed membership and revocation checks, account isolation,
Telegram notification delivery. The former full-download-before-play rule is
intentionally replaced: Play pauses a same-file full transfer and streams using
its retained cache.
They do not add a background transfer service. A later access change stores persistent activations and checks membership when communication is available.

## Changes in both apps

- Failed seeks/resumes pause once and expose Retry position and Start over.
  Pending/failed seeks cannot overwrite good watch history. Explicit timeline
  seeks can still reach the end; iOS automatic resume retains its five-second margin.
- Active full downloads remain active when checked. Interrupted/missing files
  offer Retry; paused/cancelled files do not restart full downloads from streaming activity.
- Favorites/watchlist updates avoid an unnecessary complete catalogue reload.
  iOS also reuses its database snapshot when saving progress, updating only history
  and its derived rows. No measured speedup is claimed yet.
- Search refresh keeps results for the same query and explains partial searches,
  source scope and connection failures. Different queries clear previous results.
- Access checks retry silently while a stored persistent activation is valid.
  A confirmed paid-group departure, revocation or device transfer gates access.
- History loading presents the newest eligible announcement, rather than flashing
  older banners. Dismissed banners stay dismissed. Permanent Telegram deletion
  wins over a history response that was already in flight. History errors have
  an explicit retry and do not misleadingly say the feed is empty.

## Platform details

- iOS stores full-download intent/status per Telegram account and reconciles it
  with current message/file state after activation and when opening Downloads.
  Failed entries remain visible with Retry download; paused and legacy cancelled
  entries offer Resume download. This intentionally
  replaces the previous documented behavior where incomplete queues were lost.
- Android already persisted download intent; checking Downloads now preserves
  active TDLib transfers instead of marking every incomplete transfer Retry.
  Download inside the Android player now persists its intent too, so it
  appears in Downloads after returning to the library. Completed playback cannot
  be overwritten by a later zero-position teardown save.
- Announcement previews cap decoded still-image dimensions; oversized Android GIFs
  use a still preview to bound decoding work. Image decoding failures expose Retry; closing an iOS announcement
  while media is loading cannot start its video afterward.

## Acceptance checks on Android and iPhone

1. Stream, seek, interrupt the connection, and wait for a failed seek. Check that
   the player pauses once, Play/Pause agrees with it, and Retry/Start over work.
   Close/reopen before retrying: the previous good resume position must survive.
2. Start a download, open Downloads repeatedly, background/return, then restart.
   Confirm active transfers remain Downloading and stopped work offers Retry.
   Pause, stream another part, then reopen: the full download must remain Paused
   until Resume is selected. Playing an active full download must pause it and
   open streaming without waiting for the whole file.
3. Remove a completed local file using cache cleanup. Confirm it is no longer
   presented as ready offline. Cloud messages, favorites and history must remain.
4. With a large library, watch for several minutes and toggle Favorites/Watchlist.
   Check stable scrolling, resume history and updates after selecting other sources.
   Measure database and frame time before claiming a performance improvement.
5. Search a title, refresh the same query, then disconnect while loading an older
   page. Keep existing results visible with Retry. Change the query and selected
   sources; old-query/deselected results must not appear. Check a zero-source search.
6. Disconnect during access verification and reopen the app; a persistent activation
   must remain usable. Reconnect, leave the paid group or use /revoke: a confirmed
   denial must gate access. Optional update channels must not gate access.
7. Read a long text/photo/GIF/video announcement, dismiss its banner, reopen the
   app and paginate older notices. No older banner should replace it. Repeat with
   a media load failure, Retry, Close while loading, /clear and /clearall offline.
8. Switch Telegram accounts during a download/search request. No previous-account
   results, download state, notice, entitlement or playback may cross into the next.

## Automated versus device validation

Portable Swift and JVM tests cover recovery state, download reconciliation,
permanent deletion and library/cache consistency alongside prior regressions.
Android unit tests, optimized lint and APK packaging can run on Linux. Swift
frontend parsing checks syntax; compiling UIKit/SwiftUI/VLCKit and building an IPA
requires macOS/Xcode. Actual VLC rendering, background transitions, storage/network
failures and touch behavior on phones still require the acceptance checks above.

## Download, export and long-scroll acceptance

- Pause a partially downloaded large file; record downloaded bytes. Restart the
  app, then Resume. Verify retained bytes are reused and completion remains exact.
  Repeat during a status refresh to check that Paused is not overwritten by Retry.
- Start a download and immediately Play. Check the full download becomes Paused,
  playback opens, seeks work, and Resume later completes the original file.
- Save a completed file on each platform with the system picker. Verify its name,
  size and content; cancel the picker and try a full/read-only destination too.
  Clear app media cache and verify the explicitly exported copy still exists.
- Scroll far down a channel, tap Search, and confirm results stay in that channel.
  Top returns to the beginning. Repeat Home, global Search, Library and Downloads;
  repeat Top in Channels and notification history. Check large text and keyboard.
- Compare time to first frame, seek latency and full-download MB/s on the same
  files/account/network before and after. Small partial reads reduce buffering
  thresholds, but no fixed throughput gain or background execution is claimed.

Automated tests cover paused-record persistence/reconciliation and partial-read
bounds, including small final ranges. Real TDLib cache reuse, network performance,
file-picker delivery and native scrolling/focus require the above device checks.
