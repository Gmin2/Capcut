# Driving Cutaway from a script

Everything the app does is scriptable. The CLI is the same binary as the app, so
it inherits the same screen-recording permission.

```
cutaway record --seconds 30 --out ~/demos/pitch --keys
cutaway describe --in ~/demos/pitch
# edit ~/demos/pitch/project.json
cutaway export --in ~/demos/pitch --out ~/demos/pitch.mp4
cutaway export --in ~/demos/pitch --preset vertical --out ~/demos/reel.mp4
cutaway export --in ~/demos/pitch --all --out ~/demos/pitch.mp4
cutaway pack --in ~/demos/pitch --out ~/demos/pitch.cutaway
cutaway trim --in ~/demos/pitch.cutaway
```

`pack` wraps a recording into a single `.cutaway` file in Finder (it is a
package, so `project.json` inside stays hand-editable). `trim` deletes the raw
capture once an export is approved, which is most of the size.

## Presets

| name | |
|---|---|
| `1080p` | 1920x1080 HEVC, the default |
| `4k` | 3840x2160 HEVC |
| `h264` | 1920x1080 H.264, for anything that will not take HEVC |
| `vertical` | 1080x1920, reframed for portrait |
| `square` | 1080x1080 |
| `gif` | 960x540 at 15fps, two-pass palette |

Vertical and square do not letterbox: they carry their own layouts, so the
screen fills the width and the camera sits below it rather than both shrinking.
`--all` writes every preset next to the output path.

`~/.local/bin/cutaway` is symlinked on every build. Put that on your PATH.

## The loop an agent runs

1. `cutaway describe --in DIR --json` returns duration, clicks, cuts, zooms,
   scenes and the transcript. Nothing needs decoding a video frame.
2. Rewrite `project.json`. Times are seconds in **source** time, so cutting a
   segment never invalidates a keyframe.
3. `cutaway export`.

If the app is open on that directory it hot-reloads the file, so you can watch
the edit change as you write it.

## project.json

| field | |
|---|---|
| `scenes` | `{at, layout, transition}`; layouts are `talkingHead`, `demo`, `sideBySide`, `screenOnly` |
| `zooms` | `{start, end, level, inDuration, outDuration, anchor, follow}` |
| `segments` | kept spans `{sourceStart, sourceEnd, speed}`; omitted time is cut |
| `voiceover` | `{engine, voice, rate, lines: [{at, text}]}`, synthesised on device |
| `cursor` | `{visible, scale, smoothing, clickRipple, rippleRadius}` |
| `keycast` | `{visible, position, holdFor, mergeWindow, maxChips, fontSize}` |
| `audio` | `{mic, system, voiceover, duckSystemUnderVoice}` |
| `style.background` | `{from, to, angle}` |

`cutaway voices` lists installed speech voices.

## What the recorder writes

```
display.mov       native resolution, cursor excluded
webcam.mov        camera, if enabled
mic.m4a           narration
events.json       cursor at 120Hz, clicks, app switches, keystrokes
transcript.json   on-device, word timestamps
recording.json    track sizes, durations and inter-track offsets
project.json      the edit
```

`events.json` plus `transcript.json` describe a recording completely in text,
which is what makes editing possible without looking at pixels.

## Keystroke overlay

`--keys` logs keystrokes so the renderer can show them. It needs **Input
Monitoring**, which macOS only applies on the next launch:

    System Settings > Privacy & Security > Input Monitoring > Cutaway

Without the grant, recording carries on and simply logs no keys. Typing merges
into words; chords like ⌘⇧P stay whole, because the chord is the interesting
event and the letter is not.

## Overlays and framing

| field | |
|---|---|
| `callouts` | `[{at, duration, text, subtitle, style}]` - `lowerThird`, `center`, `topLeft`, `topCenter`, `bottomCenter` |
| `deviceFrame` | `none`, `macWindow`, `browser` - chrome drawn around the screen |
| `masks` | `[{rect, start, end, style, strength}]` - `mosaic` or `blur`, rect normalised to the source |
| `motionBlur` | 0 off, 0.85 default, roughly a film shutter |

Masks are in source coordinates, so a hidden region stays on the thing it hides
while the camera zooms and pans. Window exclusion at capture time is still
better where you know in advance.
