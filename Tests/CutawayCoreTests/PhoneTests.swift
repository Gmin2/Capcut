import XCTest
@testable import CutawayCore

final class PhoneTests: XCTestCase {

    // straight from `getevent -pl` on the Pixel 9 emulator, trimmed
    let emulatorCaps = """
    add device 1: /dev/input/event12
      name:     "qwerty2"
    add device 2: /dev/input/event1
      name:     "virtio_input_multi_touch_1"
      events:
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 10, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_X     : value 0, min 0, max 32767, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_Y     : value 0, min 0, max 32767, fuzz 0, flat 0, resolution 0
    add device 3: /dev/input/event0
      name:     "gpio-keys"
    """

    func testCapabilitiesGiveTheTouchAxesOnly() {
        let axes = GetEventParser.axes(fromCapabilities: emulatorCaps)
        XCTAssertEqual(axes.count, 1)
        XCTAssertEqual(axes["/dev/input/event1"]?.x, 0...32767)
        XCTAssertEqual(axes["/dev/input/event1"]?.y, 0...32767)
    }

    func testEmulatorTapLandsOnTheScreenPixel() {
        var p = GetEventParser(screen: CGSize(width: 1080, height: 2424),
                               axes: GetEventParser.axes(fromCapabilities: emulatorCaps))
        let lines = [
            "[      32.305634] /dev/input/event1: EV_ABS       ABS_MT_TRACKING_ID   00000000",
            "[      32.305634] /dev/input/event1: EV_ABS       ABS_MT_POSITION_X    00003fff",
            "[      32.305634] /dev/input/event1: EV_ABS       ABS_MT_POSITION_Y    00003f5d",
            "[      32.305634] /dev/input/event1: EV_SYN       SYN_REPORT           00000000",
        ]
        var taps: [Tap] = []
        for (i, l) in lines.enumerated() {
            if let t = p.feed(l, received: 1000 + Double(i) * 0.001) { taps.append(t) }
        }
        XCTAssertEqual(taps, [Tap(t: 32.305634, x: 540, y: 1200)])
        XCTAssertEqual(p.clockOffset ?? 0, 1000 - 32.305634, accuracy: 1e-6)
    }

    func testMovingFingerIsOneTapAndLiftEndsIt() {
        var p = GetEventParser(screen: CGSize(width: 1080, height: 2400),
                               axes: ["/dev/input/event2": .init(x: 0...1079, y: 0...2399)])
        func feed(_ t: Double, _ code: String, _ v: String) -> Tap? {
            p.feed(String(format: "[%12.6f] /dev/input/event2: EV_ABS       %@    %@", t, code, v))
        }
        XCTAssertNil(feed(1.0, "ABS_MT_TRACKING_ID", "0000002a"))
        XCTAssertNil(feed(1.0, "ABS_MT_POSITION_X", "00000064"))
        XCTAssertNil(feed(1.0, "ABS_MT_POSITION_Y", "000000c8"))
        XCTAssertNotNil(feed(1.0, "SYN_REPORT", "00000000"))
        // a drag: more positions and reports, but no new tap
        XCTAssertNil(feed(1.1, "ABS_MT_POSITION_Y", "00000190"))
        XCTAssertNil(feed(1.1, "SYN_REPORT", "00000000"))
        XCTAssertNil(feed(1.2, "ABS_MT_TRACKING_ID", "ffffffff"))
        XCTAssertNil(feed(1.2, "SYN_REPORT", "00000000"))
        // the next touch is a new tap, even without fresh coordinates
        XCTAssertNil(feed(2.0, "ABS_MT_TRACKING_ID", "0000002b"))
        let second = feed(2.0, "SYN_REPORT", "00000000")
        XCTAssertEqual(second?.t, 2.0)
        XCTAssertEqual(second?.y ?? 0, 400, accuracy: 1)
    }

    func testSimulatorClickMapsThroughTheTitleBar() {
        // a 17 Pro at half size: 603x1311 of screen plus a 28pt title bar
        let w = SimulatorWindow(bounds: CGRect(x: 100, y: 50, width: 603, height: 1311 + 28),
                                screen: CGSize(width: 1206, height: 2622))
        XCTAssertTrue(w.isBareScreen)
        XCTAssertEqual(w.titleBar, 28, accuracy: 0.01)
        XCTAssertEqual(w.pixel(for: CGPoint(x: 100 + 301.5, y: 50 + 28 + 655.5)),
                       CGPoint(x: 603, y: 1311))
        XCTAssertNil(w.pixel(for: CGPoint(x: 300, y: 60)), "title bar is not the screen")
    }

    func testSimulatorWithBezelIsRefused() {
        let w = SimulatorWindow(bounds: CGRect(x: 0, y: 0, width: 700, height: 1400),
                                screen: CGSize(width: 1206, height: 2622))
        XCTAssertFalse(w.isBareScreen)
        XCTAssertNil(w.pixel(for: CGPoint(x: 350, y: 700)))
    }

    func testChunksJoinEndToEnd() {
        let c = ChunkClock(chunks: [.init(start: 100, end: 280), .init(start: 280.4, end: 290.4)])
        XCTAssertEqual(c.duration, 190, accuracy: 1e-9)
        XCTAssertEqual(c.videoTime(forHost: 150) ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(c.videoTime(forHost: 285.4) ?? -1, 185, accuracy: 1e-9)
        XCTAssertNil(c.videoTime(forHost: 280.2), "between chunks nothing was recorded")
        XCTAssertNil(c.videoTime(forHost: 99))
    }

    func testMarksPairIntoSnippets() {
        let s = PhoneRecorder.snippets(from: [1, 4, 6, 6.1, 9], duration: 12)
        XCTAssertEqual(s.map(\.start), [1, 9], "a pair too short to post is dropped")
        XCTAssertEqual(s.map(\.end), [4, 12], "an open one runs to the end")
    }
}

final class SnippetTests: XCTestCase {

    let screen = CGSize(width: 1080, height: 2424)

    func testOnlyNameAndRangeAreRequired() throws {
        let json = #"{"snippets": [{"name": "send", "start": 1, "end": 5}]}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let s = try XCTUnwrap(p.snippets.first)
        XCTAssertEqual(s.look, .framed)
        XCTAssertEqual(s.canvas, .feed)
        XCTAssertEqual(s.loop, .crossfade)
        XCTAssertNil(s.background)
    }

    func testOldProjectsStillLoad() throws {
        let json = #"{"cursor": {"visible": false}}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertTrue(p.snippets.isEmpty)
        XCTAssertFalse(p.cursor.touches)
        XCTAssertEqual(p.cursor.scale, 1.7)
    }

    func testSlugIsSafeForAFileName() {
        XCTAssertEqual(Snippet(name: "Guard adds margin!", start: 0, end: 1).slug, "guard-adds-margin")
        XCTAssertEqual(Snippet(name: "///", start: 0, end: 1).slug, "snippet")
    }

    func testBareKeepsTheScreenShapeAtEvenSize() {
        let s = Snippet(name: "a", start: 0, end: 1, look: .bare)
        XCTAssertEqual(s.outputSize(screen: CGSize(width: 1206, height: 2622)),
                       CGSize(width: 1080, height: 2348))
        XCTAssertEqual(Snippet(name: "a", start: 0, end: 1).outputSize(screen: screen),
                       CGSize(width: 1080, height: 1350))
    }

    func testPhoneIsCentredAndFits() {
        for canvas in Snippet.Canvas.allCases {
            let r = Snippet.phoneRect(screen: screen, canvas: canvas.size)
            XCTAssertEqual(r[0] * 2 + r[2], 1, accuracy: 1e-9)
            XCTAssertEqual(r[1] * 2 + r[3], 1, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(r[2], 0.8 + 1e-9)
            XCTAssertLessThanOrEqual(r[3], 0.8 + 1e-9)
            // the screen keeps its shape on any canvas
            XCTAssertEqual(r[2] * canvas.size.width / (r[3] * canvas.size.height),
                           screen.width / screen.height, accuracy: 1e-6)
        }
    }

    func testApplyTrimsToTheSnippetAndKeepsTheZooms() {
        var base = Project()
        base.zooms = [Zoom(start: 2, end: 3, level: 2)]
        base.segments = [Segment(sourceStart: 0, sourceEnd: 1)]
        base.deviceFrame = .iphone
        let s = Snippet(name: "a", start: 1.5, end: 4, background: "paper")
        let p = s.apply(to: base, screen: screen)
        XCTAssertEqual(p.trimStart, 1.5)
        XCTAssertEqual(p.trimEnd, 4)
        XCTAssertTrue(p.segments.isEmpty, "the snippet is its own cut")
        XCTAssertEqual(p.zooms.count, 1)
        XCTAssertEqual(p.deviceFrame, .iphone)
        XCTAssertEqual(p.style.background.from, Style.presets["paper"]?.from)
        let tl = p.timeline(sourceSize: screen, events: Events(), sourceDuration: 10)
        XCTAssertEqual(tl.timeMap.outputDuration, 2.5, accuracy: 1e-9)
    }

    func testLoopFadeEndsOnTheFirstFrame() {
        XCTAssertEqual(SnippetExport.loopFade(duration: 4), 0.5)
        XCTAssertEqual(SnippetExport.loopFade(duration: 1.5), 0.3, accuracy: 1e-9)
        XCTAssertEqual(SnippetExport.loopFade(duration: 1), 0, "too short to blend")
        let f = SnippetExport.loopFilter(duration: 4, fade: 0.5)
        XCTAssertTrue(f.contains("trim=0:0.500"))
        XCTAssertTrue(f.contains("offset=3.000"))
    }

    func testTouchSitsInsideTheBezel() throws {
        var project = Project.makePhone(
            manifest: Manifest(screen: .init(file: "display.mp4", pixelSize: [1080, 2424],
                                             offset: 0, duration: 5, frames: 300)),
            kind: .android, dir: URL(fileURLWithPath: "/nonexistent"))
        project.scenes = [Scene(at: 0, layout: "phone", transition: 0)]
        var events = Events()
        events.clicks = [(t: 1, p: CGPoint(x: 0, y: 0))]
        let tl = project.timeline(sourceSize: screen, events: events, sourceDuration: 5)
        let out = project.output.size
        let state = RenderState(screenSize: screen, webcamSize: nil, outputSize: out, timeline: tl)
        let f = state.evaluate(atSourceTime: 1.05)
        let touch = try XCTUnwrap(f.cursor)
        let sp = try XCTUnwrap(f.screen)
        // the screen's top left corner, not the bezel's
        XCTAssertEqual(touch.ripplePos.x, sp.dst.x + sp.frameBar, accuracy: 0.5)
        XCTAssertEqual(touch.ripplePos.y, sp.dst.y + sp.frameBar, accuracy: 0.5)
        XCTAssertEqual(touch.opacity, 0, "no pointer on a phone")
        XCTAssertNil(state.evaluate(atSourceTime: 2).cursor, "gone once it fades")
    }

    func testPhoneZoomsMergeCloseTapsAndLookAtThem() {
        let clicks: [(t: Double, p: CGPoint)] = [(1, CGPoint(x: 540, y: 700)),
                                                 (2.5, CGPoint(x: 300, y: 2000)),
                                                 (8, CGPoint(x: 540, y: 1200))]
        let z = AutoZoom.phone(clicks: clicks, sourceSize: screen, duration: 10)
        XCTAssertEqual(z.count, 2, "taps 1.5s apart share a zoom")
        XCTAssertEqual(z[0].start, 0.55, accuracy: 1e-9)
        XCTAssertEqual(z[0].end, 3.8, accuracy: 1e-9)
        XCTAssertNil(z[0].follow)
        XCTAssertEqual(z[1].anchor[1], 1200 / 2424, accuracy: 1e-9)
    }

    func testPhoneCameraPansBetweenTapsAndKeepsThePhoneFilling() throws {
        var project = Project.makePhone(
            manifest: Manifest(screen: .init(file: "display.mp4", pixelSize: [1080, 2424],
                                             offset: 0, duration: 10, frames: 600)),
            kind: .android, dir: URL(fileURLWithPath: "/nonexistent"))
        var events = Events()
        events.clicks = [(t: 1, p: CGPoint(x: 540, y: 300)), (t: 2.5, p: CGPoint(x: 540, y: 2200))]
        project.zooms = AutoZoom.phone(clicks: events.clicks, sourceSize: screen, duration: 10)
        let tl = project.timeline(sourceSize: screen, events: events, sourceDuration: 10)
        let out = project.output.size
        let state = RenderState(screenSize: screen, webcamSize: nil, outputSize: out, timeline: tl)

        let still = try XCTUnwrap(state.evaluate(atSourceTime: 0.2).screen)
        let early = try XCTUnwrap(state.evaluate(atSourceTime: 1.6).screen)
        let late = try XCTUnwrap(state.evaluate(atSourceTime: 3.2).screen)
        XCTAssertGreaterThan(early.dst.w, still.dst.w * 1.5, "pushed in on the whole phone")
        XCTAssertEqual(early.src.z, still.src.z, "the picture inside is never cropped")
        // looking at the top tap, then panned to the bottom one
        XCTAssertGreaterThan(early.dst.y + early.dst.w, Float(out.height))
        XCTAssertLessThan(late.dst.y, early.dst.y)
        // the phone still covers the frame top to bottom
        for f in [early, late] {
            XCTAssertLessThanOrEqual(f.dst.y, 0.5)
            XCTAssertGreaterThanOrEqual(f.dst.y + f.dst.w, Float(out.height) - 0.5)
        }
    }
}
