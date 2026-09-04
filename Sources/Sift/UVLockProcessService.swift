import Darwin
import Foundation

struct UVLockProcess: Equatable, Sendable {
    let pid: pid_t
    let command: String
}

struct UVLockProcessService: Sendable {
    private let runner = SecureCommandRunner()

    func holders() -> [UVLockProcess] {
        let lockPath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache/uv/.lock").path
        guard FileManager.default.fileExists(atPath: lockPath) else { return [] }

        let result = runner.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-Fpc", "--", lockPath],
            timeout: 5
        )
        // lsof exits with 1 when no process has the file open.
        guard result.exitCode == 0 else { return [] }
        return Self.parse(result.output)
    }

    func stopHolders() throws -> Int {
        let processes = holders()
        guard !processes.isEmpty else { return 0 }

        // Only signal processes that lsof identifies as `uv` and that currently
        // hold uv's exact cache lock. Never enumerate or terminate uv by name.
        for process in processes where process.command == "uv" {
            guard kill(process.pid, SIGTERM) == 0 || errno == ESRCH else {
                throw UVLockProcessError.couldNotStop(process.pid)
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if holders().isEmpty { return processes.count }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for process in holders() where process.command == "uv" {
            guard kill(process.pid, SIGKILL) == 0 || errno == ESRCH else {
                throw UVLockProcessError.couldNotStop(process.pid)
            }
        }
        return processes.count
    }

    static func parse(_ output: String) -> [UVLockProcess] {
        var processes: [UVLockProcess] = []
        var pid: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            if prefix == "p" {
                pid = pid_t(value)
            } else if prefix == "c", let pid, value == "uv" {
                processes.append(UVLockProcess(pid: pid, command: value))
            }
        }
        return Array(Dictionary(grouping: processes, by: \.pid).compactMap(\.value.first))
            .sorted { $0.pid < $1.pid }
    }
}

enum UVLockProcessError: LocalizedError {
    case couldNotStop(pid_t)

    var errorDescription: String? {
        switch self {
        case let .couldNotStop(pid): return "Could not stop uv process \(pid)"
        }
    }
}
