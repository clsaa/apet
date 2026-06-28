import AppKit
import AppShellKit
import AgentPetCore

// MARK: - PetAssetLoader

/// Loads pet PNG images from the bundle (packaged .app) or the repo's Resources/
/// directory (dev / `swift run`).
///
/// Lookup order:
///   1. `Bundle.main.resourceURL / pets/{pet}/{state}.png`  — packaged .app + Xcode
///   2. Repo root `Resources/pets/{pet}/{state}.png`         — `swift run` dev mode
///   3. Fall back to the "idle" state image
///   4. SF Symbol "pawprint.fill"                            — last resort
enum PetAssetLoader {

    /// Return the best image for the given pet and asset state.
    /// Falls back to "idle" when the requested state image is missing.
    static func image(pet: String = "shiba", assetState: String) -> NSImage {
        return loadImage(pet: pet, state: assetState)
            ?? loadImage(pet: pet, state: "idle")
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "pet")
            ?? NSImage()
    }

    /// Return the best image for the given ``PetKind`` and asset state.
    ///
    /// - `.builtin(name)` — delegates to the existing PNG lookup via `image(pet:assetState:)`.
    /// - `.custom(id)` — loads the image from `customStore?.imagePath(id:)`.
    ///   Falls back to the SF Symbol "pawprint.fill" when the path is missing or the
    ///   store is nil.
    static func image(
        selection: PetKind,
        assetState: String,
        customStore: CustomPetStore?
    ) -> NSImage {
        switch selection {
        case .builtin(let name):
            return image(pet: name, assetState: assetState)
        case .custom(let id):
            if let store = customStore,
               let path = store.imagePath(id: id),
               let nsImage = NSImage(contentsOfFile: path) {
                return nsImage
            }
            // Fallback: SF Symbol when custom image is missing or store unavailable.
            return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "pet")
                ?? NSImage()
        }
    }

    // MARK: - Private

    private static func loadImage(pet: String, state: String) -> NSImage? {
        let relativePath = "pets/\(pet)/\(state).png"

        // 1. Bundle resource URL (packaged .app or Xcode run)
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return NSImage(contentsOf: candidate)
            }
        }

        // 2. Dev fallback: walk up from this source file to the repo root.
        //    This file lives at Sources/apet/PetAssetLoader.swift — two levels deep.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent() // → Sources/apet/
            .deletingLastPathComponent() // → Sources/
            .deletingLastPathComponent() // → repo root
        let devCandidate = repoRoot.appendingPathComponent("Resources/\(relativePath)")
        if FileManager.default.fileExists(atPath: devCandidate.path) {
            return NSImage(contentsOf: devCandidate)
        }

        return nil
    }
}
