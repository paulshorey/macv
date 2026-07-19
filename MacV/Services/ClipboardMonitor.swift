import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ClipboardMonitor {
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var recentFrontmostApps: [(date: Date, bundleID: String)] = []
    private var frontmostObserver: NSObjectProtocol?

    var onNewClipboardContent: ((ClipboardSnapshot) -> Void)?
    var isPasteboardAccessDenied = false
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = NSPasteboard.general.changeCount
        recordFrontmostApp()

        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bid = app.bundleIdentifier {
                    self?.recentFrontmostApps.append((Date(), bid))
                    if let count = self?.recentFrontmostApps.count, count > 20 {
                        self?.recentFrontmostApps.removeFirst(count - 20)
                    }
                }
            }
        }

        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
        }
        isRunning = false
    }

    private func recordFrontmostApp() {
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recentFrontmostApps.append((Date(), bid))
        }
    }

    private func bestEffortSourceApp() -> String? {
        let own = Bundle.main.bundleIdentifier
        // Prefer an app recorded slightly before now, skipping ourselves.
        let cutoff = Date().addingTimeInterval(-2)
        for entry in recentFrontmostApps.reversed() {
            if entry.date < cutoff { break }
            if entry.bundleID != own {
                return entry.bundleID
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == own ? nil : front
    }

    private func checkForChanges() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .ask, .alwaysDeny:
                isPasteboardAccessDenied = true
                return
            case .alwaysAllow:
                isPasteboardAccessDenied = false
            @unknown default:
                break
            }
        }

        if ClipboardSnapshot.pasteboardHasInternalWrite(pasteboard)
            || ClipboardSnapshot.pasteboardHasTransient(pasteboard) {
            return
        }
        if ClipboardSnapshot.pasteboardHasConcealedContent(pasteboard) {
            return
        }

        let snapshot = ClipboardSnapshot.capture(
            from: pasteboard,
            origin: .organicCopy,
            sourceApp: bestEffortSourceApp()
        )
        guard !snapshot.representations.isEmpty else { return }
        onNewClipboardContent?(snapshot)
    }

    /// Call after a known external write so the next poll doesn't double-fire incorrectly.
    func syncChangeCount() {
        lastChangeCount = NSPasteboard.general.changeCount
    }
}
