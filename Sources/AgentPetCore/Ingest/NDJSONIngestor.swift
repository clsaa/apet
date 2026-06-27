import Foundation

public final class NDJSONIngestor {
    private let store: SessionStore
    private var seq: Int
    public var consumedSeq: Int { seq }

    public init(store: SessionStore, startSeq: Int = 0) {
        self.store = store
        self.seq = startSeq
    }

    @discardableResult
    public func ingest(line: Substring, now: Double, replay: Bool) -> [StoreChange] {
        guard let event = AgentEvent.decode(line: line) else { return [] } // 坏行：不占 seq
        seq += 1
        return store.apply(event, seq: seq, now: now, replay: replay)
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
