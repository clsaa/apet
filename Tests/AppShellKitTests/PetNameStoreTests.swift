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

    // 评审修复（用户 B1 幽灵01）：01=用户本人，无内置资产——第一张上传照片默认给 "01"；
    // "01" 已被占用则回落 04 顺延（02/03 是内置柴犬/比熊）。
    func test_defaultName_firstUpload_takes01_whenUnused() {
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 0, usedNames: []), "01")
    }

    func test_defaultName_fallsTo04Sequence_when01Used() {
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 1, usedNames: ["01"]), "05")
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 0, usedNames: ["01"]), "04")
        XCTAssertEqual(PetDefaultName.next(existingCustomCount: 6, usedNames: ["01", "自定义"]), "10")
    }
}
