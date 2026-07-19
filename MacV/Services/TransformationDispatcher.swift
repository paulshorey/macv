import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class TransformationDispatcher {
    let historyStore: HistoryStore
    let pasteSynthesizer: PasteSynthesizer
    let scriptRegistry: ScriptRegistry
    let clipboardMonitor: ClipboardMonitor

    var lastError: String?
    var lastScriptStderr: String?
    var isBusy = false

    init(
        historyStore: HistoryStore,
        pasteSynthesizer: PasteSynthesizer,
        scriptRegistry: ScriptRegistry,
        clipboardMonitor: ClipboardMonitor
    ) {
        self.historyStore = historyStore
        self.pasteSynthesizer = pasteSynthesizer
        self.scriptRegistry = scriptRegistry
        self.clipboardMonitor = clipboardMonitor
    }

    func handle(binding: ShortcutBinding) {
        guard !isBusy else { return }
        Task { @MainActor in
            await run(binding: binding)
        }
    }

    private func run(binding: ShortcutBinding) async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastScriptStderr = nil

        guard let transformation = scriptRegistry.find(binding.scriptID) else {
            lastError = "Script not found: \(binding.scriptID)"
            return
        }

        do {
            switch binding.event {
            case .paste:
                try await handlePaste(transformation: transformation, event: binding.event)
            case .copy, .cut:
                try await handleCopyOrCut(
                    transformation: transformation,
                    event: binding.event,
                    mode: binding.copyCutMode
                )
            case .none:
                try await handleSilent(transformation: transformation, event: binding.event)
            }
        } catch {
            lastError = error.localizedDescription
            lastScriptStderr = error.localizedDescription
            NSLog("MacV transform error: \(error.localizedDescription)")
        }
    }

    private func handlePaste(transformation: any Transformation, event: ClipboardEvent) async throws {
        let current = currentSnapshotForTransform()
        let transformed = try await transformation.apply(to: current, event: event)
        historyStore.append(transformed, setActive: true)
        pasteSynthesizer.writeAndPaste(transformed, restoreAfter: true)
        clipboardMonitor.syncChangeCount()
    }

    private func handleCopyOrCut(
        transformation: any Transformation,
        event: ClipboardEvent,
        mode: CopyCutMode
    ) async throws {
        switch mode {
        case .transformCurrentClipboard:
            let current = currentSnapshotForTransform()
            let transformed = try await transformation.apply(to: current, event: event)
            historyStore.append(transformed, setActive: true)
            pasteSynthesizer.write(transformed, to: .general, markers: [.internalWrite])
            clipboardMonitor.syncChangeCount()

        case .interceptThenTransform:
            let before = NSPasteboard.general.changeCount
            pasteSynthesizer.synthesizeSystemEvent(event)
            let changed = await pasteSynthesizer.waitForPasteboardChange(before: before)
            guard changed else {
                throw ScriptError.failed(stderr: "Timed out waiting for system \(event.rawValue)")
            }
            let origin: SnapshotOrigin = event == .cut ? .organicCut : .organicCopy
            let fresh = ClipboardSnapshot.capture(from: .general, origin: origin)
            historyStore.append(fresh, setActive: true)
            let transformed = try await transformation.apply(to: fresh, event: event)
            historyStore.append(transformed, setActive: true)
            pasteSynthesizer.write(transformed, to: .general, markers: [.internalWrite])
            clipboardMonitor.syncChangeCount()
        }
    }

    private func handleSilent(transformation: any Transformation, event: ClipboardEvent) async throws {
        let current = currentSnapshotForTransform()
        let transformed = try await transformation.apply(to: current, event: event)
        historyStore.append(transformed, setActive: true)
        // No pasteboard write, no key synthesis.
    }

    func promote(_ historical: ClipboardSnapshot) {
        let promoted = ClipboardSnapshot(
            id: UUID(),
            createdAt: Date(),
            parentID: historical.id,
            sourceApp: historical.sourceApp,
            origin: .promotion,
            representations: historical.representations
        )
        historyStore.append(promoted, setActive: true)
        pasteSynthesizer.write(promoted, to: .general, markers: [.internalWrite])
        clipboardMonitor.syncChangeCount()
    }

    private func currentSnapshotForTransform() -> ClipboardSnapshot {
        if let active = historyStore.activeSnapshot {
            return active
        }
        // Fall back to live pasteboard.
        return ClipboardSnapshot.capture(from: .general, origin: .organicCopy)
    }
}
