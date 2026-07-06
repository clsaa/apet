import Foundation

/// events.ndjson 压缩(技术债:hook/notify/插件只增不减,长期用户几十万行 → 启动 replay 变慢)。
///
/// 规则(按 sessionId 分组):
/// - 会话最后事件距今 ≤ maxAge(默认 72h)**或** 其 terminal.pid 仍存活(终端还开着,
///   liveness 保护中——压掉会丢面板会话)→ 保留该会话**尾部 keepPerSession 条**;
///   若尾窗内无 terminal 载体而早前有 → 额外保留最后一条带 terminal 的(字段合并
///   last-non-nil 语义:丢了它重放后终端信息消失)。
/// - 其余会话事件整组丢弃(其会话重放后也会被窗口 reap,留着纯属死重)。
/// - 坏行/无 sessionId 行原样保留(保守:不理解的不动)。
/// - **行序全局保持**(行序=seq 序,硬约束 3)。
///
/// 纯函数;IO(读/原子写/触发阈值)由调用方处理。
public enum EventLogCompactor {
    public static func compact(
        lines: [String],
        now: Double,
        maxAge: Double = 72 * 3600,
        keepPerSession: Int = 50,
        isAlive: (Int) -> Bool = { TtyLiveness.safeKill0($0) }
    ) -> [String] {
        struct Info {
            var lastTs: Double = 0
            var indices: [Int] = []
            var lastTerminalIdx: Int? = nil
            var pid: Int? = nil
        }
        var bySession: [String: Info] = [:]
        var parsedSid: [Int: String] = [:]

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["sessionId"] as? String, !sid.isEmpty else { continue }
            parsedSid[i] = sid
            var info = bySession[sid] ?? Info()
            info.indices.append(i)
            if let ts = obj["ts"] as? String {
                info.lastTs = max(info.lastTs, EventTsParser.epoch(ts, fallback: now))   // 未来钳到 now
            }
            if let term = obj["terminal"] as? [String: Any] {
                info.lastTerminalIdx = i
                if let p = term["pid"] as? Int { info.pid = p }
            }
            bySession[sid] = info
        }

        // 决定每个会话保留哪些行号
        var keep = Set<Int>()
        for (_, info) in bySession {
            let fresh = now - info.lastTs <= maxAge
            let alive = info.pid.map { $0 > 0 && isAlive($0) } ?? false
            guard fresh || alive else { continue }
            let tail = info.indices.suffix(keepPerSession)
            keep.formUnion(tail)
            if let t = info.lastTerminalIdx, !tail.contains(t) {
                keep.insert(t)   // 字段合并语义:终端载体不丢
            }
        }

        // 全局行序输出:保留行 + 未解析行(保守)
        return lines.enumerated().compactMap { (i, line) in
            if parsedSid[i] == nil { return line }       // 坏行/无 sid:原样
            return keep.contains(i) ? line : nil
        }
    }
}
