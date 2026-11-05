import AppKit
import Darwin
import SwiftUI

enum MemoryFormatting {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .memory)
    }
}

struct ProcessMemory: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let bytes: Int64
}

struct SystemMemoryUsage: Equatable, Sendable {
    let usedBytes: Int64
    let totalBytes: Int64
    var availableBytes: Int64 { totalBytes - usedBytes }
    var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    static func calculate(_ statistics: vm_statistics64_data_t, pageSize: UInt64, physicalBytes: UInt64) -> Self? {
        guard pageSize > 0, let total = Int64(exactly: physicalBytes), total > 0 else { return nil }
        // Anonymous resident pages (excluding purgeable data), wired memory,
        // and the physical compressor footprint. File caches and disk swap
        // are not counted as RAM in use; do not sum per-app RSS here.
        let anonymous = UInt64(statistics.internal_page_count)
        let appPages = anonymous - min(anonymous, UInt64(statistics.purgeable_count))
        let pages = appPages + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        guard !overflow else { return nil }
        return Self(usedBytes: Int64(min(bytes, physicalBytes)), totalBytes: total)
    }
}

struct MemoryService: Sendable {
    static func systemUsage() -> SystemMemoryUsage? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return SystemMemoryUsage.calculate(statistics, pageSize: UInt64(vm_kernel_page_size),
                                           physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }
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
    @Published private(set) var systemUsage: SystemMemoryUsage?
    @Published private(set) var refreshing = false
    @Published var message: String?
    func refreshSystemUsage() { systemUsage = MemoryService.systemUsage() }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let service = MemoryService()
            let snapshot = await Task.detached(priority: .utility) { (service.processes(), MemoryService.swapBytes(), MemoryService.systemUsage()) }.value
            swapBytes = snapshot.1
            systemUsage = snapshot.2
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

struct MemorySummaryView: View {
    @ObservedObject var memory: MemoryOverviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(memory.systemUsage.map { MemoryFormatting.string($0.usedBytes) } ?? "—")
                    .font(.system(size: 27, weight: .semibold)).monospacedDigit().tracking(-0.6)
                Text("RAM in use").font(.callout).foregroundStyle(SiftChartStyle.secondaryText)
                Spacer()
            }
            if let usage = memory.systemUsage {
                Text("\(MemoryFormatting.string(usage.usedBytes)) used of \(MemoryFormatting.string(usage.totalBytes)) physical memory")
                    .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
                StorageBlockBar(fraction: usage.usedFraction, cells: 48).frame(height: 8)
                    .accessibilityElement().accessibilityLabel("RAM usage")
                    .accessibilityValue("\(Int((usage.usedFraction * 100).rounded())) percent")
            } else {
                Text("System memory usage unavailable").font(.caption).foregroundStyle(SiftChartStyle.mutedText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
        .help("System RAM: anonymous memory excluding purgeable pages, wired memory, and compressed memory. Excludes file caches and disk swap. Not a memory-pressure indicator.")
        .task {
            while !Task.isCancelled {
                memory.refreshSystemUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
                Text(memory.swapBytes.map(MemoryFormatting.string) ?? "Unavailable").monospacedDigit()
            }.padding(13).siftStorageSurface()
            Text("Swap is RAM offloaded to disk and managed by macOS. Closing apps may relieve memory pressure; saved files and caches remain.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("RUNNING APPS · RESIDENT RAM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(memory.apps) { app in
                    HStack {
                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(MemoryFormatting.string(app.bytes)).font(.caption.monospacedDigit())
                        Button("Quit") { appToQuit = app }.buttonStyle(SiftQuietButtonStyle())
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
