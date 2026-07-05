import AppKit
import AgentPetCore
import AppShellKit

/// 会话行操作的共享执行（F7 重命名、F11 复制 ID/恢复命令）。菜单栏 popover 与宠物 popover 共用。
/// 收藏/重命名的**持久化**由 AppCoordinator 经 SessionMetaStore 完成；这里只管剪贴板与输入弹窗。
enum SessionRowActions {
    /// 临时诊断:摘要路径写日志到 apet.log,便于定位「点了没反应」。
    static func summaryDebug(_ msg: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentPet")
        let url = dir.appendingPathComponent("apet.log")
        let line = "[summary] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
    }


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

    /// M3-D①：免费本地摘要——定位 jsonl → 读尾部 → 提取对话 → 启发式一句话，弹窗展示。
    /// 快速摘要(本地即时零成本):读转录**开头**若干轮 → 第一条真实用户指令 = 会话主题。
    /// 「这个会话在做什么」的近似答案,一句话/几个字。找不到文件如实提示。
    static func quickSummary(_ s: Session) -> SummaryResult {
        summaryDebug("quick 入口 agent=\(s.key.agent) root=\(s.key.root) sid=\(s.key.sessionId) cwd=\(s.cwd ?? "nil")")
        guard let path = SessionTranscriptLocator.find(root: s.key.root, sessionId: s.key.sessionId) else {
            summaryDebug("quick 找不到转录 sid=\(s.key.sessionId)")
            return .error("该会话没有本地对话记录,无法摘要")
        }
        summaryDebug("quick 命中转录 path=\(path)")
        let headLines = TailLineReader.firstLines(path: path, maxLines: 80)
        guard !headLines.isEmpty else { return .error("会话暂无可总结内容") }
        let turns = ConversationTailParser.turns(lines: headLines)
        let summary = LocalSummarizer.summarize(turns: turns)
        return summary.hasPrefix("（") ? .error("会话暂无可总结内容") : .text(summary)
    }

    /// AI 摘要:定位会话转录 → 读**开头(开场任务)+结尾(近期)** → 后台跑 `claude -p` 出一句短标题。
    /// 用本机已装 claude CLI(无额外 key);找不到文件/无 claude/失败均如实提示。
    static func aiSummary(_ s: Session) async -> SummaryResult {
        summaryDebug("ai 入口 agent=\(s.key.agent) root=\(s.key.root) sid=\(s.key.sessionId)")
        guard let path = SessionTranscriptLocator.find(root: s.key.root, sessionId: s.key.sessionId) else {
            summaryDebug("ai 找不到转录 sid=\(s.key.sessionId)")
            return .error("该会话没有本地对话记录(可能是极短会话或 -p 模式),无法摘要")
        }
        // 会话主题最强信号是开场任务;近期给一点上下文。喂「开头 + 结尾」两段。
        let headLines = TailLineReader.firstLines(path: path, maxLines: 60)
        let tailLines: [String]
        if case .ok(let l) = TailLineReader.lastLines(path: path, maxLines: 120, maxBytes: 262_144) { tailLines = l } else { tailLines = [] }
        let headTurns = ConversationTailParser.turns(lines: headLines)
        let tailTurns = ConversationTailParser.turns(lines: tailLines)
        guard !headTurns.isEmpty || !tailTurns.isEmpty else { return .error("会话暂无可总结内容") }
        let opening = headTurns.prefix(6).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let recent = tailTurns.suffix(8).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let tail = "【会话开场】\n\(opening)\n\n【最近进展】\n\(recent)"
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

    /// 跳转失败的行内提示条内容(取代全屏 NSAlert;文案按 agent 诚实分型)。
    static func jumpFailureNotice(_ s: Session, hookHint: Bool) -> RowNotice {
        let agent = s.key.agent
        let resumeCmd = ResumeCommand.display(agent: agent, sessionId: s.key.sessionId,
                                              directory: agent == "opencode" ? s.cwd : nil)
        let text: String
        if agent == "opencode" {
            text = "OpenCode 在终端中运行,无法定位其窗口;终端已关时可用恢复命令重开。"
        } else if agent.hasPrefix("codex") {
            text = "Codex 会话记录不含终端信息,暂不支持跳转。"
        } else {
            text = "未能跳到会话终端(可能已关闭)。"
        }
        let copy: (String, String)? = resumeCmd.map { ("复制恢复命令", $0) }
            ?? (text.isEmpty ? nil : ("复制会话 ID", s.key.sessionId))
        return RowNotice(text: text,
                         copyAction: copy.map { (label: $0.0, payload: $0.1) },
                         showHookHint: hookHint)
    }

    /// 该会话是否有已核实的恢复命令（决定菜单项显示，产品评审 M3：不静默复制假命令）。
    static func hasResumeCommand(agent: String, sessionId: String) -> Bool {
        ResumeCommand.argv(agent: agent, sessionId: sessionId) != nil
    }
}
