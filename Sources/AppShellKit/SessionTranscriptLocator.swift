import Foundation

/// 按 `root + sessionId` 定位会话 jsonl 文件：`<root>/projects/**/<sessionId>.jsonl`。
/// 跳过 subagent 文件（`agent-` 前缀 / `/subagents/` 路径）。IO 缝（读目录），供本地摘要取尾部。
public enum SessionTranscriptLocator {
    public static func find(root: String, sessionId: String) -> String? {
        // 1) Claude/Qoder 布局:<root>/projects/**/<sid>.jsonl
        let projectsDir = (root as NSString).appendingPathComponent("projects")
        if let enumerator = FileManager.default.enumerator(atPath: projectsDir) {
            let target = "\(sessionId).jsonl"
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(target) else { continue }
                let basename = (relative as NSString).lastPathComponent
                guard basename == target, !relative.contains("/subagents/") else { continue }
                return (projectsDir as NSString).appendingPathComponent(relative)
            }
        }
        // 2) Codex 布局:<root>/sessions/YYYY/MM/DD/rollout-<ts>-<sid>.jsonl(按后缀匹配)
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        if let enumerator = FileManager.default.enumerator(atPath: sessionsDir) {
            let suffix = "-\(sessionId).jsonl"
            while let relative = enumerator.nextObject() as? String {
                if relative.hasSuffix(suffix) {
                    return (sessionsDir as NSString).appendingPathComponent(relative)
                }
            }
        }
        return nil
    }
}
