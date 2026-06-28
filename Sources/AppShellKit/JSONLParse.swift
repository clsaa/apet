import Foundation
import AgentPetCore

/// 纯逻辑解析器：从 JSONL 会话文件尾部行提取 ScannedFile。
/// - 零外部依赖，只用 Foundation。
/// - 不用 Date()，mtime 由 FileManager 读取，timestamp 用 ISO8601 解析成 epoch Double。
public enum JSONLParse {

    // MARK: - Public API

    /// 解析单个 JSONL 文件，返回 ScannedFile 摘要；文件不可读时返回 nil。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - root: 会话所属 profile 根目录（透传到 ScannedFile.root）
    ///   - maxLines: 从尾部读取的最大行数（默认 400）
    ///   - maxBytes: 从尾部读取的最大字节数（默认 1 MB）
    public static func parse(
        path: String,
        root: String,
        maxLines: Int = 400,
        maxBytes: Int = 1_048_576
    ) -> ScannedFile? {

        // 1. mtime
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        // 2. 读尾部行
        guard case .ok(let lines) = TailLineReader.lastLines(
            path: path, maxLines: maxLines, maxBytes: maxBytes
        ) else {
            return nil
        }

        // 3. 批量解析 JSON（坏行跳过）
        let objects: [[String: Any]] = lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // 4. 提取字段
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func epochFrom(_ s: String?) -> Double? {
            guard let s = s else { return nil }
            return iso.date(from: s)?.timeIntervalSince1970
        }

        var sessionId: String? = nil
        var cwd: String? = nil
        var hasRecentQueueOp = false
        var lastConversationTs: Double? = nil
        var lastAwayTs: Double? = nil
        var entrypoint: String? = nil      // sdk-cli 优先；否则取首个非空值
        var promptSource: String? = nil
        var isSidechain = false

        var customTitle: String? = nil
        var aiTitle: String? = nil
        var lastPromptText: String? = nil

        let conversationTypes: Set<String> = ["user", "assistant", "system", "attachment"]

        // 正向遍历：收集对话行字段、裸元数据
        for obj in objects {
            let type = obj["type"] as? String ?? ""

            // sessionId：任一行
            if sessionId == nil {
                sessionId = obj["sessionId"] as? String
            }

            // 裸元数据行
            switch type {
            case "last-prompt":
                lastPromptText = obj["lastPrompt"] as? String
            case "custom-title":
                customTitle = obj["customTitle"] as? String
            case "ai-title":
                aiTitle = obj["aiTitle"] as? String
            case "queue-operation":
                hasRecentQueueOp = true
            default:
                break
            }

            // 对话行（user / assistant / system / attachment）
            guard conversationTypes.contains(type) else { continue }

            // cwd：最后一条带 cwd 的对话行
            if let c = obj["cwd"] as? String {
                cwd = c
            }

            // isSidechain：任一行 true 即标记
            if let sc = obj["isSidechain"] as? Bool, sc {
                isSidechain = true
            }

            // entrypoint：sdk-cli 优先，否则取第一个非空值
            if let ep = obj["entrypoint"] as? String, !ep.isEmpty {
                if ep == "sdk-cli" {
                    entrypoint = "sdk-cli"
                } else if entrypoint == nil {
                    entrypoint = ep
                }
                // 若已经是 sdk-cli，保持不变
            }

            // promptSource：user 行顶层字段
            if type == "user", let ps = obj["promptSource"] as? String {
                promptSource = ps
            }

            // lastConversationTs：最后一条带 timestamp 的对话行
            if let ts = epochFrom(obj["timestamp"] as? String) {
                lastConversationTs = ts
            }

            // lastAwayTs：最后一条 type==system && subtype==away_summary
            if type == "system",
               (obj["subtype"] as? String) == "away_summary",
               let ts = epochFrom(obj["timestamp"] as? String) {
                lastAwayTs = ts
            }
        }

        // 5. 反向遍历：找末条 type==assistant，取 message.stop_reason + timestamp
        var lastAssistantStopReason: String? = nil
        var lastAssistantTs: Double? = nil

        for obj in objects.reversed() {
            guard (obj["type"] as? String) == "assistant" else { continue }

            // message.stop_reason 在 message 对象顶层
            if let message = obj["message"] as? [String: Any] {
                // NSNull（JSON null）→ as? String 返回 nil，与需求一致
                lastAssistantStopReason = message["stop_reason"] as? String
            }

            // timestamp（ISO8601 → epoch）
            lastAssistantTs = epochFrom(obj["timestamp"] as? String)
            break
        }

        // 6. isSubagentPath：路径含 /subagents/ 或 basename 以 agent- 开头
        let basename = (path as NSString).lastPathComponent
        let isSubagentPath = path.contains("/subagents/") || basename.hasPrefix("agent-")

        // 7. sessionId 兜底：用文件名（去扩展名）
        let filenameNoExt = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let resolvedSessionId = sessionId ?? filenameNoExt

        // 8. title：customTitle > aiTitle > lastPrompt
        let title = customTitle ?? aiTitle ?? lastPromptText

        return ScannedFile(
            sessionId: resolvedSessionId,
            root: root,
            cwd: cwd,
            title: title,
            lastPrompt: lastPromptText,
            mtime: mtime,
            lastAssistantStopReason: lastAssistantStopReason,
            lastAssistantTs: lastAssistantTs,
            lastAwayTs: lastAwayTs,
            hasRecentQueueOp: hasRecentQueueOp,
            lastConversationTs: lastConversationTs,
            entrypoint: entrypoint,
            promptSource: promptSource,
            isSidechain: isSidechain,
            isSubagentPath: isSubagentPath
        )
    }
}
