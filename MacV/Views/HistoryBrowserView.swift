import SwiftUI
import AppKit

struct HistoryBrowserView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            HStack {
                Text("Clipboard")
                    .font(.headline)
                Spacer()
                if appState.dispatcher.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    SettingsPresenter.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            TextField("Search history", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if let error = appState.dispatcher.lastError ?? appState.historyStore.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()

            if appState.filteredSnapshots.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clipboard",
                    description: Text("Copy something, or run a transform shortcut.")
                )
            } else {
                List(appState.filteredSnapshots) { snapshot in
                    SnapshotRow(
                        snapshot: snapshot,
                        isActive: snapshot.id == appState.historyStore.activeSnapshotID
                    ) {
                        appState.dispatcher.promote(snapshot)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(appState.historyStore.snapshots.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: ClipboardSnapshot
    let isActive: Bool
    let onPromote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.previewText.isEmpty ? "(empty)" : snapshot.previewText)
                    .lineLimit(2)
                    .font(.body)
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            HStack {
                Text(snapshot.origin.displayName)
                if let app = snapshot.sourceApp {
                    Text("·")
                    Text(app.split(separator: ".").last.map(String.init) ?? app)
                }
                Spacer()
                Text(snapshot.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Promote", action: onPromote)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}
