import Foundation

public struct ScriptInvocation: Equatable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable; self.arguments = arguments
    }
}

public enum LocatorCapability { case precise, activateOnly }
public enum LocatorError: Error, Equatable { case invalidRef, missingRef }

public protocol TerminalLocator {
    var kind: TerminalKind { get }
    var capability: LocatorCapability { get }
    func focusInvocation(for ref: TerminalRef) throws -> ScriptInvocation
}

/// iTerm2 session id 白名单校验：只允许字母数字与 ` : _ - `，杜绝引号/空格/换行注入。
public enum ITermSessionId {
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { c in
            c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-"
        }
    }
}

public struct ITerm2Locator: TerminalLocator {
    public init() {}
    public var kind: TerminalKind { .iterm2 }
    public var capability: LocatorCapability { .precise }

    /// 参数化 AppleScript：id 经 argv 传入，绝不字符串内插。设计 §3.1 / §7。
    private static let script = """
    on run argv
        set targetId to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is targetId then
                            select w
                            select t
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
    end run
    """

    public func focusInvocation(for ref: TerminalRef) throws -> ScriptInvocation {
        guard let id = ref.itermSessionId else { throw LocatorError.missingRef }
        guard ITermSessionId.isValid(id) else { throw LocatorError.invalidRef }
        // osascript -  <id>   ：脚本读 stdin，id 作为 argv（"-" 表示从 stdin 读脚本）
        return ScriptInvocation(executable: "/usr/bin/osascript",
                                arguments: [Self.script, id])
    }
}
