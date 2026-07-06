import XCTest
@testable import AppShellKit

/// events.ndjson 压缩(技术债 A):只增不减的事件日志按会话保留「新鲜 或 pid 存活」者的尾部。
final class EventLogCompactorTests: XCTestCase {
    private func ev(_ sid: String, ts: String, event: String = "busy", pid: Int? = nil) -> String {
        let term = pid.map { #","terminal":{"kind":"warp","pid":\#($0)}"# } ?? ""
        return #"{"v":1,"eventId":"\#(UUID().uuidString)","agent":"claude-code","event":"\#(event)","sessionId":"\#(sid)","root":"/r","ts":"\#(ts)"\#(term)}"#
    }

    func test_staleSession_dropped_freshKept() {
        let old = (0..<3).map { ev("old", ts: "2026-07-01T00:00:0\($0).000Z") }
        let fresh = (0..<3).map { ev("new", ts: "2026-07-06T10:00:0\($0).000Z") }
        let out = EventLogCompactor.compact(lines: old + fresh,
                                            now: 1_783_332_000,   // 2026-07-06 12:00 UTC 附近
                                            maxAge: 72 * 3600, keepPerSession: 50,
                                            isAlive: { _ in false })
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.contains("\"new\"") }, "5 天前的会话事件整组丢弃")
    }

    func test_aliveSession_keptDespiteAge() {
        let old = (0..<3).map { ev("zombie", ts: "2026-07-01T00:00:0\($0).000Z", pid: 42) }
        let out = EventLogCompactor.compact(lines: old, now: 1_783_332_000,
                                            maxAge: 72 * 3600, keepPerSession: 50,
                                            isAlive: { $0 == 42 })
        XCTAssertEqual(out.count, 3, "pid 存活(终端还开着)→ 超龄也保留")
    }

    func test_keepPerSession_tailOnly_plusLastTerminalCarrier() {
        // 100 条 busy,只有第 10 条带 terminal → 保尾部 keep 条 + 补上最后一条带 terminal 的
        var lines: [String] = []
        for i in 0..<100 {
            let ts = String(format: "2026-07-06T10:%02d:%02d.000Z", i / 60, i % 60)
            lines.append(ev("s", ts: ts, pid: i == 10 ? 42 : nil))
        }
        let out = EventLogCompactor.compact(lines: lines, now: 1_783_332_000,
                                            maxAge: 72 * 3600, keepPerSession: 20,
                                            isAlive: { _ in false })
        XCTAssertEqual(out.count, 21, "尾 20 + 最后带 terminal 的 1 条(字段合并不丢终端信息)")
        XCTAssertTrue(out.first!.contains(#""pid":42"#), "terminal 载体在前(重放序保持)")
    }

    func test_garbageLines_preserved() {
        // 坏行不丢(保守:不理解的内容原样保留,压缩绝不损数据语义)
        let lines = ["not json", ev("s", ts: "2026-07-06T10:00:00.000Z")]
        let out = EventLogCompactor.compact(lines: lines, now: 1_783_332_000,
                                            maxAge: 72 * 3600, keepPerSession: 50,
                                            isAlive: { _ in false })
        XCTAssertTrue(out.contains("not json"))
    }

    func test_order_preserved_globally() {
        let a = ev("a", ts: "2026-07-06T10:00:00.000Z")
        let b = ev("b", ts: "2026-07-06T10:00:01.000Z")
        let a2 = ev("a", ts: "2026-07-06T10:00:02.000Z")
        let out = EventLogCompactor.compact(lines: [a, b, a2], now: 1_783_332_000,
                                            maxAge: 72 * 3600, keepPerSession: 50,
                                            isAlive: { _ in false })
        XCTAssertEqual(out, [a, b, a2], "行序=seq 序,压缩不得重排(硬约束 3)")
    }
}
