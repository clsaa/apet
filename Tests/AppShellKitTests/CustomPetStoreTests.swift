import XCTest
@testable import AppShellKit

final class CustomPetStoreTests: XCTestCase {

    // MARK: - MockFileOps

    final class MockFileOps: FileOps {
        var existing = Set<String>()
        var dirs = [String: [String]]()
        func fileExists(_ p: String) -> Bool { existing.contains(p) }
        func createDir(_ p: String) throws {}
        func copyItem(from: String, to: String) throws { existing.insert(to) }
        func removeItem(_ p: String) throws {
            existing.remove(p)
            // Remove directory entry: clear the key so contentsOfDir returns []
            dirs.removeValue(forKey: p)
            // Also remove the basename from the parent directory's listing so list() reflects deletion.
            guard let slashIdx = p.lastIndex(of: "/") else { return }
            let parent = String(p[..<slashIdx])
            let base   = String(p[p.index(after: slashIdx)...])
            dirs[parent]?.removeAll { $0 == base }
        }
        func contentsOfDir(_ p: String) -> [String] { dirs[p] ?? [] }
    }

    // MARK: - imagePath tests (from brief)

    func test_imagePath_prefersCutout() {
        let fo = MockFileOps()
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "id1" })
        fo.existing.insert("/r/id1/original.png"); fo.existing.insert("/r/id1/cutout.png")
        XCTAssertEqual(store.imagePath(id: "id1"), "/r/id1/cutout.png")
    }

    func test_imagePath_fallsBackToOriginal() {
        let fo = MockFileOps()
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "id1" })
        fo.existing.insert("/r/id1/original.png")
        XCTAssertEqual(store.imagePath(id: "id1"), "/r/id1/original.png")
    }

    func test_imagePath_missing_nil() {
        let store = CustomPetStore(rootDir: "/r", fileOps: MockFileOps(), idProvider: { "id1" })
        XCTAssertNil(store.imagePath(id: "id1"))
    }

    func test_imagePath_emptyId_nil() {
        let store = CustomPetStore(rootDir: "/r", fileOps: MockFileOps(), idProvider: { "x" })
        XCTAssertNil(store.imagePath(id: ""))
    }

    func test_list_returnsSubdirs() {
        let fo = MockFileOps(); fo.dirs["/r"] = ["a", "b"]
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "x" })
        XCTAssertEqual(store.list().sorted(), ["a", "b"])
    }

    // MARK: - delete test (extra, from plan review)

    /// delete(id:) must remove every file found under <rootDir>/<id>/,
    /// then remove the id directory itself so list() returns no ghost entry.
    func test_delete_removesFilesUnderIdDir() {
        let fo = MockFileOps()
        fo.existing.insert("/r/id1/original.png")
        fo.existing.insert("/r/id1/cutout.png")
        fo.dirs["/r/id1"] = ["original.png", "cutout.png"]
        fo.dirs["/r"] = ["id1"]   // list() must return ["id1"] before delete
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "id1" })
        XCTAssertNoThrow(try store.delete(id: "id1"))
        XCTAssertFalse(fo.existing.contains("/r/id1/original.png"),
                       "original.png should be removed")
        XCTAssertFalse(fo.existing.contains("/r/id1/cutout.png"),
                       "cutout.png should be removed")
        XCTAssertTrue(store.list().isEmpty,
                      "list() must not return ghost id after delete removes the directory")
    }

    // MARK: - importPhoto test (extra, from plan review)

    /// importPhoto must use idProvider to generate the id, copyItem to the correct
    /// destination, and return that id so imagePath can derive the path.
    func test_importPhoto_usesIdProvider() throws {
        let fo = MockFileOps()
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "fixedId" })
        let id = try store.importPhoto(srcPath: "/src")
        XCTAssertEqual(id, "fixedId", "returned id must match idProvider output")
        // copyItem inserted the destination into existing, so imagePath should resolve
        XCTAssertEqual(store.imagePath(id: id), "/r/fixedId/original.png",
                       "imagePath should return original.png when only that file exists")
    }
}
