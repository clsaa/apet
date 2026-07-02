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

/// 内置宠物占 01/02/03（默认/柴犬/比熊），自定义照片默认名从 04 顺延（纯函数）。
public enum PetDefaultName {
    public static func next(existingCustomCount: Int) -> String {
        String(format: "%02d", 4 + existingCustomCount)
    }
}
