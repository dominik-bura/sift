import Foundation

struct CommandResult: Sendable {
    let output: String
    let error: String
    let exitCode: Int32
}

struct DockerService: Sendable {
    func status() -> DockerState {
        guard let executable = findDocker() else {
            return .unavailable("Docker CLI not found")
        }

        let result = run(executable, arguments: ["system", "df", "--format", "{{.Type}}|{{.Reclaimable}}"])
        guard result.exitCode == 0 else {
            return .unavailable(Self.userFacingError(result.error))
        }

        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[0].localizedCaseInsensitiveContains("image") else { continue }
            let bytes = Self.parseHumanSize(fields[1]) ?? 0
            return .available(reclaimableBytes: bytes, detail: fields[1])
        }

        return .available(reclaimableBytes: 0, detail: "No unused images")
    }

    func pruneUnusedImages() throws -> String {
        guard let executable = findDocker() else {
            throw DockerError.unavailable("Docker CLI not found")
        }
        let result = run(executable, arguments: ["image", "prune", "-a", "--force"])
        guard result.exitCode == 0 else {
            throw DockerError.unavailable(Self.userFacingError(result.error))
        }
        return result.output
    }

    private func findDocker() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/docker" }
        }
        candidates += [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func run(_ executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(output: "", error: error.localizedDescription, exitCode: -1)
        }

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(output: output, error: error, exitCode: process.terminationStatus)
    }

    static func parseHumanSize(_ input: String) -> Int64? {
        let value = input.split(separator: " ").first.map(String.init) ?? input
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let number = Double(value[numberRange]) else { return nil }

        let multiplier: Double
        switch value[unitRange].uppercased() {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }

    static func userFacingError(_ rawError: String) -> String {
        let message = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()
        let daemonUnavailableSignals = [
            "failed to connect to the docker api",
            "cannot connect to the docker daemon",
            "is the docker daemon running",
            "connection refused",
            "no such file or directory",
            "docker.sock"
        ]

        if message.isEmpty || daemonUnavailableSignals.contains(where: normalized.contains) {
            return "Docker Engine is not running"
        }

        if normalized.contains("permission denied") {
            return "Docker is running, but DevSweep cannot access it"
        }

        return "Docker is unavailable right now"
    }
}

enum DockerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        if case let .unavailable(message) = self { return message }
        return "Docker is unavailable"
    }
}
