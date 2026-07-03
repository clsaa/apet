import XCTest
@testable import AgentPetCore

final class GroupMembershipTests: XCTestCase {
    func test_toggle_addsThenRemoves() {
        XCTAssertEqual(GroupMembership.toggle("工作", in: []), ["工作"])
        XCTAssertEqual(GroupMembership.toggle("工作", in: ["工作"]), [])
    }
    func test_toggle_dedups() {
        XCTAssertEqual(GroupMembership.toggle("A", in: ["A", "A"]), [])
        XCTAssertEqual(GroupMembership.toggle("B", in: ["A"]).sorted(), ["A", "B"])
    }
    func test_isValidName() {
        XCTAssertTrue(GroupMembership.isValidName("工作"))
        XCTAssertFalse(GroupMembership.isValidName(""))
        XCTAssertFalse(GroupMembership.isValidName("   "))
        XCTAssertFalse(GroupMembership.isValidName(String(repeating: "x", count: 31)))
        XCTAssertFalse(GroupMembership.isValidName("坏\u{202E}名"))
        XCTAssertFalse(GroupMembership.isValidName("控\u{0007}制"))
    }

    func test_isValidName_graphemeCount_notScalar() {
        XCTAssertTrue(GroupMembership.isValidName(String(repeating: "😀", count: 30)), "30 emoji=30 字素")
        XCTAssertFalse(GroupMembership.isValidName(String(repeating: "😀", count: 31)))
        XCTAssertTrue(GroupMembership.isValidName("👨‍👩‍👧 家庭"), "ZWJ 合成 emoji 计 1 字素")
    }
}
