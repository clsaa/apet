import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// MARK: - FileOps Protocol

/// Abstraction over file-system operations used by ``CustomPetStore``.
///
/// Keeping real I/O behind this protocol lets unit tests inject a ``MockFileOps``
/// that records calls and controls observable state without touching the disk.
public protocol FileOps {
    /// Returns `true` if a file or directory exists at `path`.
    func fileExists(_ path: String) -> Bool

    /// Creates the directory at `path`, including intermediate directories.
    func createDir(_ path: String) throws

    /// Copies (or processes-then-copies) an item from `from` to `to`.
    ///
    /// ``RealFileOps`` resizes the image so the longer side is ≤512 px and strips
    /// GPS / EXIF metadata before writing.  ``MockFileOps`` simply records the
    /// destination path as "existing".
    func copyItem(from: String, to: String) throws

    /// Removes the file or directory at `path`.
    func removeItem(_ path: String) throws

    /// Returns the **base names** of the directory's direct children.
    /// Returns `[]` if the directory does not exist or is empty.
    func contentsOfDir(_ path: String) -> [String]
}

// MARK: - RealFileOps

/// Production implementation backed by ``FileManager``.
///
/// ``copyItem(from:to:)`` performs image processing when possible:
/// resizes so the longer side is ≤512 px, then re-encodes as PNG with
/// GPS and EXIF metadata stripped.  Falls back to a plain copy on failure.
public struct RealFileOps: FileOps {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func createDir(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Copies `from` → `to` with image processing (resize ≤512 + strip EXIF/GPS).
    /// Falls back to a plain ``FileManager`` copy when processing is unavailable.
    public func copyItem(from: String, to: String) throws {
        if processAndCopyImage(from: from, to: to) { return }
        try FileManager.default.copyItem(atPath: from, toPath: to)
    }

    public func removeItem(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func contentsOfDir(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    // MARK: Image processing (CoreGraphics + ImageIO, macOS-only)

    /// Returns `true` on success; `false` means caller should fall back to plain copy.
    @discardableResult
    private func processAndCopyImage(from src: String, to dst: String) -> Bool {
#if canImport(CoreGraphics) && canImport(ImageIO)
        let srcURL = URL(fileURLWithPath: src) as CFURL
        let dstURL = URL(fileURLWithPath: dst) as CFURL

        guard
            let source = CGImageSourceCreateWithURL(srcURL, nil),
            let image  = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }

        // --- Scale down if longer side > 512 ---
        let w = image.width
        let h = image.height
        let scaledImage: CGImage
        if max(w, h) > 512 {
            let scale = 512.0 / Double(max(w, h))
            let newW  = max(1, Int((Double(w) * scale).rounded()))
            let newH  = max(1, Int((Double(h) * scale).rounded()))
            let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard
                let ctx = CGContext(
                    data: nil, width: newW, height: newH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: bitmapInfo.rawValue
                )
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            guard let resized = ctx.makeImage() else { return false }
            scaledImage = resized
        } else {
            scaledImage = image
        }

        // --- Re-encode as PNG with GPS + EXIF stripped ---
        guard let dest = CGImageDestinationCreateWithURL(
            dstURL, "public.png" as CFString, 1, nil
        ) else { return false }

        // Preserve non-sensitive metadata (orientation, colour profile, …)
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                     as? [CFString: Any]) ?? [:]
        props.removeValue(forKey: kCGImagePropertyGPSDictionary)
        props.removeValue(forKey: kCGImagePropertyExifDictionary)

        CGImageDestinationAddImage(dest, scaledImage, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
#else
        return false
#endif
    }
}
