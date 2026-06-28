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

    /// 把图重绘进 RGBA8 premultipliedLast 缓冲并返回 (buffer, bytesPerRow, w, h)，统一字节序。
    private func rgba(_ img: CGImage) -> ([UInt8], Int, Int, Int)? {
        let w = img.width, h = img.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, bpr, w, h)
    }

    // 前置：资源路径假设有效（目录结构变动时给指向根因的失败）
    func test_petAssetPaths_exist() {
        for name in ["shiba", "bichon"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repoPetPath(name)),
                          "资源路径假设失效，疑似目录结构变动：\(repoPetPath(name))")
        }
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

    // TC-B3-FUNC-02 四角 + 四边中点 alpha == 0（背景透明，含边中点防 halo 漏判）
    func test_builtinPets_backgroundIsTransparent() {
        for name in ["shiba", "bichon"] {
            guard let img = cgImage(repoPetPath(name)), let (buf, bpr, w, h) = rgba(img) else {
                return XCTFail("无法读/绘 \(name)")
            }
            let edges = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),      // 四角
                         (w / 2, 0), (0, h / 2), (w / 2, h - 1), (w - 1, h / 2)] // 四边中点
            for (x, y) in edges {
                let alpha = buf[(y * bpr) + (x * 4) + 3]
                XCTAssertEqual(alpha, 0, "\(name) 边缘点(\(x),\(y)) 不透明（alpha=\(alpha)），疑似残留白底/halo")
            }
        }
    }

    // TC-B3-FUNC-03 本体存在：防"过度抠图/整图清零/资源损坏成空白"——空白透明图会通过上面两条
    func test_builtinPets_subjectNotErased() {
        for name in ["shiba", "bichon"] {
            guard let img = cgImage(repoPetPath(name)), let (buf, bpr, w, h) = rgba(img) else {
                return XCTFail("无法读/绘 \(name)")
            }
            // 中心 ±20px 邻域至少 1 个不透明像素（宠物本体未被抹掉）
            var found = false
            for y in (h / 2 - 20)...(h / 2 + 20) where !found {
                for x in (w / 2 - 20)...(w / 2 + 20) where buf[(y * bpr) + (x * 4) + 3] > 200 {
                    found = true; break
                }
            }
            XCTAssertTrue(found, "\(name) 中心区域无不透明像素，疑似整图被抠空")

            // 全图不透明像素占比落在合理区间（既非全透明，也非没抠到背景）
            var opaque = 0
            for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 200 { opaque += 1 }
            let ratio = Double(opaque) / Double(w * h)
            XCTAssertGreaterThan(ratio, 0.15, "\(name) 不透明占比 \(ratio) 过低，疑似过度抠图")
            XCTAssertLessThan(ratio, 0.85, "\(name) 不透明占比 \(ratio) 过高，疑似背景没抠掉")
        }
    }
}
