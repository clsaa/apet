import XCTest
@testable import AgentPetCore

/// 纯函数 `PetDisplayName.builtin`：内置宠物的展示名（F5）。
final class PetDisplayNameTests: XCTestCase {
    func test_knownBuiltins() {
        XCTAssertEqual(PetDisplayName.builtin("author"), "01 默认")
        XCTAssertEqual(PetDisplayName.builtin("shiba"),  "02 柴犬")
        XCTAssertEqual(PetDisplayName.builtin("bichon"), "03 比熊")
    }
    func test_unknownBuiltin_fallsBackToRawName() {
        XCTAssertEqual(PetDisplayName.builtin("corgi"), "corgi")
    }
}
