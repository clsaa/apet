import Foundation

/// 自定义宠物命名持久化（`~/Library/Application Support/AgentPet/pet-names.json`）：id → 名字。
/// 损坏 json → 空 map（对标 ConfigStore/SessionMetaStore）。
public struct PetNameStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch { return [:] }
    }

    public func save(_ names: [String: String]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(names)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomicWrite)
    }
}

/// 宠物默认名（纯函数）。编号语义是**家庭成员序号**：01=用户本人（无内置资产，
/// 期待第一张上传照片补位）、02=柴犬、03=比熊；再往后 04 顺延。
/// 评审修复（用户 B1）："01" 未被占用时，第一张上传照片默认命名 "01"。
public enum PetDefaultName {
    public static func next(existingCustomCount: Int, usedNames: Set<String> = []) -> String {
        if !usedNames.contains("01") { return "01" }
        return String(format: "%02d", 4 + existingCustomCount)
    }
}
