import Foundation

/// watcher 扫描预过滤(架构评审 Minor-5,codex 放大):tooOld 过滤原本在 parse **之后**,
/// 每轮对全部历史文件做 firstLine+尾窗读。改为 parse 前 stat 决策:
///
/// - 桶 = 会话文件去扩展名路径 `<dir>/<sid>`(与 subagents 目录 `<dir>/<sid>/subagents` 的
///   上级精确重合)。
/// - **subagents 豁免**(巩固评审 Major③):DirectoryScanner 的枚举**排除** agent-*.jsonl,
///   预过滤看不见 subagent 的 mtime——父文件静默但 subagent 活跃的会话(长跑 Task)若按父
///   mtime 跳过,会被幽灵对账误打灰再复活(闪灰)。故凡桶目录下存在 `subagents/` 子目录,
///   一律保守保留交给 parse(scanner 的 latestSubagentMtime 兜真值)。无 subagents 的
///   会话(绝大多数)仍按 mtime 跳过。
/// - 整桶 idle ≥ idleWindow(且无 subagents)→ 跳过 parse。
/// - stat 失败 → 保守保留(宁多读一次,不丢会话)。
///
/// 幽灵对账不受影响:被跳过文件不产生 observe,上一轮 emit 过的 key 走既有 ghost 路径
/// 补发 `.stale` 并清基线——语义与「parse 后被 tooOld 忽略」一致。
public enum StaleDirPrefilter {
    public static func freshPaths(
        _ paths: [String],
        now: Double,
        idleWindow: Double,
        mtime: (String) -> Double?,
        hasSubagents: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/subagents") }
    ) -> [String] {
        return paths.filter { p in
            let bucket = (p as NSString).deletingPathExtension   // <dir>/<sid>
            if hasSubagents(bucket) { return true }              // subagent 盲区豁免
            guard let m = mtime(p) else { return true }          // stat 失败保守保留
            return now - m < idleWindow
        }
    }
}
