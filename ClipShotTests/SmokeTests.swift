import XCTest
@testable import ClipShot

@MainActor
final class SmokeTests: XCTestCase {
    func testHostHasNoAppModel() {
        XCTAssertNil(ClipShotApp.makeModel(environment: ["XCTestConfigurationFilePath": "x"]))
        XCTAssertNotNil(ClipShotApp.makeModel(environment: [:]))
    }

    func testBundleIdentifierIsDebug() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "sk.moravcik.ClipShot.debug")
    }

    func testEventuallyReturnsTrueWhenConditionHolds() async {
        let ok = await eventually(timeout: .seconds(1)) { true }
        XCTAssertTrue(ok)
    }
}
