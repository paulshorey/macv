import AppKit
import SwiftUI

/// Pure AppKit entry — do not use SwiftUI `@main struct App` for this agent.
/// A Settings-only SwiftUI `App` on Tahoe can terminate when scenes invalidate
/// (status-item Aux errors coincide with that quit/relaunch loop).
@main
enum MacVMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Reinforce agent behavior (also set via LSUIElement in Info.plist).
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("MacV menu bar agent")
        ProcessInfo.processInfo.disableSuddenTermination()

        statusItemController.install(appState: appState)
        appState.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController.tearDown()
        NotificationCenter.default.post(name: .macvShouldStopServices, object: nil)
    }
}

extension Notification.Name {
    static let macvShouldStopServices = Notification.Name("macvShouldStopServices")
}
