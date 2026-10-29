# VLC player inspection and Cinespice controls

Inspected VLC-iOS revision `749cf8be5f3abe0a044f1680a471999d714eb9e3`
and the pinned VLCKit 3.7.4 revision
`54bba6d95502d0f3f7a9da581727935b21d55fb2`.

VLC-iOS application code is GPLv2-or-later/MPLv2; VLCKit is a separate dependency.
This implementation uses original SwiftUI controls and VLCKit rather than copying
VLC's full app, assets, media library or service stack. It is not an embedded copy
of every VLC application feature.

## UI and option map

| VLC iOS area | Cinespice implementation / status |
| --- | --- |
| Top navigation: close, filename, rotate, queue, PiP, renderer | Explicit close action, filename, manual rotation; queue/PiP/renderers deferred |
| Orange timeline, elapsed/remaining time | Implemented with seeking when VLC reports seekable |
| Play/pause and skip controls | Bottom transport with ±10 seconds; double taps also seek |
| Audio/subtitle track card | Separate Audio and Subtitles tabs, track selection/off, local external files and delay |
| Subtitle settings | Persistent 6–18 pt slider calibrated to the displayed picture |
| Aspect control and orientation lock | Fit/Fill, 16:9/4:3/21:9, optional screen edges; explicit portrait/landscape lock |
| Speed controls | 0.25× through 4× presets |
| More and interface lock | Custom bottom options; lock hides all chrome, tap reveals a temporary Unlock button |
| Sleep timer, chapters, bookmarks, A–B repeat | Planned, not implemented |
| Equalizer and video filters | Planned, not implemented |
| Repeat/shuffle/previous/next queue | Planned with an intentional queue, not exposed for the single-video flow |
| Brightness/volume gestures, long-press speed | Not implemented; use device volume controls for now |
| Online subtitles, dual subtitles, PiP/casting | Not implemented or verified against this dependency |

The layout follows VLC's navigation/timeline/bottom transport/track card model,
with Cinespice's ember accent and Telegram download actions. Portrait stacks the
transport and shortcuts; landscape places track/rotate and picture/more beside
transport. Menus have a height bound based on available safe-area geometry and
scroll rather than extending below compact landscape screens.

## Sources inspected

Under `Sources/Playback/Player/VideoPlayer-iOS/`:

- `VideoPlayerViewController.swift`, `VideoPlayerViewController+ControlsDelegate.swift`,
  `VideoPlayerControls.swift` and its XIB: navigation, transport, gestures, rotation,
  aspect handling, notch constraints and closing.
- `TrackSelector/TrackSelectorView.swift`: separate audio/subtitle tabs, Off,
  external files, subtitle lookup and synchronization.
- `MediaMoreOptionsActionSheet.swift` and `Subviews/MediaPlayerActionSheet.swift`:
  option inventory, conditionally exposed chapters and child cards.
- `Subviews/MediaNavigationBar.swift`, `OptionsNavigationBar.swift`,
  `PlaybackSpeedControlsView.swift`, `PlaybackDelayView.swift`,
  `SleepTimerControlsView.swift`, `VideoFiltersControlsView.swift`, `EqualizerView.swift`.

Also inspected `Sources/Playback/Control/VLCPlaybackService.m`,
`Sources/Settings/Model/SettingsSection.swift` and
`Resources/iOS/Settings.bundle/Root.plist`.

## Subtitle size compatibility

Earlier Cinespice builds used VLC iOS's relative renderer divisors 20/18/16/12/6,
labelled Smallest/Small/Normal/Large/Largest. These were not pixel sizes. The user
requested numeric 6–18 sizing. Cinespice now uses a 6–18 pt slider (iOS points,
logical pixels), a separate `Cinespice.subtitlePoints` preference, and explicit
migration from the old divisor values. The UI identifies the units and states
that the renderer approximates them. Physical device pixels are not promised.

VLCKit 3.7.4 implements `setTextRendererFontSize:` but does not declare it in the
public header. The guarded selector remains in use. Its renderer patch writes
`freetype-rel-fontsize`, so the app computes a divisor from the displayed picture
height and the requested logical text size. A larger slider value produces a
larger font; rotation and sizing changes recalibrate it. The renderer's integer
divisor means sizes are approximate. Bitmap and authored styled subtitles may
retain their original sizing. No Apple private API, framework fork or dependency
upgrade was introduced.

Subtitle discovery is asynchronous. The controller selects the first real track
only when VLC has not selected one and the user has not chosen a track/Off.
An explicit Off stays Off as later tracks appear. Successful external subtitle
imports reset that choice so VLC can enforce its imported track selection.
For paired VobSub imports, copy both files into the same sandbox directory but
attach only the IDX; standalone text SUB files still attach independently.
Unsupported codecs/encodings and absent subtitle streams require file/device
inspection; these changes do not establish support for every subtitle format.

## Video surface and sizing

The SwiftUI representable always occupies the full player area. It owns a stable
UIKit container and a separate drawable; screen-edge changes inset/expand only
the drawable frame. Controls keep the outer safe-area layout. A transient zero
layout does not collapse the existing drawable. The container reports actual
bounds and its window screen scale after layout, with callbacks deferred to avoid
publishing SwiftUI changes during a UIKit layout pass.

Fit resets native aspect/crop/scale overrides. Fill uses VLCKit's scaling API with
the larger width/height ratio multiplied by the window's screen scale, following
VLC iOS's fill calculation. Explicit 16:9/4:3/21:9 modes use the native aspect API
and reset Fill scaling. Calculation waits for nonzero video dimensions and is
revisited as VLC opens the output. The pinned iOS output view has flexible width/
height autoresizing and reshapes on `layoutSubviews`. This targets the reported
screen-edge blanking; rendering still requires an actual iPhone check.

### Additional primary sources checked for this change

- [Pinned VLCKit renderer patch](https://github.com/videolan/vlckit/blob/54bba6d95502d0f3f7a9da581727935b21d55fb2/libvlc/patches/0008-libvlc-add-a-basic-API-to-change-freetype-s-color-bo.patch): relative font divisor API.
- [Pinned VLC iOS playback service](https://github.com/videolan/vlc-ios/blob/749cf8be5f3abe0a044f1680a471999d714eb9e3/Sources/Playback/Control/VLCPlaybackService.m): Fit/Fill and screen scale.
- [Pinned VLCKit public header](https://github.com/videolan/vlckit/blob/54bba6d95502d0f3f7a9da581727935b21d55fb2/Headers/Public/VLCMediaPlayer.h): drawable, scaling and aspect APIs.
- [VLC iOS output](https://github.com/videolan/vlc/blob/6de05adc/modules/video_output/ios.m) and [VobSub demux](https://github.com/videolan/vlc/blob/6de05adc/modules/demux/vobsub.c): autoresizing and companion SUB lookup.
- [Apple safe-area layout](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)) and [UIKit layoutSubviews](https://developer.apple.com/documentation/uikit/uiview/layoutsubviews()): layout boundaries and subview frame updates.

## Close and opening behavior

The down arrow calls a closure which clears the library's actual full-screen
selection binding. The video surface does not consume touch events. The local
range server is stopped before VLC teardown, and teardown remains idempotent.
On leaving the view, portrait and the idle timer are restored. The video surface
is attached once instead of reassigning `drawable` on every SwiftUI update.
Pinned VLCKit's `setDrawable:` synchronously dispatches to its background queue;
removing repeated assignments avoids that unnecessary main-thread wait while
progress and track state updates redraw the controls.

A play tap immediately shows a blocking, cancellable Loading media card. Duplicate
taps cannot initiate another player. Cancel invalidates the opening token; an old
request completing late cannot open a video. After presentation, Opening media
remains visible until VLC reports playing or an error/end. Genuine later stalls
retain the existing progress-based buffering indicator.

TDLib revision `c15d3f5a5de6e3ba5839822c451152e5e18bb700`,
`VideosManager::get_video_object` and `DocumentsManager::get_document_object`,
construct their File objects through the current FileManager. `getMessage`
therefore already returns that file state, so preparation
no longer performs a serial `getFile`. Playback starts before the metadata save /
whole-library snapshot refresh. The save still runs and reports failures. Deleted
messages remain errors; old saved paths are never trusted without a current message.
Download/export callers retain their default persistence behavior.

These changes remove known work from the critical path. No measured startup time,
rendering, touch, close or throughput improvement is claimed until the signed app
is exercised on an iPhone/iPad.

## October UI redesign

The options panel now uses a compact dark surface, capped width and internal
scrolling; landscape anchors it at the trailing bottom edge. No full-screen dim
layer or engine/service branding. All existing controls remain. See
[the UI dimensions and device gates](UI-README.md#player). Native layout/touch
verification remains outstanding for this patch.
