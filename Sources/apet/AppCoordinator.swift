import Foundation
import AppKit
import AgentPetCore
import AppShellKit

/// 应用协调者：持有 SessionStore + NDJSONIngestor，监听 events.ndjson 增量变更，
/// 启动时回放历史，运行期间实时 ingest，定期 markStale + reap。
/// 必须在 @MainActor 上持有（满足 SessionStore 非线程安全约束）。
@MainActor
final class AppCoordinator {

    // MARK: - Config (persistent)

    let eventsPath: String
    let logPath: String

    private let configStore: ConfigStore
    private var config: AppConfig

    private let tickInterval: Double = 60         // 1 min

    // MARK: - State

    private var store: SessionStore?
    private var ingestor: NDJSONIngestor?
    private let reader = EventTailReader()
    private var checkpoint: Checkpoint?

    private var notificationService: NotificationService?
    private var menuBar: MenuBarController?
    private var petWindow: PetWindowController?

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFd: Int32 = -1
    private var reapTimer: DispatchSourceTimer?
    private var isStopped = false

    private var preferencesController: PreferencesWindowController?

    // MARK: - Derived config helpers

    /// Convert the string-encoded notifyMode into the typed enum consumed by NotificationDecider.
    private var currentNotifyMode: NotifyMode {
        config.notifyMode == "everyStop" ? .everyStop : .attentionOnly
    }

    // MARK: - Init

    init() {
        let env = ProcessInfo.processInfo.environment
        let appSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AgentPet")
        self.eventsPath = env["AGENTPET_EVENTS"] ?? AppPaths.eventsFile
        self.logPath = env["AGENTPET_LOG"]
            ?? (appSupport as NSString).appendingPathComponent("apet.log")

        let configURL = URL(fileURLWithPath: appSupport)
            .appendingPathComponent("config.json")
        let store = ConfigStore(url: configURL)
        self.configStore = store
        self.config = store.load()
    }

    // MARK: - Lifecycle

    func start(headless: Bool = false) {
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
        let sessionStore = SessionStore()
        let ingestor = NDJSONIngestor(store: sessionStore)
        self.store = sessionStore
        self.ingestor = ingestor

        // 2b. Create and start NotificationService (safe to call before replay).
        // Single shared TerminalFocusService instance injected into both consumers (Fix M-3).
        let focusService = TerminalFocusService()
        let ns = NotificationService(focusService: focusService, sessionLookup: { [weak self] key in
            self?.store?.sessions[key]
        })
        notificationService = ns
        ns.start()

        // 2c. Create MenuBarController + PetWindowController for real GUI app (skip in headless mode)
        if !headless {
            let mb = MenuBarController(focusService: focusService)
            let pw = PetWindowController(focusService: focusService, pet: config.selectedPet)
            mb.petVisibilityProvider = { [weak pw] in pw?.isVisible ?? false }
            mb.onTogglePet = { [weak pw] in
                guard let pw else { return }
                pw.setVisible(!pw.isVisible)
            }
            mb.onOpenPreferences = { [weak self] in
                self?.openPreferences()
            }
            menuBar = mb
            petWindow = pw

            // Apply display mode from config.
            let showPet = config.displayMode != "menuBarOnly"
            if showPet {
                pw.setVisible(true)
            }
            // Activate the app once so AppKit delivers window-order events properly.
            NSApp.activate(ignoringOtherApps: true)
        }

        // 3. Register change handler: log every store mutation + refresh menu bar
        sessionStore.addChangeHandler { [weak self] changes, isReplay in
            guard let self, let store = self.store else { return }
            let summary = store.summary()
            let line = "[change] \(changes) replay=\(isReplay) summary=\(summary)\n"
            self.appendToLog(line)
            let sessions = store.activeSessions()
            self.menuBar?.update(summary: summary, sessions: sessions)
            self.petWindow?.update(summary: summary, sessions: sessions)
        }

        // 4. Replay existing file content (replay: true)
        let replayNow = Date().timeIntervalSince1970
        let replayMode = currentNotifyMode
        do {
            let result = try reader.readNewLines(path: eventsPath, from: nil)
            for line in result.lines {
                ingestor.ingest(line: Substring(line), now: replayNow, replay: true)
                // replay: true — NotificationGate suppresses all; call for correct flag propagation.
                if let event = AgentEvent.decode(line: Substring(line)) {
                    let key = SessionKey(event: event)
                    ns.consider(event: event, session: sessionStore.sessions[key],
                                mode: replayMode, replay: true)
                }
            }
            checkpoint = result.next
            appendToLog("[start] replay done, lines=\(result.lines.count), offset=\(result.next.offset)\n")
        } catch {
            appendToLog("[error] replay failed: \(error)\n")
        }

        // 5. Live file watch via DispatchSource
        openWatchSource()

        // 6. Reap timer: every 60 s, markStale + reap + refresh menu bar
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.store else { return }
            let now = Date().timeIntervalSince1970
            _ = store.markStale(now: now, timeout: self.config.staleAfterSec)
            store.reap(now: now,
                       endedAfter: self.config.endedAfterSec,
                       waitingEndedAfter: self.config.waitingEndedAfterSec)
            let timerSessions = store.activeSessions()
            self.menuBar?.update(summary: store.summary(), sessions: timerSessions)
            self.petWindow?.update(summary: store.summary(), sessions: timerSessions)
        }
        timer.resume()
        reapTimer = timer
    }

    func stop() {
        isStopped = true
        watchSource?.cancel()
        watchSource = nil
        if watchFd >= 0 {
            Darwin.close(watchFd)
            watchFd = -1
        }
        reapTimer?.cancel()
        reapTimer = nil
    }

    // MARK: - Preferences

    /// Open the Preferences window, creating it if needed.
    ///
    /// If the window is already visible, it is simply brought to front.
    func openPreferences() {
        if let pc = preferencesController, pc.window?.isVisible == true {
            pc.show()
            return
        }
        let pc = PreferencesWindowController(
            config: config,
            configStore: configStore,
            onSave: { [weak self] newConfig in
                self?.applyConfig(newConfig)
            }
        )
        preferencesController = pc
        pc.show()
    }

    // MARK: - Config application

    /// Apply a newly-saved configuration at runtime (no restart needed for thresholds/mode).
    ///
    /// - Thresholds (`staleAfterSec`, `endedAfterSec`, `waitingEndedAfterSec`) take effect
    ///   on the **next** reap-timer tick.
    /// - `notifyMode` takes effect on the **next** inbound event.
    /// - `displayMode` is applied immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig

        // Apply display mode immediately.
        if let pw = petWindow {
            let shouldShow = newConfig.displayMode != "menuBarOnly"
            if shouldShow != pw.isVisible {
                pw.setVisible(shouldShow)
            }
            // Apply selected pet sprite immediately (Fix I-2).
            pw.applyPet(newConfig.selectedPet)
        }
    }

    // MARK: - Private: file watch

    private func openWatchSource() {
        guard !isStopped else { return }
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
            let liveMode = self.currentNotifyMode
            do {
                let result = try self.reader.readNewLines(path: self.eventsPath, from: self.checkpoint)
                for line in result.lines {
                    // Decode once: ingest(event:) avoids a second decode for notification dispatch.
                    if let event = AgentEvent.decode(line: Substring(line)) {
                        ingestor.ingest(event: event, now: now, replay: false)
                        if let ns = self.notificationService {
                            let key = SessionKey(event: event)
                            ns.consider(event: event, session: self.store?.sessions[key],
                                        mode: liveMode, replay: false)
                        }
                    }
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

        // Eager drain: read any lines written between replay-end and source-resume
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped, let ingestor = self.ingestor else { return }
            let now = Date().timeIntervalSince1970
            let drainMode = self.currentNotifyMode
            do {
                let result = try self.reader.readNewLines(path: self.eventsPath, from: self.checkpoint)
                for line in result.lines {
                    // Decode once: reuse the same event for ingest + notification.
                    if let event = AgentEvent.decode(line: Substring(line)) {
                        ingestor.ingest(event: event, now: now, replay: false)
                        if let ns = self.notificationService {
                            let key = SessionKey(event: event)
                            ns.consider(event: event, session: self.store?.sessions[key],
                                        mode: drainMode, replay: false)
                        }
                    }
                }
                if !result.lines.isEmpty {
                    self.checkpoint = result.next
                }
            } catch {
                self.appendToLog("[error] eager drain: \(error)\n")
            }
        }
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
