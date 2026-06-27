import Foundation

public final class NDJSONIngestor {
    private let store: SessionStore
    private var seq: Int
    public var consumedSeq: Int { seq }

    public init(store: SessionStore, startSeq: Int = 0) {
        self.store = store
        self.seq = startSeq
    }

    /// 直接接收已解码的 `AgentEvent`，分配下一个单调序列号并写入 store。
    /// 避免调用方先 `AgentEvent.decode` 再 `ingest(line:)` 时的二次解码。
    @discardableResult
    public func ingest(event: AgentEvent, now: Double, replay: Bool) -> [StoreChange] {
        seq += 1
        return store.apply(event, seq: seq, now: now, replay: replay)
    }

    @discardableResult
    public func ingest(line: Substring, now: Double, replay: Bool) -> [StoreChange] {
        let clean = line.hasSuffix("\r") ? line.dropLast() : line
        guard let event = AgentEvent.decode(line: clean) else { return [] } // 坏行：不占 seq
        return ingest(event: event, now: now, replay: replay)
    }

    @discardableResult
    public func ingest(text: String, now: Double, replay: Bool) -> [StoreChange] {
        var all: [StoreChange] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            all += ingest(line: raw, now: now, replay: replay)
        }
        return all
    }
}
