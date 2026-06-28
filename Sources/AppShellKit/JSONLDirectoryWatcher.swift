import Foundation
import AgentPetCore

// MARK: - DirectoryScanning Protocol

/// 枚举目录下可扫描的 JSONL 文件路径（不含 subagent 路径）。
public protocol DirectoryScanning {
    func jsonlFiles(under projectsDir: String) -> [String]
}

// MARK: - DefaultDirectoryScanner

/// 生产实现：用 FileManager.enumerator 枚举，排除 /subagents/ 路径和 agent- 前缀文件。
public struct DefaultDirectoryScanner: DirectoryScanning {
    public init() {}

    public func jsonlFiles(under projectsDir: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: projectsDir) else {
            return []
        }
        var result: [String] = []
        while let relativePath = enumerator.nextObject() as? String {
            // 只要 .jsonl 后缀
            guard relativePath.hasSuffix(".jsonl") else { continue }

            let fullPath = (projectsDir as NSString).appendingPathComponent(relativePath)

            // 排除路径含 /subagents/
            if fullPath.contains("/subagents/") { continue }

            // 排除 basename 以 agent- 开头
            let basename = (relativePath as NSString).lastPathComponent
            if basename.hasPrefix("agent-") { continue }

            result.append(fullPath)
        }
        return result
    }
}

// MARK: - JSONLDirectoryWatcher

/// 目录监听器：定期扫描 JSONL 文件，应用滞回（quietStreak）+ 差分（lastEmitted）后发射 ScanResult。
public final class JSONLDirectoryWatcher {

    // MARK: Init params

    private let projectsDir: String
    private let root: String
    private let now: () -> Double
    private let scanner: DirectoryScanning
    private let parse: (String) -> ScannedFile?
    private let emit: (ScanResult) -> Void
    private let runningWindow: Double
    private let idleWindow: Double

    // MARK: Internal state

    /// 上次 emit 的状态（差分基线）
    private var lastEmitted: [SessionKey: ScanState] = [:]
    /// 连续处于 waitingStop 候选的次数（滞回计数）
    private var quietStreak: [SessionKey: Int] = [:]

    // MARK: Timer

    private var timer: DispatchSourceTimer?

    // MARK: - Init

    public init(
        projectsDir: String,
        root: String,
        now: @escaping () -> Double,
        scanner: DirectoryScanning = DefaultDirectoryScanner(),
        parse: @escaping (String) -> ScannedFile? = { JSONLParse.parse(path: $0, root: "") },
        emit: @escaping (ScanResult) -> Void,
        runningWindow: Double = 120,
        idleWindow: Double = 1800
    ) {
        self.projectsDir = projectsDir
        self.root = root
        self.now = now
        self.scanner = scanner
        self.parse = parse
        self.emit = emit
        self.runningWindow = runningWindow
        self.idleWindow = idleWindow
    }

    // MARK: - Scan

    /// 执行一次扫描：枚举文件 → parse → scan → 滞回 → 差分 emit。
    public func scanOnce() {
        let paths = scanner.jsonlFiles(under: projectsDir)
        for path in paths {
            guard let file = parse(path) else { continue }

            let raw = JSONLSessionScanner.scan(
                file,
                now: now(),
                runningWindow: runningWindow,
                idleWindow: idleWindow
            )

            switch raw {
            case .ignore:
                // ignore 不 emit，不更新状态
                continue

            case .observe(let rawState, let key, let cwd, let title):
                // 滞回：running → waitingStop 需连续 ≥2 次才翻转
                let effState: ScanState
                if rawState == .waitingStop, lastEmitted[key] == .running {
                    let streak = (quietStreak[key] ?? 0) + 1
                    quietStreak[key] = streak
                    if streak < 2 {
                        // 尚未确认，本轮保持 running
                        effState = .running
                    } else {
                        // 连续两次 quiet，确认翻转
                        effState = .waitingStop
                        quietStreak[key] = 0
                    }
                } else {
                    // 其它情况：重置 streak，直接用 raw
                    quietStreak[key] = 0
                    effState = rawState
                }

                // 差分：与上次 emit 比较，变化才发射
                if lastEmitted[key] != effState {
                    emit(.observe(state: effState, key: key, cwd: cwd, title: title))
                    lastEmitted[key] = effState
                }
            }
        }
    }

    // MARK: - Timer

    /// 启动定时扫描，间隔 `every` 秒，在 DispatchQueue.main 上运行。
    public func start(every interval: Double) {
        let src = DispatchSource.makeTimerSource(queue: .main)
        let delayNanos = Int(interval * 1_000_000_000)
        src.schedule(
            deadline: .now() + interval,
            repeating: .nanoseconds(delayNanos)
        )
        src.setEventHandler { [weak self] in
            self?.scanOnce()
        }
        src.resume()
        timer = src
    }

    /// 停止定时扫描。
    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
