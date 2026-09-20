import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

/// Pulls frames from one source track, holding the most recent one so a caller
/// stepping output time never gets a gap. Screen is 60fps and variable, the
/// camera is 30fps and starts a second late; both are handled the same way.
final class TrackReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var current: CMSampleBuffer?
    /// Global time minus this is the track's own time.
    let offset: Double
    let size: CGSize
    private(set) var held = 0

    init(url: URL, offset: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "cutaway", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "no video track in \(url.lastPathComponent)"])
        }
        size = try await track.load(.naturalSize)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        self.offset = offset
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "cutaway", code: 21)
        }
        pending = output.copyNextSampleBuffer()
    }

    /// Must be called with non-decreasing `t`; the reader only moves forward.
    func pixelBuffer(at t: Double) -> CVPixelBuffer? {
        let local = t - offset
        guard local >= 0 else { return nil }
        var advanced = false
        while let p = pending,
              CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(p)) <= local + 1e-9 {
            current = p
            pending = output.copyNextSampleBuffer()
            advanced = true
        }
        if !advanced { held += 1 }
        return current.flatMap { CMSampleBufferGetImageBuffer($0) }
    }
}

/// Constant-frame-rate export driven by our own clock, so animation is smooth
/// even while the screen is perfectly still.
public enum Export {

    public static func run(recordingDir: URL,
                           outputSize: CGSize = CGSize(width: 1920, height: 1080),
                           fps: Int32 = 60,
                           timeline: Timeline? = nil,
                           preset: ExportPreset? = nil,
                           to url: URL) async throws {
        let preset = preset ?? ExportPreset(
            name: "custom", size: outputSize, fps: fps,
            codec: .hevc, bitrate: 12_000_000)

        let outputSize = preset.size
        let fps = preset.fps
        // GIFs are produced by encoding a video first, then quantising it.
        let videoTarget = preset.isGIF
            ? url.deletingPathExtension().appendingPathExtension("gifsrc.mp4")
            : url
        let manifest = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))
        let screenFile = manifest?.screen.file ?? "display.mov"

        let screen = try await TrackReader(
            url: recordingDir.appendingPathComponent(screenFile), offset: 0)
        var webcam: TrackReader?
        if let wc = manifest?.webcam {
            webcam = try? await TrackReader(
                url: recordingDir.appendingPathComponent(wc.file), offset: wc.offset)
        }
        let duration: Double
        if let d = manifest?.screen.duration {
            duration = d
        } else {
            let a = AVURLAsset(url: recordingDir.appendingPathComponent(screenFile))
            duration = CMTimeGetSeconds(try await a.load(.duration))
        }

        let project = loadOrCreateProject(recordingDir: recordingDir,
                                          screenSize: screen.size,
                                          duration: duration,
                                          hasWebcam: webcam != nil)
        let tl = timeline ?? project.timeline(
            sourceSize: screen.size, events: Events.load(from: recordingDir),
            sourceDuration: duration,
            transcript: Transcript.load(from: recordingDir))

        // a subtitle file beside the video, in edited time, because every
        // upload form asks for one and nobody wants to retype the words
        defer {
            if !preset.isGIF {
                Subtitles.write(recordingDir: recordingDir, timeMap: tl.timeMap, beside: url)
            }
        }
        if let override = preset.layoutOverride {
            tl.layouts = tl.layouts.merging(override) { _, new in new }
        }

        // Narration is synthesised before the video loop so its length can
        // extend the export when a line runs past the last frame.
        var voiceURL: URL?
        var voiceDuration = 0.0
        if let vo = project.voiceover, !vo.lines.isEmpty {
            let u = recordingDir.appendingPathComponent("voiceover.m4a")
            // Narration is authored against the edited timeline, so it is
            // rendered to the post-cut duration, not the raw one.
            let editedForVoice = tl.timeMap.outputDuration > 0
                ? tl.timeMap.outputDuration : duration
            voiceDuration = (try? await VoiceoverRenderer.render(
                vo, duration: editedForVoice, to: u)) ?? 0
            if voiceDuration > 0 { voiceURL = u }
        }
        // Cuts shorten the video; narration can lengthen it again.
        let editedDuration = tl.timeMap.outputDuration > 0
            ? tl.timeMap.outputDuration : duration
        let renderDuration = max(editedDuration, voiceDuration)

        // Recorded voice and system sound, retimed through the same cuts as
        // the picture, then mixed with any narration.
        let manifestForAudio = manifest ?? Manifest(
            screen: .init(file: screenFile, pixelSize: [screen.size.width, screen.size.height],
                          offset: 0, duration: duration, frames: 0), webcam: nil)
        let mixURL = try? await AudioMix.build(
            recordingDir: recordingDir, manifest: manifestForAudio,
            timeMap: tl.timeMap, settings: project.audio,
            voiceover: voiceURL, outputDuration: renderDuration,
            to: recordingDir.appendingPathComponent("mix.m4a"))
        let state = RenderState(screenSize: screen.size, webcamSize: webcam?.size,
                                outputSize: outputSize, timeline: tl)
        let engine = try RenderEngine()
        engine.loadBackgroundImage(path: tl.style.background.image)

        // Video first, audio muxed after. Feeding an audio input only once the
        // video is done makes AVAssetWriter stall waiting to interleave, so the
        // two are kept in separate passes.
        let videoURL = mixURL == nil ? videoTarget
            : videoTarget.deletingLastPathComponent()
                 .appendingPathComponent("." + videoTarget.lastPathComponent + ".video.mp4")
        try? FileManager.default.removeItem(at: videoTarget)
        try? FileManager.default.removeItem(at: videoURL)
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: preset.codec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        let total = max(1, Int(renderDuration * Double(fps)))
        var written = 0

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<total {
                    let outT = Double(i) / Double(fps)
                    // Everything downstream works in source time; only this
                    // line knows about cuts.
                    let t = tl.timeMap.sourceTime(forOutput: outT)
                    let f = state.evaluate(atSourceTime: t)

                    var layers: [RenderEngine.Draw] = []
                    if let sp = f.screen, let pb = screen.pixelBuffer(at: t),
                       let tex = engine.texture(from: pb) {
                        layers.append(.init(texture: tex, params: sp))
                    }
                    if let wp = f.webcam, let pb = webcam?.pixelBuffer(at: t),
                       let tex = engine.texture(from: pb) {
                        layers.append(.init(texture: tex, params: wp))
                    }

                    if let k = engine.keycastDraw(f, style: tl.keycastStyle,
                                                  outputSize: outputSize) {
                        layers.append(k)
                    }
                    if let c = engine.calloutDraw(f, theme: tl.calloutTheme,
                                                  outputSize: outputSize) {
                        layers.append(c)
                    }
                    if let cap = engine.captionDraw(f, timeline: tl,
                                                    outputSize: outputSize) {
                        layers.append(cap)
                    }

                    guard let pool = adaptor.pixelBufferPool else { continue }
                    var dst: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                          let dst else { continue }
                    guard engine.render(background: f.background, layers: layers,
                                        cursor: f.cursor, into: dst) else { continue }

                    while !input.isReadyForMoreMediaData { usleep(500) }
                    if adaptor.append(dst, withPresentationTime:
                                        CMTime(value: CMTimeValue(i), timescale: fps)) {
                        written += 1
                    }
                }
                input.markAsFinished()
                cont.resume()
            }
        }
        await writer.finishWriting()
        if let mixURL {
            try await mux(video: videoURL, audio: mixURL, to: videoTarget)
            try? FileManager.default.removeItem(at: videoURL)
        }

        if preset.isGIF {
            try await GIFEncoder.encode(video: videoTarget, to: url,
                                        fps: fps, width: Int(outputSize.width))
            try? FileManager.default.removeItem(at: videoTarget)
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        Log.line("""
          export[\(preset.name)]: \(written)/\(total) frames \(Int(outputSize.width))x\(Int(outputSize.height)) \
          @\(fps) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \
          \(String(format: "%.1f", Double(size) / 1_048_576)) MB, \
          webcam=\(webcam != nil ? "yes" : "no"), \
          segments=\(tl.timeMap.segments.count) (\(String(format: "%.2f", duration))s -> \(String(format: "%.2f", editedDuration))s), \
          audio=\(mixURL != nil ? "mixed" : "none")\
          \(voiceURL != nil ? String(format: " (vo %.1fs)", voiceDuration) : ""), \
          writer=\(writer.status.rawValue) \
          \(writer.error.map { "err=\($0.localizedDescription)" } ?? "")
          """)
    }

    /// Reads project.json, or writes a sensible default derived from the
    /// recording so there is always a file to edit.
    public static func loadOrCreateProject(recordingDir: URL, screenSize: CGSize,
                                           duration: Double, hasWebcam: Bool) -> Project {
        if let p = Project.load(from: recordingDir) { return p }
        let manifest = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))
            ?? Manifest(screen: .init(file: "display.mov",
                                      pixelSize: [screenSize.width, screenSize.height],
                                      offset: 0, duration: duration, frames: 0),
                        webcam: nil)
        let p = Project.makeDefault(recordingDir: recordingDir, manifest: manifest)
        if Project.exists(in: recordingDir) { return p }
        do {
            try p.write(to: recordingDir)
            Log.line("wrote default \(Project.filename)")
        } catch {
            Log.line("could not write \(Project.filename): \(error.localizedDescription)")
        }
        return p
    }

    /// Passthrough mux: no re-encode, so it costs a fraction of a second.
    static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)

        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "cutaway", code: 60) }
        let vDur = try await vAsset.load(.duration)
        try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)

        if let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio,
                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = try await aAsset.load(.duration)
            try aDst.insertTimeRange(CMTimeRange(start: .zero,
                                                 duration: min(aDur, vDur)),
                                     of: aTrack, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: comp,
                                                 presetName: AVAssetExportPresetPassthrough)
        else { throw NSError(domain: "cutaway", code: 61) }
        try? FileManager.default.removeItem(at: out)
        try await session.export(to: out, as: .mp4)
    }

    static func defaultTimeline(recordingDir: URL, screenSize: CGSize,
                                duration: Double, hasWebcam: Bool) -> Timeline {
        var clicks: [(t: Double, p: CGPoint)] = []
        var cursor: [(t: Double, p: CGPoint)] = []
        if let d = try? Data(contentsOf: recordingDir.appendingPathComponent("events.json")),
           let ev = try? JSONDecoder().decode(EventRecorder.Events.self, from: d) {
            clicks = ev.clicks.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
            cursor = ev.cursor.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        }
        let zooms = AutoZoom.generate(clicks: clicks, sourceSize: screenSize,
                                      duration: duration)
        let tl = Timeline(zooms: zooms, sourceSize: screenSize, cursor: cursor)

        // Open on the face, then hand over to the screen. This is the shape of
        // a pitch video; the editor will let you move the handover later.
        tl.scenes = hasWebcam
            ? [Scene(at: 0, layout: "talkingHead"),
               Scene(at: duration * 0.35, layout: "demo", transition: 0.8)]
            : [Scene(at: 0, layout: "screenOnly")]

        Log.line("timeline: \(zooms.count) zooms, \(tl.scenes.count) scenes " +
                 tl.scenes.map { String(format: "%@@%.2f", $0.layout, $0.at) }.joined(separator: " -> "))
        return tl
    }
}
