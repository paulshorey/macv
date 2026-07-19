import Foundation

struct ScriptResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

enum ScriptError: LocalizedError {
    case failed(stderr: String)
    case timedOut
    case missingScript(String)
    case notExecutable(String)

    var errorDescription: String? {
        switch self {
        case .failed(let stderr):
            return stderr.isEmpty ? "Script failed" : stderr
        case .timedOut:
            return "Script timed out"
        case .missingScript(let id):
            return "Script not found: \(id)"
        case .notExecutable(let path):
            return "Script is not executable: \(path)"
        }
    }
}

struct ScriptRunner: Sendable {
    var timeout: TimeInterval
    var supportDirectory: URL

    init(timeout: TimeInterval = 5, supportDirectory: URL = AppPaths.supportDirectory) {
        self.timeout = timeout
        self.supportDirectory = supportDirectory
    }

    func run(
        script: URL,
        stdin: Data,
        env: [String: String]
    ) async throws -> ScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runSync(
                        script: script,
                        stdin: stdin,
                        env: env,
                        timeout: self.timeout,
                        supportDirectory: self.supportDirectory
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(
        script: URL,
        stdin: Data,
        env: [String: String],
        timeout: TimeInterval,
        supportDirectory: URL
    ) throws -> ScriptResult {
        let process = Process()
        // IMPORTANT: do not exec shell scripts via shebang alone.
        // User ~/.zshenv (always sourced by zsh) often prints banners / cds / lists
        // files, which would pollute stdout and land in the clipboard.
        configureProcess(process, for: script)
        process.currentDirectoryURL = supportDirectory
        process.environment = makeCleanEnvironment(
            supportDirectory: supportDirectory,
            extra: env
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutLock = NSLock()
        var stdoutData = Data()
        let stderrLock = NSLock()
        var stderrData = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutLock.lock()
            stdoutData.append(chunk)
            stdoutLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(chunk)
            stderrLock.unlock()
        }

        try process.run()

        // Write stdin asynchronously to avoid 64 KiB pipe deadlock.
        let writeHandle = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            if !stdin.isEmpty {
                writeHandle.write(stdin)
            }
            try? writeHandle.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining buffered data.
        stdoutLock.lock()
        stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        let out = stdoutData
        stdoutLock.unlock()

        stderrLock.lock()
        stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let err = stderrData
        stderrLock.unlock()

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: out,
            stderr: err,
            timedOut: timedOut
        )
    }

    /// Launch shell scripts with rc files disabled; run other shebang scripts directly.
    private static func configureProcess(_ process: Process, for script: URL) {
        let ext = script.pathExtension.lowercased()
        let shebang = readShebang(of: script) ?? ""

        let isZsh = ext == "zsh" || ext == "sh"
            || shebang.contains("/zsh")
            || shebang.hasSuffix(" zsh")
            || shebang == "#!/bin/sh"
            || shebang.hasPrefix("#!/bin/sh ")
        let isBash = ext == "bash"
            || shebang.contains("/bash")
            || shebang.hasSuffix(" bash")

        if isZsh {
            // -f => NO_RCS: skip ~/.zshenv, ~/.zshrc, etc. (/etc/zshenv still runs)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "--", script.path]
            return
        }
        if isBash {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", "--", script.path]
            return
        }

        // python / node / other shebang scripts — no shell rc involvement
        process.executableURL = script
        process.arguments = []
    }

    private static func readShebang(of script: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: script) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 128)
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init),
            line.hasPrefix("#!")
        else { return nil }
        return line
    }

    /// Curated env: keep tools on PATH, drop shell-init knobs that print to stdout.
    private static func makeCleanEnvironment(
        supportDirectory: URL,
        extra: [String: String]
    ) -> [String: String] {
        let path = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            supportDirectory.appendingPathComponent("bin").path
        ].joined(separator: ":")

        var environment: [String: String] = [
            "PATH": path,
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb",
            "MACV_SUPPORT_DIR": supportDirectory.path,
            // Empty ZDOTDIR => zsh won't find a user .zshenv even without -f
            "ZDOTDIR": supportDirectory.appendingPathComponent(".empty-zdotdir").path
        ]

        // Ensure empty ZDOTDIR exists (no rc files inside).
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: environment["ZDOTDIR"]!),
            withIntermediateDirectories: true
        )

        // Explicitly omit ENV / BASH_ENV / SHELLOPTS which can force rc sourcing.
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }
}
