import Foundation

public enum EventKind: Equatable {
    case sessionStart, busy, stop, attention, sessionEnd, pluginError
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "session_start": self = .sessionStart
        case "busy":          self = .busy
        case "stop":          self = .stop
        case "attention":     self = .attention
        case "session_end":   self = .sessionEnd
        case "plugin_error":  self = .pluginError
        default:              self = .unknown(raw)
        }
    }
}

public enum WaitingReason: String, Codable, Equatable { case stop, attention }
public enum TerminalKind: String, Codable, Equatable { case iterm2, terminal, warp, ghostty, vscode, other }

public extension TerminalKind {
    /// 默认 app bundleId(图标 + 激活兜底共用;other 未知→nil)。M3-D-D。
    /// ⚠️ 仅**兜底**默认值:hook 优先写 `__CFBundleIdentifier` 真值(见 apet-emit-event.sh)。
    /// 这里的 warp=Stable / vscode=VS Code 对 Warp-Preview / Cursor 是错的,仅在真值缺失时用。
    /// 值取自各终端 Info.plist;新增/改名终端时同步 hook 与 TerminalFocusPlanner。
    var bundleId: String? {
        switch self {
        case .iterm2:   return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .warp:     return "dev.warp.Warp-Stable"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .vscode:   return "com.microsoft.VSCode"
        case .other:    return nil
        }
    }
}
public enum NotifyClass: String, Codable, Equatable { case alert, passive, none }

public struct TerminalRef: Equatable, Decodable {
    public var kind: TerminalKind
    public var itermSessionId: String?
    public var tty: String?
    public var pid: Int?
    public var bundleId: String?

    public init(kind: TerminalKind, itermSessionId: String? = nil,
                tty: String? = nil, pid: Int? = nil, bundleId: String? = nil) {
        self.kind = kind; self.itermSessionId = itermSessionId
        self.tty = tty; self.pid = pid; self.bundleId = bundleId
    }

    enum CodingKeys: String, CodingKey { case kind, itermSessionId, tty, pid, bundleId }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // 未知 kind 一律降级为 .other（设计 §3）
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        self.kind = TerminalKind(rawValue: rawKind) ?? .other
        self.itermSessionId = try c.decodeIfPresent(String.self, forKey: .itermSessionId)
        self.tty = try c.decodeIfPresent(String.self, forKey: .tty)
        self.pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        self.bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
    }
}

public struct AgentEvent: Equatable {
    public var v: Int
    public var eventId: String
    public var seq: Int?
    public var agent: String
    public var kind: EventKind
    public var sessionId: String
    public var root: String
    public var cwd: String?
    public var title: String?
    public var terminal: TerminalRef?
    public var notify: NotifyClass?
    public var reason: WaitingReason?
    public var message: String?
    public var ts: String
    /// 进程内来源标记（不进 wire）。hook 实时事件默认 .hook；jsonl 合成事件由调用方置 .jsonl。
    public var source: SessionSource

    public init(v: Int, eventId: String, seq: Int? = nil, agent: String, kind: EventKind,
                sessionId: String, root: String, cwd: String? = nil, title: String? = nil,
                terminal: TerminalRef? = nil, notify: NotifyClass? = nil,
                reason: WaitingReason? = nil, message: String? = nil, ts: String,
                source: SessionSource = .hook) {
        self.v = v; self.eventId = eventId; self.seq = seq; self.agent = agent
        self.kind = kind; self.sessionId = sessionId; self.root = root; self.cwd = cwd
        self.title = title; self.terminal = terminal; self.notify = notify
        self.reason = reason; self.message = message; self.ts = ts; self.source = source
    }

    /// 解析单行 NDJSON。坏行/解析失败返回 nil（绝不抛）。设计 §9。
    /// reason/notify 宽容解码：未知 rawValue 不丢整条事件，字段降为 nil（面板 B5）。
    public static func decode(line: Substring) -> AgentEvent? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        struct Raw: Decodable {
            var v: Int?; var eventId: String?; var seq: Int?; var agent: String?
            var event: String?; var sessionId: String?; var root: String?
            var cwd: String?; var title: String?; var terminal: TerminalRef?
            var notify: String?; var reason: String?; var message: String?; var ts: String?
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: data),
              let eventId = r.eventId, let agent = r.agent, let event = r.event,
              let sessionId = r.sessionId, let root = r.root, let ts = r.ts
        else { return nil }
        return AgentEvent(v: r.v ?? 1, eventId: eventId, seq: r.seq, agent: agent,
                          kind: EventKind(raw: event), sessionId: sessionId, root: root,
                          cwd: r.cwd, title: r.title, terminal: r.terminal,
                          notify: NotifyClass(rawValue: r.notify ?? ""),
                          reason: WaitingReason(rawValue: r.reason ?? ""),
                          message: r.message, ts: ts)
    }
}
