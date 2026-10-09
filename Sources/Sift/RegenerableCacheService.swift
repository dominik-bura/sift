import AppKit
import Foundation

struct RegenerableCacheDefinition: Sendable {
    let id: String
    let name: String
    let relativePaths: [String]
    let appNames: [String]
    let detail: String
}

struct RegenerableCacheService: Sendable {
    static let definitions: [RegenerableCacheDefinition] = [
        .init(id: "xcode-build", name: "Xcode build data", relativePaths: ["Library/Developer/Xcode/DerivedData"], appNames: ["Xcode"], detail: "Rebuildable DerivedData only; archives and simulators are excluded"),
        .init(id: "dia-cache", name: "Dia caches", relativePaths: ["Library/Caches/Dia", "Library/Caches/company.thebrowser.dia"], appNames: ["Dia"], detail: "Browser cache only; profiles and browsing history are excluded"),
        .init(id: "codex-cache", name: "Codex app cache", relativePaths: ["Library/Caches/Codex"], appNames: ["Codex", "ChatGPT"], detail: "App cache only; conversations and worktrees are excluded"),
        .init(id: "spark-cache", name: "Spark cache", relativePaths: ["Library/Caches/com.readdle.SparkDesktop"], appNames: ["Spark", "Spark Desktop"], detail: "Regenerable cache only; mail app support data is excluded")
    ]
    private let home: URL
    private let runningAppNames: @Sendable () -> Set<String>
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         runningAppNames: @escaping @Sendable () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName)) }) {
        self.home = home.standardizedFileURL
        self.runningAppNames = runningAppNames
    }

    func inspectAll() -> [GlobalCache] { Self.definitions.compactMap(inspect) }
    func inspect(id: String) -> GlobalCache? { Self.definitions.first { $0.id == id }.flatMap(inspect) }
    private func inspect(_ definition: RegenerableCacheDefinition) -> GlobalCache? {
        let paths = definition.relativePaths.map { home.appendingPathComponent($0) }
        guard paths.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        guard paths.allSatisfy({ validated($0, definition: definition) }) else {
            return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: "app.badge", state: .failed("Cache path could not be verified"))
        }
        var bytes: Int64 = 0
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            let result = SecureCommandRunner().run(URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-sk", path.path], timeout: 120)
            guard result.exitCode == 0, let total = StorageOverviewService.parse(result, path: path.path).totalBytes else {
                return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail, symbolName: "app.badge",
                                   state: .failed("Could not measure cache; check permissions"))
            }
            bytes += total
        }
        return GlobalCache(id: definition.id, name: definition.name, detail: definition.detail,
                           symbolName: definition.id == "xcode-build" ? "hammer.fill" : "app.badge",
                           state: .available(bytes: bytes, path: paths.first(where: { FileManager.default.fileExists(atPath: $0.path) })!.path))
    }

    func clean(id: String) throws {
        guard let definition = Self.definitions.first(where: { $0.id == id }) else { throw GlobalCacheError.unavailable }
        let runningNames = runningAppNames()
        if let running = definition.appNames.first(where: { runningNames.contains($0) }) {
            throw GlobalCacheError.failed("Quit \(running) before clearing its cache. Use the Memory tab to request a normal quit.")
        }
        for relative in definition.relativePaths {
            let url = home.appendingPathComponent(relative)
            guard validated(url, definition: definition) else { throw GlobalCacheError.failed("Cache path could not be safely verified") }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Delete only immediate children of an exact approved cache directory.
            // Removing a symlink child removes the link, never its destination.
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children {
                guard validated(url, definition: definition), child.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path else {
                    throw GlobalCacheError.failed("Cache location changed during cleanup")
                }
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    func validated(_ url: URL, definition: RegenerableCacheDefinition) -> Bool {
        let expected = definition.relativePaths.map { home.appendingPathComponent($0).standardizedFileURL.path }
        guard expected.contains(url.standardizedFileURL.path) else { return false }
        // Reject redirected cache directories and every symlink ancestor below home.
        var ancestor = url.standardizedFileURL
        while ancestor.path != home.path {
            guard ancestor.path.hasPrefix(home.path + "/") else { return false }
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            ancestor.deleteLastPathComponent()
        }
        return true
    }
}
