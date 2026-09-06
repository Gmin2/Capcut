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
