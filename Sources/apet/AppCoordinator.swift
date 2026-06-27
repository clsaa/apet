import Foundation
import AgentPetCore
import AppShellKit

/// 应用协调者：持有 SessionStore + NDJSONIngestor，监听 events.ndjson 增量变更，
/// 启动时回放历史，运行期间实时 ingest，定期 markStale + reap。
/// 必须在 @MainActor 上持有（满足 SessionStore 非线程安全约束）。
@MainActor
final class AppCoordinator {

    // MARK: - Config

    let eventsPath: String
    let logPath: String

    private let staleAfter: Double = 600          // 10 min
    private let endedAfter: Double = 14400        // 4 h
    private let waitingEndedAfter: Double = 28800 // 8 h
    private let tickInterval: Double = 60         // 1 min

    // MARK: - State

    private var store: SessionStore?
    private var ingestor: NDJSONIngestor?
    private let reader = EventTailReader()
    private var checkpoint: Checkpoint?

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFd: Int32 = -1
    private var reapTimer: DispatchSourceTimer?

    // MARK: - Init

    init() {
        let env = ProcessInfo.processInfo.environment
        let appSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AgentPet")
        self.eventsPath = env["AGENTPET_EVENTS"]
            ?? (appSupport as NSString).appendingPathComponent("events.ndjson")
        self.logPath = env["AGENTPET_LOG"]
            ?? (appSupport as NSString).appendingPathComponent("apet.log")
    }

    // MARK: - Lifecycle

    func start() {
        // 1. Create parent dirs; touch events file if missing
        let fm = FileManager.default
        for path in [eventsPath, logPath] {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: eventsPath) {
            fm.createFile(atPath: eventsPath, contents: nil)
        }

        // 2. Create store + ingestor
        let store = SessionStore()
        let ingestor = NDJSONIngestor(store: store)
        self.store = store
        self.ingestor = ingestor

        // 3. Register change handler: log every store mutation
        store.addChangeHandler { [weak self] changes, isReplay in
            guard let self else { return }
            let summary = store.summary()
            let line = "[change] \(changes) replay=\(isReplay) summary=\(summary)\n"
            self.appendToLog(line)
        }

        // 4. Replay existing file content (replay: true)
        let replayNow = Date().timeIntervalSince1970
        do {
            let result = try reader.readNewLines(path: eventsPath, from: nil)
            for line in result.lines {
                ingestor.ingest(line: Substring(line), now: replayNow, replay: true)
            }
            checkpoint = result.next
            appendToLog("[start] replay done, lines=\(result.lines.count), offset=\(result.next.offset)\n")
        } catch {
            appendToLog("[error] replay failed: \(error)\n")
        }

        // 5. Live file watch via DispatchSource
        openWatchSource()

        // 6. Reap timer: every 60 s, markStale + reap
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.store else { return }
            let now = Date().timeIntervalSince1970
            _ = store.markStale(now: now, timeout: self.staleAfter)
            store.reap(now: now, endedAfter: self.endedAfter, waitingEndedAfter: self.waitingEndedAfter)
        }
        timer.resume()
        reapTimer = timer
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
        if watchFd >= 0 {
            Darwin.close(watchFd)
            watchFd = -1
        }
        reapTimer?.cancel()
        reapTimer = nil
    }

    // MARK: - Private: file watch

    private func openWatchSource() {
        guard let ingestor else { return }

        let fd = Darwin.open(eventsPath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            appendToLog("[warn] cannot open events file for kqueue watch: \(eventsPath)\n")
            return
        }
        watchFd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data

            if flags.contains(.delete) || flags.contains(.rename) {
                // File rotated — cancel current source, reopen after short delay
                source.cancel()
                Darwin.close(fd)
                self.watchFd = -1
                self.checkpoint = nil
                self.watchSource = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.openWatchSource()
                }
                return
            }

            // .write / .extend: read new content
            let now = Date().timeIntervalSince1970
            do {
                let result = try self.reader.readNewLines(path: self.eventsPath, from: self.checkpoint)
                for line in result.lines {
                    ingestor.ingest(line: Substring(line), now: now, replay: false)
                }
                if !result.lines.isEmpty {
                    self.checkpoint = result.next
                }
            } catch {
                self.appendToLog("[error] tail read: \(error)\n")
            }
        }

        source.setCancelHandler {
            // fd already closed by caller; nothing to do here
        }

        source.resume()
        watchSource = source
    }

    // MARK: - Private: logging

    private func appendToLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            fm.createFile(atPath: logPath, contents: data)
        }
    }
}
