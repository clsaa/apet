import XCTest
@testable import AgentPetCore

final class NotificationDeciderTests: XCTestCase {
    private func ev(_ kind: EventKind, notify: NotifyClass? = nil, title: String? = "Proj", message: String? = nil) -> AgentEvent {
        AgentEvent(v: 1, eventId: "E", agent: "a", kind: kind, sessionId: "S", root: "r",
                   title: title, notify: notify, message: message, ts: "t")
    }
    private let sess = Session(key: SessionKey(agent: "a", root: "r", sessionId: "S"),
                               state: .waiting(.attention), title: "Proj", lastSeq: 1, lastActiveAt: 0)

    func test_attention_rings_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertEqual(d.content?.title, "Proj")
    }

    func test_stop_silent_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_stop_rings_in_everyStop_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .everyStop, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_notify_none_override_silences_attention() {
        let d = NotificationDecider.decide(event: ev(.attention, notify: NotifyClass.none), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_notify_alert_override_rings_stop_even_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .alert), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_replay_never_rings() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: true)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_busy_and_start_never_ring() {
        XCTAssertFalse(NotificationDecider.decide(event: ev(.busy), session: sess, mode: .everyStop, replay: false).shouldNotify)
        XCTAssertFalse(NotificationDecider.decide(event: ev(.sessionStart), session: sess, mode: .everyStop, replay: false).shouldNotify)
    }

    func test_pluginError_rings() {
        let d = NotificationDecider.decide(event: ev(.pluginError), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_pluginError_uses_message_as_body() {
        let dWithMessage = NotificationDecider.decide(event: ev(.pluginError, message: "boom"), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertEqual(dWithMessage.content?.body, "boom")

        let dWithoutMessage = NotificationDecider.decide(event: ev(.pluginError, message: nil), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertEqual(dWithoutMessage.content?.body, "插件错误")
    }

    func test_passive_stop_silent_in_attentionOnly() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .passive), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_passive_attention_rings() {
        let d = NotificationDecider.decide(event: ev(.attention, notify: .passive), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_replay_beats_alert_override() {
        let d = NotificationDecider.decide(event: ev(.attention, notify: .alert), session: sess, mode: .attentionOnly, replay: true)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_sessionEnd_and_unknown_never_ring() {
        let dSessionEnd = NotificationDecider.decide(event: ev(.sessionEnd), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(dSessionEnd.shouldNotify)

        let dUnknown = NotificationDecider.decide(event: ev(.unknown("x")), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(dUnknown.shouldNotify)
    }

    // MARK: - H3 新增：title 回退 / passive×everyStop / alert body / pluginError 空 message

    /// title 三级回退：event.title=nil → session.title → event.agent
    func test_title_three_level_fallback() {
        // Level 2: event.title=nil, session.title="Proj" → "Proj"
        let d1 = NotificationDecider.decide(event: ev(.attention, title: nil), session: sess,
                                             mode: .attentionOnly, replay: false)
        XCTAssertEqual(d1.content?.title, "Proj")

        // Level 3: event.title=nil, session=nil → event.agent == "a"
        let d2 = NotificationDecider.decide(event: ev(.attention, title: nil), session: nil,
                                             mode: .attentionOnly, replay: false)
        XCTAssertEqual(d2.content?.title, "a")
    }

    /// .passive + stop + .everyStop → shouldNotify==true（passive 走默认分类逻辑）
    func test_passive_stop_rings_in_everyStop() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .passive), session: sess,
                                            mode: .everyStop, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    /// .alert + event.title="X" → body 含 "需要你关注"（H3: alert 走固定 fallback，不等于 title）
    func test_alert_body_contains_fixed_fallback_not_title() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .alert, title: "X"),
                                            session: nil, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.content?.body.contains("需要你关注") == true)
    }

    /// M1: .pluginError + message="" → body 含 "插件错误"（空串触发守卫，不退化为空）
    func test_pluginError_empty_message_falls_back_to_default() {
        let d = NotificationDecider.decide(event: ev(.pluginError, message: ""),
                                            session: nil, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.content?.body.contains("插件错误") == true,
                      "empty message should fall back to '插件错误', got: \(d.content?.body ?? "nil")")
    }

    // MARK: - H3-5: 通知带项目身份

    func test_body_prefixed_with_project_tag_when_cwd_set() {
        let sessWithCwd = Session(key: SessionKey(agent: "a", root: "r", sessionId: "S"),
                                  state: .waiting(.attention), cwd: "/x/proj-a",
                                  lastSeq: 1, lastActiveAt: 0)
        let d = NotificationDecider.decide(event: ev(.attention), session: sessWithCwd,
                                           mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.content?.body.hasPrefix("[proj-a] ") == true,
                      "body should start with '[proj-a] ', got: \(d.content?.body ?? "nil")")
    }

    func test_body_has_no_bracket_prefix_when_session_nil() {
        let d = NotificationDecider.decide(event: ev(.attention), session: nil,
                                           mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertFalse(d.content?.body.hasPrefix("[") == true,
                       "body should not have '[' prefix when session is nil")
    }

    /// F 升级:通知副标题带手动摘要(与标题重复省略)。
    func test_subtitle_carriesNote_dedupesTitle() {
        var sess = Session(key: SessionKey(agent: "a", root: "r", sessionId: "s"),
                           state: .running, cwd: "/x/proj", title: "修复面板",
                           lastSeq: 1, lastActiveAt: 0)
        sess.note = "通知重构那单"
        let ev = AgentEvent(v: 1, eventId: "e", agent: "a", kind: .attention,
                            sessionId: "s", root: "r", ts: "t")
        let d = NotificationDecider.decide(event: ev, session: sess, mode: .attentionOnly, replay: false)
        XCTAssertEqual(d.content?.subtitle, "通知重构那单")
        sess.note = "修复面板"   // 与标题相同 → 省略
        let d2 = NotificationDecider.decide(event: ev, session: sess, mode: .attentionOnly, replay: false)
        XCTAssertEqual(d2.content?.subtitle, "")
    }
}
