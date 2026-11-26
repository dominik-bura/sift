import Foundation

struct GlobalCacheService: Sendable {
    private let runner = SecureCommandRunner()
    private let uvLockProcesses = UVLockProcessService()
    private let regenerableCaches = RegenerableCacheService()
    private var fileManager: FileManager { .default }

    static let otherPnpmStoresID = "pnpm-other-stores"

    /// Used when a tool's cache exists but its executable is not in a location
    /// Sift runs commands from: the fixed cache directory is emptied directly.
    private static let directFallbacks: [String: RegenerableCacheDefinition] = [
        "bun": .init(id: "bun", name: "Bun cache", relativePaths: [".bun/install/cache"], appNames: [],
                     detail: "Clears downloaded package archives directly because no trusted bun executable was found",
                     category: .packages, symbol: "hare.fill")
    ]

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
        // File-based sources are independent directory walks, so a few workers
        // measure them while the package-manager commands run one after another.
        // This keeps the inventory from slowing down as more sources are supported.
        let fileBased = RegenerableCacheService.definitions
        let slots = InspectionSlots(count: fileBased.count)
        let regenerableCaches = regenerableCaches
        return withoutActuallyEscaping(onResult) { onResult in
            let fileBasedWork = DispatchGroup()
            DispatchQueue.global(qos: .utility).async(group: fileBasedWork) {
                DispatchQueue.concurrentPerform(iterations: min(3, fileBased.count)) { _ in
                    while let index = slots.claimNext() {
                        guard let cache = regenerableCaches.inspect(fileBased[index]) else { continue }
                        slots.store(cache, at: index)
                        onResult(cache)
                    }
                }
            }
            var results: [GlobalCache] = []
            for definition in definitions {
                guard let cache = inspect(definition) else { continue }
                results.append(cache); onResult(cache)
                if definition.id == "pnpm", let others = inspectOtherPnpmStores(activePath: cache.state.path) {
                    results.append(others); onResult(others)
                }
            }
            // The callback must not outlive this call.
            fileBasedWork.wait()
            return results + slots.caches
        }
    }

    func inspect(id: String) -> GlobalCache? {
        if id == Self.otherPnpmStoresID { return inspectOtherPnpmStores(activePath: activePnpmStorePath()) }
        return definitions.first(where: { $0.id == id }).flatMap(inspect) ?? regenerableCaches.inspect(id: id)
    }

    func inspectAfterCleanup(id: String) -> GlobalCache? {
        if id == Self.otherPnpmStoresID {
            return inspectOtherPnpmStores(activePath: activePnpmStorePath(), reportEmpty: true)
        }
        if RegenerableCacheService.definition(id: id) != nil {
            return regenerableCaches.inspectAfterCleanup(id: id)
        }
        return inspect(id: id)
    }

    func installedPlaceholders() -> [GlobalCache] {
        let tools = definitions.compactMap { definition -> GlobalCache? in
            guard TrustedExecutable.find(definition.executable) != nil
                    || Self.directFallbacks[definition.id].map(regenerableCaches.hasMatches) == true else { return nil }
            return GlobalCache(
                id: definition.id,
                name: definition.name,
                detail: definition.detail,
                symbolName: definition.symbol,
                state: .checking
            )
        }
        let local = RegenerableCacheService.definitions.compactMap { definition -> GlobalCache? in
            guard regenerableCaches.hasMatches(definition) else { return nil }
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol, state: .checking)
        }
        return tools + local
    }

    func clean(id: String) throws {
        if id == "uv", ProcessInfo.processInfo.environment["UV_LINK_MODE"] == "symlink" {
            throw GlobalCacheError.failed("uv symlink mode depends on cache files. Change the link mode and recreate environments before clearing this cache.")
        }
        if id == Self.otherPnpmStoresID {
            try cleanOtherPnpmStores()
            return
        }
        if RegenerableCacheService.definition(id: id) != nil {
            try regenerableCaches.clean(id: id)
            return
        }
        guard let definition = definitions.first(where: { $0.id == id }) else { throw GlobalCacheError.unavailable }
        guard let executable = TrustedExecutable.find(definition.executable) else {
            guard let fallback = Self.directFallbacks[id] else { throw GlobalCacheError.unavailable }
            try regenerableCaches.clean(fallback)
            return
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
        guard let executable = TrustedExecutable.find(definition.executable) else {
            return Self.directFallbacks[definition.id].flatMap(regenerableCaches.inspect)
        }
        var path: String
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
            // `npm cache clean` only clears the content cache. Measuring the whole
            // npm folder would also count npx packages and logs it leaves behind.
            if definition.id == "npm", path.hasPrefix("/") {
                path = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("_cacache", isDirectory: true).path
            }
        } else {
            return nil
        }

        guard let validated = validatedCachePath(path) else {
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol, state: .failed("Cache location is outside your home folder"))
        }
        if definition.id == "simulators" {
            do {
                let measurement = try SimulatorCacheService().inspect(executable: executable, deviceRoot: validated)
                return GlobalCache(id: definition.id, name: definition.name,
                                   detail: "\(measurement.deviceCount) unavailable device\(measurement.deviceCount == 1 ? "" : "s") · available devices and runtimes are preserved",
                                   symbolName: definition.symbol, state: .available(bytes: measurement.bytes, path: validated.path))
            } catch {
                return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail,
                                   symbolName: definition.symbol, state: .failed(error.localizedDescription))
            }
        }
        guard let measurement = DirectoryMeasurement.measure(validated.resolvingSymlinksInPath()) else {
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol,
                               state: .failed("Could not measure cache; check permissions"))
        }
        let bytes = measurement.bytes
        let lastChanged = bytes > 0 ? measurement.newestChange : nil
        if definition.id == "uv" {
            let holders = uvLockProcesses.holders(cachePath: validated.path)
            if !holders.isEmpty {
                return GlobalCache(
                    id: definition.id,
                    name: definition.name,
                    detail: definition.detail,
                    symbolName: definition.symbol,
                    state: .blocked(bytes: bytes, path: validated.path, processCount: holders.count),
                    lastChanged: lastChanged
                )
            }
        }
        return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: definition.symbol,
                           state: .available(bytes: bytes, path: validated.path), lastChanged: lastChanged)
    }

    // MARK: - Other pnpm stores

    private func activePnpmStorePath() -> String? {
        guard let executable = TrustedExecutable.find("pnpm"),
              let result = try? runInTemporaryDirectory(named: "Sift-pnpm-inspect", executable: executable,
                                                        arguments: ["store", "path"], timeout: 10),
              result.exitCode == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every pnpm major release writes a new `v<number>` store next to the old
    /// one, and `pnpm store prune` only touches the store of the pnpm that runs it.
    private func otherPnpmStores(activePath: String?) throws -> [URL] {
        guard let activePath, let active = validatedCachePath(activePath) else {
            throw GlobalCacheError.failed("Could not verify the active pnpm store")
        }
        return try PnpmStoreLayout.otherStores(besides: active).filter { validatedCachePath($0.path) != nil }
    }

    private func inspectOtherPnpmStores(activePath: String?, reportEmpty: Bool = false) -> GlobalCache? {
        let name = "Other pnpm stores"
        let stores: [URL]
        do {
            stores = try otherPnpmStores(activePath: activePath)
            if stores.isEmpty, reportEmpty, let activePath {
                let active = URL(fileURLWithPath: activePath)
                guard try PnpmStoreLayout.versionStores(besides: active).isEmpty else {
                    throw GlobalCacheError.failed("pnpm stores with global virtual-store links were retained; remaining size is unknown")
                }
                return GlobalCache(id: Self.otherPnpmStoresID, name: name, detail: "No other versioned stores remain", symbolName: "shippingbox",
                                   state: .available(bytes: 0, path: active.deletingLastPathComponent().path))
            }
        } catch {
            return GlobalCache(id: Self.otherPnpmStoresID, name: name, detail: "Could not verify other pnpm stores", symbolName: "shippingbox",
                               state: .failed(error.localizedDescription))
        }
        guard let first = stores.first else { return nil }
        let detail = "\(stores.count) other store version\(stores.count == 1 ? "" : "s"); stores with global virtual-store links are excluded"
        var total = DirectoryMeasurement()
        for store in stores {
            guard let measurement = DirectoryMeasurement.measure(store) else {
                return GlobalCache(id: Self.otherPnpmStoresID, name: name, detail: detail, symbolName: "shippingbox",
                                   state: .failed("Could not measure cache; check permissions"))
            }
            total.add(measurement)
        }
        return GlobalCache(id: Self.otherPnpmStoresID, name: name, detail: detail, symbolName: "shippingbox",
                           state: .available(bytes: total.bytes, path: first.path),
                           lastChanged: total.bytes > 0 ? total.newestChange : nil)
    }

    private func cleanOtherPnpmStores() throws {
        guard let activePath = activePnpmStorePath() else { throw GlobalCacheError.unavailable }
        for store in try otherPnpmStores(activePath: activePath) {
            // Recheck immediately before removal: the store must still be a real
            // versioned directory beside the active one, never the active store.
            guard try PnpmStoreLayout.otherStores(besides: URL(fileURLWithPath: activePath, isDirectory: true)).contains(store),
                  validatedCachePath(store.path) != nil else {
                throw GlobalCacheError.failed("Cache location changed during cleanup")
            }
            try fileManager.removeItem(at: store)
        }
    }

    private func validatedCachePath(_ rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/"), resolved != home else { return nil }
        return url
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

/// Hands out definition indexes to concurrent workers and keeps results in definition order.
private final class InspectionSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var stored: [GlobalCache?]

    init(count: Int) { stored = Array(repeating: nil, count: count) }

    func claimNext() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < stored.count else { return nil }
        defer { next += 1 }
        return next
    }
    func store(_ cache: GlobalCache, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        stored[index] = cache
    }
    var caches: [GlobalCache] {
        lock.lock(); defer { lock.unlock() }
        return stored.compactMap { $0 }
    }
}

enum PnpmStoreLayout {
    static func isVersionDirectoryName(_ name: String) -> Bool {
        name.count > 1 && name.hasPrefix("v") && name.dropFirst().allSatisfy(\.isASCII) && name.dropFirst().allSatisfy(\.isNumber)
    }

    /// Versioned store directories beside the active one. Symbolic links and
    /// anything not named `v<number>` are never returned.
    static func otherStores(besides active: URL, fileManager: FileManager = .default) throws -> [URL] {
        try versionStores(besides: active, fileManager: fileManager).filter { store in
            // A pnpm global virtual store lives at <store>/links. Its packages
            // may still be symlinked by projects using another pnpm version.
            // Preserve it even if unused: we cannot prove external references.
            do {
                _ = try fileManager.attributesOfItem(atPath: store.appendingPathComponent("links").path)
                return false
            } catch where (error as? CocoaError)?.code == .fileReadNoSuchFile { return true }
        }
    }

    static func versionStores(besides active: URL, fileManager: FileManager = .default) throws -> [URL] {
        let active = active.standardizedFileURL
        guard isVersionDirectoryName(active.lastPathComponent) else { return [] }
        let root = active.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries: [URL]
        do { entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) }
        catch where (error as? CocoaError)?.code == .fileReadNoSuchFile { return [] }
        return try entries.filter { entry in
            guard isVersionDirectoryName(entry.lastPathComponent), entry.lastPathComponent != active.lastPathComponent else { return false }
            let values = try entry.resourceValues(forKeys: Set(keys))
            return values.isDirectory == true && values.isSymbolicLink != true
        }.map { root.appendingPathComponent($0.lastPathComponent, isDirectory: true).standardizedFileURL }
            .sorted { $0.path < $1.path }
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
