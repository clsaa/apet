import XCTest
@testable import AppShellKit

final class PetNameStoreTests: XCTestCase {
    private var url: URL!
    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-petnames-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url); super.tearDown() }

    func test_missing_returnsEmpty() {
        XCTAssertEqual(PetNameStore(url: url).load(), [:])
    }
    func test_roundTrip() throws {
        let store = PetNameStore(url: url)
        try store.save(["id-a": "我的狗", "id-b": "04"])
        XCTAssertEqual(store.load(), ["id-a": "我的狗", "id-b": "04"])
    }
    func test_corrupt_returnsEmpty() throws {
        try "{bad".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(PetNameStore(url: url).load(), [:])
    }

    // 内置占 01/02/03，自定义从 04 起顺延。
    func test_defaultName_startsAt04() {
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 0), "04")
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 1), "05")
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 6), "10")
    }
}
