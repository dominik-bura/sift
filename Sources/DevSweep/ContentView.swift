import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCleanupConfirmation = false
    @State private var showDockerConfirmation = false
    @State private var showRoots = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440, height: 620)
        .task {
            if model.workspaces.isEmpty { model.scan() }
        }
        .confirmationDialog(
            "Permanently remove selected generated folders?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.selectedCandidates.count) folders · \(ByteFormatting.string(model.selectedBytes))", role: .destructive) {
                model.cleanSelected()
            }
        } message: {
            Text("Only the listed generated folders will be deleted. Project files and workspace roots are structurally excluded.")
        }
        .confirmationDialog(
            "Remove all unused Docker images?",
            isPresented: $showDockerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Prune unused images", role: .destructive) { model.pruneDockerImages() }
        } message: {
            Text("Running containers, stopped containers, volumes, and application data will not be removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.linearGradient(colors: [.mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("DevSweep").font(.title2.weight(.bold))
                if model.isScanning {
                    Text("Scanning developer storage…").foregroundStyle(.secondary)
                } else {
                    Text("\(ByteFormatting.string(model.totalReclaimableBytes)) ready to reclaim")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.scan() } label: {
                if model.isScanning { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(model.isScanning || model.isCleaning)
            .help("Scan again")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.workspaces.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Finding worktrees and measuring generated files")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    dockerCard
                    worktreesSection
                    rootsSection
                    safetyNote
                }
                .padding(14)
            }
        }
    }

    private var dockerCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docker images").font(.headline)
                    switch model.dockerState {
                    case .checking:
                        Text("Checking Docker…").foregroundStyle(.secondary)
                    case let .unavailable(message):
                        Text(message).foregroundStyle(.secondary).lineLimit(2)
                    case let .available(bytes, detail):
                        Text(bytes > 0 ? "\(ByteFormatting.string(bytes)) reclaimable" : detail)
                            .foregroundStyle(.secondary)
                    }
                    Text("Keeps containers and every volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case let .available(bytes, _) = model.dockerState, bytes > 0 {
                    Button("Clean") { showDockerConfirmation = true }
                        .disabled(model.isCleaning)
                }
            }
        }
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WORKTREES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.workspaces.count)").font(.caption).foregroundStyle(.tertiary)
            }

            if model.workspaces.isEmpty {
                Card {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                        Text("No generated folders found").font(.headline)
                        Text("Add another project folder below if something is missing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            } else {
                ForEach(model.workspaces) { workspace in
                    workspaceCard(workspace)
                }
            }
        }
    }

    private func workspaceCard(_ workspace: Workspace) -> some View {
        Card {
            DisclosureGroup {
                VStack(spacing: 0) {
                    ForEach(workspace.candidates) { candidate in
                        Divider().padding(.leading, 28)
                        Toggle(isOn: Binding(
                            get: { model.selectedCandidateIDs.contains(candidate.id) },
                            set: { isOn in
                                if isOn { model.selectedCandidateIDs.insert(candidate.id) }
                                else { model.selectedCandidateIDs.remove(candidate.id) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.kind.symbolName)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.url.lastPathComponent).font(.callout)
                                    Text(candidate.url.deletingLastPathComponent().path.replacingOccurrences(of: workspace.url.path, with: "Project"))
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormatting.string(candidate.allocatedBytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 7)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { workspace.candidates.allSatisfy { model.selectedCandidateIDs.contains($0.id) } },
                        set: { model.toggleWorkspace(workspace, selected: $0) }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(workspace.name).font(.headline).lineLimit(1)
                            Text(workspace.branch)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .lineLimit(1)
                        }
                        Text(workspace.url.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormatting.string(workspace.reclaimableBytes))
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
            }
        }
    }

    private var rootsSection: some View {
        Card {
            DisclosureGroup(isExpanded: $showRoots) {
                VStack(spacing: 8) {
                    ForEach(model.searchRoots, id: \.path) { root in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeSearchRoot(root) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { model.addSearchRoot() } label: {
                        Label("Add project folder", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
            } label: {
                Label("Scanned folders", systemImage: "folder.badge.gearshape")
            }
        }
    }

    private var safetyNote: some View {
        Label("Only allow-listed generated folders can be deleted. DevSweep never targets a project root, Git data, Docker volumes, or application caches.", systemImage: "lock.shield.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = model.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                if let free = model.freeDiskSpace() {
                    Label("\(ByteFormatting.string(free)) free", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                Button {
                    showCleanupConfirmation = true
                } label: {
                    if model.isCleaning { ProgressView().controlSize(.small) }
                    else { Text("Clean selected · \(ByteFormatting.string(model.selectedBytes))") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCandidates.isEmpty || model.isCleaning || model.isScanning)
            }
        }
        .padding(12)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .background(.quinary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 0.5)
            }
    }
}
