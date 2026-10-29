# iPhone player checks

## What changed

- Lock removes player chrome. Tap the picture to reveal an Unlock button at the
  side; it hides after two seconds unless VoiceOver is running. Tap Unlock to
  restore controls. Playback errors and resume warnings also unlock controls.
- Embedded subtitles select the first real track if VLC leaves them Off. Manual
  track choices and Off take precedence as more tracks are discovered.
- Subtitle size is a saved 6–18 **pt** slider. iOS points are logical pixels,
  not physical Retina pixels. Old relative size presets migrate. VLC approximates
  the requested text size; bitmap/strongly styled subtitles can keep authored sizes.
- Screen edges resize a persistent drawable inside a UIKit container. Fit, Fill
  and explicit ratios reapply once real video dimensions become available.
- For VobSub, import matching IDX and SUB together; only the index is attached.

## Run on a newly built, configured IPA

Use a short MP4, an MKV with multiple audio/subtitle tracks, and a file which failed
before. Test both a completed download and uncached streaming when applicable.
Record iPhone model, iOS version, build, file container and subtitle format with
any failure. A subtitle screenshot and whether the track appears in the list are
useful; account credentials and bot secrets are not needed.

| Check | Expected result |
| --- | --- |
| Lock while playing; single/double tap | No persistent unlock overlay; taps reveal Unlock and do not seek/pause. Unlock restores controls. |
| VoiceOver lock, reveal, escape gesture | Unlock remains discoverable; escape unlocks first, then can close the player. |
| Embedded text captions; choose another track then Off | A track is enabled by default if VLC has no selection; switching works and Off remains Off. |
| Subtitle slider at 6/12/18; rotate, close and reopen | Text grows with the number; choice persists; no inverted preset behavior. Check long/non-Latin text. |
| ASS/SSA and PGS/VobSub | Correct track can be selected; authored/bitmap sizes may differ. Test text captions separately for size control. |
| Import SRT and paired IDX/SUB through Files | Imported captions appear after resuming. Pick both VobSub files; no duplicate companion track attachment. |
| Fit → Fill → each ratio → Fit | Picture remains visible; Fit restores proportions, Fill crops, ratios intentionally alter proportions. |
| Toggle Screen edges repeatedly in portrait/landscape | No blank video or audio-only state; controls stay clear of camera/home indicator. Test a notched phone. |
| Seek ±10 s, scrub far forward/back and reopen | Playback reaches the target and resume restores the saved place; slow/unseekable files show a warning. |
| Alternate audio, speed and ±0.25 s delay/reset | Correct track/rate/timing changes without losing the picture or captions. |
| Background/foreground, phone interruption, unplug headphones | Playback pauses appropriately; it resumes only under the existing foreground policy. Closing restores portrait and sleep behavior. |
| Cold open, cancel while opening, offline/network loss | No duplicate player; cancelled opening stays closed; failures offer download-first/retry paths. |
| Notifications and access | Announcements expand/close and clear correctly; a membership/license revocation locks the app, including during playback. |

## What is verified here

The Linux Swift suite exercises core sizing calculations (including Retina scale),
subtitle preference migration, delayed track discovery/Off intent, paired import
selection, lock state, and the existing streaming/library/access core. Native
Swift files are also checked for syntax. SwiftUI/UIKit/MobileVLCKit compilation
and actual video/subtitle rendering require macOS/Xcode and an iPhone. Passing the
portable tests does not establish that every media file or device layout works.

See [the existing integration protocol](INTEGRATION.md#real-iphone-verification-protocol)
for larger-library, cache, uncached-streaming and account-boundary tests. Planned
features such as PiP/casting and playback queues are listed in
[VLC player inspection](VLC-PLAYER.md); they are not claimed as implemented here.
