import Foundation

struct GlobalCacheService: Sendable {
    private let runner = SecureCommandRunner()
    private let uvLockProcesses = UVLockProcessService()
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
            Definition(id: "homebrew", name: "Homebrew", detail: "Prunes stale downloads and old formula versions", symbol: "mug.fill", executable: "brew", fixedPath: { _ in nil }, pathArguments: ["--cache"], cleanArguments: ["cleanup"])
        ]
    }

    func inspectAll() -> [GlobalCache] {
        definitions.compactMap(inspect)
    }

    func inspect(id: String) -> GlobalCache? {
        definitions.first(where: { $0.id == id }).flatMap(inspect)
    }

    func installedPlaceholders() -> [GlobalCache] {
        definitions.compactMap { definition in
            guard TrustedExecutable.find(definition.executable) != nil else { return nil }
            return GlobalCache(
                id: definition.id,
                name: definition.name,
                detail: definition.detail,
                symbolName: definition.symbol,
                state: .checking
            )
        }
    }

    func clean(id: String) throws {
        guard let definition = definitions.first(where: { $0.id == id }),
              let executable = TrustedExecutable.find(definition.executable) else {
            throw GlobalCacheError.unavailable
        }
        guard let current = inspect(definition), case .available = current.state else {
            throw GlobalCacheError.failed("The cache location could not be safely verified")
        }
        let result: CommandResult
        if definition.id == "bun" {
            result = try runBunCacheCleanup(executable, arguments: definition.cleanArguments)
        } else if definition.id == "pnpm" {
            result = try runInTemporaryDirectory(
                named: "Sift-pnpm",
                executable: executable,
                arguments: definition.cleanArguments,
                timeout: 120
            )
        } else {
            result = runner.run(
                executable,
                arguments: definition.cleanArguments,
                timeout: definition.id == "homebrew" ? 300 : 120,
                environmentOverrides: definition.id == "uv" ? ["UV_LOCK_TIMEOUT": "0"] : [:]
            )
        }
        guard result.exitCode == 0 else {
            throw GlobalCacheError.failed(Self.safeError(result.error))
        }
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
        let bytes = allocatedSize(of: validated)
        if definition.id == "uv" {
            let holders = uvLockProcesses.holders()
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

    private func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .mayShareFileContentKey
        ]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            guard values.mayShareFileContent != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
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
