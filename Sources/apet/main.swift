import AppKit
import Foundation

// --smoke: headless smoke-test mode — RunLoop only, no NSApplication
if CommandLine.arguments.contains("--smoke") {
    // We ARE on the main thread here; MainActor.assumeIsolated makes the
    // @MainActor-isolated AppCoordinator callable from this synchronous context.
    MainActor.assumeIsolated {
        let coordinator = AppCoordinator()
        coordinator.start(headless: true)

        // Spin the RunLoop for up to 60 s; the test harness kills us externally
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }

        coordinator.stop()
    }
    exit(0)
}

// Normal mode: background accessory app (LSUIElement)
// app.run() blocks, keeping `delegate` alive via the local strong reference.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
