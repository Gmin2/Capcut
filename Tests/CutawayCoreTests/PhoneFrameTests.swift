import XCTest
@testable import CutawayCore

final class PhoneFrameTests: XCTestCase {
    func testPhoneBezelGrowsThePlateOnEverySide() {
        var placement = Placement(rect: [0, 0, 1, 1], cornerRadius: 40)
        placement.frame = .phone
        let p = placement.layerParams(sourceSize: CGSize(width: 1080, height: 2424),
                                      outputSize: CGSize(width: 1080, height: 2424))
        let bezel = 1080 * Placement.phoneBezel
        XCTAssertEqual(p.frameKind, 3)
        XCTAssertEqual(p.frameBar, bezel, accuracy: 0.01)
        XCTAssertEqual(p.dst.x, -bezel, accuracy: 0.01)
        XCTAssertEqual(p.dst.y, -bezel, accuracy: 0.01)
        XCTAssertEqual(p.dst.z, 1080 + bezel * 2, accuracy: 0.01)
        XCTAssertEqual(p.dst.w, 2424 + bezel * 2, accuracy: 0.01)
        XCTAssertEqual(p.cornerRadius, 40 + bezel, accuracy: 0.01)
    }

    func testLayoutInProjectOnlyNeedsTheFieldsThatDiffer() throws {
        let json = """
        {"deviceFrame": "phone",
         "layouts": {"phone": {"screen": {"rect": [0.1, 0.05, 0.8, 0.9], "cornerRadius": 90}}},
         "scenes": [{"at": 0, "layout": "phone"}]}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.deviceFrame, .phone)
        let screen = try XCTUnwrap(project.layouts["phone"]?.screen)
        XCTAssertEqual(screen.cornerRadius, 90)
        XCTAssertEqual(screen.fit, "contain")
        XCTAssertEqual(screen.shadowRadius, 70)

        let tl = project.timeline(sourceSize: CGSize(width: 1080, height: 2424), events: Events())
        XCTAssertNotNil(tl.layouts["phone"])
        XCTAssertNotNil(tl.layouts["screenOnly"], "built in layouts stay available")
    }
}
