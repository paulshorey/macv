import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ScriptsSettingsView()
                .tabItem { Label("Scripts", systemImage: "terminal") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .environment(appState)
        // Dev convenience: select/copy labels and help text when talking to engineers.
        .textSelection(.enabled)
        .onAppear {
            appState.permissions.refresh()
            appState.scriptRegistry.reload()
        }
    }
}

struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newScriptID: String = ""
    @State private var newEvent: ClipboardEvent = .paste

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcut Bindings")
                .font(.title2)

            if appState.bindingStore.bindings.isEmpty {
                Text("No bindings yet. Add one below.")
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(appState.bindingStore.bindings) { binding in
                    BindingEditorRow(binding: binding)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let id = appState.bindingStore.bindings[index].id
                        appState.removeBinding(id: id)
                    }
                }
            }
            .frame(minHeight: 200)

            Divider()

            HStack {
                Picker("Script", selection: $newScriptID) {
                    Text("Select…").tag("")
                    ForEach(appState.scriptRegistry.scripts) { script in
                        Text(script.displayName).tag(script.scriptID)
                    }
                }
                Picker("Event", selection: $newEvent) {
                    ForEach(ClipboardEvent.allCases) { event in
                        Text(event.displayName).tag(event)
                    }
                }
                .frame(width: 180)
                Button("Add") {
                    guard !newScriptID.isEmpty else { return }
                    appState.addBinding(scriptID: newScriptID, event: newEvent)
                }
                .disabled(newScriptID.isEmpty)
            }

            if let err = appState.bindingStore.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .onAppear {
            if newScriptID.isEmpty {
                newScriptID = appState.scriptRegistry.scripts.first?.scriptID ?? ""
            }
        }
    }
}

private struct BindingEditorRow: View {
    @Environment(AppState.self) private var appState
    @State var binding: ShortcutBinding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                KeyboardShortcuts.Recorder("Shortcut", name: .binding(binding.id))
                Spacer()
                Button(role: .destructive) {
                    appState.removeBinding(id: binding.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Picker("Script", selection: $binding.scriptID) {
                    ForEach(appState.scriptRegistry.scripts) { script in
                        Text(script.displayName).tag(script.scriptID)
                    }
                }
                Picker("Event", selection: $binding.event) {
                    ForEach(ClipboardEvent.allCases) { event in
                        Text(event.displayName).tag(event)
                    }
                }
            }

            Toggle("Suppress key (CGEventTap)", isOn: $binding.requiresSuppression)

            if binding.event == .copy || binding.event == .cut {
                Picker("Copy/Cut mode", selection: $binding.copyCutMode) {
                    ForEach(CopyCutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: binding) { _, newValue in
            let updated = newValue
            if updated.event == .paste {
                // Keep paste suppressed by default when event flips to paste.
            }
            appState.updateBinding(updated)
        }
    }
}

struct ScriptsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transformation Scripts")
                .font(.title2)
            Text("Scripts live in Application Support and receive clipboard text on stdin. Exit 0 + stdout replaces the active snapshot’s plain text. They may call python3, node, jq, etc.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(appState.scriptRegistry.scripts) { script in
                VStack(alignment: .leading) {
                    Text(script.displayName).font(.headline)
                    Text(script.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button("Reveal Scripts Folder") {
                    appState.revealScriptsFolder()
                }
                Button("Reload") {
                    appState.scriptRegistry.reload()
                }
            }

            if let stderr = appState.dispatcher.lastScriptStderr {
                GroupBox("Last script error") {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct PermissionsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2)
            Text("MacV needs these so hotkeys can suppress keys and paste into other apps. Grant them once; they persist — but only if the app is signed with a stable Development Team (not ad-hoc).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.permissions.isAdHocSigned {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Ad-hoc code signature detected", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("System Settings may show MacV as allowed while this build still fails the live check. Each Xcode rebuild can get a new signature, so TCC treats it as a different app.\n\nFix: in Xcode → MacV target → Signing & Capabilities → enable “Automatically manage signing” and pick your Team (Apple ID). Then quit MacV, rebuild, re-grant permissions once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            permissionRow(
                title: "Input Monitoring",
                detail: "Required for CGEventTap key suppression. Live check: \(appState.permissions.hasInputMonitoring ? "OK" : "failing")",
                ok: appState.permissions.hasInputMonitoring,
                request: { appState.permissions.requestInputMonitoring() },
                open: { appState.permissions.openInputMonitoringSettings() }
            )
            permissionRow(
                title: "Accessibility / Post Event",
                detail: "Required to synthesize Cmd+V / Cmd+C. Live check: \(appState.permissions.hasPostEvent || appState.permissions.hasAccessibility ? "OK" : "failing")",
                ok: appState.permissions.hasPostEvent || appState.permissions.hasAccessibility,
                request: {
                    appState.permissions.requestPostEvent()
                    appState.permissions.requestAccessibility()
                },
                open: { appState.permissions.openAccessibilitySettings() }
            )
            HStack {
                VStack(alignment: .leading) {
                    Text("Paste from Other Apps")
                    Text("Status: \(appState.permissions.pasteboardAccessLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { appState.permissions.openPasteboardSettings() }
                Button("Refresh") { appState.permissions.refresh() }
            }

            Text("After changing any toggle in System Settings, fully Quit MacV from the menu bar (not just close Settings), then Run again from Xcode. Permissions are evaluated at process start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh all") { appState.permissions.refresh() }
        }
        .onAppear { appState.permissions.refresh() }
    }

    private func permissionRow(
        title: String,
        detail: String,
        ok: Bool,
        request: @escaping () -> Void,
        open: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Request", action: request)
            Button("Open Settings", action: open)
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Launch") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchesAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
            }
            Section("History") {
                Button("Clear clipboard history", role: .destructive) {
                    appState.historyStore.clearAll()
                }
            }
            Section("About") {
                Text("MacV 0.1.0")
                Text("Local clipboard transforms via shell scripts.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { appState.refreshLoginItemStatus() }
    }
}
