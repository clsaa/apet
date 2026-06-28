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
}
