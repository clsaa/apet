import XCTest
@testable import AppShellKit

/// OpenCode 插件门控安装:模板渲染/外人文件拒绝/装卸往返。
final class OpenCodePluginInstallerTests: XCTestCase {
    private var dir: String!
    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "oc-plugin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir); super.tearDown() }

    private let template = """
    // apet-notify — test template
    const OUT = "__APET_OUT__"
    const ROOT = "__APET_ROOT__"
    """

    func test_render_bakesPaths() {
        let out = OpenCodePluginInstaller.render(template: template,
                                                 eventsPath: "/e/events.ndjson", root: "/r/opencode")!
        XCTAssertTrue(out.contains(#"const OUT = "/e/events.ndjson""#))
        XCTAssertTrue(out.contains(#"const ROOT = "/r/opencode""#))
    }

    func test_render_rejectsTemplateWithoutMarker() {
        XCTAssertNil(OpenCodePluginInstaller.render(template: "export const X = 1",
                                                    eventsPath: "/e", root: "/r"),
                     "模板缺 marker(打包损坏)→ 拒绝")
    }

    func test_render_escapesQuotesInPath() {
        let out = OpenCodePluginInstaller.render(template: template,
                                                 eventsPath: #"/we"ird/ev.ndjson"#, root: "/r")!
        XCTAssertTrue(out.contains(#"const OUT = "/we\"ird/ev.ndjson""#), out)
    }

    func test_installUninstall_roundTrip() {
        let tpl = dir + "/tpl.js"
        try! template.write(toFile: tpl, atomically: true, encoding: .utf8)
        let pluginDir = dir + "/plugins"

        XCTAssertNil(OpenCodePluginInstaller.install(pluginDir: pluginDir, templatePath: tpl,
                                                     eventsPath: "/e", root: "/r"))
        let dest = pluginDir + "/apet-notify.js"
        XCTAssertEqual(OpenCodePluginInstaller.status(pluginPath: dest), .installed)
        // 幂等重装
        XCTAssertNil(OpenCodePluginInstaller.install(pluginDir: pluginDir, templatePath: tpl,
                                                     eventsPath: "/e", root: "/r"))
        // 卸载 = 删文件
        XCTAssertNil(OpenCodePluginInstaller.uninstall(pluginDir: pluginDir))
        XCTAssertEqual(OpenCodePluginInstaller.status(pluginPath: dest), .notInstalled)
    }

    func test_foreignFile_refusedBothWays() {
        let pluginDir = dir + "/plugins"
        try! FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
        let dest = pluginDir + "/apet-notify.js"
        try! "export const UserOwn = 1".write(toFile: dest, atomically: true, encoding: .utf8)
        let tpl = dir + "/tpl.js"
        try! template.write(toFile: tpl, atomically: true, encoding: .utf8)

        XCTAssertNotNil(OpenCodePluginInstaller.install(pluginDir: pluginDir, templatePath: tpl,
                                                        eventsPath: "/e", root: "/r"),
                        "外人同名文件 → 拒绝覆盖")
        XCTAssertNotNil(OpenCodePluginInstaller.uninstall(pluginDir: pluginDir), "外人文件 → 拒绝删除")
        XCTAssertEqual(try! String(contentsOfFile: dest, encoding: .utf8), "export const UserOwn = 1",
                       "用户文件原样")
    }
}
