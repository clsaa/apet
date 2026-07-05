import Foundation

/// watcher 扫描预过滤(架构评审 Minor-5,codex 放大):tooOld 过滤原本在 parse **之后**,
/// 每轮对全部历史文件做 firstLine+尾窗读——claude ~400 文件、codex 按日归档只增不减,
/// 每 8s 全量 IO。改为 parse 前按**目录桶** stat 决策:
///
/// - 桶 = **会话**:父文件 `<dir>/<sid>.jsonl` 桶=去扩展名路径 `<dir>/<sid>`,subagent
///   `<dir>/<sid>/subagents/agent-*.jsonl` 桶=其 `/subagents/` 前缀——两者精确重合
///  (真实布局见 JSONLParse:165)。活跃 subagent 会让父文件 mtime 很老的会话仍是 running
///  (scanner activity 取 max),单文件 mtime 预过滤会误杀;会话桶取 max 语义等价且逐会话粒度。
/// - 整桶所有文件 idle ≥ idleWindow → 跳过 parse(scanner 反正会 `.ignore(.tooOld)`)。
/// - stat 失败 → 保守保留(宁多读一次,不丢会话)。
///
/// 幽灵对账不受影响:被跳过的文件不产生 observe,上一轮 emit 过的 key 走既有
/// ghost 路径补发 `.stale` 并清基线——语义与「parse 后被 tooOld 忽略」一致。
public enum StaleDirPrefilter {
    public static func freshPaths(
        _ paths: [String],
        now: Double,
        idleWindow: Double,
        mtime: (String) -> Double?
    ) -> [String] {
        // 1. 分桶 + 桶内最新 mtime
        var bucketFresh: [String: Double] = [:]
        var bucketOf: [String: String] = [:]
        var statFailed: Set<String> = []
        for p in paths {
            let dir: String
            if let r = p.range(of: "/subagents/") {
                dir = String(p[..<r.lowerBound])          // <dir>/<sid>
            } else {
                dir = (p as NSString).deletingPathExtension   // <dir>/<sid>
            }
            bucketOf[p] = dir
            if let m = mtime(p) {
                bucketFresh[dir] = max(bucketFresh[dir] ?? -.infinity, m)
            } else {
                statFailed.insert(p)
            }
        }
        // 2. 桶新鲜(或含 stat 失败成员)→ 整桶保留
        return paths.filter { p in
            if statFailed.contains(p) { return true }
            guard let dir = bucketOf[p], let fresh = bucketFresh[dir] else { return true }
            return now - fresh < idleWindow
        }
    }
}
