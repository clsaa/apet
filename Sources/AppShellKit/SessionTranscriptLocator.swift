import Foundation

/// 按 `root + sessionId` 定位会话 jsonl 文件：`<root>/projects/**/<sessionId>.jsonl`。
/// 跳过 subagent 文件（`agent-` 前缀 / `/subagents/` 路径）。IO 缝（读目录），供本地摘要取尾部。
public enum SessionTranscriptLocator {
    public static func find(root: String, sessionId: String) -> String? {
        let projectsDir = (root as NSString).appendingPathComponent("projects")
        guard let enumerator = FileManager.default.enumerator(atPath: projectsDir) else { return nil }
        let target = "\(sessionId).jsonl"
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(target) else { continue }
            let basename = (relative as NSString).lastPathComponent
            guard basename == target, !relative.contains("/subagents/") else { continue }
            return (projectsDir as NSString).appendingPathComponent(relative)
        }
        return nil
    }
}
