import Foundation

/// OpenCode 全局插件(`~/.config/opencode/plugins/apet-notify.js`)的门控安装(P1 增强)。
///
/// - 模板占位 `__APET_OUT__`/`__APET_ROOT__` 安装时烤入真值——**root 必须与 apet 的
///   OpenCode DB watcher 同键**(dirname(opencode.db)),否则插件事件与 DB 会话分裂
///  (前车之鉴:claude/claude-code 双 agent 会话重复 bug)。
/// - 硬约束 12(门控):调用方先展示 preview 用户确认;文件级安装,卸载=删文件;
///   目标已存在且**非 apet 所有**(无 marker 首行)→ 诚实拒绝,绝不覆盖用户插件。
public enum OpenCodePluginInstaller {
    public static let fileName = "apet-notify.js"
    static let marker = "// apet-notify"

    public enum Status: Equatable {
        case notInstalled
        case installed
        case occupiedByForeignFile   // 同名文件存在但不是 apet 的 → 拒绝动
    }

    public static func status(pluginPath: String,
                              read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Status {
        guard let content = read(pluginPath) else { return .notInstalled }
        return content.hasPrefix(marker) ? .installed : .occupiedByForeignFile
    }

    /// 渲染模板(烤入 out/root)。模板必须以 marker 开头(打包完整性检查)。
    public static func render(template: String, eventsPath: String, root: String) -> String? {
        guard template.hasPrefix(marker) else { return nil }
        return template
            .replacingOccurrences(of: "__APET_OUT__", with: jsEscape(eventsPath))
            .replacingOccurrences(of: "__APET_ROOT__", with: jsEscape(root))
    }

    /// JS 双引号字符串转义(路径含 " \ 时不破坏语法)。
    static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func previewLines(pluginPath: String, root: String) -> [String] {
        ["将写入:\(pluginPath)",
         "订阅 session.idle/question.asked → 发 apet 事件(root=\(root))",
         "不改动任何既有文件;关闭 = 删除该文件。"]
    }

    /// 安装。返回错误描述(nil=成功)。
    @discardableResult
    public static func install(pluginDir: String, templatePath: String,
                               eventsPath: String, root: String,
                               fm: FileManager = .default) -> String? {
        let dest = (pluginDir as NSString).appendingPathComponent(fileName)
        if case .occupiedByForeignFile = status(pluginPath: dest) {
            return "已存在同名插件且非 apet 所有,拒绝覆盖(请手动处理 \(dest))"
        }
        guard let template = try? String(contentsOfFile: templatePath, encoding: .utf8),
              let content = render(template: template, eventsPath: eventsPath, root: root) else {
            return "插件模板缺失或损坏(\(templatePath))"
        }
        do {
            try fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
            try content.write(toFile: dest, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "写入失败:\(error.localizedDescription)"
        }
    }

    @discardableResult
    public static func uninstall(pluginDir: String, fm: FileManager = .default) -> String? {
        let dest = (pluginDir as NSString).appendingPathComponent(fileName)
        switch status(pluginPath: dest) {
        case .notInstalled: return nil
        case .occupiedByForeignFile: return "该文件非 apet 所有,拒绝删除"
        case .installed:
            do { try fm.removeItem(atPath: dest); return nil }
            catch { return "删除失败:\(error.localizedDescription)" }
        }
    }
}
