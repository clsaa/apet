import XCTest
import AppKit

/// 内置宠物 PNG 必须是透明背景（B3）。现状根因是 RGB 无 alpha 的不透明方块，
/// 桌面上显示为白底方块。本测试锁定"含 alpha 通道 + 四角透明"，防回归。
final class BuiltinPetAssetTests: XCTestCase {

    /// 从本测试文件路径上溯到仓库根 `apet/`，再拼宠物资源路径。
    private func repoPetPath(_ name: String) -> String {
        var url = URL(fileURLWithPath: #filePath) // .../apet/Tests/AppShellKitTests/BuiltinPetAssetTests.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }   // → apet/
        return url.appendingPathComponent("Resources/pets/\(name)/idle.png").path
    }

    private func cgImage(_ path: String) -> CGImage? {
        guard let data = NSData(contentsOfFile: path),
              let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // TC-B3-FUNC-01 含 alpha 通道
    func test_builtinPets_haveAlphaChannel() {
        for name in ["shiba", "bichon"] {
            guard let img = cgImage(repoPetPath(name)) else { return XCTFail("无法读 \(name)") }
            let ai = img.alphaInfo
            XCTAssertFalse(ai == .none || ai == .noneSkipFirst || ai == .noneSkipLast,
                           "\(name) 缺 alpha 通道（仍是不透明方块）")
        }
    }

    // TC-B3-FUNC-02 四角像素 alpha == 0（背景已透明）
    func test_builtinPets_cornersAreTransparent() {
        for name in ["shiba", "bichon"] {
            guard let img = cgImage(repoPetPath(name)) else { return XCTFail("无法读 \(name)") }
            // 统一转 RGBA8 premultipliedLast 上下文采样，规避源位图字节序差异
            let w = img.width, h = img.height
            let bytesPerRow = w * 4
            var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return XCTFail("无法建上下文 \(name)")
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            // 四角 alpha（每像素第 4 字节）
            let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
            for (x, y) in corners {
                let alpha = buf[(y * bytesPerRow) + (x * 4) + 3]
                XCTAssertEqual(alpha, 0, "\(name) 角点(\(x),\(y)) 不透明（alpha=\(alpha)）")
            }
        }
    }
}
