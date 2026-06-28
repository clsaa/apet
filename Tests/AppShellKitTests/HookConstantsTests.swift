import XCTest
@testable import AppShellKit

final class HookConstantsTests: XCTestCase {

    // MARK: - marker

    func test_marker_value() {
        XCTAssertEqual(HookConstants.marker, "apet-1")
    }
}
