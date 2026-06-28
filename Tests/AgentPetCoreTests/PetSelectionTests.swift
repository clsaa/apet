import XCTest
@testable import AgentPetCore
final class PetSelectionTests: XCTestCase {
    func test_builtin_shiba() { XCTAssertEqual(PetSelection.parse("shiba"), .builtin("shiba")) }
    func test_builtin_bichon() { XCTAssertEqual(PetSelection.parse("bichon"), .builtin("bichon")) }
    func test_custom_withId() { XCTAssertEqual(PetSelection.parse("custom:abc123"), .custom(id: "abc123")) }
    func test_custom_emptyId_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse("custom:"), .builtin("shiba")) }
    func test_empty_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse(""), .builtin("shiba")) }
    func test_unknown_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse("dragon"), .builtin("shiba")) }
}
