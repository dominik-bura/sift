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
        let result = runner.run(
            executable,
            arguments: ["system", "df", "--format", "{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}"]
        )
        guard result.exitCode == 0 else {
            return .unavailable(Self.userFacingError(result.error))
        }
        let usage = Self.parseSystemDF(result.output)
        let detail = usage.imageCount == 0
            ? "No local images"
            : "\(usage.imageCount) image\(usage.imageCount == 1 ? "" : "s") · \(ByteFormatting.string(usage.imageBytes))"
        return .available(reclaimableBytes: usage.reclaimableBytes, detail: detail)
    }

    func pruneUnusedData() throws -> String {
        guard let executable = findDocker() else {
            throw DockerError.unavailable("Docker CLI not found")
        }
        guard localEndpoint(using: executable) != nil else {
            throw DockerError.unavailable("Remote Docker contexts are not supported")
        }
        let imageResult = runner.run(executable, arguments: ["image", "prune", "-a", "--force"], timeout: 120)
        guard imageResult.exitCode == 0 else {
            throw DockerError.unavailable(Self.userFacingError(imageResult.error))
        }
        let builderResult = runner.run(executable, arguments: ["builder", "prune", "-a", "--force"], timeout: 120)
        guard builderResult.exitCode == 0 else {
            throw DockerError.unavailable(Self.userFacingError(builderResult.error))
        }
        return imageResult.output + builderResult.output
    }

    static func reclaimedBytes(fromPruneOutput output: String) -> Int64? {
        let prefix = "Total reclaimed space:"
        let values = output.components(separatedBy: .newlines).compactMap { line -> Int64? in
            guard let range = line.range(of: prefix, options: .caseInsensitive) else { return nil }
            return parseHumanSize(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return values.isEmpty ? nil : values.reduce(0, +)
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

    static func parseSystemDF(_ output: String) -> DockerUsage {
        var usage = DockerUsage()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            if fields[0].localizedCaseInsensitiveContains("image") {
                usage.imageCount = Int(fields[1]) ?? 0
                usage.imageBytes = parseHumanSize(fields[2]) ?? 0
                usage.reclaimableBytes += parseHumanSize(fields[3]) ?? 0
            } else if fields[0].localizedCaseInsensitiveContains("build cache") {
                usage.reclaimableBytes += parseHumanSize(fields[3]) ?? 0
            }
        }
        return usage
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
            return "Docker is running, but Sift cannot access it"
        }

        return "Docker is unavailable right now"
    }
}

struct DockerUsage: Equatable, Sendable {
    var imageCount = 0
    var imageBytes: Int64 = 0
    var reclaimableBytes: Int64 = 0
}

enum DockerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        if case let .unavailable(message) = self { return message }
        return "Docker is unavailable"
    }
}
