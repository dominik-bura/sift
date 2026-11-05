import Foundation

/// The size and cleanup command use the same CoreSimulator device set and
/// unavailable-device predicate. Never substitute the whole Devices folder.
struct SimulatorCacheService: Sendable {
    var run: @Sendable (URL, [String], TimeInterval) -> CommandResult = { executable, arguments, timeout in
        SecureCommandRunner().run(executable, arguments: arguments, timeout: timeout)
    }

    struct Measurement {
        let bytes: Int64
        let deviceCount: Int
    }

    func inspect(executable: URL, deviceRoot: URL) throws -> Measurement {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: deviceRoot.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw GlobalCacheError.failed("Simulator device storage is not a regular directory")
            }
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError {
                return Measurement(bytes: 0, deviceCount: 0)
            }
            throw GlobalCacheError.failed("Could not access simulator device storage")
        }
        let listing = run(executable, ["simctl", "--set", deviceRoot.path, "list", "--json", "devices"], 30)
        guard listing.exitCode == 0, !listing.timedOut else {
            throw GlobalCacheError.failed("Could not list unavailable simulators")
        }
        let paths = try Self.unavailableDirectories(json: Data(listing.output.utf8), root: deviceRoot)
        guard !paths.isEmpty else { return Measurement(bytes: 0, deviceCount: 0) }
        var total: Int64 = 0
        // Bound argv size and preserve du's hard-link deduplication within each
        // batch. Sizes remain attributed storage, not guaranteed freed space.
        for start in stride(from: 0, to: paths.count, by: 100) {
            let batch = Array(paths[start..<min(start + 100, paths.count)])
            let result = run(URL(fileURLWithPath: "/usr/bin/du"), ["-s", "-k"] + batch.map(\.path), 120)
            let bytes = try Self.measuredBytes(result, expectedPaths: Set(batch.map(\.path)))
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw GlobalCacheError.failed("Simulator size is out of range") }
            total = sum
        }
        return Measurement(bytes: total, deviceCount: paths.count)
    }

    static func unavailableDirectories(json: Data, root: URL) throws -> [URL] {
        struct Device: Decodable { let udid: String; let isAvailable: Bool }
        struct Listing: Decodable { let devices: [String: [Device]] }
        let listing: Listing
        do { listing = try JSONDecoder().decode(Listing.self, from: json) }
        catch { throw GlobalCacheError.failed("Could not read simulator availability") }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var paths: [String: URL] = [:]
        for device in listing.devices.values.flatMap({ $0 }) where !device.isAvailable {
            guard let uuid = UUID(uuidString: device.udid), uuid.uuidString.lowercased() == device.udid.lowercased() else {
                throw GlobalCacheError.failed("Invalid simulator device identifier")
            }
            let candidate = root.appendingPathComponent(device.udid, isDirectory: true).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent().path == canonicalRoot.path,
                  resolved.lastPathComponent.lowercased() == device.udid.lowercased() else {
                throw GlobalCacheError.failed("Simulator device path is redirected")
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue,
                      (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw GlobalCacheError.failed("Simulator device path is not a regular directory")
                }
                paths[resolved.path] = candidate
            }
        }
        return paths.values.sorted { $0.path < $1.path }
    }

    static func measuredBytes(_ result: CommandResult, expectedPaths: Set<String>) throws -> Int64 {
        guard result.exitCode == 0, !result.timedOut, result.error.isEmpty else {
            throw GlobalCacheError.failed("Could not measure unavailable simulators")
        }
        var measured: [String: Int64] = [:]
        for line in result.output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]),
                  kb >= 0, kb <= Int64.max / 1024 else {
                throw GlobalCacheError.failed("Incomplete simulator size results")
            }
            let path = String(line[line.index(after: tab)...])
            guard expectedPaths.contains(path), measured[path] == nil else {
                throw GlobalCacheError.failed("Incomplete simulator size results")
            }
            measured[path] = kb * 1024
        }
        guard Set(measured.keys) == expectedPaths else {
            throw GlobalCacheError.failed("Incomplete simulator size results")
        }
        var total: Int64 = 0
        for bytes in measured.values {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw GlobalCacheError.failed("Simulator size is out of range") }
            total = sum
        }
        return total
    }
}
