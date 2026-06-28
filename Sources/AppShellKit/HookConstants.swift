import Foundation

// MARK: - HookConstants

/// 与 emit-event.sh 共享的 hook 协议常量。
///
/// `marker` 写入每条 NDJSON 事件行，接收方以此过滤非 apet 行。
public enum HookConstants {
    /// NDJSON 行中标识 apet 事件的标记字符串。
    public static let marker = "apet-1"
}
