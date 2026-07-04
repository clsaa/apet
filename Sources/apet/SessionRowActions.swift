import AppKit
import AgentPetCore
import AppShellKit

/// 会话行操作的共享执行（F7 重命名、F11 复制 ID/恢复命令）。菜单栏 popover 与宠物 popover 共用。
/// 收藏/重命名的**持久化**由 AppCoordinator 经 SessionMetaStore 完成；这里只管剪贴板与输入弹窗。
enum SessionRowActions {


    static func copyToPasteboard(_ text: String, hud: String? = "已复制") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let hud { CopyHUD.flash(hud) }   // B3:瞬时反馈,不再静默
    }

    static func copyId(_ s: Session) { copyToPasteboard(s.key.sessionId) }

    static func copyResume(_ s: Session) {
        // M3-C+:opencode 目录敏感(TUI 按 cwd 解析 project),恢复命令带目录位置参数。
        if let cmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId,
                                           directory: s.cwd) {
            copyToPasteboard(cmd)
        } else {
            copyToPasteboard(s.key.sessionId, hud: "已复制会话 ID")  // 未知 agent 兜底
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
            : "apet 无法定位它所在的终端窗口,且该会话 ID 格式无法核实(旧迁移或 SDK 自带),无可用恢复命令(可复制会话 ID 自行处理)。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: hasCmd ? "复制恢复命令" : "复制会话 ID")
        // HIG(实现评审):与动作按钮并排的配对按钮用「取消」而非确认词「好」。
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"   // Esc 可取消(HIG;NSAlert 不给"好"自动绑 Esc)
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement:弹窗置前(既有惯例)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if hasCmd { copyResume(s) } else { copyId(s) }
        return true
    }

    /// M3-D①：免费本地摘要——定位 jsonl → 读尾部 → 提取对话 → 启发式一句话，弹窗展示。
    /// AI 摘要:定位会话转录 → 读 tail → 后台跑 `claude -p` 出一句中文总结。
    /// 用本机已装 claude CLI(无额外 key);找不到文件/无 claude/失败均如实提示。
    static func aiSummary(_ s: Session) async -> SummaryResult {
        guard let path = SessionTranscriptLocator.find(root: s.key.root, sessionId: s.key.sessionId),
              case .ok(let lines) = TailLineReader.lastLines(path: path, maxLines: 200, maxBytes: 524_288) else {
            return .error("找不到该会话的记录文件,无法生成 AI 摘要")
        }
        let turns = ConversationTailParser.turns(lines: lines)
        guard !turns.isEmpty else { return .error("会话暂无可总结内容") }
        let tail = turns.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let cwd = s.cwd ?? NSHomeDirectory()
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let svc = SummarizerService(runner: RealProcessRunner(),
                                            resolveExecutable: ExecutableLocator.resolve)
                switch svc.summarize(tail: tail, cwd: cwd, timeout: 45) {
                case .success(let text):
                    cont.resume(returning: .text(text))
                case .failure(let err):
                    let msg: String
                    switch err {
                    case SummarizerService.SummaryError.executableNotFound:
                        msg = "未找到 claude 命令(需装 Claude Code CLI 才能生成 AI 摘要)"
                    case SummarizerService.SummaryError.emptyOutput:
                        msg = "AI 未返回摘要,稍后再试"
                    case SummarizerService.SummaryError.nonZeroExit(let e):
                        msg = "生成失败:\(e.prefix(80))"
                    default:
                        msg = "生成失败:\(err.localizedDescription)"
                    }
                    cont.resume(returning: .error(msg))
                }
            }
        }
    }

    /// 该会话是否有已核实的恢复命令（决定菜单项显示，产品评审 M3：不静默复制假命令）。
    static func hasResumeCommand(agent: String, sessionId: String) -> Bool {
        ResumeCommand.argv(agent: agent, sessionId: sessionId) != nil
    }
}
