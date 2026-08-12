import Foundation

struct DockerService: Sendable {
    private let runner = SecureCommandRunner()

    func status() -> DockerState {
        guard let executable = findDocker() else {
            return .unavailable("Docker CLI not found")
        }

        guard localEndpoint(using: executable) != nil else {
            return .unavailable("Remote Docker contexts are not supported")
        }
        let result = runner.run(executable, arguments: ["system", "df", "--format", "{{.Type}}|{{.Reclaimable}}"])
        guard result.exitCode == 0 else {
            return .unavailable(Self.userFacingError(result.error))
        }

        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[0].localizedCaseInsensitiveContains("image") else { continue }
            let bytes = Self.parseHumanSize(fields[1]) ?? 0
            return .available(
                reclaimableBytes: bytes,
                detail: bytes == 0 ? "No unused images" : ByteFormatting.string(bytes)
            )
        }

        return .available(reclaimableBytes: 0, detail: "No unused images")
    }

    func pruneUnusedImages() throws -> String {
        guard let executable = findDocker() else {
            throw DockerError.unavailable("Docker CLI not found")
        }
        guard localEndpoint(using: executable) != nil else {
            throw DockerError.unavailable("Remote Docker contexts are not supported")
        }
        let result = runner.run(executable, arguments: ["image", "prune", "-a", "--force"], timeout: 120)
        guard result.exitCode == 0 else {
            throw DockerError.unavailable(Self.userFacingError(result.error))
        }
        return result.output
    }

    private func findDocker() -> URL? {
        TrustedExecutable.find("docker", additionalPaths: [
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"
        ])
    }

    func localEndpoint(using executable: URL) -> String? {
        let result = runner.run(
            executable,
            arguments: ["context", "inspect", "--format", "{{(index .Endpoints \"docker\").Host}}"]
        )
        guard result.exitCode == 0 else { return nil }
        let endpoint = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAllowedEndpoint(endpoint) else { return nil }
        return endpoint
    }

    static func isAllowedEndpoint(_ endpoint: String) -> Bool {
        endpoint.hasPrefix("unix://") && !endpoint.contains("\n") && !endpoint.contains("\r")
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
