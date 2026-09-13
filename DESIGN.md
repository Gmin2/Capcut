# Cutaway design system

Taken from two reference shots: a light recording setup screen and a dark
player/editor. Every colour below was sampled from the reference pixels, not
picked by eye. Text colours come from the darkest (light theme) or brightest
(dark theme) pixel inside the glyph strokes, so they are the real ink colour
and not an anti-aliased edge.

## What the two references agree on

- neutral greys with no hue tint. no blue-grey, no warm grey
- controls are filled, not outlined. a border only ever means selected or focused
- one accent colour, used sparingly: selection, the playhead, a slider fill
- soft corners everywhere, big on containers and smaller on controls
- text is never pure black on light or pure white on dark, except the one number
  you should look at first (the current time)
- lots of air. panels breathe, rows are tall, nothing is cramped

## Colour

| token | light | dark | used for |
|---|---|---|---|
| `canvas` | `#FFFFFF` | `#232323` | window background, centre column |
| `panel` | `#F8F8F8` | `#272727` | sidebars, grouped containers |
| `inset` | `#F2F2F2` | `#2D2D2D` | wells inside a panel: ruler, waveform, transcript |
| `fill` | `#EDEDED` | `#343434` | buttons, chips, dropdowns, idle cards |
| `fillHover` | `#E5E5E5` | `#3B3B3B` | hover on anything filled |
| `fillSelected` | `#E4F1F7` | `#414141` | a selected card |
| `badge` | `#E2E2E2` | `#3E3E3E` | number squares in lists |
| `divider` | `#E6E6E6` | `#303030` | hairlines between sections |
| `textPrimary` | `#333333` | `#EDEDED` | titles, button labels, values |
| `textStrong` | `#1F1F1F` | `#FFFFFF` | the current time, the one thing to read first |
| `textSecondary` | `#636363` | `#A0A0A0` | meta, totals, transcript body |
| `textTertiary` | `#8A8A8A` | `#7B7B7B` | ruler numbers, placeholder |
| `icon` | `#696969` | `#7D7D7D` | line icons |
| `accent` | `#00B4FF` | `#FFAA00` | selection, playhead, slider fill, handles |
| `accentBorder` | `#3FB2E6` | `#FFAA00` | focused controls, selected list rows |
| `cardOutline` | `#3FB2E6` | `#A6A6A6` | a selected card. neutral in dark, per the reference |
| `onAccent` | `#FFFFFF` | `#1A1A1A` | text sitting on the accent |
| `record` | `#F2493F` | `#F2493F` | the record dot, and nothing else |
| `waveform` | `#DADADA` | `#3B3B3B` | unplayed waveform |
| `track` | `#E0E0E0` | `#3A3A3A` | slider and toggle track when off |

The accent is sky blue in the light reference and amber in the dark one. That is
kept as-is here, but it is a single token, so it is a one line change if one
colour should carry across both themes.

## Type

System font (SF Pro). The references are set in an Inter-like grotesk and SF is
close enough to read the same while staying native. All numbers that change,
like times and sizes, use monospaced digits so they do not jitter.

| style | size | weight | used for |
|---|---|---|---|
| `time` | 22 | semibold | current playback time |
| `title` | 15 | semibold | recording title, panel heading |
| `body` | 13 | regular | buttons, labels, list rows |
| `bodyStrong` | 13 | medium | selected tab, row time |
| `meta` | 12 | regular | resolution, fps, dates |
| `caption` | 11 | medium | section labels, ruler numbers, badges |

## Shape

| token | value | used for |
|---|---|---|
| `radiusPanel` | 12 | sidebars, the control bar, the preview |
| `radiusCard` | 8 | recording cards, list rows, dropdowns |
| `radiusControl` | 6 | buttons, chips, badges, tabs |
| `borderSelected` | 1.5 | the only border weight in the system |

## Spacing

4pt grid. `2 4 8 12 16 24`. Panel padding 12, gaps between controls 8, gaps
between sections 16.

## Components

Everything on screen is built from these, so the two themes stay consistent.

- **button** filled, icon plus label, `radiusControl`
- **split button** a button with a divider and a chevron: start recording
- **icon button** square filled button holding one icon
- **play button** the one inverted control: dark ink on light fill in dark mode
- **chip** small filled label, optionally with an app icon
- **badge** number in a filled square, turns accent when its row is selected
- **tabs** segmented, the selected tab gets `fill`, idle tabs have none
- **toggle** pill track with a knob, accent when on
- **dropdown** filled pill with a chevron, accent border when focused
- **slider pill** label, track and value in one filled pill
- **card** selectable; selected gets `fillSelected` plus a `cardOutline`
- **list row** badge, time, title; selected gets an `accentBorder`
- **section header** small icon plus a caption label
- **ruler and playhead** tick marks, numbers, an accent line with a numbered tab
- **waveform** smooth filled shape, the played or selected part in accent

## Icons

Line icons from the local Nucleo `ui` and `core` sets, drawn as template images
so they take the `icon` colour in either theme. Play, pause and skip are drawn
as plain shapes because the library has no media glyphs.
