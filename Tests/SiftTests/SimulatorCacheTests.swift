import Foundation
import XCTest
@testable import Sift

final class SimulatorCacheTests: XCTestCase {
    private let availableID = "11111111-1111-1111-1111-111111111111"
    private let unavailableID = "22222222-2222-2222-2222-222222222222"

    private func listing(_ devices: String) -> String { "{\"devices\":{\"runtime\":[\(devices)]}}" }
    private func device(_ id: String, available: Bool) -> String { "{\"udid\":\"\(id)\",\"isAvailable\":\(available)}" }

    func testOnlyUnavailableDeviceDirectoriesAreMeasured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-simulators-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let available = root.appendingPathComponent(availableID)
        let unavailable = root.appendingPathComponent(unavailableID)
        for path in [available, unavailable] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 65_536).write(to: available.appendingPathComponent("keep"))
        try Data(repeating: 2, count: 8_192).write(to: unavailable.appendingPathComponent("measure"))
        let json = listing(device(availableID, available: true) + "," + device(unavailableID, available: false))
        let service = SimulatorCacheService(run: { executable, arguments, timeout in
            if executable.lastPathComponent == "xcrun" {
                XCTAssertEqual(arguments, ["simctl", "--set", root.path, "list", "--json", "devices"])
                return CommandResult(output: json, error: "", exitCode: 0, timedOut: false)
            }
            XCTAssertEqual(arguments, ["-s", "-k", unavailable.path])
            return SecureCommandRunner().run(executable, arguments: arguments, timeout: timeout)
        })
        let measured = try service.inspect(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), deviceRoot: root)
        let baseline = SecureCommandRunner().run(URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-s", "-k", unavailable.path])
        XCTAssertEqual(measured.bytes, try SimulatorCacheService.measuredBytes(baseline, expectedPaths: [unavailable.path]))
        XCTAssertEqual(measured.deviceCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: available.appendingPathComponent("keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unavailable.appendingPathComponent("measure").path))
    }

    func testAvailableOnlyListingIsZeroWithoutMeasuringWholeRoot() throws {
        let root = FileManager.default.temporaryDirectory
        let json = listing(device(availableID, available: true))
        let service = SimulatorCacheService(run: { executable, _, _ in
            XCTAssertEqual(executable.lastPathComponent, "xcrun")
            return CommandResult(output: json, error: "", exitCode: 0, timedOut: false)
        })
        let measured = try service.inspect(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), deviceRoot: root)
        XCTAssertEqual(measured.bytes, 0)
        XCTAssertEqual(measured.deviceCount, 0)
    }

    func testMalformedAvailabilityAndPathTraversalFailClosed() {
        for json in ["{}", listing("{\"udid\":\"\(unavailableID)\"}"), listing(device("../outside", available: false))] {
            XCTAssertThrowsError(try SimulatorCacheService.unavailableDirectories(json: Data(json.utf8), root: FileManager.default.temporaryDirectory))
        }
    }

    func testRedirectedDeviceDirectoryIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-simulator-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(availableID)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(unavailableID), withDestinationURL: target)
        XCTAssertThrowsError(try SimulatorCacheService.unavailableDirectories(json: Data(listing(device(unavailableID, available: false)).utf8), root: root))
    }

    func testIncompleteAndFailedSizeResultsAreNotReportedAsZero() {
        let path = "/devices/\(unavailableID)"
        for result in [CommandResult(output: "", error: "", exitCode: 0, timedOut: false),
                       CommandResult(output: "1\t\(path)\n", error: "Permission denied", exitCode: 1, timedOut: false),
                       CommandResult(output: "1\t\(path)\n", error: "", exitCode: -2, timedOut: true)] {
            XCTAssertThrowsError(try SimulatorCacheService.measuredBytes(result, expectedPaths: [path]))
        }
    }
}
