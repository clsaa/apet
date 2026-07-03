import AppKit

/// 按 bundleId 取 app 图标,进程内缓存(图标不变)。取不到(未安装)→ nil,调用方兜底 SF Symbol。M3-D-D。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        let img: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = nil
        }
        cache[bundleId] = img
        return img
    }
}
