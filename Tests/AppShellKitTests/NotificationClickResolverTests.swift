import XCTest
import AgentPetCore
@testable import AppShellKit

final class NotificationClickResolverTests: XCTestCase {
    private let key = SessionKey(agent: "claude", root: "/r", sessionId: "s1")

    // TC-B1-FUNC-01 合法 userInfo → 先 acknowledge 再 focus
    func test_resolve_returnsAckThenFocus_whenValid() {
        let info: [AnyHashable: Any] = ["agent": "claude", "root": "/r", "sessionId": "s1"]
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: info), [.acknowledge(key), .focus(key)])
    }
    // TC-B1-FUNC-02 多余字段被忽略，仍正确解析
    func test_resolve_ignoresExtraKeys() {
        let info: [AnyHashable: Any] = ["agent": "claude", "root": "/r", "sessionId": "s1", "extra": 42]
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: info), [.acknowledge(key), .focus(key)])
    }
    // TC-B1-ERR-03 缺单字段 → 空动作
    func test_resolve_returnsEmpty_whenMissingSessionId() {
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: ["agent": "claude", "root": "/r"]), [])
    }
    // TC-B1-ERR-04 字段类型错误（agent 为 Int）→ 空动作
    func test_resolve_returnsEmpty_whenWrongType() {
        let info: [AnyHashable: Any] = ["agent": 123, "root": "/r", "sessionId": "s1"]
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: info), [])
    }
    // TC-B1-ERR-05 空 userInfo → 空动作
    func test_resolve_returnsEmpty_whenEmpty() {
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: [:]), [])
    }
}
