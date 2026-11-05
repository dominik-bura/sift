import Foundation
import Darwin

struct CommandResult: Sendable {
    let output: String
    let error: String
    let exitCode: Int32
    let timedOut: Bool
    var cancelled = false
}

final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); defer { lock.unlock() }; stopped = true }
}

struct SecureCommandRunner: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 30,
        currentDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        captureOutput: Bool = true,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        cancellation: CommandCancellation? = nil
    ) -> CommandResult {
        if cancellation?.isCancelled == true {
            return CommandResult(output: "", error: "Command cancelled", exitCode: -3, timedOut: false, cancelled: true)
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DOCKER_HOST")
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        var trustedPathDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let marker = "/installation/"
        if let range = executable.standardizedFileURL.path.range(of: marker) {
            let installationRoot = String(executable.standardizedFileURL.path[..<range.upperBound])
            trustedPathDirectories.insert(installationRoot + "bin", at: 0)
        }
        environment["PATH"] = trustedPathDirectories.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        // Keep the environment surface narrow. Callers cannot override PATH,
        // HOME, Docker routing, or other process-sensitive configuration.
        for key in ["UV_LOCK_TIMEOUT"] {
            if let value = environmentOverrides[key] { environment[key] = value }
        }
        process.environment = environment

        let output = LockedData(capture: captureOutput, onLine: onOutputLine)
        let errors = LockedData()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(output: "", error: error.localizedDescription, exitCode: -1, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, cancellation?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let cancelled = process.isRunning && cancellation?.isCancelled == true
        let timedOut = process.isRunning && !cancelled
        if timedOut || cancelled {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        output.finishLines()
        errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return CommandResult(
            output: String(decoding: output.value, as: UTF8.self),
            error: cancelled ? "Command cancelled" : timedOut ? "Command timed out" : String(decoding: errors.value, as: UTF8.self),
            exitCode: cancelled ? -3 : timedOut ? -2 : process.terminationStatus,
            timedOut: timedOut, cancelled: cancelled
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var pending = Data()
    private let capture: Bool
    private let onLine: (@Sendable (String) -> Void)?

    init(capture: Bool = true, onLine: (@Sendable (String) -> Void)? = nil) {
        self.capture = capture
        self.onLine = onLine
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if capture { storage.append(data) }
        if let onLine {
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                onLine(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
    }

    func finishLines() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }
}

enum TrustedExecutable {
    static func find(_ name: String, additionalPaths: [String] = []) -> URL? {
        let home = NSHomeDirectory()
        let candidates = additionalPaths + fnmCandidates(name: name, home: home) + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.cargo/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.pulumi/bin/\(name)"
        ]
        let allowedRoots = [
            "/opt/homebrew/", "/usr/local/", "/usr/bin/", "/Applications/",
            "\(home)/.local/", "\(home)/.cargo/", "\(home)/.bun/", "\(home)/.pulumi/bin/"
        ]

        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard allowedRoots.contains(where: { resolved.path.hasPrefix($0) }) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func fnmCandidates(name: String, home: String) -> [String] {
        let versions = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.map { $0.appendingPathComponent("installation/bin/\(name)").path }
    }
}
