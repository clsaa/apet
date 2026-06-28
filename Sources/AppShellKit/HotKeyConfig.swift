import Foundation

// MARK: - HotKeyConfig

/// 快捷键配置：虚拟键码 + Carbon 修饰键位 + 显示用键名。
///
/// Carbon 修饰键位字面量（无需 import Carbon）：
/// - cmdKey     = 256
/// - shiftKey   = 512
/// - optionKey  = 2048
/// - controlKey = 4096
public struct HotKeyConfig: Equatable, Codable {
    /// 虚拟键码（如 P = 35）。
    public var keyCode: UInt32
    /// Carbon 修饰键位（如 ⌥⌘ = 256 | 2048 = 2304）。
    public var modifiers: UInt32
    /// 显示用键名，如 `"P"`、`"F1"`。
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// 按 ⌃⌥⇧⌘ 固定顺序拼修饰符号，末尾加 keyLabel。
    ///
    /// 示例：`modifiers = 256|2048, keyLabel = "P"` → `"⌥⌘P"`
    public var displayString: String {
        var parts = ""
        if modifiers & 4096 != 0 { parts += "⌃" }  // controlKey
        if modifiers & 2048 != 0 { parts += "⌥" }  // optionKey
        if modifiers &  512 != 0 { parts += "⇧" }  // shiftKey
        if modifiers &  256 != 0 { parts += "⌘" }  // cmdKey
        return parts + keyLabel
    }

    /// 默认快捷键：⌥⌘P（optionKey | cmdKey，虚拟键码 35）。
    public static let defaultPanel = HotKeyConfig(
        keyCode: 35,
        modifiers: 256 | 2048,
        keyLabel: "P"
    )
}

// MARK: - NSEvent.ModifierFlags → Carbon modifier bits

/// 把 NSEvent.ModifierFlags.rawValue 转换为 Carbon RegisterEventHotKey 所用的修饰键位掩码。
///
/// NSEvent.ModifierFlags raw 位（不需要 import AppKit）：
/// - .command  = 1 << 20 = 1048576
/// - .shift    = 1 << 17 = 131072
/// - .option   = 1 << 19 = 524288
/// - .control  = 1 << 18 = 262144
///
/// Carbon 修饰键位（与 HotKeyConfig.modifiers 使用的值一致）：
/// - cmdKey     = 256
/// - shiftKey   = 512
/// - optionKey  = 2048
/// - controlKey = 4096
///
/// 纯函数，无 AppKit 依赖，可在 AppShellKitTests 中单测。
public func nsModifiersToCarbonModifiers(_ nsRawFlags: UInt) -> UInt32 {
    var result: UInt32 = 0
    if nsRawFlags & (1 << 20) != 0 { result |= 256 }   // .command  → cmdKey
    if nsRawFlags & (1 << 17) != 0 { result |= 512 }   // .shift    → shiftKey
    if nsRawFlags & (1 << 19) != 0 { result |= 2048 }  // .option   → optionKey
    if nsRawFlags & (1 << 18) != 0 { result |= 4096 }  // .control  → controlKey
    return result
}
