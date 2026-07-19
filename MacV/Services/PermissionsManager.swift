import Foundation
import AppKit
import ApplicationServices
import Observation

@MainActor
@Observable
final class PermissionsManager {
    var hasInputMonitoring = false
    var hasPostEvent = false
    var hasAccessibility = false
    var pasteboardAccessLabel = "Unknown"

    func refresh() {
        hasInputMonitoring = CGPreflightListenEventAccess()
        hasPostEvent = CGPreflightPostEventAccess()
        hasAccessibility = AXIsProcessTrusted()

        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: pasteboardAccessLabel = "Always Allow"
            case .ask: pasteboardAccessLabel = "Ask"
            case .alwaysDeny: pasteboardAccessLabel = "Deny"
            @unknown default: pasteboardAccessLabel = "Unknown"
            }
        } else {
            pasteboardAccessLabel = "Not restricted"
        }
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func requestPostEvent() {
        _ = CGRequestPostEventAccess()
        refresh()
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refresh()
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
