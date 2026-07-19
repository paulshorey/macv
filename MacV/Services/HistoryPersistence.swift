import Foundation
import GRDB

struct HistoryPersistence {
    private let dbQueue: DatabaseQueue
    private let largeBlobThreshold = 64 * 1024

    init(databaseURL: URL = AppPaths.databaseURL) {
        do {
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try migrator.migrate(dbQueue)
        } catch {
            fatalError("Failed to open history database: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "snapshots") { t in
                t.column("id", .text).primaryKey()
                t.column("created_at", .datetime).notNull()
                t.column("parent_id", .text)
                t.column("source_app", .text)
                t.column("origin_json", .text).notNull()
                t.column("preview", .text).notNull()
            }
            try db.create(table: "representations") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("snapshot_id", .text).notNull()
                    .references("snapshots", onDelete: .cascade)
                t.column("uti", .text).notNull()
                t.column("data", .blob)
                t.column("blob_path", .text)
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.create(index: "snapshots_created_at", on: "snapshots", columns: ["created_at"])
        }
        return migrator
    }

    func insert(_ snapshot: ClipboardSnapshot) throws {
        try dbQueue.write { db in
            let originData = try JSONEncoder().encode(snapshot.origin)
            let originJSON = String(data: originData, encoding: .utf8) ?? "{}"
            try db.execute(
                sql: """
                INSERT INTO snapshots (id, created_at, parent_id, source_app, origin_json, preview)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    snapshot.id.uuidString,
                    snapshot.createdAt,
                    snapshot.parentID?.uuidString,
                    snapshot.sourceApp,
                    originJSON,
                    snapshot.previewText
                ]
            )
            for rep in snapshot.representations {
                if rep.data.count > largeBlobThreshold {
                    let path = try Self.writeBlob(snapshotID: snapshot.id, uti: rep.uti, data: rep.data)
                    try db.execute(
                        sql: """
                        INSERT INTO representations (snapshot_id, uti, data, blob_path)
                        VALUES (?, ?, NULL, ?)
                        """,
                        arguments: [snapshot.id.uuidString, rep.uti, path]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO representations (snapshot_id, uti, data, blob_path)
                        VALUES (?, ?, ?, NULL)
                        """,
                        arguments: [snapshot.id.uuidString, rep.uti, rep.data]
                    )
                }
            }
        }
    }

    func loadRecent(limit: Int) throws -> [ClipboardSnapshot] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, created_at, parent_id, source_app, origin_json
                FROM snapshots
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try rows.map { row in
                let id = UUID(uuidString: row["id"])!
                let reps = try loadRepresentations(db: db, snapshotID: id)
                let originJSON: String = row["origin_json"]
                let origin = try JSONDecoder().decode(
                    SnapshotOrigin.self,
                    from: Data(originJSON.utf8)
                )
                let parent: String? = row["parent_id"]
                return ClipboardSnapshot(
                    id: id,
                    createdAt: row["created_at"],
                    parentID: parent.flatMap(UUID.init(uuidString:)),
                    sourceApp: row["source_app"],
                    origin: origin,
                    representations: reps
                )
            }
        }
    }

    private func loadRepresentations(db: Database, snapshotID: UUID) throws -> [PasteboardRepresentation] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT uti, data, blob_path FROM representations WHERE snapshot_id = ?",
            arguments: [snapshotID.uuidString]
        )
        return try rows.map { row in
            let uti: String = row["uti"]
            if let blobPath: String = row["blob_path"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: blobPath))
                return PasteboardRepresentation(uti: uti, data: data)
            }
            let data: Data = row["data"]
            return PasteboardRepresentation(uti: uti, data: data)
        }
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    func clearAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM representations")
            try db.execute(sql: "DELETE FROM snapshots")
            try db.execute(sql: "DELETE FROM meta")
        }
        let blobs = AppPaths.blobsDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func setActiveID(_ id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES ('active_id', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [id.uuidString]
            )
        }
    }

    func loadActiveID() -> UUID? {
        try? dbQueue.read { db in
            let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = 'active_id'"
            )
            return value.flatMap(UUID.init(uuidString:))
        }
    }

    private static func writeBlob(snapshotID: UUID, uti: String, data: Data) throws -> String {
        let safeUTI = uti.replacingOccurrences(of: "/", with: "_")
        let url = AppPaths.blobsDirectory
            .appendingPathComponent("\(snapshotID.uuidString)_\(safeUTI).bin")
        try data.write(to: url, options: .atomic)
        return url.path
    }
}
