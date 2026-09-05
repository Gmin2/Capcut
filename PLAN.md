# Cutaway

A macOS screen recorder that produces demo videos which look designed rather than
captured. Working name, rename whenever.

Target output: a 60 to 120 second product demo with a gradient background, the
screen inset with rounded corners and a shadow, smooth automatic zooms that follow
where you click, dead air removed, private windows never captured at all.

---

## 1. The core principle

Capture is dumb. The editor is smart.

We record one clean, full resolution, unmodified screen video plus a separate
timeline of input events. Nothing is baked in. Every visual effect (background,
inset, corner radius, zoom, blur, cursor, cuts, speed) is a pure function applied
at render time over that raw footage.

Consequences that follow from this and drive every decision below:

- Zoom is a crop rect animated over a 4K+ source. At 1080p output a 2x zoom is
  still real pixels, not upscaled mush. This is the entire quality difference
  between this and OBS.
- Every edit is non destructive and reorderable. You can move a zoom keyframe a
  week later.
- The recorder must never drop frames doing compositing work. It writes raw
  frames to disk and nothing else.
- Preview and export must run the identical render code, or what you see is not
  what you get.

---

## 2. Stack decision

**Swift, AppKit + SwiftUI, ScreenCaptureKit, AVFoundation, Metal. One language,
one process, no IPC.**

The deciding factor is `AVVideoComposition` with a custom `AVVideoCompositing`.
You write one Metal compositor that turns (source frame, time) into an output
frame. Then:

- `AVPlayerItem.videoComposition = comp` gives you a real time scrubbable preview
  for free
- `AVAssetReader` + `AVAssetWriter` with the same composition gives you the export

Same code, both paths, frame exact. In a Tauri or Electron build you write the
preview twice: once in WebGL for the editor and once in Rust/wgpu or ffmpeg
filters for the export, and they drift. That is the trap.

Rejected alternatives, for the record:

| option | why not |
|---|---|
| Tauri + Rust + Swift capture sidecar | what Cap does. Faster UI iteration, but two render pipelines and an IPC boundary carrying 4K frames |
| Electron + getDisplayMedia | no window exclusion, no cursor metadata, no control over encoding, cursor is baked in |
| ffmpeg avfoundation capture | no per window filtering, no click events, no hardware path we control |

If the SwiftUI timeline UI becomes the bottleneck later, the escape hatch is a
`WKWebView` for the timeline only, with the video preview staying native
underneath. Do not start there.

Minimum target: macOS 14. Everything below assumes 15+ for mic capture, with a
fallback noted.

---

## 3. Architecture

Five modules, dependencies point downward only.

```
                 CutawayApp (SwiftUI)
                  /                \
          RecorderUI              EditorUI
              |                       |
        CaptureKit              RenderEngine
              \                    /      \
               \                  /      ExportService
                ProjectModel  <--/
```

**CaptureKit** owns `SCStream`, `AVAssetWriter`, and the event recorder. Its only
output is a finished project bundle on disk. It knows nothing about zooms or
backgrounds.

**ProjectModel** is the document. Plain Codable structs, no UIKit types, fully
serialisable. This is the single source of truth the renderer reads.

**RenderEngine** is `(ProjectModel, CMTime, source pixel buffer) -> pixel buffer`.
Pure. Metal. No file IO, no AVFoundation ownership. Wrapped by a
`CutawayCompositor: AVVideoCompositing` so AVFoundation can drive it.

**ExportService** wires reader, composition, writer, progress, cancellation.

**EditorUI** is the timeline, inspector, and an `AVPlayerLayer` preview.

### Why the compositor reads the model directly

The conventional approach stuffs per instruction parameters into
`AVVideoCompositionInstruction` objects. For continuously animated properties
that means thousands of instructions. Instead we use one instruction spanning the
whole asset, and the compositor computes everything from
`request.compositionTime` against a snapshot of the model. Editing a keyframe
means swapping the snapshot, not rebuilding the composition.

---

## 4. Data model

The project is an `NSFileWrapper` package so it opens as a single file in Finder.

```
MyDemo.cutaway/
  project.json
  raw/
    display.mov         ProRes 422 or HEVC, native resolution, no cursor
    system.m4a
    mic.m4a
    webcam.mov
  events.json
  thumbs/
```

### events.json

Written once at end of capture. Timestamps are seconds since capture start, on
the same host time clock as the video PTS (see section 6.2, this is the part that
silently breaks).

```json
{
  "version": 1,
  "startedAtHostTime": 918273645,
  "displayPixelSize": [3456, 2234],
  "displayPointSize": [1728, 1117],
  "backingScale": 2,
  "cursor": [
    { "t": 0.0000, "x": 1204, "y": 880 },
    { "t": 0.0083, "x": 1206, "y": 878 }
  ],
  "clicks": [
    { "t": 2.41, "x": 1204, "y": 880, "button": "left", "kind": "down", "clickCount": 1 }
  ],
  "keys": [
    { "t": 5.02, "chars": "cmd+S", "isModifier": false }
  ],
  "apps": [
    { "t": 0.0, "bundleId": "com.apple.Terminal", "name": "Terminal" }
  ],
  "markers": [
    { "t": 34.2, "kind": "pause" },
    { "t": 41.9, "kind": "resume" }
  ]
}
```

Cursor is sampled on a fixed 120 Hz timer rather than from move events, so the
array is a regular grid and interpolation is trivial. All coordinates are in
capture pixel space, origin top left.

### project.json

```json
{
  "version": 1,
  "source": { "video": "raw/display.mov", "size": [3456, 2234], "fps": 60 },
  "output": { "size": [1920, 1080], "fps": 60 },

  "background": {
    "kind": "gradient",
    "stops": [ { "at": 0, "color": "#2E1065" }, { "at": 1, "color": "#0B1120" } ],
    "angle": 135
  },

  "plate": {
    "padding": 0.06,
    "cornerRadius": 14,
    "shadow": { "opacity": 0.45, "radius": 60, "yOffset": 24 },
    "borderWidth": 1,
    "borderColor": "#FFFFFF22"
  },

  "segments": [
    { "sourceStart": 0.0,  "sourceEnd": 34.2, "speed": 1.0 },
    { "sourceStart": 41.9, "sourceEnd": 96.5, "speed": 1.0 },
    { "sourceStart": 96.5, "sourceEnd": 104.0, "speed": 4.0 }
  ],

  "zooms": [
    {
      "id": "z1",
      "start": 12.4, "end": 19.8,
      "inDuration": 0.45, "outDuration": 0.6,
      "level": 2.0,
      "follow": { "mode": "cursor", "damping": 0.06, "deadzone": 60 },
      "anchor": [0.42, 0.61]
    }
  ],

  "masks": [
    { "start": 22.0, "end": 30.0, "rect": [0.7, 0.02, 0.28, 0.09], "style": "mosaic", "strength": 24 }
  ],

  "cursor": {
    "visible": true, "scale": 1.6, "smoothing": 0.35,
    "clickEffect": "ripple", "hideWhenIdle": 2.0
  },

  "webcam": { "enabled": false, "shape": "circle", "corner": "bottomRight", "size": 0.18 },
  "keycast": { "enabled": true, "position": "bottomCenter", "holdFor": 1.4 },

  "audio": { "system": 0.6, "mic": 1.0, "duckSystemUnderMic": true }
}
```

Times in `zooms`, `masks`, `keycast` are in **source time**, not output time. The
segment list maps source to output. Keeping effects in source time means cutting a
segment does not require rewriting every keyframe.

---

## 5. Phases

Each phase ends with something runnable. Do not start a phase before the previous
one demos.

### Phase 0 - skeleton and permissions

Xcode app target, hardened runtime, stable bundle id, signed with a real
Developer ID or Apple Development cert (see section 7, ad hoc signing will cost
you an hour a day in re granted permissions). Info.plist usage strings. A window
with a Record button that calls `SCShareableContent` and prints the display list.

Done when: the permission prompt appears once, is granted once, and survives a
rebuild.

### Phase 1 - capture MVP

`SCStream` to `AVAssetWriter`. Display picker. Start, stop. Writes
`raw/display.mov` at native pixel resolution, 60fps, cursor hidden.

Done when: a 30 second recording plays in QuickTime at full resolution with
correct timing and no dropped frames.

### Phase 2 - event recorder

120 Hz cursor sampler, global click monitor, app activation observer. Optional
key monitor behind Input Monitoring permission. Writes `events.json`.

Done when: you can overlay the logged cursor path onto the video in a throwaway
script and it lines up within one frame at both ends. This alignment check is the
whole point of the phase, do not skip it.

### Phase 3 - render engine, static

Metal pipeline: background gradient, screen plate inset with corner radius and
drop shadow. No animation yet. Drive it from a `CutawayCompositor` and render a
still frame to a PNG.

Done when: one frame out of the compositor looks like a finished thumbnail.

### Phase 4 - preview and shell UI

`AVPlayer` + `AVPlayerLayer` with the composition attached. Transport controls,
scrubber, a timeline strip with thumbnails.

Done when: you can scrub a real recording and watch it composited in real time.

### Phase 5 - zoom

Crop rect math, easing, cursor following with damping and deadzone. Manual
keyframe creation and dragging in the timeline.

Done when: a hand placed zoom feels good enough that you would ship the video.

### Phase 6 - auto zoom

Click clustering into zoom keyframes. This is the feature that makes the tool
feel expensive: record normally, open the editor, the zooms are already there.

Done when: on a real 90 second recording, auto zoom needs three or fewer manual
corrections.

### Phase 7 - cuts, pause, speed

Segment editing. Pause markers become cuts. Auto detect dead air (no input for
more than 2s) and offer cut or 4x. Time mapping between source and output time.

Done when: a recording with a 40 second interruption exports as if it never
happened, and zoom keyframes stay attached to the right moments.

### Phase 8 - privacy

Window exclusion in the recorder (via `SCContentFilter`, nothing sensitive ever
enters a frame) and post hoc mosaic/blur rects in the editor for what you missed.

Done when: recording with a private window open produces footage where that
window does not exist.

### Phase 9 - cursor and keycast

Smoothed interpolated cursor drawn at render time, scaled up, with a click
ripple. Keystroke overlay.

Done when: the rendered cursor moves better than the real one did.

### Phase 10 - export

`AVAssetReader` to `AVAssetWriter` through the composition. Presets: 1080p and
4K, H.264 and HEVC, plus a GIF path via a palette pass. Progress and cancel.

Done when: export is deterministic and matches the preview frame for frame.

### Later, not now

Webcam PIP, background images and video, multi display, audio ducking, captions,
templates, a shareable link.

---

## 6. The hard parts

### 6.1 Capture configuration

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: true)
guard let display = content.displays.first else { return }

// exclude anything the user marked private
let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

let config = SCStreamConfiguration()
// native pixels, not points. display.width is in points.
let scale = NSScreen.screens.first { $0.displayID == display.displayID }?
    .backingScaleFactor ?? 2
config.width  = Int(CGFloat(display.width)  * scale)
config.height = Int(CGFloat(display.height) * scale)
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.colorSpaceName = CGColorSpace.sRGB
config.showsCursor = false          // we draw our own later
config.queueDepth = 8               // >= 6 or SCStream drops frames
config.capturesAudio = true
config.captureMicrophone = true     // macOS 15+, else use AVCaptureSession

let stream = SCStream(filter: filter, configuration: config, delegate: self)
try stream.addStreamOutput(self, type: .screen,     sampleHandlerQueue: videoQueue)
try stream.addStreamOutput(self, type: .audio,      sampleHandlerQueue: audioQueue)
try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
try await stream.startCapture()
```

Codec choice for the intermediate: screen content is sharp text, and HEVC 4:2:0
chroma subsampling puts colour fringes on it. On Apple Silicon Pro/Max/Ultra
there is hardware ProRes encode, so default to `AVVideoCodecType.proRes422` when
available and fall back to HEVC at a deliberately high bitrate (40 Mbps at 1440p,
80 at 4K). ProRes files are large. That is acceptable for an intermediate that
gets deleted after export.

In the `didOutputSampleBuffer` callback, check the frame status attachment and
skip anything that is not `.complete`. ScreenCaptureKit sends idle frames.

### 6.2 Clock alignment (the one that silently breaks everything)

`SCStream` sample buffer presentation timestamps are on the host time clock.
Cursor samples taken with a `Timer` and stamped with `Date()` are on the wall
clock. They drift, and worse, they have a fixed unknown offset. Your zooms end up
half a second behind your clicks and you will spend a day blaming the easing.

Stamp everything with the same clock:

```swift
let hostClock = CMClockGetHostTimeClock()
func now() -> CMTime { CMClockGetTime(hostClock) }
```

Record `captureStart = now()` when the first video sample arrives (not when you
call `startCapture`, there is a warmup), and store every event as
`CMTimeGetSeconds(now() - captureStart)`.

Verify it in Phase 2 by clicking a stopwatch on screen at known moments and
checking the logged click times against the frames.

### 6.3 Coordinate spaces

Three spaces, converted in exactly one place each:

1. **AppKit screen points** - `NSEvent.mouseLocation`, origin bottom left of the
   main display, y up.
2. **Capture pixels** - origin top left, y down, multiplied by backing scale.
3. **Normalised source** - 0..1, what project.json stores, resolution independent.

```swift
func toCapturePixels(_ p: NSPoint, screen: NSScreen, scale: CGFloat) -> CGPoint {
    let f = screen.frame
    return CGPoint(x: (p.x - f.minX) * scale,
                   y: (f.maxY - p.y) * scale)   // flip y
}
```

Write this once, in one file, and never do the flip inline anywhere else.

### 6.4 Cursor sampling

Do not derive position from `.mouseMoved` events. They are irregular, they stop
entirely when the pointer is still, and the global monitor misses movement over
some system surfaces. Sample instead:

```swift
// 120 Hz, no permission required
let timer = DispatchSource.makeTimerSource(queue: samplerQueue)
timer.schedule(deadline: .now(), repeating: .milliseconds(8))
timer.setEventHandler { [weak self] in
    let p = NSEvent.mouseLocation          // needs no TCC permission
    self?.appendCursorSample(t: self!.elapsed(), point: p)
}
```

Clicks come from `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,
.rightMouseDown, .leftMouseUp])`, which also needs no permission. Only
`.keyDown` requires Input Monitoring, so keycast is an opt in feature gated
behind its own prompt, requested lazily the first time it is enabled.

### 6.5 The compositor

```swift
final class CutawayCompositor: NSObject, AVVideoCompositing {

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    // swapped atomically when the user edits; never mutated in place
    static let state = Atomic<RenderState?>(nil)

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        guard let state = Self.state.load(),
              let trackID = req.sourceTrackIDs.first?.int32Value,
              let src = req.sourceFrame(byTrackID: trackID),
              let dst = req.renderContext.newPixelBuffer() else {
            req.finish(with: CompositorError.noFrame); return
        }
        let t = CMTimeGetSeconds(req.compositionTime)
        let params = state.evaluate(atSourceTime: t)   // pure function
        renderer.draw(source: src, into: dst, params: params)
        req.finish(withComposedVideoFrame: dst)
    }

    func renderContextChanged(_ ctx: AVVideoCompositionRenderContext) { }
}
```

`state.evaluate(at:)` is the piece to unit test hardest. It is pure, takes a
model and a time, returns a flat struct of numbers, and is the only place
animation logic lives. If a zoom looks wrong, it is wrong here, not in the shader.

Everything AVFoundation calls here happens on its own queues, possibly several
concurrently. The Metal renderer needs a command queue per thread or a lock, and
`state` must be immutable once published.

### 6.6 Zoom math

```
source size      S = (sw, sh)
zoom level       z >= 1
focus (norm)     c = (cx, cy)

crop size        (sw/z, sh/z)
crop origin      clamp(c*S - cropSize/2, to: [0, S - cropSize])
```

The clamp is what stops the camera swinging off the edge of the screen when you
click near a corner, and it must be applied after smoothing, not before.

**Easing.** A zoom keyframe has an in ramp, a hold, and an out ramp. Use a cubic
bezier close to `(0.32, 0.72, 0, 1)` for the in and something gentler for the
out. Linear zooms look mechanical, and `easeInOut` overshoots visually because
scale is perceived logarithmically. Interpolate `log(z)`, not `z`:

```swift
let z = exp(mix(log(z0), log(z1), ease(progress)))
```

**Cursor following.** Inside a zoom, the focus point tracks the cursor, but never
1:1, which is nauseating. One pole low pass filter plus a deadzone:

```swift
let raw = cursorPosition(at: t)
if hypot(raw.x - focus.x, raw.y - focus.y) > deadzone {
    target = raw
}
focus = focus + (target - focus) * damping   // damping ~0.06 at 60fps
```

The deadzone (about 60 source pixels) is what stops the frame breathing while you
hover in place. Both numbers need to be tuneable in the inspector because the
right value depends on zoom level.

### 6.7 Auto zoom from clicks

```
1. take clicks, drop rapid double clicks down to one event
2. greedily cluster: same cluster if dt < 2.5s AND distance < 400 source pt
3. drop clusters whose span would be shorter than 0.8s
4. merge clusters whose gap is under 1.0s
5. for each cluster:
     start   = firstClick - 0.4
     end     = lastClick  + 1.2
     anchor  = centroid of clicks
     spread  = bounding box of clicks
     level   = clamp(min(sw, sh) / (max(spread) * 2.2), 1.4, 2.5)
6. never let two zooms overlap; if they do after step 4, extend the earlier one
```

Tune this on real footage, not synthetic. The failure mode is over zooming during
a burst of clicks in a form, which step 5 handles by widening the level based on
spatial spread.

Also worth generating from events: dead air segments (no click, key, or cursor
movement above a threshold for over 2s) become suggested cuts in Phase 7.

### 6.8 Cuts and time mapping

Segments define output time from source time. Build an `AVMutableComposition`,
insert each segment's time range, and apply `scaleTimeRange(_:toDuration:)` for
speed changes. Then attach the video composition on top.

The renderer works in **source** time, so it needs the inverse map:

```swift
func sourceTime(forOutput t: Double) -> Double
```

Keep this as a small monotonic lookup table built once per edit. Every effect
lookup goes through it. Getting this wrong is what makes zooms drift after a cut.

Audio needs the same treatment, and sped up audio should be dropped or pitch
corrected rather than played back as chipmunks.

### 6.9 Export

Do not use `AVAssetExportSession`. Use reader plus writer so you get real
progress, cancellation, and bitrate control:

```
AVAssetReader (composition + videoComposition)
  -> AVAssetReaderVideoCompositionOutput
  -> AVAssetWriterInput (HEVC or H.264, hardware)
  -> AVAssetWriter
```

Export must be the same composition object the preview used. Assert on output
size, fps, and colour space, and diff one frame from each path in a test.

---

## 7. Permissions and signing

| capability | permission | prompt trigger |
|---|---|---|
| screen capture | Screen Recording (TCC) | first `SCShareableContent` call |
| system audio | covered by Screen Recording | none |
| mic | `NSMicrophoneUsageDescription` | first mic capture |
| webcam | `NSCameraUsageDescription` | first camera use |
| keystrokes | Input Monitoring | first `.keyDown` global monitor |

Entitlements: hardened runtime on, App Sandbox **off** for now (sandbox plus
screen recording plus writing project bundles anywhere is a fight worth having
only if you go to the App Store). Add `com.apple.security.device.audio-input` and
`com.apple.security.device.camera`.

The single biggest dev annoyance: TCC keys grants by code signature. Ad hoc
signing (`-`) produces a new signature every build, so macOS re prompts, or worse,
silently returns empty content. Sign with a stable Apple Development identity from
day one and keep the bundle id fixed. If permissions get into a bad state:

```
tccutil reset ScreenCapture com.yourorg.cutaway
```

---

## 8. Risks, ranked

1. **Clock drift between video and events.** Highest impact, easiest to miss.
   Mitigated in 6.2, verified explicitly in Phase 2.
2. **Dropped frames under load.** The capture path must do nothing but append.
   No compositing, no thumbnailing, no UI updates from the sample queue. Watch
   `queueDepth` and log every dropped frame status.
3. **Preview and export diverging.** Prevented structurally by sharing the
   composition. Add a frame diff test in Phase 10 before you trust it.
4. **Zoom feel.** Not an engineering risk, a taste risk. Budget real time in
   Phase 5 for tuning on actual footage, and expose damping, deadzone and easing
   in the UI so tuning does not need a rebuild.
5. **File size.** ProRes at 4K60 is roughly 2 GB per minute. Offer HEVC as the
   default for long recordings and delete raw media after a confirmed export.
6. **Retina and multi display coordinates.** Contained by doing conversions in
   exactly one file.

---

## 9. Rough schedule

Evenings and weekends, solo.

| | phases | outcome |
|---|---|---|
| week 1 | 0, 1, 2 | records clean video plus aligned event data |
| week 2 | 3, 4 | composited scrubbable preview with background and plate |
| week 3 | 5, 6 | zooms, automatic and manual. This is the demo moment |
| week 4 | 7, 8 | cuts, dead air removal, privacy |
| week 5 | 9, 10 | cursor, keycast, export presets |

Phase 6 is the point where the tool becomes worth using. If time runs short,
ship phases 0 through 6 plus a crude export and skip everything else.

---

## 10. First thing to build

Phase 0 and 1 together, in one sitting: a single window, a display picker, a
record button, and a file on disk. Everything else in this document depends on
having real footage to look at.
