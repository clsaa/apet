import Foundation
import Carbon

// MARK: - HotKeyManager

/// Carbon 全局快捷键管理器。
///
/// 使用 `RegisterEventHotKey` + `InstallEventHandler` 注册系统级热键，
/// **无需辅助功能权限**。热键触发时在主线程调用 `onActivate`。
///
/// 用法：
/// ```swift
/// let hkm = HotKeyManager()
/// hkm.onActivate = { print("hot key fired") }
/// hkm.register(keyCode: 35, modifiers: 256 | 2048)   // ⌥⌘P
/// ```
final class HotKeyManager {

    // MARK: - Public API

    /// 热键被触发时调用（在主线程）。
    var onActivate: (() -> Void)?

    // MARK: - Private state

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Lifecycle

    deinit {
        unregister()
    }

    // MARK: - Registration

    /// 注册全局热键。若已注册旧热键，先自动注销再注册新的。
    ///
    /// - Parameters:
    ///   - keyCode: 虚拟键码（如 P = 35，与 `HotKeyConfig.keyCode` 一致）。
    ///   - modifiers: Carbon 修饰键位（cmdKey=256 / shiftKey=512 / optionKey=2048 / controlKey=4096，
    ///     与 `HotKeyConfig.modifiers` 一致，可直接透传）。
    /// - Returns: 注册是否成功（评审修复 产品M4：失败不再静默，供 UI 提示"可能被占用"）。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        // 事件类型：键盘类 hot-key-pressed
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 把 self 作为 userData 透传到 C 回调（不 retain；HotKeyManager 的生命周期由调用者持有）
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // C 回调：非捕获闭包，可作为 @convention(c) 函数指针传给 Carbon
        let callback: EventHandlerProcPtr = { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon 事件在主线程投递，用 async 让 onActivate 在下一 runloop tick 执行，
            // 避免在 Carbon 事件处理栈内直接弹窗/操作 UI 产生重入问题。
            DispatchQueue.main.async {
                manager.onActivate?()
            }
            return noErr
        }

        // 安装事件处理器
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        // 注册热键（signature 'apet' = 0x61706574，id 固定为 1）
        let hotKeyID = EventHotKeyID(signature: 0x61706574, id: 1)
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            // 注册失败（如快捷键被其他 App 占用）——清理并上报（不崩溃）
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
            return false
        }
        return true
    }

    /// 注销当前热键及事件处理器。
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}
