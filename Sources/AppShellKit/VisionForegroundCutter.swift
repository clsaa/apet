import Foundation
import AppKit
import Vision
import CoreImage
import ImageIO

// MARK: - Factory

/// Returns ``VisionForegroundCutter`` on macOS 14 + and ``UnavailableForegroundCutter`` on older
/// systems. Callers depend only on the ``ForegroundCutter`` protocol seam — no
/// `@available` guard required at call-site (spec §3 BLK-1/架构 B-2).
public func makeForegroundCutter() -> ForegroundCutter {
    if #available(macOS 14.0, *) {
        return VisionForegroundCutter()
    } else {
        return UnavailableForegroundCutter()
    }
}

// MARK: - VisionForegroundCutter

/// On-device background removal using Vision (macOS 14+).
///
/// **Five-step pipeline** (spec §3 MAJ-1):
/// 1. `CGImageSource` → read image + EXIF orientation  (prevents rotated-cutout defect).
/// 2. `VNImageRequestHandler(cgImage:orientation:).perform([VNGenerateForegroundInstanceMaskRequest])`.
/// 3. Guard `!observation.allInstances.isEmpty` → `noForegroundDetected`
///    (spec §3 MAJ-3: without this guard generateMaskedImage silently returns a fully-transparent image).
/// 4. `generateMaskedImage(ofInstances:from:croppingToInstancesExtent:false)` → `CVPixelBuffer` (with alpha).
/// 5. `CVPixelBuffer → CIImage → CGImage → NSBitmapImageRep → PNG Data` → write to `dstPath`.
///
/// Vision's `perform` is synchronous and blocks 300 ms – 2 s; the method dispatches off-main
/// via `withCheckedThrowingContinuation` + `DispatchQueue.global` (spec §3 BLK-2).
@available(macOS 14.0, *)
public struct VisionForegroundCutter: ForegroundCutter {

    /// 共享 CIContext，避免每次 cutout 调用都重新初始化（MINOR-7a）。
    /// `CIContext` 初始化会分配 GPU/Metal 资源，代价较高。
    private static let sharedContext = CIContext()

    public init() {}

    public func cutout(srcPath: String, dstPath: String) async throws {
        // Push the synchronous Vision pipeline onto a non-main background queue.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.performCutout(srcPath: srcPath, dstPath: dstPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous pipeline (background thread)

    private static func performCutout(srcPath: String, dstPath: String) throws {

        // ── Step 1: Read CGImage + EXIF orientation ──────────────────────────────
        // Passing the stored orientation prevents the Vision cutout region from being
        // rotated relative to the displayed image (spec §3 MAJ-1 step 1).
        let srcURL = URL(fileURLWithPath: srcPath) as CFURL
        guard let imageSource = CGImageSourceCreateWithURL(srcURL, nil) else {
            throw CutoutError.inferenceFailure("cannot open image source: \(srcPath)")
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CutoutError.inferenceFailure("cannot decode CGImage: \(srcPath)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let rawOrientation = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        // ── Step 2: Vision inference ──────────────────────────────────────────────
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw CutoutError.inferenceFailure("Vision perform failed: \(error.localizedDescription)")
        }

        // ── Step 3: Validate observation; guard empty allInstances ────────────────
        // spec §3 MAJ-3: generateMaskedImage on an empty IndexSet produces a fully-
        // transparent (or solid-black) image without throwing — must check explicitly.
        guard let observation = request.results?.first as? VNInstanceMaskObservation else {
            throw CutoutError.inferenceFailure("no VNInstanceMaskObservation in results")
        }
        guard !observation.allInstances.isEmpty else {
            throw CutoutError.noForegroundDetected
        }

        // ── Step 4: Generate masked CVPixelBuffer (with alpha) ───────────────────
        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
        } catch {
            throw CutoutError.inferenceFailure(
                "generateMaskedImage failed: \(error.localizedDescription)"
            )
        }

        // ── Step 5: CVPixelBuffer → PNG (orientation=up) → disk ─────────────────
        // Use CGImageDestination instead of NSBitmapImageRep so we can embed
        // kCGImagePropertyOrientation = .up in the output file.
        //
        // Vision corrected the pixels to display orientation in Step 2 (it receives
        // the stored EXIF orientation and un-rotates the pixel buffer during inference).
        // NSBitmapImageRep strips all metadata, leaving the PNG without an orientation tag.
        // Image loaders that see no tag default to .up — but macOS uses the EXIF tag when
        // present, so a portrait photo previously written with NSBitmapImageRep appeared
        // sideways because the source file had orientation=6 (.right) copied through.
        // Fix (MAJOR-3): write the PNG via CGImageDestination with orientation=1 (.up)
        // so loaders know the pixels are already in display orientation. (Any nil below
        // is a system/disk issue, not a Vision inference problem.)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // 显式 RGBA8 + sRGB：保住 alpha 通道，否则透明背景会被压成黑/白方块（安全评审 MAJ-1）。
        let rgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let resultCGImage = Self.sharedContext.createCGImage(
            ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: rgbColorSpace
        ) else {
            throw CutoutError.outputWriteFailed("CIContext.createCGImage returned nil")
        }
        let dstCFURL = URL(fileURLWithPath: dstPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(dstCFURL, "public.png" as CFString, 1, nil) else {
            throw CutoutError.outputWriteFailed("CGImageDestinationCreateWithURL returned nil")
        }
        // Orientation 1 = .up: pixels are already in display orientation; no rotation needed.
        let imgProps: [CFString: Any] = [kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue]
        CGImageDestinationAddImage(dest, resultCGImage, imgProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CutoutError.outputWriteFailed("CGImageDestinationFinalize failed: \(dstPath)")
        }
    }
}
