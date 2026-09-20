import XCTest
import CoreGraphics
@testable import CutawayCore

/// Tests for the pure decision logic: the parts that decide what a frame looks
/// like, independent of Metal, AVFoundation and permissions.
///
/// These exist because the alternative is exporting a video and measuring
/// pixels, which is slow enough that bugs survive. The zoom ramp bug below is
/// a real one that shipped and was only caught by chance.
final class TimeMapTests: XCTestCase {

    func testIdentityWhenNoSegments() {
        let m = TimeMap(segments: [], sourceDuration: 10)
        XCTAssertTrue(m.isIdentity)
        XCTAssertEqual(m.outputDuration, 10, accuracy: 0.001)
        XCTAssertEqual(m.sourceTime(forOutput: 4), 4, accuracy: 0.001)
    }

    func testCutRemovesTime() {
        // Keep 0-2 and 6-10: four seconds are cut out of the middle.
        let m = TimeMap(segments: [
            Segment(sourceStart: 0, sourceEnd: 2),
            Segment(sourceStart: 6, sourceEnd: 10),
        ], sourceDuration: 10)
        XCTAssertEqual(m.outputDuration, 6, accuracy: 0.001)
        XCTAssertEqual(m.sourceTime(forOutput: 1), 1, accuracy: 0.001)
        // Just past the cut, output 2 lands on source 6.
        XCTAssertEqual(m.sourceTime(forOutput: 2.001), 6, accuracy: 0.01)
        XCTAssertEqual(m.sourceTime(forOutput: 5), 9, accuracy: 0.001)
    }

    func testSpeedRampCompresses() {
        let m = TimeMap(segments: [
            Segment(sourceStart: 0, sourceEnd: 4, speed: 4),
        ], sourceDuration: 4)
        XCTAssertEqual(m.outputDuration, 1, accuracy: 0.001)
        XCTAssertEqual(m.sourceTime(forOutput: 0.5), 2, accuracy: 0.001)
    }

    func testRoundTrip() {
        let m = TimeMap(segments: [
            Segment(sourceStart: 0, sourceEnd: 3),
            Segment(sourceStart: 5, sourceEnd: 9, speed: 2),
        ], sourceDuration: 9)
        for source in [0.5, 2.9, 5.1, 7.0, 8.9] {
            guard let out = m.outputTime(forSource: source) else {
                XCTFail("source \(source) should map into the output")
                continue
            }
            XCTAssertEqual(m.sourceTime(forOutput: out), source, accuracy: 0.01,
                           "source -> output -> source must be stable")
        }
    }

    func testCutMaterialHasNoOutputTime() {
        let m = TimeMap(segments: [
            Segment(sourceStart: 0, sourceEnd: 2),
            Segment(sourceStart: 6, sourceEnd: 10),
        ], sourceDuration: 10)
        XCTAssertNil(m.outputTime(forSource: 4), "4s was cut, so it has no output time")
    }
}

final class TrimTests: XCTestCase {

    func testTrimClipsSegments() {
        var p = Project()
        p.trimStart = 1.2
        p.trimEnd = 4.0
        let segs = p.trimmedSegments(sourceDuration: 5.33)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].sourceStart, 1.2, accuracy: 0.001)
        XCTAssertEqual(segs[0].sourceEnd, 4.0, accuracy: 0.001)
    }

    /// The case verified by export earlier: trim and a speed ramp must compose.
    func testTrimComposesWithSpeedRamp() {
        var p = Project()
        p.trimStart = 1.2
        p.trimEnd = 4.0
        p.segments = [
            Segment(sourceStart: 0, sourceEnd: 2.0),
            Segment(sourceStart: 2.0, sourceEnd: 3.0, speed: 4),
            Segment(sourceStart: 3.0, sourceEnd: 5.33),
        ]
        let m = TimeMap(segments: p.trimmedSegments(sourceDuration: 5.33),
                        sourceDuration: 5.33)
        // (2.0-1.2) + (1.0/4) + (4.0-3.0) = 0.8 + 0.25 + 1.0
        XCTAssertEqual(m.outputDuration, 2.05, accuracy: 0.01)
    }

    func testTrimBeyondEndIsHarmless() {
        var p = Project()
        p.trimStart = 0
        p.trimEnd = 999
        XCTAssertEqual(p.trimmedSegments(sourceDuration: 5).count, 1)
    }
}

final class ZoomTests: XCTestCase {

    private func timeline(_ zooms: [Zoom]) -> Timeline {
        Timeline(zooms: zooms, sourceSize: CGSize(width: 1000, height: 1000), cursor: [])
    }

    func testLevelIsOneOutsideTheBlock() {
        let tl = timeline([Zoom(start: 2, end: 4, level: 2)])
        XCTAssertEqual(tl.level(at: 1.9, zoom: tl.zooms[0]), 1, accuracy: 0.001)
        XCTAssertEqual(tl.level(at: 4.1, zoom: tl.zooms[0]), 1, accuracy: 0.001)
    }

    func testLevelReachesTargetInTheHold() {
        var z = Zoom(start: 0, end: 4, level: 2.5)
        z.inDuration = 0.5
        z.outDuration = 0.5
        let tl = timeline([z])
        XCTAssertEqual(tl.level(at: 2, zoom: z), 2.5, accuracy: 0.001)
    }

    /// The shipped bug: ramps longer than the block used to overlap, and where
    /// they crossed the level jumped instead of ramping.
    ///
    /// Told apart from a merely fast ramp by sampling twice as finely: a real
    /// discontinuity keeps the same size however closely you look, while a
    /// steep ramp halves. Checking a fixed step size instead would just be
    /// measuring how fast the zoom is.
    func testShortBlockRampsAreContinuous() {
        var z = Zoom(start: 2.0, end: 2.6, level: 2.5)   // 0.6s block
        z.inDuration = 0.45
        z.outDuration = 0.6                              // 1.05s of ramps
        let tl = timeline([z])

        func worstStep(sampling dt: Double) -> Double {
            var previous = tl.level(at: 2.0, zoom: z)
            var worst = 0.0
            var t = 2.0
            while t <= 2.6 {
                let level = tl.level(at: t, zoom: z)
                worst = max(worst, abs(level - previous))
                previous = level
                t += dt
            }
            return worst
        }

        let coarse = worstStep(sampling: 1.0 / 60.0)
        let fine = worstStep(sampling: 1.0 / 480.0)
        XCTAssertLessThan(fine, coarse * 0.5,
                          "sampling 8x finer must shrink the largest step; "
                          + "a step that survives is a jump, not a ramp")
    }

    func testLevelIsMonotonicThroughTheRampIn() {
        var z = Zoom(start: 0, end: 4, level: 3)
        z.inDuration = 1.0
        let tl = timeline([z])
        var previous = 0.0
        var t = 0.0
        while t <= 1.0 {
            let level = tl.level(at: t, zoom: z)
            XCTAssertGreaterThanOrEqual(level, previous - 0.0001,
                                        "ramp in must never go backwards")
            previous = level
            t += 0.02
        }
    }

    func testCropStaysInsideTheSource() {
        var z = Zoom(start: 0, end: 4, level: 3)
        z.anchor = [0.02, 0.98]   // hard against a corner
        z.follow = nil
        let tl = timeline([z])
        let crop = tl.crop(at: 2)
        XCTAssertGreaterThanOrEqual(crop.minX, -0.001)
        XCTAssertGreaterThanOrEqual(crop.minY, -0.001)
        XCTAssertLessThanOrEqual(crop.maxX, 1000.001)
        XCTAssertLessThanOrEqual(crop.maxY, 1000.001)
    }
}

final class EasingTests: XCTestCase {

    func testBezierEndpoints() {
        let e = CubicBezier.zoomIn
        XCTAssertEqual(e.solve(0), 0, accuracy: 0.001)
        XCTAssertEqual(e.solve(1), 1, accuracy: 0.001)
    }

    func testBezierIsMonotonic() {
        let e = CubicBezier.zoomIn
        var previous = -1.0
        for i in 0...100 {
            let v = e.solve(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 0.0001)
            previous = v
        }
    }
}

final class ColourTests: XCTestCase {

    func testHexParsing() {
        let white = Style.rgba("#FFFFFF")
        XCTAssertEqual(white.x, 1, accuracy: 0.01)
        XCTAssertEqual(white.w, 1, accuracy: 0.01, "missing alpha means opaque")

        let half = Style.rgba("#00000080")
        XCTAssertEqual(half.w, 0.502, accuracy: 0.01)
    }

    func testMalformedHexDoesNotCrash() {
        _ = Style.rgba("nonsense")
        _ = Style.rgba("#12")
        _ = Style.rgba("")
    }
}

final class AutoZoomTests: XCTestCase {

    func testNoClicksMeansNoZooms() {
        XCTAssertTrue(AutoZoom.generate(clicks: [], sourceSize: CGSize(width: 100, height: 100),
                                        duration: 10).isEmpty)
    }

    func testNearbyClicksBecomeOneZoom() {
        let clicks = [(t: 1.0, p: CGPoint(x: 500, y: 500)),
                      (t: 1.8, p: CGPoint(x: 520, y: 510)),
                      (t: 2.4, p: CGPoint(x: 505, y: 495))]
        let zooms = AutoZoom.generate(clicks: clicks,
                                      sourceSize: CGSize(width: 2000, height: 2000),
                                      duration: 10)
        XCTAssertEqual(zooms.count, 1, "clicks close in time and space are one intent")
    }

    func testDistantClicksBecomeSeparateZooms() {
        let clicks = [(t: 1.0, p: CGPoint(x: 100, y: 100)),
                      (t: 8.0, p: CGPoint(x: 1900, y: 1900))]
        let zooms = AutoZoom.generate(clicks: clicks,
                                      sourceSize: CGSize(width: 2000, height: 2000),
                                      duration: 10)
        XCTAssertEqual(zooms.count, 2)
    }

    func testZoomsNeverOverlap() {
        let clicks = (0..<12).map { i in
            (t: Double(i) * 0.9, p: CGPoint(x: Double(i) * 150, y: 500))
        }
        let zooms = AutoZoom.generate(clicks: clicks,
                                      sourceSize: CGSize(width: 2000, height: 2000),
                                      duration: 20)
        for (a, b) in zip(zooms, zooms.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 0.001,
                                     "overlapping zooms fight and look like a glitch")
        }
    }

    func testLevelStaysInRange() {
        let clicks = [(t: 1.0, p: CGPoint(x: 10, y: 10)),
                      (t: 1.5, p: CGPoint(x: 1990, y: 1990))]
        let zooms = AutoZoom.generate(clicks: clicks,
                                      sourceSize: CGSize(width: 2000, height: 2000),
                                      duration: 10)
        for z in zooms {
            XCTAssertGreaterThanOrEqual(z.level, 1.4)
            XCTAssertLessThanOrEqual(z.level, 2.5)
        }
    }
}

final class AutoCutTests: XCTestCase {

    func testNoActivityKeepsEverything() {
        let segs = AutoCut.segments(events: Events(), transcript: nil, duration: 10)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].sourceEnd, 10, accuracy: 0.001)
    }

    func testQuietMiddleIsCompressed() {
        var e = Events()
        e.clicks = [(t: 0.5, p: .zero), (t: 9.5, p: .zero)]
        let segs = AutoCut.segments(events: e, transcript: nil, duration: 10)
        let output = segs.reduce(0.0) { $0 + ($1.sourceEnd - $1.sourceStart) / $1.speed }
        XCTAssertLessThan(output, 10, "a long silent middle should shorten the video")
        XCTAssertGreaterThan(output, 0, "but it must not remove everything")
    }

    func testSegmentsStayInOrderAndInRange() {
        var e = Events()
        e.clicks = [(t: 1.0, p: .zero), (t: 5.0, p: .zero), (t: 9.0, p: .zero)]
        let segs = AutoCut.segments(events: e, transcript: nil, duration: 10)
        for s in segs {
            XCTAssertGreaterThanOrEqual(s.sourceStart, -0.001)
            XCTAssertLessThanOrEqual(s.sourceEnd, 10.001)
            XCTAssertLessThanOrEqual(s.sourceStart, s.sourceEnd)
        }
        for (a, b) in zip(segs, segs.dropFirst()) {
            XCTAssertLessThanOrEqual(a.sourceStart, b.sourceStart)
        }
    }
}

final class ProjectDecodingTests: XCTestCase {

    /// Every new feature adds a field. An older project file must keep working,
    /// which the synthesised decoder does not do.
    func testMinimalProjectDecodes() throws {
        let json = Data("""
        {"version": 1, "scenes": [{"at": 0, "layout": "screenOnly", "transition": 0.6}]}
        """.utf8)
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.scenes.count, 1)
        XCTAssertEqual(p.motionBlur, 0.85, accuracy: 0.001, "missing fields take defaults")
        XCTAssertTrue(p.zooms.isEmpty)
    }

    func testEmptyObjectDecodes() throws {
        let p = try JSONDecoder().decode(Project.self, from: Data("{}".utf8))
        XCTAssertEqual(p.version, 1)
    }

    func testRoundTrip() throws {
        var p = Project()
        p.zooms = [Zoom(start: 1, end: 2, level: 2)]
        p.trimStart = 0.5
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.zooms.count, 1)
        XCTAssertEqual(back.trimStart, 0.5, accuracy: 0.001)
    }
}

final class HistoryTests: XCTestCase {

    private func project(trim: Double) -> Project {
        var p = Project()
        p.trimStart = trim
        return p
    }

    func testNothingToUndoInitially() {
        let h = History()
        XCTAssertFalse(h.canUndo)
        XCTAssertNil(h.undo(current: project(trim: 0)))
    }

    func testUndoReturnsThePreviousState() {
        let h = History()
        let first = project(trim: 0)
        h.record(first)
        let second = project(trim: 1)
        guard let back = h.undo(current: second) else { return XCTFail("undo failed") }
        XCTAssertEqual(back.trimStart, 0, accuracy: 0.001)
    }

    func testRedoReturnsTheUndoneState() {
        let h = History()
        h.record(project(trim: 0))
        let second = project(trim: 1)
        guard let back = h.undo(current: second) else { return XCTFail("undo failed") }
        XCTAssertTrue(h.canRedo)
        guard let forward = h.redo(current: back) else { return XCTFail("redo failed") }
        XCTAssertEqual(forward.trimStart, 1, accuracy: 0.001)
    }

    func testWalkingBackThroughSeveralEdits() {
        let h = History()
        for i in 0..<4 { h.record(project(trim: Double(i))) }
        var current = project(trim: 4)
        for expected in [3.0, 2.0, 1.0, 0.0] {
            guard let previous = h.undo(current: current) else {
                return XCTFail("ran out of history at \(expected)")
            }
            XCTAssertEqual(previous.trimStart, expected, accuracy: 0.001)
            current = previous
        }
        XCTAssertFalse(h.canUndo)
    }

    /// The rule every editor follows: editing after an undo throws away the
    /// branch you had undone.
    func testNewEditClearsRedo() {
        let h = History()
        h.record(project(trim: 0))
        _ = h.undo(current: project(trim: 1))
        XCTAssertTrue(h.canRedo)
        h.record(project(trim: 5))
        XCTAssertFalse(h.canRedo)
    }

    /// Restoring a state must not itself become a step, or undo would toggle
    /// between two states forever.
    func testReplayDoesNotRecord() {
        let h = History()
        h.record(project(trim: 0))
        let before = h.depth.undo
        h.replay { h.record(project(trim: 9)) }
        XCTAssertEqual(h.depth.undo, before)
    }

    func testHistoryIsBounded() {
        let h = History(limit: 3)
        for i in 0..<10 { h.record(project(trim: Double(i))) }
        XCTAssertEqual(h.depth.undo, 3, "old steps are dropped rather than grown forever")
    }
}

final class HistoryGroupTests: XCTestCase {

    /// A drag sends many edits. It must still undo in one step.
    func testGroupedEditsUndoInOneStep() {
        let h = History()
        var p = Project()
        h.beginGroup()
        for trim in stride(from: 0.0, through: 0.8, by: 0.2) {
            h.record(p)
            p.trimStart = trim
        }
        h.endGroup()
        guard let back = h.undo(current: p) else { return XCTFail("nothing to undo") }
        XCTAssertEqual(back.trimStart, 0, accuracy: 0.001, "one undo returns to before the drag")
        XCTAssertFalse(h.canUndo)
    }

    func testRecordingResumesAfterAGroup() {
        let h = History()
        h.beginGroup()
        h.record(Project())
        h.record(Project())
        h.endGroup()
        h.record(Project())
        XCTAssertEqual(h.depth.undo, 2)
    }
}

final class SceneDecodingTests: XCTestCase {

    func testSceneWithoutTransitionStillDecodes() throws {
        let json = #"{"scenes": [{"at": 0, "layout": "talkingHead"}]}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.scenes.count, 1)
        XCTAssertEqual(p.scenes.first?.layout, "talkingHead")
        XCTAssertEqual(p.scenes.first?.transition ?? 0, 0.6, accuracy: 0.001)
    }
}

final class AutoCutSafetyTests: XCTestCase {

    /// A talking-head take has no clicks and, without a mic, no transcript.
    /// Cutting "idle" time there removes the whole recording.
    func testSilentTakeWithNoClicksIsLeftWhole() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Manifest(screen: .init(file: "display.mov", pixelSize: [1920, 1080],
                                              offset: 0, duration: 160, frames: 9600),
                                webcam: .init(file: "webcam.mov", pixelSize: [1920, 1080],
                                              offset: 0, duration: 160, frames: 4800))
        let p = Project.makeDefault(recordingDir: dir, manifest: manifest)
        XCTAssertTrue(p.segments.isEmpty, "no speech and no clicks means no cutting")
    }
}

final class CaptureGeometryTests: XCTestCase {

    /// The screen is y-up with the origin bottom left; a capture region is
    /// y-down from the top of its display. Getting this backwards captures the
    /// mirror image of what was dragged.
    @MainActor
    func testSelectionConvertsToDisplayLocal() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let dragged = NSRect(x: 100, y: 800, width: 400, height: 100)
        let local = SelectionOverlay.local(dragged, on: screen)
        XCTAssertEqual(local.minX, 100, accuracy: 0.001)
        XCTAssertEqual(local.minY, 82, accuracy: 0.001, "982 - (800 + 100)")
        XCTAssertEqual(local.width, 400, accuracy: 0.001)
    }

    @MainActor
    func testSelectionOnASecondScreenIsRelativeToThatScreen() {
        let screen = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let dragged = NSRect(x: 1612, y: 80, width: 200, height: 200)
        let local = SelectionOverlay.local(dragged, on: screen)
        XCTAssertEqual(local.minX, 100, accuracy: 0.001)
        XCTAssertEqual(local.minY, 800, accuracy: 0.001)
    }
}

final class FrameTests: XCTestCase {

    func testPaddingGrowsTheExportOnBothSides() {
        var f = Frame()
        f.padding = 80
        let image = CGSize(width: 1200, height: 800)
        let content = CGSize(width: image.width + f.padding * 2, height: image.height + f.padding * 2)
        XCTAssertEqual(content.width, 1360)
        XCTAssertEqual(content.height, 960)
    }

    func testStepMarkIsRoundAroundItsPoint() {
        let m = Mark(tool: .step, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100),
                     color: .red, width: 4, text: "", number: 1)
        let b = m.bounds(scale: 1)
        XCTAssertEqual(b.midX, 100, accuracy: 0.001)
        XCTAssertEqual(b.midY, 100, accuracy: 0.001)
        XCTAssertEqual(b.width, b.height, accuracy: 0.001)
    }
}

final class StitchTests: XCTestCase {

    /// A tall page, sliced into overlapping screenfuls the way scrolling gives
    /// them, has to come back as the same page.
    private func page(height: Int, width: Int = 400) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // rows of text-like bars, never repeating, so every row is telling apart
        for i in 0..<(height / 20) {
            NSColor(white: Double(i % 17) / 20.0, alpha: 1).setFill()
            NSRect(x: 20, y: i * 20 + 4, width: 40 + (i * 37) % 320, height: 10).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private func slice(_ image: CGImage, top: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height))!
    }

    func testOverlapFindsHowFarThePageScrolled() {
        let tall = page(height: 1200)
        let first = slice(tall, top: 0, height: 400)
        let second = slice(tall, top: 260, height: 400)   // scrolled 260 rows
        let repeated = Stitch.overlap(first, second)
        XCTAssertNotNil(repeated)
        XCTAssertEqual(repeated ?? 0, 140, accuracy: 2, "400 - 260 rows are the same")
    }

    func testFramesJoinBackIntoTheWholePage() {
        let tall = page(height: 1200)
        let frames = [slice(tall, top: 0, height: 400),
                      slice(tall, top: 300, height: 400),
                      slice(tall, top: 600, height: 400),
                      slice(tall, top: 800, height: 400)]
        let joined = Stitch.vertical(frames)
        XCTAssertNotNil(joined)
        XCTAssertEqual(joined?.width, 400)
        XCTAssertEqual(Double(joined?.height ?? 0), 1200, accuracy: 4)
    }

    func testAStillPageAddsNothing() {
        let tall = page(height: 800)
        let same = slice(tall, top: 0, height: 400)
        let joined = Stitch.vertical([same, same, same])
        XCTAssertEqual(joined?.height, 400, "nothing moved, so there is nothing to add")
    }
}

final class ShotNamingTests: XCTestCase {

    /// Two captures in the same second used to land on the same name, and the
    /// second one quietly replaced the first.
    func testASecondCaptureInTheSameSecondGetsItsOwnName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("CUTAWAY_SHOTS", dir.path, 1)
        defer { unsetenv("CUTAWAY_SHOTS") }

        let first = Paths.newShot()
        try Data("x".utf8).write(to: first)
        let second = Paths.newShot()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
}
