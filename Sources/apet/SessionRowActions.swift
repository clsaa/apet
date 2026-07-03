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
        // M3-C+:opencode 目录敏感(TUI 按 cwd 解析 project),恢复命令带目录位置参数。
        if let cmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId,
                                           directory: s.cwd) {
            copyToPasteboard(cmd)
        } else {
            copyToPasteboard(s.key.sessionId)  // 未知 agent 兜底复制 ID
        }
    }

    /// opencode 点击弹窗(M3-C+ 评审 B3:诚实降级 + 把死路变恢复路径)。@MainActor 调用。
    /// 返回 true = 用户点了主按钮并已复制。
    /// 评审:复制按钮继承右键菜单的 hasResumeCommand 门控(产品 M3「不静默复制假命令」)——
    /// 异形 id(旧迁移/SDK 自带)拿不到恢复命令时按钮如实降级为「复制会话 ID」。
    @discardableResult
    static func showOpenCodeNoJumpAlert(_ s: Session) -> Bool {
        let hasCmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId,
                                           directory: s.cwd) != nil
        let alert = NSAlert()
        alert.messageText = "OpenCode 在终端中运行"
        alert.informativeText = hasCmd
            ? "apet 无法定位它所在的终端窗口。若该会话的终端还开着,直接切换过去即可;终端已关时,可复制恢复命令粘贴到项目目录的终端里打开该会话。"
            : "apet 无法定位它所在的终端窗口,且该会话 ID 来自旧版本、无可用恢复命令(可复制会话 ID 自行处理)。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: hasCmd ? "复制恢复命令" : "复制会话 ID")
        let cancel = alert.addButton(withTitle: "好")
        cancel.keyEquivalent = "\u{1b}"   // Esc 可取消(HIG;NSAlert 不给"好"自动绑 Esc)
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement:弹窗置前(既有惯例)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if hasCmd { copyResume(s) } else { copyId(s) }
        return true
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
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement：不激活则弹窗可能不在最前（用户评审 M5）
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
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement：确保弹窗在最前（用户评审 M5）
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .set(name.isEmpty ? nil : name)
    }

    /// 该会话是否有已核实的恢复命令（决定菜单项显示，产品评审 M3：不静默复制假命令）。
    static func hasResumeCommand(agent: String, sessionId: String) -> Bool {
        ResumeCommand.argv(agent: agent, sessionId: sessionId) != nil
    }
}
