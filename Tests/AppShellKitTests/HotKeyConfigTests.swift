import XCTest
@testable import AppShellKit

final class HotKeyConfigTests: XCTestCase {

    // MARK: - displayString

    /// ⌥⌘P：modifiers = 256|2048 = 2304，keyLabel = "P" → "⌥⌘P"
    func test_displayString_optionCommand_P() {
        let cfg = HotKeyConfig(keyCode: 35, modifiers: 256 | 2048, keyLabel: "P")
        XCTAssertEqual(cfg.displayString, "⌥⌘P")
    }

    /// ⌃⇧A：modifiers = 4096|512 = 4608，keyLabel = "A" → "⌃⇧A"
    func test_displayString_controlShift_A() {
        let cfg = HotKeyConfig(keyCode: 0, modifiers: 4096 | 512, keyLabel: "A")
        XCTAssertEqual(cfg.displayString, "⌃⇧A")
    }

    /// 全修饰 ⌃⌥⇧⌘X：modifiers = 4096|2048|512|256，keyLabel = "X" → "⌃⌥⇧⌘X"
    func test_displayString_allModifiers_X() {
        let cfg = HotKeyConfig(keyCode: 0, modifiers: 4096 | 2048 | 512 | 256, keyLabel: "X")
        XCTAssertEqual(cfg.displayString, "⌃⌥⇧⌘X")
    }

    /// 无修饰（modifiers = 0），keyLabel = "F1" → "F1"
    func test_displayString_noModifiers_F1() {
        let cfg = HotKeyConfig(keyCode: 0, modifiers: 0, keyLabel: "F1")
        XCTAssertEqual(cfg.displayString, "F1")
    }

    /// defaultPanel.displayString == "⌥⌘P"
    func test_defaultPanel_displayString() {
        XCTAssertEqual(HotKeyConfig.defaultPanel.displayString, "⌥⌘P")
    }

    // MARK: - defaultPanel 字段

    func test_defaultPanel_keyCode_is35() {
        XCTAssertEqual(HotKeyConfig.defaultPanel.keyCode, 35)
    }

    func test_defaultPanel_modifiers_isOptionCommand() {
        XCTAssertEqual(HotKeyConfig.defaultPanel.modifiers, 256 | 2048)
    }

    func test_defaultPanel_keyLabel_isP() {
        XCTAssertEqual(HotKeyConfig.defaultPanel.keyLabel, "P")
    }

    // MARK: - Equatable

    func test_equatable_sameValues_equal() {
        let a = HotKeyConfig(keyCode: 35, modifiers: 2304, keyLabel: "P")
        let b = HotKeyConfig(keyCode: 35, modifiers: 2304, keyLabel: "P")
        XCTAssertEqual(a, b)
    }

    func test_equatable_differentKeyLabel_notEqual() {
        let a = HotKeyConfig(keyCode: 35, modifiers: 2304, keyLabel: "P")
        let b = HotKeyConfig(keyCode: 35, modifiers: 2304, keyLabel: "Q")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let original = HotKeyConfig(keyCode: 35, modifiers: 2304, keyLabel: "P")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotKeyConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - nsModifiersToCarbonModifiers

    /// NSEvent.ModifierFlags.command.rawValue (1<<20) → cmdKey (256)
    func test_nsModifiers_command_only() {
        let nsRaw: UInt = 1 << 20   // .command = 1048576
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 256)
    }

    /// NSEvent.ModifierFlags.option.rawValue (1<<19) → optionKey (2048)
    func test_nsModifiers_option_only() {
        let nsRaw: UInt = 1 << 19   // .option = 524288
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 2048)
    }

    /// NSEvent.ModifierFlags.shift.rawValue (1<<17) → shiftKey (512)
    func test_nsModifiers_shift_only() {
        let nsRaw: UInt = 1 << 17   // .shift = 131072
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 512)
    }

    /// NSEvent.ModifierFlags.control.rawValue (1<<18) → controlKey (4096)
    func test_nsModifiers_control_only() {
        let nsRaw: UInt = 1 << 18   // .control = 262144
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 4096)
    }

    /// ⌥⌘ (option | command) → 2048 | 256 = 2304（⌥⌘P 默认快捷键修饰组合）
    func test_nsModifiers_optionCommand() {
        let nsRaw: UInt = (1 << 19) | (1 << 20)   // .option | .command
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 2048 | 256)
    }

    /// 全修饰（⌃⌥⇧⌘）→ 4096 | 2048 | 512 | 256 = 6912
    func test_nsModifiers_allFour() {
        let nsRaw: UInt = (1 << 20) | (1 << 17) | (1 << 19) | (1 << 18)
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 256 | 512 | 2048 | 4096)
    }

    /// 无修饰位 → 0
    func test_nsModifiers_none() {
        XCTAssertEqual(nsModifiersToCarbonModifiers(0), 0)
    }

    /// 不相关位（如 .numericPad = 1<<21）不映射到任何 Carbon 修饰位
    func test_nsModifiers_numericPad_ignored() {
        let nsRaw: UInt = 1 << 21   // .numericPad — not mapped to Carbon modifiers
        XCTAssertEqual(nsModifiersToCarbonModifiers(nsRaw), 0)
    }
}
