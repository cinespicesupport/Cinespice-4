# Cinespice UI specification

Implementation: October 2026 redesign. This describes the current source, not a
claim that the new screens passed native compilation or physical-device testing.
See [Android translation](ANDROID-UI.md) and [device checks](TOUCH-CHECKLIST.md).

## Navigation and space

- Header: CINESPICE refresh button, one Channels icon, Profile icon. A back arrow
  appears inside a collection. No duplicate search or channel-selection shortcuts.
- Footer: **Home / Search / Library / Downloads** use native SwiftUI TabView.
  System sizing, selection, animation and accessibility adapt to the OS. Header
  controls remain at least 44 points; safe areas are retained. iOS 26 supplies
  its native floating appearance; earlier systems use their native tab bar.
- Content uses 20–24-point margins, adaptive grids (140-point minimum cards),
  a 1,200-point maximum content width, and 16–20-point section gaps.
- Scroll identity includes account, destination, collection and saved-list choice.
  Switching destinations starts at the top. Returning from a player preserves the
  underlying destination and scroll state. No shared offset between tabs.
- Login uses native rounded fields and prominent Continue buttons. Keyboard Done,
  interactive scroll dismissal and focus-aware form scrolling keep controls and
  errors reachable. No window-wide tap recognizer competes with buttons.
- Cinespice refreshes an open collection or active search. Elsewhere it queues one
  newest page per selected source through the existing serial loader. It does not
  erase cached metadata, lists, progress or older-page cursors. Feedback appears
  below the header; errors remain visible. Refreshing does not crawl all history.

## Pages

| Page | Content and behavior |
| --- | --- |
| Home | Seven-slot swipe hero, Continue Watching (up to 12), and one horizontal row per selected channel (up to 15 cached videos). Each channel heading opens its collection. No global library grid or duplicate channel-card rail. Channel video order varies per app launch and stays stable while browsing; hero and Continue Watching retain their existing ordering. |
| Library | Opens on New Releases from all selected channels, sorted by filename year; Favorites, Watchlist and History categories retain saved membership and history |
| Search | Universal input across all selected channels and groups. Empty guidance initially; only nonempty queries show cached and remote results; paging remains bounded |
| Downloads | Preparing, active and completed full downloads from selected sources; video menu exposes pause/resume and save-to-device; streaming fragments are excluded |
| Library → History | Five most recently watched entries; older resume positions remain stored |
| Collection | One selected channel's videos, scoped search, shared sorting and explicit Load more / Retry pagination; no automatic endless scroll |
| Profile | Real account display name/username, palette, request-feature placeholder, storage/history cleanup, creator links, sign-out |

The source sheet has **My channels / Selected / All sources** scopes and shows
eligible channels/groups, owner-first, oldest available Telegram date first.
Ownership/date are not guessed. Typing searches
saved source metadata and Telegram's local/server chat search; resolve enough IDs
to find up to 30 actual groups/channels before applying the result cap, since
Telegram may mix people and bots into an unfiltered result page. Show progress,
empty and retry/error states in the sheet. Tap a row to select or deselect;
selected rows gain an independent arrow to browse. Scanning while visible is
gradual, 30 sources at a time. Closing the picker loads the first page for each
selected source; tapping a channel arrow opens its full collection page. A
collection page requests at most 30 video and 30 document messages per page.

### Saved lists and downloads

The video long-press context menu adds/removes **Favorites** or **Watchlist**, with saving feedback
and a heart/bookmark on the card. SQLite schema 3 stores membership by scoped
message ID (`chatID:messageID`), independently of history/cache state. A saved
remote search result gets metadata persisted with its membership. Deselecting a
source hides its items without deleting membership. Each Telegram account has its
own database. Custom named lists are a future extension, not implemented here.

Download is available in video details, video menus and the player's More panel. Play streams
when possible and pauses a same-file full download without removing cached bytes.
Downloads persist preparing/downloading/paused/completed intent per account and
reconcile it with TDLib after restart. Paused and legacy cancelled entries offer
Resume; failed work offers Retry. Download cards and details show clear action buttons.
Completed items expose Save to device using the iOS Files picker and original filename. TDLib may evict cached data; playback and
export refresh message/file state instead of blindly trusting stored paths.

Long library pages expose Search and Top controls. Collection search queries only
the opened channel, including older messages. Channel pickers and notification
history offer Top as well.

### Sorting and metadata truthfulness

Default: **Latest releases**. Other choices: Earliest releases, Title A–Z, Title
Z–A, Recently added, Oldest uploads. The choice is a local preference shared by
collection, saved lists, downloads and search. Library → New Releases always uses
latest filename year order; History stays chronological.

Until a metadata provider is connected, release sorting uses **filename year
hints**, with the displayed title as fallback only when there is no filename.
A standalone year from 1880–2099 is accepted; ambiguous multiple years and
embedded numbers such as `12024p` or `S02E2024` are rejected. These hints can be
wrong (e.g. a film named “1917”) and are labeled as filename years. Unknown years
always follow known years in either direction. Ties use upload date, chat ID and
message ID. Upload time is never represented as release time. Sorting applies to
loaded results; fetching all Telegram history merely to sort is not performed.

### Seven hero positions

1. Most recently added cached video (Telegram upload time).
2. Daily pseudo-random pick, deterministic for a UTC day and unchanged cached
   library; recomputed on foregrounding. Adding/removing cached titles may change it.
3–6. Four explicit **catalogue not connected** placeholders, not fabricated trends.
7. Representative result from the last completed nonempty search in this app
   session; hidden if its source is deselected. It is not persisted search history.

No OMDb/TMDb/trending connection, catalogue posters or quality grouping is implied.
Slots may show the same video in a small library. No automatic carousel motion.

## Color and materials

See [Cinespice design system](DESIGN-SYSTEM.md) for palettes, responsive rules,
brand artwork provenance and Apple references.

Four choices share the same layout: **Cinespice Glass**, **Cinespice Dark**
(default), **Crimson Cinema**, and **Silver Screen**. Semantic palette tokens
cover surfaces, text, accents and primary actions. The supplied red glass C stays
recognizable in every theme; login shows the name alone. The player retains its
black video surface and readable white controls, with matching dark option sheets.

Preferences remain under `cinespice.theme`. Older names resolve as follows:
Cinema → Dark; Ember → Crimson; Midnight → Silver; Pearl/Sage → Glass. These
replace the previous choices intentionally without resetting local account data.
Native list rows use the chosen surface palette. Navigation material and motion
are owned by the system tab bar and its accessibility settings.

## Player

Keep the video black-backed in every palette. Preserve manual one-tap orientation,
camera-safe Fit, timeline, ±10 seconds, play/pause, tracks, speed, picture and lock.
Options use the palette's dark surface with a subtle border. Glass uses its Dark
companion while playing. Panels are capped at 460 points in portrait and 400 in
landscape, within the current safe viewport. The total panel height includes its
header and padding; long option lists scroll. Outside tap or X dismisses.

All existing subtitle sizes, track selection/import, delays, picture ratios and
speed settings remain. Transport uses white controls; the timeline and selected options use the palette accent. Player controls still cover part of the picture while
visible. Exact VLC application UI/feature parity is not claimed. Visible branding
is Cinespice; creator credit is “Created by Masalaots · @notmasalaoats”. Profile
links use camera/paperplane symbols for Instagram/Telegram (not copied brand art).
Account, search, streaming and player copy uses neutral wording. The creator's
messaging link is labeled Community. Dependency names remain in open source
notices and repository source/licensing documentation.

## Acceptance before release

Run the new native build, then the [device checklist](TOUCH-CHECKLIST.md) on a
notched iPhone, small iPhone and iPad, portrait and locked landscape. Verify all
four palettes, keyboard interactions, independent scrolling, upgrade persistence,
completed download restart/export, seven hero slots and player options. Portable
unit tests do not establish visual correctness or iOS touch behavior.

## Login and video actions update

Cards expose compact Play and Info buttons with 44-point touch targets. Artwork
opens details; long press reveals saved lists, playback, download/export and history
actions using native context menus. Home uses portrait cards in horizontal rows, including Continue Watching. Play controls use compact 56 × 34-point pills with at least 44-point touch targets and real saved progress when available.

Login reads build-injected Telegram credentials; API entry fields are removed.
Phone entry separates country calling code and national number. Code entry offers
resend (subject to Telegram limits). Back to sign in restarts TDLib authorization
via logout and returns to phone entry, including from password/email steps. It
does not merely change the visible screen while leaving an old challenge active.

These changes intentionally replace the previous Home and credential-entry
contracts. Native compilation, accessibility and device acceptance remain required.

## Apple-inspired navigation and motion refinement

- Four destinations: Home, Search, Library, Downloads. Library defaults to New Releases.
  Release order continues to use filename year hints, never invented catalogue dates.
- Channel rows retain the 15-title limit, horizontal scrolling and collection arrow.
  Portrait artwork is independent of scroll direction.
- Native TabView replaces the custom dock, selection spring and gesture handling.
  CI uses macOS 26 and its Xcode SDK; deployment remains iOS 16. Appearance follows
  the installed iOS version, including its accessibility preferences.
- All seven hero pages reserve the same artwork and scaled metadata dimensions,
  regardless of available content. Native paging owns horizontal swipes. Long
  metadata scrolls vertically inside its reserved region.
- Cards, hero, opening overlay and player use cleaned display names. Known source
  prefixes, separator underscores/dots and media extensions are removed only for
  presentation. Title sorting uses those names; filename-year sorting, persistence
  and Files export retain original data. About shows the original filename once
  and retains the caption (an identical caption is not repeated).
- Details displays the complete thumbnail with fit/letterboxing. Player controls
  use one horizontal row, scrolling on narrow/large-text displays. The play/pause
  pill shows a native waveform animated only during actual playback, respecting
  Reduce Motion. Speed remains in More; rotation remains in the top bar.
- TDLib setup is guarded per client against duplicate initial state updates/queries;
  stale state-query responses and setup failures cannot replace newer login stages.
  Build credential validation and real OTP/password/email handlers remain intact.
- Reference: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
  and https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
