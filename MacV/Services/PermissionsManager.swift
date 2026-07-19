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
    var isAdHocSigned = false
    var signingSummary = ""

    func refresh() {
        hasInputMonitoring = CGPreflightListenEventAccess()
        hasPostEvent = CGPreflightPostEventAccess()
        hasAccessibility = AXIsProcessTrusted()
        refreshSigningStatus()

        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .default: pasteboardAccessLabel = "Default"
            case .alwaysAllow: pasteboardAccessLabel = "Always Allow"
            case .ask: pasteboardAccessLabel = "Ask"
            case .alwaysDeny: pasteboardAccessLabel = "Deny"
            @unknown default: pasteboardAccessLabel = "Unknown"
            }
        } else {
            pasteboardAccessLabel = "Not restricted"
        }
    }

    private func refreshSigningStatus() {
        guard let url = Bundle.main.bundleURL as URL? else {
            isAdHocSigned = true
            signingSummary = "unknown"
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--verbose=2", url.path]
        let err = Pipe()
        task.standardError = err
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            isAdHocSigned = text.contains("Signature=adhoc") || text.contains("flags=0x2(adhoc)")
            if let team = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) {
                signingSummary = String(team)
            } else if isAdHocSigned {
                signingSummary = "Signature=adhoc (TeamIdentifier=not set)"
            } else {
                signingSummary = "signed"
            }
        } catch {
            isAdHocSigned = true
            signingSummary = "codesign check failed"
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
