import Foundation
import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppState {
    let historyStore: HistoryStore
    let clipboardMonitor: ClipboardMonitor
    let scriptRegistry: ScriptRegistry
    let bindingStore: BindingStore
    let permissions: PermissionsManager
    let pasteSynthesizer: PasteSynthesizer
    let dispatcher: TransformationDispatcher
    let hotkeyInterceptor: HotkeyInterceptor

    var searchText = ""
    var launchesAtLogin = false
    private var didStart = false

    init() {
        let historyStore = HistoryStore()
        let clipboardMonitor = ClipboardMonitor()
        let scriptRegistry = ScriptRegistry()
        let bindingStore = BindingStore()
        let permissions = PermissionsManager()
        let pasteSynthesizer = PasteSynthesizer()
        let dispatcher = TransformationDispatcher(
            historyStore: historyStore,
            pasteSynthesizer: pasteSynthesizer,
            scriptRegistry: scriptRegistry,
            clipboardMonitor: clipboardMonitor
        )
        let hotkeyInterceptor = HotkeyInterceptor()

        self.historyStore = historyStore
        self.clipboardMonitor = clipboardMonitor
        self.scriptRegistry = scriptRegistry
        self.bindingStore = bindingStore
        self.permissions = permissions
        self.pasteSynthesizer = pasteSynthesizer
        self.dispatcher = dispatcher
        self.hotkeyInterceptor = hotkeyInterceptor
    }

    func start() {
        // Status-item panel views can be recreated; services must start only once per process.
        guard !didStart else { return }
        didStart = true

        permissions.refresh()

        clipboardMonitor.onNewClipboardContent = { [weak self] snapshot in
            self?.historyStore.append(snapshot, setActive: true)
        }
        clipboardMonitor.start()

        bindingStore.onBindingTriggered = { [weak self] binding in
            self?.dispatcher.handle(binding: binding)
        }

        hotkeyInterceptor.onSuppressedBinding = { [weak self] id in
            guard let self, let binding = self.bindingStore.binding(id: id) else { return }
            self.dispatcher.handle(binding: binding)
        }
        refreshInterceptor()
        hotkeyInterceptor.start()

        refreshLoginItemStatus()
    }

    func refreshInterceptor() {
        hotkeyInterceptor.updateSuppressedBindings(bindingStore.suppressedBindings)
    }

    func addBinding(scriptID: String, event: ClipboardEvent) {
        let binding = ShortcutBinding(scriptID: scriptID, event: event)
        bindingStore.add(binding)
        refreshInterceptor()
    }

    func updateBinding(_ binding: ShortcutBinding) {
        bindingStore.update(binding)
        refreshInterceptor()
    }

    func removeBinding(id: UUID) {
        bindingStore.remove(id: id)
        refreshInterceptor()
    }

    var filteredSnapshots: [ClipboardSnapshot] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return historyStore.snapshots }
        return historyStore.snapshots.filter {
            $0.previewText.localizedCaseInsensitiveContains(q)
                || ($0.sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.origin.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    func refreshLoginItemStatus() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            dispatcher.lastError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    func revealScriptsFolder() {
        NSWorkspace.shared.open(AppPaths.scriptsDirectory)
    }
}
