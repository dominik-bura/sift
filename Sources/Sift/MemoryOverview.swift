import AppKit
import Darwin
import SwiftUI

struct ProcessMemory: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let bytes: Int64
}

struct MemoryService: Sendable {
    func processes() -> [ProcessMemory] {
        let result = SecureCommandRunner().run(URL(fileURLWithPath: "/bin/ps"),
                                               arguments: ["-axo", "pid=,ppid=,rss="], timeout: 10)
        return result.exitCode == 0 ? Self.parse(result.output) : []
    }
    static func parse(_ output: String) -> [ProcessMemory] {
        output.split(separator: "\n").compactMap { line in
            let values = line.split(whereSeparator: \.isWhitespace)
            guard values.count == 3, let pid = Int32(values[0]), let parent = Int32(values[1]),
                  let kb = Int64(values[2]), kb >= 0, kb <= Int64.max / 1024 else { return nil }
            return ProcessMemory(pid: pid, parent: parent, bytes: kb * 1024)
        }
    }
    static func groupedBytes(root: Int32, processes: [ProcessMemory]) -> Int64 {
        let children = Dictionary(grouping: processes, by: \.parent)
        var pending = [root], visited = Set<Int32>(), total: Int64 = 0
        let byPID = Dictionary(processes.map { ($0.pid, $0.bytes) }, uniquingKeysWith: max)
        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else { continue }
            total += byPID[pid] ?? 0
            pending += (children[pid] ?? []).map(\.pid)
        }
        return total
    }
    static func swapBytes() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(usage.xsu_used)
    }
}

struct RunningAppMemory: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let bundlePath: String
    let bytes: Int64
}

@MainActor final class MemoryOverviewModel: ObservableObject {
    @Published private(set) var apps: [RunningAppMemory] = []
    @Published private(set) var swapBytes: Int64?
    @Published private(set) var refreshing = false
    @Published var message: String?
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let service = MemoryService()
            let snapshot = await Task.detached(priority: .utility) { (service.processes(), MemoryService.swapBytes()) }.value
            swapBytes = snapshot.1
            apps = NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let bundle = app.bundleURL,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return RunningAppMemory(pid: app.processIdentifier, name: app.localizedName ?? bundle.lastPathComponent,
                                        bundlePath: bundle.path,
                                        bytes: MemoryService.groupedBytes(root: app.processIdentifier, processes: snapshot.0))
            }.sorted { $0.bytes > $1.bytes }
            if snapshot.0.isEmpty { message = "Process memory could not be read." }
            refreshing = false
        }
    }
    func quit(_ app: RunningAppMemory) {
        guard let running = NSRunningApplication(processIdentifier: app.pid), running.bundleURL?.path == app.bundlePath else {
            message = "The app is no longer running."; refresh(); return
        }
        message = running.terminate() ? "Asked \(app.name) to quit. It may prompt you to save work." : "\(app.name) did not accept the quit request."
        Task { try? await Task.sleep(for: .seconds(2)); refresh() }
    }
}

struct MemoryOverviewView: View {
    @ObservedObject var memory: MemoryOverviewModel
    @State private var appToQuit: RunningAppMemory?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MEMORY & SWAP").font(.caption.weight(.semibold))
                Spacer()
                Button { memory.refresh() } label: {
                    if memory.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).disabled(memory.refreshing).help("Refresh memory usage")
            }
            HStack {
                Label("System swap", systemImage: "memorychip")
                Spacer()
                Text(memory.swapBytes.map(ByteFormatting.string) ?? "Unavailable").monospacedDigit()
            }.padding(13).siftStorageSurface()
            Text("Swap is RAM offloaded to disk and managed by macOS. Closing apps may relieve memory pressure; saved files and caches remain.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("RUNNING APPS · RESIDENT RAM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(memory.apps) { app in
                    HStack {
                        Text(app.name).font(.callout).lineLimit(1)
                        Spacer()
                        Text(ByteFormatting.string(app.bytes)).font(.caption.monospacedDigit())
                        Button("Quit") { appToQuit = app }.controlSize(.small)
                    }.padding(12)
                    if app.id != memory.apps.last?.id { Divider().padding(.horizontal, 12) }
                }
            }.siftStorageSurface()
            Text("Includes each app's child processes. Shared RAM can be counted more than once. Swap cannot be reliably attributed to individual apps.")
                .font(.caption2).foregroundStyle(.secondary)
            if let message = memory.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { memory.refresh() }
            .alert("Quit \(appToQuit?.name ?? "app")?", isPresented: Binding(get: { appToQuit != nil }, set: { if !$0 { appToQuit = nil } })) {
                Button("Quit") { if let appToQuit { memory.quit(appToQuit) }; appToQuit = nil }
                Button("Cancel", role: .cancel) { appToQuit = nil }
            } message: { Text("The app may ask you to save unsaved work. Quitting does not delete its stored files or guarantee an immediate swap reduction.") }
    }
}
