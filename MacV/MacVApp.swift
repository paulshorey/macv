import SwiftUI

@main
struct MacVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("MacV", systemImage: "doc.on.clipboard") {
            HistoryBrowserView()
                .environment(appState)
                .frame(width: 380, height: 520)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppState.start is invoked from Settings/History appear; also start here via notification.
        NotificationCenter.default.post(name: .macvShouldStartServices, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .macvShouldStopServices, object: nil)
    }
}

extension Notification.Name {
    static let macvShouldStartServices = Notification.Name("macvShouldStartServices")
    static let macvShouldStopServices = Notification.Name("macvShouldStopServices")
}
