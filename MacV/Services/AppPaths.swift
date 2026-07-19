import Foundation
import AppKit

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("macv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var scriptsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var blobsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL {
        supportDirectory.appendingPathComponent("history.sqlite")
    }

    static var bindingsURL: URL {
        supportDirectory.appendingPathComponent("bindings.json")
    }
}
