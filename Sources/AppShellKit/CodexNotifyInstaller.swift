import Foundation

/// Codex `config.toml` 的 notify 链式安装(M3-C++ CLI 精确跳转)。
///
/// Codex 只支持**一个** notify 程序;真机实锤该位可能已被占用(如 Codex Desktop 的
/// SkyComputerUseClient)。直接覆盖会弄坏原功能 → **链式包装**:
/// `notify = ["<apet脚本>", "<原程序>", "<原参数>..."]`——apet 脚本收到 payload 后先原样
/// 转发给原程序,再自己发事件。卸载 = 把首元素(apet 脚本)剥掉还原。
///
/// 硬约束 12(门控):绝不自动写;调用方必须先展示 `previewLines` 用户确认;写前自动备份
/// `config.toml.apet.bak`;可一键卸载。
///
/// TOML 处理为**单行 notify 的行级改写**(codex 实际写法;多行数组/罕见形态 → 诚实拒绝,
/// 零第三方依赖不引入完整 TOML 解析器)。只动第一个 `[section]` 之前的顶层 notify。
public enum CodexNotifyInstaller {

    public enum Status: Equatable {
        case notInstalled(existingNotify: [String]?)   // nil = 原本无 notify
        case installed(chained: [String])              // 已装;chained = 链着的原 argv(空=原本无)
        case unsupported(reason: String)               // 多行数组等无法安全改写
    }

    // MARK: - 纯逻辑(String → String,可测)

    /// 解析顶层单行 `notify = ["a", "b"]` → argv。无 notify → nil。无法解析 → .unsupported。
    public static func status(configText: String, scriptPath: String) -> Status {
        guard let (_, argv) = topLevelNotifyLine(configText) else {
            if hasUnparsableNotify(configText) {
                return .unsupported(reason: "notify 配置为多行/复杂形态,无法安全改写")
            }
            return .notInstalled(existingNotify: nil)
        }
        if argv.first == scriptPath {
            return .installed(chained: Array(argv.dropFirst()))
        }
        return .notInstalled(existingNotify: argv)
    }

    /// 安装改写:已装 → 原样;未装 → notify 行替换/插入为 [script, 原argv...]。
    /// 返回 nil = unsupported(调用方拒绝写)。
    public static func installedText(configText: String, scriptPath: String) -> String? {
        switch status(configText: configText, scriptPath: scriptPath) {
        case .installed: return configText
        case .unsupported: return nil
        case .notInstalled(let existing):
            let newArgv = [scriptPath] + (existing ?? [])
            let newLine = renderNotifyLine(newArgv)
            if let (lineIdx, _) = topLevelNotifyLine(configText) {
                var lines = configText.components(separatedBy: "\n")
                lines[lineIdx] = newLine
                return lines.joined(separator: "\n")
            }
            // 无 notify:插到文件顶部(顶层区)
            return newLine + "\n" + configText
        }
    }

    /// 卸载改写:剥掉首元素(apet 脚本)。原本无链 → 整行移除。未装 → 原样。
    public static func uninstalledText(configText: String, scriptPath: String) -> String? {
        switch status(configText: configText, scriptPath: scriptPath) {
        case .notInstalled: return configText
        case .unsupported: return nil
        case .installed(let chained):
            guard let (lineIdx, _) = topLevelNotifyLine(configText) else { return configText }
            var lines = configText.components(separatedBy: "\n")
            if chained.isEmpty {
                lines.remove(at: lineIdx)
            } else {
                lines[lineIdx] = renderNotifyLine(chained)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 预览(门控展示用):变更前后 notify 行。
    public static func previewLines(configText: String, scriptPath: String) -> [String] {
        let before = topLevelNotifyLine(configText).map { $0.1 }
        let after: [String] = [scriptPath] + (before ?? [])
        var out: [String] = []
        out.append("现在:" + (before.map { renderNotifyLine($0) } ?? "(无 notify 配置)"))
        out.append("将改为:" + renderNotifyLine(after))
        if before != nil {
            out.append("原 notify 程序将被链式保留(apet 收到事件后原样转发,不影响其功能)。")
        }
        return out
    }

    // MARK: - IO(备份 + 写)

    /// 安装到真实文件:备份 `config.toml.apet.bak` 后改写。返回错误描述(nil=成功)。
    @discardableResult
    public static func install(configPath: String, scriptPath: String,
                               fm: FileManager = .default) -> String? {
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        guard let newText = installedText(configText: text, scriptPath: scriptPath) else {
            return "notify 配置形态无法安全改写(多行/复杂 TOML),请手动配置"
        }
        guard newText != text else { return nil }   // 已装,无事可做
        let bak = configPath + ".apet.bak"
        try? fm.removeItem(atPath: bak)
        try? fm.copyItem(atPath: configPath, toPath: bak)   // 无原文件时忽略(新建场景)
        do {
            try newText.write(toFile: configPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "写入失败:\(error.localizedDescription)"
        }
    }

    @discardableResult
    public static func uninstall(configPath: String, scriptPath: String,
                                 fm: FileManager = .default) -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        guard let newText = uninstalledText(configText: text, scriptPath: scriptPath) else {
            return "notify 配置形态无法安全改写,请手动移除"
        }
        guard newText != text else { return nil }
        do {
            try newText.write(toFile: configPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "写入失败:\(error.localizedDescription)"
        }
    }

    // MARK: - 行级 TOML 助手

    /// 顶层(首个 [section] 前)单行 notify → (行号, argv)。
    static func topLevelNotifyLine(_ text: String) -> (Int, [String])? {
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }          // 进入 section,顶层区结束
            guard t.hasPrefix("notify") else { continue }
            let afterKey = t.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            let value = afterKey.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let argv = parseTomlStringArray(value) else { return nil }   // 单行但解析失败→按 unsupported 走
            return (i, argv)
        }
        return nil
    }

    /// 是否存在顶层 notify 但不可按单行解析(多行数组等)。
    static func hasUnparsableNotify(_ text: String) -> Bool {
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return false }
            if t.hasPrefix("notify"),
               t.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                let value = t.drop(while: { $0 != "=" }).dropFirst().trimmingCharacters(in: .whitespaces)
                return parseTomlStringArray(value) == nil
            }
        }
        return false
    }

    /// 解析单行 TOML 字符串数组 `["a", "b"]`(basic string,支持 \" \\ 转义)。失败 → nil。
    static func parseTomlStringArray(_ s: String) -> [String]? {
        var chars = Array(s), i = 0
        func skipWs() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        skipWs()
        guard i < chars.count, chars[i] == "[" else { return nil }
        i += 1
        var out: [String] = []
        while true {
            skipWs()
            guard i < chars.count else { return nil }
            if chars[i] == "]" { i += 1; break }
            guard chars[i] == "\"" else { return nil }
            i += 1
            var cur = ""
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    cur.append(n == "n" ? "\n" : n == "t" ? "\t" : n)
                    i += 2
                } else { cur.append(chars[i]); i += 1 }
            }
            guard i < chars.count else { return nil }   // 未闭合引号
            i += 1
            out.append(cur)
            skipWs()
            if i < chars.count, chars[i] == "," { i += 1 }
        }
        skipWs()
        // 行尾只允许注释/空白
        if i < chars.count, chars[i] != "#" { return nil }
        return out
    }

    /// 渲染单行 notify(basic string 转义 \ 与 ")。
    static func renderNotifyLine(_ argv: [String]) -> String {
        let items = argv.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "notify = [" + items.joined(separator: ", ") + "]"
    }
}
