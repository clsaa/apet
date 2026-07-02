import AppKit
import AgentPetCore
import AppShellKit

/// 会话行操作的共享执行（F7 重命名、F11 复制 ID/恢复命令）。菜单栏 popover 与宠物 popover 共用。
/// 收藏/重命名的**持久化**由 AppCoordinator 经 SessionMetaStore 完成；这里只管剪贴板与输入弹窗。
enum SessionRowActions {

    enum RenameResult { case cancel; case set(String?) }  // set(nil) = 恢复默认名

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copyId(_ s: Session) { copyToPasteboard(s.key.sessionId) }

    static func copyResume(_ s: Session) {
        if let cmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId) {
            copyToPasteboard(cmd)
        } else {
            copyToPasteboard(s.key.sessionId)  // 未知 agent 兜底复制 ID
        }
    }

    /// M3-D①：免费本地摘要——定位 jsonl → 读尾部 → 提取对话 → 启发式一句话，弹窗展示。
    /// 全程本地零网络零成本；找不到文件/无内容时如实提示。
    static func showLocalSummary(_ s: Session) {
        let summary: String
        if let path = SessionTranscriptLocator.find(root: s.key.root, sessionId: s.key.sessionId),
           case .ok(let lines) = TailLineReader.lastLines(path: path, maxLines: 100, maxBytes: 524_288) {
            summary = LocalSummarizer.summarize(turns: ConversationTailParser.turns(lines: lines))
        } else {
            summary = "（找不到该会话的记录文件，无法生成摘要）"
        }
        let alert = NSAlert()
        alert.messageText = "会话摘要（本地）"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "复制")
        if alert.runModal() == .alertSecondButtonReturn {
            copyToPasteboard(summary)
        }
    }

    /// 弹输入框改名；取消→`.cancel`，确定→`.set(名字或 nil)`。
    static func promptRename(_ s: Session) -> RenameResult {
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = "留空则恢复默认名称。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = s.customName ?? ""
        alert.accessoryView = tf
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .set(name.isEmpty ? nil : name)
    }
}
