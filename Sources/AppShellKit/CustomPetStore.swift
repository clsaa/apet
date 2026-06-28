import Foundation

// MARK: - CustomPetStore

/// Manages a user's custom pet photos on disk.
///
/// Each pet is stored under `<rootDir>/<id>/`:
/// - `original.png` — the processed import (resized ≤512 px, EXIF stripped)
/// - `cutout.png`   — the transparent-background cutout written by the cutter
///
/// All file-system operations are delegated to a ``FileOps`` value so that
/// unit tests can inject a ``MockFileOps`` and avoid any disk I/O.
/// Time-based id generation is avoided by design — callers supply an
/// `idProvider` closure (e.g. `{ UUID().uuidString }`).
public struct CustomPetStore {

    private let rootDir: String
    private let fileOps: FileOps
    private let idProvider: () -> String

    public init(
        rootDir: String,
        fileOps: FileOps,
        idProvider: @escaping () -> String
    ) {
        self.rootDir    = rootDir
        self.fileOps    = fileOps
        self.idProvider = idProvider
    }

    // MARK: - Write operations

    /// Imports a photo from `srcPath` into the store.
    ///
    /// - Creates `<rootDir>/<id>/`
    /// - Copies / processes `srcPath` to `<rootDir>/<id>/original.png`
    /// - Returns the generated `id` so callers can reference this pet later.
    @discardableResult
    public func importPhoto(srcPath: String) throws -> String {
        let id    = idProvider()
        let idDir = idDir(for: id)
        try fileOps.createDir(idDir)
        try fileOps.copyItem(from: srcPath, to: originalPath(id: id))
        return id
    }

    /// Removes every file found under `<rootDir>/<id>/`, then removes the id directory itself.
    /// Without removing the directory, `list()` would still enumerate it as a ghost entry.
    public func delete(id: String) throws {
        let dir   = idDir(for: id)
        let files = fileOps.contentsOfDir(dir)
        for file in files {
            try fileOps.removeItem("\(dir)/\(file)")
        }
        try fileOps.removeItem(dir)
    }

    // MARK: - Read operations

    /// Returns the best available image path for `id`.
    ///
    /// Priority: `cutout.png` (transparent-bg, preferred for rendering)
    ///           › `original.png` (fallback)
    ///           › `nil` if neither exists or `id` is empty.
    public func imagePath(id: String) -> String? {
        guard !id.isEmpty else { return nil }
        let cutout   = cutoutPath(id: id)
        let original = originalPath(id: id)
        if fileOps.fileExists(cutout)   { return cutout }
        if fileOps.fileExists(original) { return original }
        return nil
    }

    /// Returns all pet ids currently stored (base names of `rootDir` children).
    public func list() -> [String] {
        fileOps.contentsOfDir(rootDir)
    }

    // MARK: - Path helpers

    /// Path where the background-removed cutout is written by the cutter.
    public func cutoutPath(id: String) -> String   { "\(idDir(for: id))/cutout.png" }

    /// Path where the imported (processed) original is stored.
    public func originalPath(id: String) -> String { "\(idDir(for: id))/original.png" }

    // MARK: - Private helpers

    private func idDir(for id: String) -> String { "\(rootDir)/\(id)" }
}
