# Driving Cutaway from a script

## Recording a clean take

Start and stop with the global hotkeys so the Cutaway window is never in shot:

| | |
|---|---|
| `⌘⇧8` | start / stop recording |
| `⌘⇧9` | pause / resume |

The window hides itself and a 3 second countdown runs before capture begins, so
you have time to get to the right app. Put `0` in
`~/Library/Application Support/Cutaway/countdown` to disable it.

## Editing on the timeline

| | |
|---|---|
| drag a zoom block | move it |
| drag either end | change when it starts or stops |
| double-click the zoom lane | add a zoom there |
| alt-click a zoom | delete it |
| up / down arrow | zoom level of the block under the playhead |
| drag a scene marker | move the handover point |
| double-click the scenes lane | add a scene change |
| drag the yellow ends | trim the top and tail |

Every one of these rewrites `project.json`, so a UI edit and a scripted edit are
the same operation and neither can get out of step with the other.

## Choosing a display

    cutaway displays                      # ids, sizes, which is main
    cutaway record --display 2

With no `--display` it records the screen with the menu bar. Note that
`displays.first` is not the main display on a multi-monitor Mac, so passing an
id is worth doing when you have two.

## Keeping things out of shot

    cutaway windows                                  # find bundle ids
    cutaway record --exclude com.brave.Browser,notion.id
    cutaway record --only com.apple.Terminal

`--exclude` keeps an app's windows out of the capture entirely: the pixels never
exist, so there is nothing to leak even if you share the raw file. `--only`
captures a single app instead of the whole display. Both beat masking after the
fact, which is only for what you did not think of in advance.

## Undo

Command-Z and shift-command-Z, or the buttons in the transport. Every edit is a
whole-file write of project.json, so history is a stack of previous documents
rather than a set of inverse operations -- undo cannot be wrong, because there
are no inverses to get wrong.

## Where things live

Each take gets its own dated folder in `~/Movies/Cutaway/`, so recordings
accumulate rather than overwriting each other. `Latest` is a symlink to the
newest, which is what commands use when you give no `--in`.

    cutaway list                                  # every take, newest first
    cutaway record --name "pitch take 3"          # name it yourself

Set `CUTAWAY_HOME` to keep them somewhere else.

## Tests

    swift test

28 tests over the pure decision logic: the time map, trim composition, zoom
ramps, auto-zoom clustering, dead-air detection and project decoding. They run
in about 5ms and need no permissions, camera or GPU, which is the point -- the
alternative is exporting a video and measuring pixels, and that is slow enough
that bugs survive.

## Start here

    cutaway doctor

Checks every permission and dependency and says how to fix whatever is missing.
macOS permissions fail quietly - a denied grant looks exactly like an empty
display list - so run this first whenever something silently does nothing.

## Making a pitch video

    cutaway record --seconds 60 --out ~/demos/pitch --keys
    cutaway pitch --in ~/demos/pitch --name "Your Name" --role "Your Role"
    cutaway export --in ~/demos/pitch --out ~/demos/pitch.mp4

`pitch` writes a project.json shaped like a pitch video: webcam opening, handover
to the screen, lower third, auto zooms from your clicks, device frame. Edit the
file from there; the app reloads it as you save.


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
| `trimStart` / `trimEnd` | top and tail, in source seconds; `trimEnd` omitted runs to the end |
| `voiceover` | `{engine, voice, rate, lines: [{at, text}]}`, synthesised on device |
| `cursor` | `{visible, scale, smoothing, clickRipple, rippleRadius}` |
| `captions` | `{enabled, wordsPerCue, fontSize, highlightSpoken, highlight, bottomMargin}` |
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

## Captions

    cutaway transcribe --in DIR      # writes transcript.json
    # then set captions.enabled in project.json

Built from the word timestamps already in `transcript.json`, with the spoken
word highlighted as it is said. Most demo videos are watched on mute, so this
does more for reach than any visual effect.

Transcription runs on device. It is reliable on real speech and unreliable on
synthesised narration, which it sometimes hears as nothing at all -- the command
says so rather than writing an empty transcript that looks successful.

## Backgrounds

`backgroundPreset` is shorthand for the whole `style.background` block:

| preset | |
|---|---|
| `midnight` | purple to near-black, the default |
| `slate` | neutral grey-blue |
| `ember` | warm red to black |
| `forest` | deep teal |
| `paper` | light, with grain |
| `ink` | flat near-black |
| `screen` | the recording itself, blurred and dimmed behind the plate |

`screen` is worth knowing about: the backdrop is taken from the footage, so it
always matches the shot. For anything else, set `style.background` directly with
`kind` (`gradient`, `solid`, `blurredScreen`, `image`), `from`, `to`, `angle`,
`grain` and `dim`. `kind: "image"` reads `style.background.image` as a path.
