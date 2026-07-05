import XCTest
@testable import AppShellKit

/// Codex notify 链式安装:单行 TOML 改写(fixture 取自本机真实 config.toml 形态)。
final class CodexNotifyInstallerTests: XCTestCase {
    private let script = "/Applications/AgentPet.app/Contents/Resources/apet-codex-notify.sh"

    // 真机形态:notify 已被 Codex Desktop 占用
    private let occupied = """
    model = "gpt-5.5"

    notify = ["/Users/x/.codex/computer-use/Sky.app/Contents/MacOS/SkyClient", "turn-ended"]

    [projects."/Users/x"]
    trust_level = "trusted"
    """

    private let noNotify = """
    model = "gpt-5.5"

    [projects."/Users/x"]
    trust_level = "trusted"
    """

    func test_status_occupied_notInstalled_withExisting() {
        guard case .notInstalled(let existing) =
                CodexNotifyInstaller.status(configText: occupied, scriptPath: script) else {
            return XCTFail()
        }
        XCTAssertEqual(existing, ["/Users/x/.codex/computer-use/Sky.app/Contents/MacOS/SkyClient", "turn-ended"])
    }

    func test_install_chainsExistingNotify() {
        let out = CodexNotifyInstaller.installedText(configText: occupied, scriptPath: script)!
        XCTAssertTrue(out.contains(
            #"notify = ["\#(script)", "/Users/x/.codex/computer-use/Sky.app/Contents/MacOS/SkyClient", "turn-ended"]"#),
            "原程序链式保留: \(out)")
        // 幂等:再装不变
        XCTAssertEqual(CodexNotifyInstaller.installedText(configText: out, scriptPath: script), out)
        // status → installed
        guard case .installed(let chained) = CodexNotifyInstaller.status(configText: out, scriptPath: script) else {
            return XCTFail()
        }
        XCTAssertEqual(chained.count, 2)
    }

    func test_install_noExistingNotify_insertsAtTop() {
        let out = CodexNotifyInstaller.installedText(configText: noNotify, scriptPath: script)!
        XCTAssertTrue(out.hasPrefix(#"notify = ["\#(script)"]"#), out)
        XCTAssertTrue(out.contains("model = \"gpt-5.5\""), "原内容保留")
    }

    func test_uninstall_restoresOriginalChain() {
        let installed = CodexNotifyInstaller.installedText(configText: occupied, scriptPath: script)!
        let restored = CodexNotifyInstaller.uninstalledText(configText: installed, scriptPath: script)!
        XCTAssertEqual(restored, occupied, "卸载恢复原样(链剥离)")
    }

    func test_uninstall_noChain_removesLine() {
        let installed = CodexNotifyInstaller.installedText(configText: noNotify, scriptPath: script)!
        let restored = CodexNotifyInstaller.uninstalledText(configText: installed, scriptPath: script)!
        XCTAssertFalse(restored.contains("notify"), "原本无 notify → 整行移除")
        XCTAssertTrue(restored.contains("model = \"gpt-5.5\""))
    }

    func test_sectionNotify_notTouched() {
        // section 内的 notify 键(非顶层)不得误改
        let cfg = """
        model = "x"

        [tui]
        notify = ["something"]
        """
        guard case .notInstalled(let existing) = CodexNotifyInstaller.status(configText: cfg, scriptPath: script) else {
            return XCTFail()
        }
        XCTAssertNil(existing, "section 内 notify 不算顶层")
        let out = CodexNotifyInstaller.installedText(configText: cfg, scriptPath: script)!
        XCTAssertTrue(out.contains(#"[tui]"#) && out.contains(#"notify = ["something"]"#), "section 内容原样")
    }

    func test_multilineNotify_unsupported_refused() {
        let cfg = """
        notify = [
            "prog", "arg"
        ]
        """
        guard case .unsupported = CodexNotifyInstaller.status(configText: cfg, scriptPath: script) else {
            return XCTFail("多行数组须诚实拒绝")
        }
        XCTAssertNil(CodexNotifyInstaller.installedText(configText: cfg, scriptPath: script))
        XCTAssertNil(CodexNotifyInstaller.uninstalledText(configText: cfg, scriptPath: script))
    }

    func test_escapedQuotesAndComment_parsed() {
        let cfg = #"notify = ["/path/with \"q\"", "a\\b"]  # comment"#
        guard case .notInstalled(let existing) = CodexNotifyInstaller.status(configText: cfg, scriptPath: script) else {
            return XCTFail()
        }
        XCTAssertEqual(existing, [#"/path/with "q""#, #"a\b"#])
    }

    func test_emptyConfig_installCreatesNotify() {
        let out = CodexNotifyInstaller.installedText(configText: "", scriptPath: script)!
        XCTAssertTrue(out.hasPrefix("notify = ["))
    }

    func test_previewLines_showBeforeAfter() {
        let lines = CodexNotifyInstaller.previewLines(configText: occupied, scriptPath: script)
        XCTAssertTrue(lines[0].contains("SkyClient"), "现状含原程序")
        XCTAssertTrue(lines[1].contains(script), "变更后含 apet 脚本")
        XCTAssertTrue(lines.count >= 3, "占用场景须说明链式保留")
    }

    // MARK: - IO(临时文件)

    func test_install_io_backsUpAndWrites() {
        let dir = NSTemporaryDirectory() + "codex-inst-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cfg = dir + "/config.toml"
        try! occupied.write(toFile: cfg, atomically: true, encoding: .utf8)

        XCTAssertNil(CodexNotifyInstaller.install(configPath: cfg, scriptPath: script))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg + ".apet.bak"), "写前备份")
        let written = try! String(contentsOfFile: cfg, encoding: .utf8)
        XCTAssertTrue(written.contains(script))
        XCTAssertEqual(try! String(contentsOfFile: cfg + ".apet.bak", encoding: .utf8), occupied, "备份=原文")

        XCTAssertNil(CodexNotifyInstaller.uninstall(configPath: cfg, scriptPath: script))
        XCTAssertEqual(try! String(contentsOfFile: cfg, encoding: .utf8), occupied, "卸载恢复原样")
    }
}
