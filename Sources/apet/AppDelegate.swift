import AppKit
import AgentPetCore
import AppShellKit

// AppDelegate is called on the main thread by AppKit (ObjC runtime).
// We leave @MainActor off the class declaration so main.swift can create it
// in a non-isolated context; individual methods use MainActor.assumeIsolated
// where they need to touch @MainActor-isolated AppCoordinator.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep a strong reference; NSApplication.delegate is a weak ObjC property.
    var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApplicationDelegate callbacks run on the main thread.
        let c = MainActor.assumeIsolated { AppCoordinator() }
        MainActor.assumeIsolated { c.start() }
        coordinator = c
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let c = coordinator {
            MainActor.assumeIsolated { c.stop() }
        }
    }
}
