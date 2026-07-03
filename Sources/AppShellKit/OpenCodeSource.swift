import Foundation
import AgentPetCore

// MARK: - OpenCodeSessionRow

/// 最后一条 assistant 消息的结构性信号(上游 getCurrentAssistant 同款判据,projector.ts:134-151)。
/// M3-C+ 计划评审 v3:取代 ε 时间比较——part 的 upsert 只更新 data、time_created 冻结
/// (projector.ts:319-324),长工具/长文本期间活动时间链停摆,任何窗口判据都会误降;
/// in-flight 布尔不受影响。
public enum AssistantSignal: Equatable {
    case none        // 无 assistant 消息(会话刚建/降级读取)
    case inFlight    // $.time.completed IS NULL → 本轮进行中
    case completed   // 非 NULL(任意类型,ISO 串也算)→ 本轮真实完成
}

/// OpenCode(opencode.db,源码核实 v1.17.13)一条会话的轻量投影。
/// 时间为 **Unix 秒**(Reader 层已从 epoch 毫秒换算);directory/title 空串已映射 nil(约束 5)。
public struct OpenCodeSessionRow: Equatable {
    public let sessionId: String
    public let directory: String?
    public let title: String?
    /// 最近**行插入**时间:MAX(part.time_created) → session_message → session.time_updated 降级链。
    /// 仅用于年龄降档(stale/排除),不用于 running 判定(见 AssistantSignal)。
    public let lastActivity: Double
    public let assistantSignal: AssistantSignal
    public let createdAt: Double

    public init(sessionId: String, directory: String?, title: String?,
                lastActivity: Double, assistantSignal: AssistantSignal, createdAt: Double) {
        self.sessionId = sessionId; self.directory = directory; self.title = title
        self.lastActivity = lastActivity; self.assistantSignal = assistantSignal
        self.createdAt = createdAt
    }
}

// MARK: - OpenCodeScanner(纯函数)

/// 状态派生(spec §3.1 v3):
/// 1. 年龄降档先行:age>=staleHorizon 排除;age>=idleWindow → stale(灰显不蒸发——常开 TUI
///    挂机 30 分钟就消失违背用户直觉;亦是 in-flight 的 kill 兜底:进程死后 completed 永为
///    NULL,靠年龄出场)。
/// 2. 活跃窗口内:.inFlight → running;.completed → waitingStop(不等窗口);
///    .none → age<runningWindow ? running : waitingStop(窗口兜底,prompt-touch 保活)。
public enum OpenCodeScanner {
    public static func scan(
        rows: [OpenCodeSessionRow],
        root: String,
        now: Double,
        runningWindow: Double = 120,
        idleWindow: Double = 1800,
        staleHorizon: Double = 86400
    ) -> [ScanResult] {
        rows.compactMap { row in
            guard row.lastActivity > 0 else { return nil }   // 0/负值:坏数据,静默排除
            let age = now - row.lastActivity
            guard age < staleHorizon else { return nil }
            let key = SessionKey(agent: "opencode", root: root, sessionId: row.sessionId)
            let state: ScanState
            if age >= idleWindow {
                state = .stale
            } else {
                switch row.assistantSignal {
                case .inFlight:  state = .running
                case .completed: state = .waitingStop
                case .none:      state = age < runningWindow ? .running : .waitingStop
                }
            }
            return .observe(state: state, key: key, cwd: row.directory, title: row.title)
        }
    }
}
