import XCTest
import AgentPetCore
@testable import AppShellKit

final class NotificationClickResolverTests: XCTestCase {
    // TC-B1-FUNC-01 合法 userInfo → 先 acknowledge 再 focus
    func test_resolve_returnsAckThenFocus_whenValid() {
        let info: [String: Any] = ["agent": "claude", "root": "/r", "sessionId": "s1"]
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s1")
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: info), [.acknowledge(key), .focus(key)])
    }
    // TC-B1-ERR-02 缺字段 → 空动作（不崩、不臆造 key）
    func test_resolve_returnsEmpty_whenMissingField() {
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: ["agent": "claude"]), [])
    }
}
