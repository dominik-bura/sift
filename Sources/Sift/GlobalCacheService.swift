import Foundation

struct GlobalCacheService: Sendable {
    private let runner = SecureCommandRunner()
    private let uvLockProcesses = UVLockProcessService()
    private let regenerableCaches = RegenerableCacheService()
    private var fileManager: FileManager { .default }

    private struct Definition: Sendable {
        let id: String
        let name: String
        let detail: String
        let symbol: String
        let executable: String
        let fixedPath: @Sendable (String) -> String?
        let pathArguments: [String]?
        let cleanArguments: [String]
    }

    private var definitions: [Definition] {
        let home = NSHomeDirectory()
        return [
            Definition(id: "uv", name: "uv cache", detail: "Clears downloaded packages and disposable cache data", symbol: "bolt.fill", executable: "uv", fixedPath: { _ in nil }, pathArguments: ["cache", "dir"], cleanArguments: ["cache", "clean"]),
            Definition(id: "pnpm", name: "pnpm store", detail: "Prunes packages unreferenced by local projects", symbol: "shippingbox.fill", executable: "pnpm", fixedPath: { _ in nil }, pathArguments: ["store", "path"], cleanArguments: ["store", "prune"]),
            Definition(id: "bun", name: "Bun cache", detail: "Clears downloaded package archives", symbol: "hare.fill", executable: "bun", fixedPath: { _ in "\(home)/.bun/install/cache" }, pathArguments: nil, cleanArguments: ["pm", "cache", "rm"]),
            Definition(id: "yarn", name: "Yarn cache", detail: "Clears the shared package archive cache", symbol: "shippingbox.circle.fill", executable: "yarn", fixedPath: { _ in nil }, pathArguments: ["cache", "dir"], cleanArguments: ["cache", "clean"]),
            Definition(id: "npm", name: "npm cache", detail: "Clears npm's self-healing content cache", symbol: "cube.fill", executable: "npm", fixedPath: { _ in nil }, pathArguments: ["config", "get", "cache"], cleanArguments: ["cache", "clean", "--force"]),
            Definition(id: "go", name: "Go build cache", detail: "Clears reproducible build and test results", symbol: "hammer.fill", executable: "go", fixedPath: { _ in nil }, pathArguments: ["env", "GOCACHE"], cleanArguments: ["clean", "-cache", "-testcache"]),
            Definition(id: "homebrew", name: "Homebrew", detail: "Prunes stale downloads and old formula versions", symbol: "mug.fill", executable: "brew", fixedPath: { _ in nil }, pathArguments: ["--cache"], cleanArguments: ["cleanup"]),
            Definition(id: "pulumi", name: "Pulumi plugins", detail: "Clears downloaded provider plugins; required versions download again", symbol: "shippingbox.fill", executable: "pulumi", fixedPath: { _ in "\(ProcessInfo.processInfo.environment["PULUMI_HOME"] ?? home + "/.pulumi")/plugins" }, pathArguments: nil, cleanArguments: ["plugin", "rm", "--all", "--yes"]),
            Definition(id: "simulators", name: "Unavailable simulators", detail: "Removes devices whose runtimes are no longer installed; device data is deleted", symbol: "iphone", executable: "xcrun", fixedPath: { _ in "\(home)/Library/Developer/CoreSimulator/Devices" }, pathArguments: nil, cleanArguments: ["simctl", "delete", "unavailable"])
        ]
    }

    func inspectAll(onResult: @Sendable (GlobalCache) -> Void = { _ in }) -> [GlobalCache] {
        var results: [GlobalCache] = []
        for definition in definitions {
            if let cache = inspect(definition) { results.append(cache); onResult(cache) }
        }
        for definition in RegenerableCacheService.definitions {
            if let cache = regenerableCaches.inspect(id: definition.id) { results.append(cache); onResult(cache) }
        }
        return results
    }

    func inspect(id: String) -> GlobalCache? {
        definitions.first(where: { $0.id == id }).flatMap(inspect) ?? regenerableCaches.inspect(id: id)
    }

    func installedPlaceholders() -> [GlobalCache] {
        let tools = definitions.compactMap { definition -> GlobalCache? in
            guard TrustedExecutable.find(definition.executable) != nil else { return nil }
            return GlobalCache(
                id: definition.id,
                name: definition.name,
                detail: definition.detail,
                symbolName: definition.symbol,
                state: .checking
            )
        }
        let local = RegenerableCacheService.definitions.compactMap { definition -> GlobalCache? in
            guard definition.relativePaths.contains(where: { fileManager.fileExists(atPath: NSHomeDirectory() + "/" + $0) }) else { return nil }
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: "app.badge", state: .checking)
        }
        return tools + local
    }

    func clean(id: String) throws {
        if id == "uv", ProcessInfo.processInfo.environment["UV_LINK_MODE"] == "symlink" {
            throw GlobalCacheError.failed("uv symlink mode depends on cache files. Change the link mode and recreate environments before clearing this cache.")
        }
        if RegenerableCacheService.definitions.contains(where: { $0.id == id }) {
            try regenerableCaches.clean(id: id)
            return
        }
        guard let definition = definitions.first(where: { $0.id == id }),
              let executable = TrustedExecutable.find(definition.executable) else {
            throw GlobalCacheError.unavailable
        }
        guard let current = inspect(definition), case .available = current.state else {
            throw GlobalCacheError.failed("The cache location could not be safely verified")
        }
        var cleanupArguments = definition.cleanArguments
        if definition.id == "uv" { cleanupArguments = uvCleanupArguments(executable) }
        if definition.id == "simulators", let path = current.state.path {
            cleanupArguments = ["simctl", "--set", path, "delete", "unavailable"]
        }
        let result: CommandResult
        if definition.id == "bun" {
            result = try runBunCacheCleanup(executable, arguments: cleanupArguments)
        } else if definition.id == "pnpm" {
            result = try runInTemporaryDirectory(
                named: "Sift-pnpm",
                executable: executable,
                arguments: cleanupArguments,
                timeout: 120
            )
        } else {
            result = runner.run(
                executable,
                arguments: cleanupArguments,
                timeout: definition.id == "homebrew" ? 300 : 120,
                environmentOverrides: definition.id == "uv" ? ["UV_LOCK_TIMEOUT": "0"] : [:]
            )
        }
        guard result.exitCode == 0 else {
            throw GlobalCacheError.failed(Self.safeError(result.error))
        }
    }

    private func uvCleanupArguments(_ executable: URL) -> [String] {
        let help = runner.run(executable, arguments: ["cache", "clean", "--help"], timeout: 10)
        // Probe the specific feature using a read-only cache-directory query.
        // Older uv versions reject the feature even if the global flag exists.
        if help.output.contains("--preview-features"),
           let probe = try? runInTemporaryDirectory(named: "Sift-uv-feature", executable: executable,
                 arguments: ["cache", "dir", "--preview-features", "cache-physical-space"], timeout: 10), probe.exitCode == 0 {
            return ["cache", "clean", "--preview-features", "cache-physical-space"]
        }
        return ["cache", "clean"]
    }

    private func runBunCacheCleanup(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Sift-Bun-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        let manifest = Data(#"{"name":"sift-cache-cleanup","version":"0.0.0","private":true}"#.utf8)
        try manifest.write(to: directory.appendingPathComponent("package.json"), options: .atomic)
        return runner.run(executable, arguments: arguments, timeout: 120, currentDirectory: directory)
    }

    private func runInTemporaryDirectory(
        named prefix: String,
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        return runner.run(executable, arguments: arguments, timeout: timeout, currentDirectory: directory)
    }

    private func inspect(_ definition: Definition) -> GlobalCache? {
        guard let executable = TrustedExecutable.find(definition.executable) else { return nil }
        let path: String
        if let fixed = definition.fixedPath(NSHomeDirectory()) {
            path = fixed
        } else if let arguments = definition.pathArguments {
            let result: CommandResult
            if definition.id == "pnpm" {
                do {
                    result = try runInTemporaryDirectory(
                        named: "Sift-pnpm-inspect",
                        executable: executable,
                        arguments: arguments,
                        timeout: 10
                    )
                } catch {
                    return GlobalCache(
                        id: definition.id,
                        name: definition.name,
                        detail: definition.detail,
                        symbolName: definition.symbol,
                        state: .failed("Could not create a private inspection directory")
                    )
                }
            } else {
                result = runner.run(executable, arguments: arguments, timeout: 10)
            }
            guard result.exitCode == 0 else {
                return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol, state: .failed(Self.safeError(result.error)))
            }
            path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        guard let validated = validatedCachePath(path) else {
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol, state: .failed("Cache location is outside your home folder"))
        }
        guard let bytes = allocatedSize(of: validated) else {
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol,
                               state: .failed("Could not measure cache; check permissions"))
        }
        if definition.id == "uv" {
            let holders = uvLockProcesses.holders(cachePath: validated.path)
            if !holders.isEmpty {
                return GlobalCache(
                    id: definition.id,
                    name: definition.name,
                    detail: definition.detail,
                    symbolName: definition.symbol,
                    state: .blocked(bytes: bytes, path: validated.path, processCount: holders.count)
                )
            }
        }
        return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol, state: .available(bytes: bytes, path: validated.path))
    }

    private func validatedCachePath(_ rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/"), resolved != home else { return nil }
        return url
    }

    private func allocatedSize(of directory: URL) -> Int64? {
        if !fileManager.fileExists(atPath: directory.path) { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .mayShareFileContentKey
        ]
        var failed = false
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in failed = true; return true }) else { return nil }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys) else { failed = true; continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return failed ? nil : total
    }

    private static func safeError(_ raw: String) -> String {
        let normalized = raw.lowercased()
        if normalized.contains("timed out") { return "Cleanup timed out" }
        if normalized.contains("permission denied") { return "Permission denied" }
        if normalized.contains("lock") && (normalized.contains("cache") || normalized.contains("resource temporarily unavailable")) {
            return "Cache is in use by another uv process"
        }
        return "Cleanup command failed"
    }
}

enum GlobalCacheError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The package manager is no longer available"
        case let .failed(message): return message
        }
    }
}
