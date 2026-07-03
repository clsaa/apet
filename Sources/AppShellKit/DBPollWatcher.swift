import Foundation
import AgentPetCore

/// 通用 DB 轮询器(泛化自 QoderWorkWatcher,评审 B4 回归网先行后重构):
/// 定时轮询 → scan 闭包(读+纯扫描)→ 差分 emit + 幽灵对账。
/// 契约(随泛化保持,架构评审):timer `queue: .main`;`start` 幂等(stop-first);
/// scan 返回 nil(如写锁竞争半读)→ 整轮跳过,不差分、不发幽灵 stale。
public final class DBPollWatcher {
    private let scan: (Double) -> [ScanResult]?
    private let now: () -> Double
    private let emit: (ScanResult) -> Void

    private var lastEmitted: [SessionKey: ScanState] = [:]
    private var timer: DispatchSourceTimer?

    public init(
        scan: @escaping (Double) -> [ScanResult]?,
        now: @escaping () -> Double,
        emit: @escaping (ScanResult) -> Void
    ) {
        self.scan = scan; self.now = now; self.emit = emit
    }

    public func scanOnce() {
        guard let results = scan(now()) else { return }
        var observed: Set<SessionKey> = []
        for result in results {
            guard case .observe(let state, let key, _, _) = result else { continue }
            observed.insert(key)
            if lastEmitted[key] != state {
                emit(result)
                lastEmitted[key] = state
            }
        }
        // 幽灵对账:上轮活跃、本轮消失/过老 → 补发 stale 打灰。
        let ghosts = lastEmitted.keys.filter { !observed.contains($0) }
        for key in ghosts {
            emit(.observe(state: .stale, key: key, cwd: nil, title: nil))
            lastEmitted.removeValue(forKey: key)
        }
    }

    public func start(every interval: Double) {
        stop()  // 幂等:重复 start 不产生双 timer(测试评审 M6)
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + interval, repeating: interval)
        src.setEventHandler { [weak self] in self?.scanOnce() }
        src.resume()
        timer = src
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
