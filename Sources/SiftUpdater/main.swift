import Foundation
import Darwin

enum UpdaterFailure: Error { case invalidArguments, invalidBundle, timeout }

func waitForExit(pid: pid_t, timeout: TimeInterval = 30) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while kill(pid, 0) == 0 {
        guard Date() < deadline else { throw UpdaterFailure.timeout }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func validatedBundle(_ rawPath: String) throws -> URL {
    let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
    guard url.lastPathComponent == "Sift.app",
          !url.path.contains("\n"), !url.path.contains("\r"),
          (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
          let bundle = Bundle(url: url),
          bundle.bundleIdentifier == "com.dominikhait.sift" else {
        throw UpdaterFailure.invalidBundle
    }
    return url
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, let parentPID = pid_t(arguments[3]), parentPID > 1 else {
        throw UpdaterFailure.invalidArguments
    }
    let current = try validatedBundle(arguments[1])
    let staged = try validatedBundle(arguments[2])
    let fileManager = FileManager.default
    let parent = current.deletingLastPathComponent()
    guard fileManager.isWritableFile(atPath: parent.path) else { throw UpdaterFailure.invalidBundle }

    try waitForExit(pid: parentPID)
    let backup = parent.appendingPathComponent(".Sift-previous-\(UUID().uuidString).app", isDirectory: true)
    try fileManager.moveItem(at: current, to: backup)
    do {
        try fileManager.moveItem(at: staged, to: current)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [current.path]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else { throw UpdaterFailure.invalidBundle }
        try? fileManager.removeItem(at: backup)
        try? fileManager.removeItem(at: staged.deletingLastPathComponent())
    } catch {
        try? fileManager.removeItem(at: current)
        try? fileManager.moveItem(at: backup, to: current)
        let rollbackOpener = Process()
        rollbackOpener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        rollbackOpener.arguments = [current.path]
        try? rollbackOpener.run()
        throw error
    }
} catch {
    FileHandle.standardError.write(Data("Sift update failed: \(error)\n".utf8))
    exit(1)
}
