// JSONLSessionScanner.swift
// 纯逻辑扫描器：接受 ScannedFile（JSONL 解析后的结构化摘要），返回 ScanResult。
// 无 IO，无 Date()，无外部依赖。

// MARK: - ScannedFile

/// JSONL 会话文件的结构化摘要，由上游解析器填充。
public struct ScannedFile: Equatable {
    public let sessionId: String
    public let root: String
    public var cwd: String?
    public var title: String?
    public var lastPrompt: String?
    public var mtime: Double
    public var lastAssistantStopReason: String?
    public var lastAssistantTs: Double?
    /// away_summary 的时间戳（nil = 无 away_summary 记录）
    public var lastAwayTs: Double?
    public var hasRecentQueueOp: Bool
    public var lastConversationTs: Double?
    public var entrypoint: String?
    public var promptSource: String?
    public var isSidechain: Bool
    public var isSubagentPath: Bool

    public init(
        sessionId: String,
        root: String,
        cwd: String? = nil,
        title: String? = nil,
        lastPrompt: String? = nil,
        mtime: Double,
        lastAssistantStopReason: String? = nil,
        lastAssistantTs: Double? = nil,
        lastAwayTs: Double? = nil,
        hasRecentQueueOp: Bool = false,
        lastConversationTs: Double? = nil,
        entrypoint: String? = nil,
        promptSource: String? = nil,
        isSidechain: Bool = false,
        isSubagentPath: Bool = false
    ) {
        self.sessionId = sessionId
        self.root = root
        self.cwd = cwd
        self.title = title
        self.lastPrompt = lastPrompt
        self.mtime = mtime
        self.lastAssistantStopReason = lastAssistantStopReason
        self.lastAssistantTs = lastAssistantTs
        self.lastAwayTs = lastAwayTs
        self.hasRecentQueueOp = hasRecentQueueOp
        self.lastConversationTs = lastConversationTs
        self.entrypoint = entrypoint
        self.promptSource = promptSource
        self.isSidechain = isSidechain
        self.isSubagentPath = isSubagentPath
    }
}

// MARK: - Result Types

public enum SyntheticKind: Equatable {
    case sdkCli
    case sdkPromptSource
}

public enum IgnoreReason: Equatable {
    case subagent
    case synthetic(SyntheticKind)
    case blacklistedCwd
    case tooOld
}

public enum ScanState: Equatable {
    case running
    case waitingStop
    case stale
}

public enum ScanResult: Equatable {
    case observe(state: ScanState, key: SessionKey, cwd: String?, title: String?)
    case ignore(IgnoreReason)
}

// MARK: - Scanner

/// cwd 黑名单子串（大小写敏感）
private let cwdBlacklist: [String] = [
    "-iteration-",
    "/eval-",
    "/private/tmp/claude-",
    "/private/var/folders",
]

public enum JSONLSessionScanner {

    /// 扫描单个 JSONL 会话文件，返回 ScanResult。
    /// - Parameters:
    ///   - f: 结构化文件摘要
    ///   - now: 当前 Unix 秒（注入，不用 Date()）
    ///   - runningWindow: 判定 running 的时间窗口（Task 5 使用）
    ///   - idleWindow: 超出此秒数视为 tooOld
    public static func scan(
        _ f: ScannedFile,
        now: Double,
        runningWindow: Double = 120,
        idleWindow: Double = 1800
    ) -> ScanResult {

        // 优先级 1：subagent / sidechain
        if f.isSubagentPath || f.isSidechain {
            return .ignore(.subagent)
        }

        // 优先级 2：synthetic
        if f.entrypoint == "sdk-cli" {
            return .ignore(.synthetic(.sdkCli))
        }
        if f.promptSource == "sdk" {
            return .ignore(.synthetic(.sdkPromptSource))
        }

        // 优先级 3：blacklistedCwd
        if let cwd = f.cwd {
            for substr in cwdBlacklist where cwd.contains(substr) {
                return .ignore(.blacklistedCwd)
            }
        }

        // 优先级 4：tooOld
        // effectiveTs = min(mtime, lastConversationTs ?? mtime)
        let effectiveTs = min(f.mtime, f.lastConversationTs ?? f.mtime)
        if now - effectiveTs >= idleWindow {
            return .ignore(.tooOld)
        }

        // 过滤全未命中 → observe（状态 Task 5 补完，暂占位 .stale）
        let key = SessionKey(agent: "claude", root: f.root, sessionId: f.sessionId)
        let displayTitle = f.title ?? f.lastPrompt
        return .observe(state: .stale, key: key, cwd: f.cwd, title: displayTitle)
    }
}
