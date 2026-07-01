import AppKit
import AgentPetCore

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
