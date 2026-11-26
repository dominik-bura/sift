import AppKit
import Darwin
import Foundation

struct RegenerableCacheDefinition: Sendable {
    enum Removal: Sendable, Equatable {
        /// Empty the matched directory but keep the directory itself.
        case contents
        /// Remove the matched file or directory itself.
        case item
    }

    struct Target: Sendable, Equatable {
        /// Path relative to the home folder. A component may contain `*`
        /// wildcards; wildcards never match symbolic links.
        let pattern: String
        let removal: Removal

        static func contents(_ pattern: String) -> Target { .init(pattern: pattern, removal: .contents) }
        static func item(_ pattern: String) -> Target { .init(pattern: pattern, removal: .item) }
    }

    let id: String
    let name: String
    let targets: [Target]
    /// Display names first, then bundle identifiers. Any running match blocks cleanup.
    let appNames: [String]
    let detail: String
    var category: CacheCategory = .apps
    var symbol = "app.badge"
    var includedInCleanAll = true
    /// Matches changed more recently than this are neither measured nor removed.
    var minimumAge: TimeInterval? = nil
}

extension RegenerableCacheDefinition {
    init(id: String, name: String, relativePaths: [String], appNames: [String], detail: String,
         category: CacheCategory = .apps, symbol: String = "app.badge", includedInCleanAll: Bool = true) {
        self.init(id: id, name: name, targets: relativePaths.map(Target.contents), appNames: appNames, detail: detail,
                  category: category, symbol: symbol, includedInCleanAll: includedInCleanAll)
    }
}

struct RegenerableCacheService: Sendable {
    static let definitions: [RegenerableCacheDefinition] = [
        .init(id: "xcode-build", name: "Xcode build data", relativePaths: ["Library/Developer/Xcode/DerivedData"], appNames: ["Xcode"], detail: "Rebuildable DerivedData only; archives and simulators are excluded", category: .developerTools, symbol: "hammer.fill"),
        .init(id: "dia-cache", name: "Dia caches", relativePaths: ["Library/Caches/Dia", "Library/Caches/company.thebrowser.dia"], appNames: ["Dia"], detail: "Browser cache only; profiles and browsing history are excluded"),
        .init(id: "codex-cache", name: "Codex app cache", relativePaths: ["Library/Caches/Codex"], appNames: ["Codex", "ChatGPT"], detail: "App cache only; conversations and worktrees are excluded"),
        .init(id: "spark-cache", name: "Spark cache", relativePaths: ["Library/Caches/com.readdle.SparkDesktop"], appNames: ["Spark", "Spark Desktop"], detail: "Regenerable cache only; mail app support data is excluded")
    ] + appCaches + developerToolCaches + packageCaches

    private static let appCaches: [RegenerableCacheDefinition] = [
        electron("vscode-cache", "VS Code caches", folder: "Code", apps: ["Visual Studio Code", "Code", "com.microsoft.VSCode"], editor: true),
        electron("vscode-insiders-cache", "VS Code Insiders caches", folder: "Code - Insiders", apps: ["Visual Studio Code - Insiders", "Code - Insiders", "com.microsoft.VSCodeInsiders"], editor: true),
        electron("cursor-cache", "Cursor caches", folder: "Cursor", apps: ["Cursor", "com.todesktop.230313mzl4w4u92"], editor: true),
        electron("kiro-cache", "Kiro caches", folder: "Kiro", apps: ["Kiro", "dev.kiro.desktop"], editor: true),
        electron("antigravity-cache", "Antigravity caches", folder: "Antigravity", apps: ["Antigravity", "com.google.antigravity"], editor: true),
        electron("notion-cache", "Notion cache", folder: "Notion", apps: ["Notion", "notion.id"]),
        electron("miro-cache", "Miro cache", folder: "RealtimeBoard", apps: ["Miro", "com.electron.realtimeboard"]),
        electron("slack-cache", "Slack cache", folder: "Slack", apps: ["Slack", "com.tinyspeck.slackmacgap"]),
        electron("claude-cache", "Claude cache", folder: "Claude", apps: ["Claude", "com.anthropic.claudefordesktop"]),
        electron("capacities-cache", "Capacities cache", folder: "Capacities", apps: ["Capacities", "io.capacities.app"]),
        electron("postman-cache", "Postman cache", folder: "Postman", apps: ["Postman", "com.postmanlabs.mac"]),
        .init(id: "helium-cache", name: "Helium cache", relativePaths: ["Library/Caches/net.imput.helium"], appNames: ["Helium", "net.imput.helium"], detail: "Browser cache only; profiles and browsing history are excluded"),
        .init(id: "firefox-cache", name: "Firefox cache", relativePaths: ["Library/Caches/Firefox", "Library/Caches/Mozilla"], appNames: ["Firefox", "org.mozilla.firefox"], detail: "Page cache and update downloads only; profiles and browsing history are excluded"),
        .init(id: "spotify-cache", name: "Spotify cache", relativePaths: ["Library/Caches/com.spotify.client"], appNames: ["Spotify", "com.spotify.client"], detail: "Streaming cache only; offline downloads are excluded"),
        .init(id: "app-updaters", name: "App update downloads",
              targets: [.item("Library/Caches/*-updater"), .item("Library/Caches/*.ShipIt"), .item("Library/Application Support/Caches/*-updater")],
              appNames: [], detail: "Leftover update packages from app updaters; anything changed in the last 24 hours is kept",
              symbol: "arrow.down.app", minimumAge: 86_400)
    ]

    private static let developerToolCaches: [RegenerableCacheDefinition] = [
        .init(id: "docker-scout", name: "Docker Scout cache", relativePaths: [".docker/scout/sbom"], appNames: [], detail: "Cached image analysis results; rebuilt the next time Docker Scout analyses an image", category: .developerTools, symbol: "doc.text.magnifyingglass"),
        .init(id: "simulator-dyld", name: "Simulator dyld cache", relativePaths: ["Library/Developer/CoreSimulator/Caches/dyld"], appNames: ["Simulator", "com.apple.iphonesimulator"], detail: "Shared library caches for simulators; rebuilt when a simulator next boots", category: .developerTools, symbol: "iphone"),
        .init(id: "xcode-docs", name: "Xcode documentation cache", relativePaths: ["Library/Developer/Xcode/DocumentationCache"], appNames: ["Xcode", "com.apple.dt.Xcode"], detail: "Downloaded documentation only; Xcode fetches it again when you open the documentation", category: .developerTools, symbol: "book.closed"),
        .init(id: "virtualenv-wheels", name: "virtualenv seed wheels", relativePaths: ["Library/Application Support/virtualenv/wheel"], appNames: [], detail: "pip, setuptools, and wheel copies used to seed new environments; downloaded again when needed", category: .developerTools, symbol: "shippingbox"),
        .init(id: "node-gyp", name: "node-gyp headers", relativePaths: ["Library/Caches/node-gyp"], appNames: [], detail: "Node.js headers for native builds; the current version downloads again on the next build", category: .developerTools, symbol: "curlybraces"),
        .init(id: "playwright-browsers", name: "Playwright browsers", relativePaths: ["Library/Caches/ms-playwright"], appNames: [], detail: "Downloaded test browsers; run playwright install before the next test run", category: .developerTools, symbol: "theatermasks", includedInCleanAll: false),
        .init(id: "azcopy-logs", name: "AzCopy job logs", targets: [.item(".azcopy/*.log")], appNames: [], detail: "Job logs only; transfer plans needed to resume jobs and logs from the last 24 hours are kept", category: .developerTools, symbol: "doc.plaintext", minimumAge: 86_400)
    ]

    private static let packageCaches: [RegenerableCacheDefinition] = [
        .init(id: "npx-cache", name: "npx packages", relativePaths: [".npm/_npx"], appNames: [], detail: "Packages downloaded by npx; each one downloads again the next time it is run", category: .packages, symbol: "cube"),
        .init(id: "reflex-bun", name: "Reflex Bun cache", relativePaths: ["Library/Application Support/reflex/bun/install/cache"], appNames: [], detail: "Package archives downloaded by Reflex's bundled Bun; downloaded again on the next install", category: .packages, symbol: "hare"),
        .init(id: "pip-cache", name: "pip cache", relativePaths: ["Library/Caches/pip"], appNames: [], detail: "Downloaded and built wheels; installed packages are untouched", category: .packages, symbol: "shippingbox")
    ]

    private static let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    static func definition(id: String) -> RegenerableCacheDefinition? { definitionsByID[id] }

    /// Chromium-based apps keep these folders purely as caches. Sign-in state,
    /// Local Storage, IndexedDB, and Service Worker data live elsewhere and are never listed.
    private static func electron(_ id: String, _ name: String, folder: String, apps: [String], editor: Bool = false) -> RegenerableCacheDefinition {
        var directories = ["Cache", "Code Cache", "GPUCache", "Partitions/*/Cache", "Partitions/*/Code Cache", "Partitions/*/GPUCache"]
        if editor { directories += ["CachedData", "CachedExtensionVSIXs", "logs"] }
        return .init(id: id, name: name,
                     targets: directories.map { .contents("Library/Application Support/\(folder)/\($0)") },
                     appNames: apps,
                     detail: editor
                        ? "Caches, cached extension downloads, and logs only; settings, extensions, and workspace state are excluded"
                        : "Web cache only; sign-in, settings, and offline data are excluded")
    }

    private let home: URL
    private let runningAppNames: @Sendable () -> Set<String>
    private let now: @Sendable () -> Date
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         runningAppNames: @escaping @Sendable () -> Set<String> = {
             Set(NSWorkspace.shared.runningApplications.flatMap { [$0.localizedName, $0.bundleIdentifier].compactMap { $0 } })
         },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home.standardizedFileURL
        self.runningAppNames = runningAppNames
        self.now = now
    }

    func inspectAll() -> [GlobalCache] { Self.definitions.compactMap(inspect) }
    func inspect(id: String) -> GlobalCache? { Self.definition(id: id).flatMap(inspect) }
    func inspectAfterCleanup(id: String) -> GlobalCache? {
        guard let definition = Self.definition(id: id) else { return nil }
        return inspect(definition, reportEmpty: true)
    }

    /// True when at least one target currently exists, without measuring it.
    func hasMatches(_ definition: RegenerableCacheDefinition) -> Bool {
        do {
            for target in definition.targets where !(try matches(target)).isEmpty { return true }
            return false
        } catch {
            // Keep a placeholder so inspection can show the failure, not hide it.
            return true
        }
    }

    func inspect(_ definition: RegenerableCacheDefinition) -> GlobalCache? {
        inspect(definition, reportEmpty: false)
    }

    private func inspect(_ definition: RegenerableCacheDefinition, reportEmpty: Bool) -> GlobalCache? {
        let checkedAt = now()
        var total = DirectoryMeasurement()
        var firstPath: String?
        var retainedRecentItems = false
        do {
        for target in definition.targets {
            for url in try matches(target) {
                guard validated(url, target: target) else {
                    return cache(definition, state: .failed("Cache path could not be verified"))
                }
                guard let measurement = DirectoryMeasurement.measure(url, now: checkedAt) else {
                    return cache(definition, state: .failed("Could not measure cache; check permissions"))
                }
                if isTooRecent(measurement, definition: definition, now: checkedAt) {
                    retainedRecentItems = true
                    continue
                }
                total.add(measurement)
                if firstPath == nil { firstPath = url.path }
            }
        }
        } catch { return cache(definition, state: .failed("Could not enumerate cache; check permissions")) }
        guard let firstPath else {
            guard reportEmpty else { return nil }
            if retainedRecentItems {
                return cache(definition, state: .failed("Recent items were retained. No remaining stored-size measurement is available."))
            }
            // Zero is justified only after every target was enumerated and no
            // matches existed, not merely because normal inspection returned nil.
            let prefix = definition.targets.first?.pattern.split(separator: "/").prefix { !$0.contains("*") }.joined(separator: "/") ?? ""
            return cache(definition, state: .available(bytes: 0, path: home.appendingPathComponent(prefix).path))
        }
        // Age-filtered inventory changes are not proof of removed bytes. Keep
        // the post-cleanup size unknown if recent matches were left behind.
        if reportEmpty, retainedRecentItems {
            return cache(definition, state: .failed("Recent items were retained. No remaining stored-size measurement is available."))
        }
        return cache(definition, state: .available(bytes: total.bytes, path: firstPath),
                     lastChanged: total.bytes > 0 ? total.newestChange : nil)
    }

    func clean(id: String) throws {
        guard let definition = Self.definition(id: id) else { throw GlobalCacheError.unavailable }
        try clean(definition)
    }

    func clean(_ definition: RegenerableCacheDefinition) throws {
        let runningNames = runningAppNames()
        if let running = definition.appNames.first(where: { runningNames.contains($0) }) {
            // A bundle identifier is not a name a person recognises.
            let shown = running.contains(".") ? (definition.appNames.first ?? running) : running
            throw GlobalCacheError.failed("Quit \(shown) before clearing its cache. Use the Memory tab to request a normal quit.")
        }
        let checkedAt = now()
        for target in definition.targets {
            for url in try matches(target) {
                guard validated(url, target: target) else { throw GlobalCacheError.failed("Cache path could not be safely verified") }
                if definition.minimumAge != nil {
                    guard let measurement = DirectoryMeasurement.measure(url, now: checkedAt) else {
                        throw GlobalCacheError.failed("Could not check how recently the cache changed")
                    }
                    if isTooRecent(measurement, definition: definition, now: checkedAt) { continue }
                }
                switch target.removal {
                case .contents:
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    // Delete only immediate children of an exact approved cache directory.
                    // Removing a symlink child removes the link, never its destination.
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    for child in children {
                        guard validated(url, target: target), child.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path else {
                            throw GlobalCacheError.failed("Cache location changed during cleanup")
                        }
                        try FileManager.default.removeItem(at: child)
                    }
                case .item:
                    // Revalidate at the last possible moment to narrow path-swap races.
                    guard validated(url, target: target) else { throw GlobalCacheError.failed("Cache location changed during cleanup") }
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Existing paths matching a target. Wildcard components skip symbolic links;
    /// a literal component that is a link is returned and then fails validation.
    func matches(_ target: RegenerableCacheDefinition.Target) throws -> [URL] {
        var current = [home]
        for component in target.pattern.split(separator: "/").map(String.init) {
            var next: [URL] = []
            for base in current {
                guard component.contains("*") else {
                    next.append(base.appendingPathComponent(component))
                    continue
                }
                let values: URLResourceValues
                do { values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
                catch where (error as? CocoaError)?.code == .fileReadNoSuchFile { continue }
                if values.isSymbolicLink == true { throw GlobalCacheError.failed("Cache path could not be safely verified") }
                guard values.isDirectory == true else { continue }
                // A literal symlink ancestor must fail before enumerating it.
                var ancestor = base.standardizedFileURL
                while ancestor.path != home.path {
                    guard ancestor.path.hasPrefix(home.path + "/"),
                          try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw GlobalCacheError.failed("Cache path could not be safely verified")
                    }
                    ancestor.deleteLastPathComponent()
                }
                let children = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard Self.matches(pattern: component, name: child.lastPathComponent) else { continue }
                    guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    next.append(base.appendingPathComponent(child.lastPathComponent))
                }
            }
            current = next
        }
        return try current.filter { url in
            do { _ = try url.resourceValues(forKeys: [.isSymbolicLinkKey]); return true }
            catch where (error as? CocoaError)?.code == .fileReadNoSuchFile { return false }
        }
    }

    func validated(_ url: URL, target: RegenerableCacheDefinition.Target) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix(home.path + "/") else { return false }
        let components = standardized.path.dropFirst(home.path.count + 1).split(separator: "/").map(String.init)
        let pattern = target.pattern.split(separator: "/").map(String.init)
        guard components.count == pattern.count,
              zip(pattern, components).allSatisfy({ Self.matches(pattern: $0, name: $1) }) else { return false }
        // Reject redirected cache directories and every symlink ancestor below home.
        var ancestor = standardized
        while ancestor.path != home.path {
            guard ancestor.path.hasPrefix(home.path + "/") else { return false }
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            ancestor.deleteLastPathComponent()
        }
        return true
    }

    static func matches(pattern: String, name: String) -> Bool {
        pattern.contains("*") ? fnmatch(pattern, name, 0) == 0 : pattern == name
    }

    private func isTooRecent(_ measurement: DirectoryMeasurement, definition: RegenerableCacheDefinition, now: Date) -> Bool {
        guard let minimumAge = definition.minimumAge, let newest = measurement.newestChange else { return false }
        return now.timeIntervalSince(newest) < minimumAge
    }

    private func cache(_ definition: RegenerableCacheDefinition, state: GlobalCache.State, lastChanged: Date? = nil) -> GlobalCache {
        GlobalCache(id: definition.id, name: definition.name, detail: definition.detail,
                    symbolName: definition.symbol, state: state, lastChanged: lastChanged)
    }
}
