import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class HistoryStore {
    private(set) var snapshots: [ClipboardSnapshot] = []
    private(set) var activeSnapshotID: UUID?
    private let persistence: HistoryPersistence
    private let maxEntries: Int

    var activeSnapshot: ClipboardSnapshot? {
        guard let activeSnapshotID else { return snapshots.first }
        return snapshots.first(where: { $0.id == activeSnapshotID }) ?? snapshots.first
    }

    var lastError: String?

    init(persistence: HistoryPersistence = HistoryPersistence(), maxEntries: Int = 500) {
        self.persistence = persistence
        self.maxEntries = maxEntries
        reload()
    }

    func reload() {
        do {
            snapshots = try persistence.loadRecent(limit: maxEntries)
            activeSnapshotID = persistence.loadActiveID() ?? snapshots.first?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func append(_ snapshot: ClipboardSnapshot, setActive: Bool) -> ClipboardSnapshot {
        do {
            try persistence.insert(snapshot)
            if setActive {
                try persistence.setActiveID(snapshot.id)
                activeSnapshotID = snapshot.id
            }
            snapshots.insert(snapshot, at: 0)
            if snapshots.count > maxEntries {
                let removed = snapshots.suffix(from: maxEntries)
                snapshots = Array(snapshots.prefix(maxEntries))
                try persistence.delete(ids: removed.map(\.id))
            }
        } catch {
            lastError = error.localizedDescription
        }
        return snapshot
    }

    func setActive(_ id: UUID) {
        do {
            try persistence.setActiveID(id)
            activeSnapshotID = id
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearAll() {
        do {
            try persistence.clearAll()
            snapshots = []
            activeSnapshotID = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
