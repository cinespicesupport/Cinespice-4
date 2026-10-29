# Cinespice design system

## Direction and identity

Spacious, artwork-led screens using native system typography and the supplied
red glass C identity. The app icon and `BrandMark` image are extracted from the
large light icon in the user's Design.jpeg board (620 × 620 crop, coordinates
72,52–692,672). The 1024 px icon is resized from that raster reference, not vector
artwork. Keep the original red artwork in every palette; do not recolor it.
Login and connection-loading screens show only the CINESPICE wordmark.

## Four palettes

| Palette | Background | Surface | Text | Secondary text | Accent | Action fill |
| --- | --- | --- | --- | --- | --- | --- |
| Cinespice Glass | `#F8F6F4` | `#FFFFFF` | `#171518` | `#68616A` | `#CC182A` | `#CC182A` |
| Cinespice Dark (default) | `#0B0B0F` | `#1C1C22` | `#F8F6F4` | `#B5AFB9` | `#FF6975` | `#B6111B` |
| Crimson Cinema | `#1B0D14` | `#311D27` | `#FBF3EC` | `#C5ADB6` | `#F3929E` | `#A32C44` |
| Silver Screen | `#14171C` | `#272C34` | `#F5F7FA` | `#B4BDC9` | `#D6DDE7` | `#D6DDE7` |

Action labels are white except on Silver Screen, where they use deep graphite.
Accents adjust the supplied red family for contrast. Shared tokens cover fields,
cards, lists, dialogs, navigation, metadata and actions. Playback remains black
with white controls and dark option surfaces; Glass uses its Dark companion there.

This intentionally replaces the previous five palettes. Saved `cinema` resolves
to Dark, `ember` to Crimson, `midnight` to Silver, and `pearl`/`sage` to Glass.
The preference key remains `cinespice.theme`; the picker offers exactly four
choices. Theme changes affect color only. Dark remains the default.

## Responsive sizing before effects

- Measure the current safe viewport, cap library content at 1200 pt, and derive
  grid columns from that content width rather than the full device screen.
- Shared screen gutters: 16 pt below 360 pt, 24 pt below 700 pt, then 32 pt.
  Poster gaps are 16 pt; sections have 28–32 pt separation.
- Grid columns use a Dynamic Type-scaled 136 pt minimum, from one to six columns.
  Portrait posters retain their 0.73 width/height ratio. Home rails remain
  horizontal, with up to 15 titles and an arrow to open each channel.
- Hero artwork height follows available width/orientation, within 200–440 pt.
  Titles, metadata and actions sit below it in a shared, Dynamic Type-scaled
  region. Empty and populated pages have equal height; long metadata scrolls
  within that region. No automatic carousel motion.
- Use system text styles. At accessibility sizes, phone fields, download rows,
  details and metadata rows stack; source filtering uses a native menu. System
  tab navigation retains all four accessible destinations.
- Touch targets remain at least 44 pt. Video Play graphics are compact pills;
  Info and the existing long-press menus retain their separate actions.
- Login, source sheets, details and the library can scroll. Do not squeeze
  content vertically to fit a screenshot.

## Player

Controls stay inside the safe viewport, including when video alone extends to
screen edges. Keep the timeline wide, with a centered transport group and evenly
spaced tools. A single icon row scrolls horizontally if the available width
cannot accommodate every 44-point target. Short viewports and accessibility
text can scroll the chrome. The original video gestures remain available.

Option panels fit the safe viewport, capped at 460 pt wide in portrait and 400 pt
in landscape. Their maximum height includes the header and padding. Long track
lists scroll; accessibility text uses one column of speed/more options. Audio
and subtitle delay controls retain decrease, increase and Reset actions.

Do not add unsupported VLC features or change the playback engine, track and
subtitle behavior, orientation handlers, download actions, or auto-hide timing.
Press feedback must continue to update the existing control-hide interaction state.

## Materials and motion

Native TabView owns the Home / Search / Library / Downloads navigation and its system materials.
The iOS version supplies its native tab appearance, materials and accessibility
adaptations. No custom glass API is required for tabs. Press feedback, native tab
motion and option-panel transitions respect Reduce Motion.
Posters and content use solid surfaces and restrained corners, without extra glass.

## Preserved contracts and verification

Keep all four tabs, seven hero positions, selected Telegram sources, per-launch
Home rail variation, Continue Watching order, saved lists, filename-year release
ordering, authentication stages and existing player actions. This is a UI
refinement within the current SwiftUI architecture.

Syntax parsing and asset checks do not establish SDK compilation, native
appearance or touch behavior. The required native build remains the existing
GitHub Actions iOS workflow. API ID/hash checks and app metadata checks remain.

## Apple references

- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Custom Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
