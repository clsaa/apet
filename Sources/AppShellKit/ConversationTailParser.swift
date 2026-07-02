import Foundation
import AgentPetCore

/// 纯函数：jsonl 尾部行 → ``ConversationTurn`` 列表（供 ``LocalSummarizer`` 本地摘要）。
/// 只认 user / assistant 行；坏行/元数据行跳过。content 兼容字符串与块数组两种形态。
public enum ConversationTailParser {

    public static func turns(lines: [String]) -> [ConversationTurn] {
        lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any]
            else { return nil }

            let text = extractText(message["content"])
            let stopReason = message["stop_reason"] as? String
            return ConversationTurn(role: type, text: text, stopReason: stopReason)
        }
    }

    /// content 两种形态：纯字符串，或 `[{"type":"text","text":...}, {"type":"tool_use",...}]` 块数组。
    /// 块数组只拼接 text 块；无 text 块（纯 tool_use）→ 空串。
    private static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
    }
}
