# Driving Cutaway from a script

Everything the app does is scriptable. The CLI is the same binary as the app, so
it inherits the same screen-recording permission.

```
cutaway record --seconds 30 --out ~/demos/pitch
cutaway describe --in ~/demos/pitch
# edit ~/demos/pitch/project.json
cutaway export --in ~/demos/pitch --out ~/demos/pitch.mp4
```

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
| `audio` | `{mic, system, voiceover, duckSystemUnderVoice}` |
| `style.background` | `{from, to, angle}` |

`cutaway voices` lists installed speech voices.

## What the recorder writes

```
display.mov       native resolution, cursor excluded
webcam.mov        camera, if enabled
mic.m4a           narration
events.json       cursor at 120Hz, clicks, app switches
transcript.json   on-device, word timestamps
recording.json    track sizes, durations and inter-track offsets
project.json      the edit
```

`events.json` plus `transcript.json` describe a recording completely in text,
which is what makes editing possible without looking at pixels.
