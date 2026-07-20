import AppKit
import SwiftUI

/// Menu-bar agent UI: `NSStatusItem` + `NSMenu` + independent windows.
///
/// Avoids SwiftUI `MenuBarExtra` and `NSPopover` attached to the status button — both
/// create Control Center `…-Aux[1]-NSStatusItemView` scenes that invalidate on Tahoe.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var historyWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private weak var appState: AppState?

    private let historySize = NSSize(width: 380, height: 520)
    private let settingsSize = NSSize(width: 560, height: 440)

    func install(appState: AppState) {
        self.appState = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "MacV"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Clipboard History",
            action: #selector(showHistory),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit MacV",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item

        SettingsPresenter.openHandler = { [weak self] in
            self?.showSettings()
        }
        SettingsPresenter.dismissHistoryHandler = { [weak self] in
            self?.closeHistory()
        }
    }

    func tearDown() {
        closeHistory()
        settingsWindow?.orderOut(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func closeHistory() {
        historyWindow?.orderOut(nil)
    }

    @objc private func showHistory() {
        guard let appState else { return }

        if historyWindow == nil {
            let root = HistoryBrowserView()
                .environment(appState)
                .frame(width: historySize.width, height: historySize.height)

            let hosting = NSHostingController(rootView: root)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: historySize),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "MacV Clipboard"
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 320, height: 360)
            historyWindow = panel
        }

        positionBelowStatusItem(historyWindow)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        guard let appState else { return }
        closeHistory()

        if settingsWindow == nil {
            let root = SettingsView()
                .environment(appState)
                .frame(minWidth: settingsSize.width, minHeight: settingsSize.height)

            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: settingsSize),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacV Settings"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 360)
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func positionBelowStatusItem(_ window: NSWindow?) {
        guard let window else { return }
        if let button = statusItem?.button,
           let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            var frame = window.frame
            frame.origin.x = screenRect.midX - frame.width / 2
            frame.origin.y = screenRect.minY - frame.height - 8
            if let screen = buttonWindow.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
                frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
            }
            window.setFrame(frame, display: true)
        } else if let screen = NSScreen.main {
            // Fallback when the status-item button has no window yet (Tahoe).
            var frame = window.frame
            frame.origin.x = screen.visibleFrame.midX - frame.width / 2
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 40
            window.setFrame(frame, display: true)
        }
    }
}
