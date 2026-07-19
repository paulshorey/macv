import Foundation
import Observation

protocol Transformation: Sendable {
    var id: String { get }
    var displayName: String { get }
    func apply(to snapshot: ClipboardSnapshot, event: ClipboardEvent) async throws -> ClipboardSnapshot
}

struct ShellScriptTransformation: Transformation {
    let id: String
    let displayName: String
    let scriptURL: URL
    let runner: ScriptRunner

    func apply(to snapshot: ClipboardSnapshot, event: ClipboardEvent) async throws -> ClipboardSnapshot {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ScriptError.missingScript(id)
        }
        let input = snapshot.preferredPlainTextData() ?? Data()
        let env: [String: String] = [
            "MACV_SCRIPT_ID": id,
            "MACV_EVENT": event.rawValue,
            "MACV_SNAPSHOT_ID": snapshot.id.uuidString,
            "MACV_SOURCE_APP": snapshot.sourceApp ?? "",
            "MACV_PLAINTEXT_UTI": "public.utf8-plain-text"
        ]
        let result = try await runner.run(script: scriptURL, stdin: input, env: env)
        if result.timedOut {
            throw ScriptError.timedOut
        }
        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw ScriptError.failed(stderr: stderr)
        }
        let rep = PasteboardRepresentation(
            uti: "public.utf8-plain-text",
            data: result.stdout
        )
        return ClipboardSnapshot(
            id: UUID(),
            createdAt: Date(),
            parentID: snapshot.id,
            sourceApp: snapshot.sourceApp,
            origin: .transformation(scriptID: id),
            representations: [rep]
        )
    }
}

struct ScriptInfo: Identifiable, Equatable, Sendable {
    var id: String { scriptID }
    let scriptID: String
    let displayName: String
    let url: URL
}

@MainActor
@Observable
final class ScriptRegistry {
    private(set) var scripts: [ScriptInfo] = []
    var lastError: String?
    private var runner: ScriptRunner

    init(runner: ScriptRunner = ScriptRunner()) {
        self.runner = runner
        installBundledScriptsIfNeeded()
        reload()
    }

    func reload() {
        let dir = AppPaths.scriptsDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            scripts = []
            return
        }
        let allowed = Set(["sh", "py", "js", "mjs", "zsh", "bash"])
        scripts = files
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return ScriptInfo(
                    scriptID: id,
                    displayName: Self.prettyName(id),
                    url: url
                )
            }
    }

    func find(_ scriptID: String) -> (any Transformation)? {
        guard let info = scripts.first(where: { $0.scriptID == scriptID }) else { return nil }
        return ShellScriptTransformation(
            id: info.scriptID,
            displayName: info.displayName,
            scriptURL: info.url,
            runner: runner
        )
    }

    func installBundledScriptsIfNeeded() {
        let dest = AppPaths.scriptsDirectory
        let fm = FileManager.default

        // Prefer copying from the app bundle Resources/Scripts folder.
        let bundledCandidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Scripts"),
            Bundle.main.resourceURL?.appendingPathComponent("MacV/Resources/Scripts"),
            Bundle.main.url(forResource: "Scripts", withExtension: nil)
        ].compactMap { $0 }

        var installedFromBundle = false
        for bundled in bundledCandidates {
            guard fm.fileExists(atPath: bundled.path),
                  let items = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil),
                  !items.isEmpty
            else { continue }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                let target = dest.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { continue }
                do {
                    try fm.copyItem(at: item, to: target)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                    installedFromBundle = true
                } catch {
                    lastError = error.localizedDescription
                }
            }
            if installedFromBundle { break }
        }

        // Fallback: write embedded starters if folder is still empty.
        let existing = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        if existing.isEmpty {
            for starter in EmbeddedStarters.all {
                let target = dest.appendingPathComponent(starter.filename)
                do {
                    try starter.contents.write(to: target, atomically: true, encoding: .utf8)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private static func prettyName(_ id: String) -> String {
        id
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private enum EmbeddedStarters {
    struct Starter {
        let filename: String
        let contents: String
    }

    static let all: [Starter] = [
        Starter(filename: "plain-text-only.sh", contents: """
            #!/bin/zsh
            set -euo pipefail
            cat
            """),
        Starter(filename: "json-pretty.sh", contents: """
            #!/bin/zsh
            set -euo pipefail
            python3 - <<'PY'
            import json, sys
            raw = sys.stdin.read()
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                sys.stderr.write("not JSON\\n")
                sys.exit(1)
            print(json.dumps(obj, indent=2, ensure_ascii=False))
            PY
            """),
        Starter(filename: "html-strip.sh", contents: """
            #!/bin/zsh
            set -euo pipefail
            python3 - <<'PY'
            import sys
            from html.parser import HTMLParser

            class Stripper(HTMLParser):
                def __init__(self):
                    super().__init__()
                    self.parts = []
                def handle_data(self, data):
                    self.parts.append(data)

            raw = sys.stdin.read()
            p = Stripper()
            try:
                p.feed(raw)
                p.close()
            except Exception as e:
                sys.stderr.write(f"html parse error: {e}\\n")
                sys.exit(1)
            print("".join(p.parts))
            PY
            """),
        Starter(filename: "uppercase.js", contents: """
            #!/usr/bin/env node
            const chunks = [];
            process.stdin.on('data', (c) => chunks.push(c));
            process.stdin.on('end', () => {
              const text = Buffer.concat(chunks).toString('utf8');
              process.stdout.write(text.toUpperCase());
            });
            """)
    ]
}
