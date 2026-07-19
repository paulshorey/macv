import Foundation
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    static func binding(_ id: UUID) -> Self {
        .init("binding_\(id.uuidString)")
    }
}

@MainActor
@Observable
final class BindingStore {
    private(set) var bindings: [ShortcutBinding] = []
    var lastError: String?

    /// Called when a non-suppressed KeyboardShortcuts hotkey fires.
    var onBindingTriggered: ((ShortcutBinding) -> Void)?

    private var registeredNames: Set<String> = []

    init() {
        load()
        reregisterAll()
    }

    func load() {
        let url = AppPaths.bindingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            bindings = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            bindings = try JSONDecoder().decode([ShortcutBinding].self, from: data)
        } catch {
            lastError = error.localizedDescription
            bindings = []
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(bindings)
            try data.write(to: AppPaths.bindingsURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(_ binding: ShortcutBinding) {
        bindings.append(binding)
        save()
        reregisterAll()
    }

    func update(_ binding: ShortcutBinding) {
        guard let idx = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        bindings[idx] = binding
        save()
        reregisterAll()
    }

    func remove(id: UUID) {
        KeyboardShortcuts.setShortcut(nil, for: .binding(id))
        bindings.removeAll { $0.id == id }
        save()
        reregisterAll()
    }

    func binding(id: UUID) -> ShortcutBinding? {
        bindings.first { $0.id == id }
    }

    /// Bindings that need CGEventTap suppression.
    var suppressedBindings: [ShortcutBinding] {
        bindings.filter(\.requiresSuppression)
    }

    func reregisterAll() {
        // Clear previous listeners by re-setting handlers for known names.
        for nameKey in registeredNames {
            // Best-effort: KeyboardShortcuts doesn't expose remove-all;
            // we overwrite handlers for current bindings below.
            _ = nameKey
        }
        registeredNames.removeAll()

        for binding in bindings {
            let name = KeyboardShortcuts.Name.binding(binding.id)
            registeredNames.insert(name.rawValue)

            // For suppressed bindings, KeyboardShortcuts may still fire;
            // the CGEventTap swallows the key and the interceptor dispatches.
            // We still register so Recorder persistence works, but skip the
            // Carbon callback when suppression is required to avoid double-fire.
            if binding.requiresSuppression {
                KeyboardShortcuts.onKeyDown(for: name) { }
                continue
            }

            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                Task { @MainActor in
                    guard let self,
                          let current = self.binding(id: binding.id) else { return }
                    self.onBindingTriggered?(current)
                }
            }
        }
    }
}
