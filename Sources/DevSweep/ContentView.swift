import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmation: CleanupConfirmation?
    @State private var showRoots = false
    @State private var expandedWorkspaceIDs = Set<String>()
    @State private var collapsedRepositoryIDs = Set<String>()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        summary
                        if isInitialScan {
                            loadingState
                        } else {
                            syncBanner
                            dockerCard
                            worktreesSection
                            settingsSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                footer
            }

            if let confirmation {
                confirmationOverlay(confirmation)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: 460, height: 660)
        .background(.ultraThinMaterial)
        .task { if model.workspaces.isEmpty { model.scan() } }
        .animation(.easeInOut(duration: 0.14), value: confirmation)
    }

    private func confirmationOverlay(_ kind: CleanupConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    Image(systemName: kind == .docker ? "shippingbox.fill" : "trash.fill")
                        .font(.title2).foregroundStyle(kind == .docker ? .blue : .red)
                    Text(kind == .docker ? "Remove unused Docker images?" : "Move selected folders to Trash?")
                        .font(.headline)
                }
                Text(kind == .docker
                     ? "Docker image pruning is permanent. All containers and volumes remain untouched."
                     : "Only the selected generated folders will move to macOS Trash. Project files and workspace roots are excluded.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    Button {
                        confirmation = nil
                        if kind == .docker { model.pruneDockerImages() }
                        else { model.cleanSelected() }
                    } label: {
                        Text(kind == .docker
                             ? "Prune unused images"
                             : "Move \(model.selectedCandidates.count) folders · \(ByteFormatting.string(model.selectedBytes)) to Trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)

                    Button("Cancel") { confirmation = nil }
                        .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                }
            }
            .padding(20).frame(width: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.6), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        }
        .onExitCommand { confirmation = nil }
    }

    private var syncBanner: some View {
        HStack(spacing: 9) {
            if model.isScanning {
                ProgressView().controlSize(.mini).tint(.accentColor)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if model.isScanning {
                Text("Refreshing results").fontWeight(.medium)
                if let lastSyncedAt = model.lastSyncedAt {
                    Text("· Last synced").foregroundStyle(.secondary)
                    Text(lastSyncedAt, style: .relative).foregroundStyle(.secondary)
                }
            } else if let lastSyncedAt = model.lastSyncedAt {
                Text("Last synced").fontWeight(.medium)
                Text(lastSyncedAt, style: .relative).foregroundStyle(.secondary)
            } else {
                Text("Results loaded from cache").fontWeight(.medium)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background((model.isScanning ? Color.accentColor : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .padding(.bottom, 12)
        .help(model.lastSyncedAt.map { "Last successful scan: \($0.formatted(date: .long, time: .standard))" } ?? "Waiting for the first completed scan")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.linearGradient(colors: [.cyan, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles").font(.title2.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                Text("DevSweep").font(.title2.weight(.bold))
                Spacer()
                Button { model.scan() } label: {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(model.isScanning || model.isCleaning)
                .help("Scan again")
            }

            if isInitialScan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scanning developer storage")
                        .font(.title3.weight(.semibold))
                    Text("Finding worktrees and measuring generated folders")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ByteFormatting.string(model.totalReclaimableBytes))
                            .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("reclaimable").font(.headline).foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.linearGradient(colors: [.cyan, .mint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * storageFreeFraction)
                        }
                    }
                    .frame(height: 7)
                    HStack {
                        Text(freeSpaceText).foregroundStyle(.secondary)
                        Spacer()
                        if let capacity = model.diskCapacity(), let free = model.freeDiskSpace() {
                            Text("\(ByteFormatting.string(max(0, capacity - free))) used")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.top, 16).padding(.bottom, 18)
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12))
                ProgressView().controlSize(.regular)
            }
            .frame(width: 52, height: 52)

            VStack(spacing: 5) {
                Text("Looking for reclaimable space…").font(.headline)
                Text("DevSweep is checking Git worktrees, generated dependencies, build output, and Docker images.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
            }

            VStack(spacing: 9) {
                LoadingRow(width: 0.78)
                LoadingRow(width: 0.58)
                LoadingRow(width: 0.69)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning worktrees and generated folders")
    }

    private var dockerCard: some View {
        Panel {
            HStack(spacing: 13) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.blue).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Docker images").font(.headline)
                    switch model.dockerState {
                    case .checking: Text("Checking Docker…").foregroundStyle(.secondary)
                    case let .unavailable(message): Text(message).foregroundStyle(.secondary)
                    case let .available(bytes, detail):
                        Text(bytes > 0 ? "\(ByteFormatting.string(bytes)) reclaimable" : detail).foregroundStyle(.secondary)
                    }
                    Text("Preserves all containers and volumes").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if case let .available(bytes, _) = model.dockerState, bytes > 0 {
                    Button("Clean") { confirmation = .docker }.disabled(model.isCleaning)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isScanning {
                scanProgress
            }
            if !model.workspaces.isEmpty {
                HStack(spacing: 10) {
                    Text("WORKTREES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(model.workspaces.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Deselect all") { model.deselectAll() }.disabled(model.selectedCandidateIDs.isEmpty)
                    Button("Select all") { model.selectAll() }.disabled(model.selectedCandidateIDs.count == model.candidates.count)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
            }

            if model.workspaces.isEmpty {
                Panel {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.green.opacity(0.12))
                            Image(systemName: "checkmark").font(.title3.weight(.bold)).foregroundStyle(.green)
                        }.frame(width: 44, height: 44)
                        VStack(spacing: 4) {
                            Text("Nothing to clean right now").font(.headline)
                            Text("No generated dependency or build folders were found in your scanned projects.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        HStack(spacing: 12) {
                            Button("Scan again") { model.scan() }
                            Button("Add project folder") { model.addSearchRoot() }.buttonStyle(.borderedProminent)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 18)
                }
            } else {
                ForEach(model.repositoryGroups) { repository in repositorySection(repository) }
            }
        }
    }

    private var scanProgress: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scanning worktrees…").font(.caption.weight(.semibold))
                if model.discoveredWorkspaceCount > 0 {
                    Text("\(model.scannedWorkspaceCount) of \(model.discoveredWorkspaceCount) checked")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Discovering Git repositories").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func repositorySection(_ repository: RepositoryGroup) -> some View {
        let isCollapsed = collapsedRepositoryIDs.contains(repository.id)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isCollapsed { collapsedRepositoryIDs.remove(repository.id) }
                else { collapsedRepositoryIDs.insert(repository.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repository.name).font(.headline).lineLimit(1)
                        Text("\(repository.workspaces.count) worktree\(repository.workspaces.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteFormatting.string(repository.reclaimableBytes))
                        .font(.callout.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(repository.workspaces) { workspace in workspaceCard(workspace) }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isCollapsed)
    }

    private func workspaceCard(_ workspace: Workspace) -> some View {
        let selectedCount = model.selectedCount(in: workspace)
        let state: SelectionState = selectedCount == 0 ? .off : (selectedCount == workspace.candidates.count ? .on : .mixed)
        let expanded = expandedWorkspaceIDs.contains(workspace.id)

        return Panel(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SelectionCheckbox(state: state) { model.toggleWorkspaceSelection(workspace) }
                    Button { toggleExpansion(workspace) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(workspace.name).font(.headline).lineLimit(1)
                                    Text(workspace.branch).font(.caption)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule()).lineLimit(1)
                                }
                                Text(workspace.url.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormatting.string(workspace.reclaimableBytes))
                                .font(.callout.weight(.semibold).monospacedDigit())
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(13)

                if expanded {
                    VStack(spacing: 0) {
                        ForEach(workspace.candidates) { candidate in
                            Divider().padding(.leading, 48)
                            HStack(spacing: 10) {
                                SelectionCheckbox(state: model.selectedCandidateIDs.contains(candidate.id) ? .on : .off) {
                                    if model.selectedCandidateIDs.contains(candidate.id) { model.selectedCandidateIDs.remove(candidate.id) }
                                    else { model.selectedCandidateIDs.insert(candidate.id) }
                                }
                                Image(systemName: candidate.kind.symbolName).foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.url.lastPathComponent).font(.callout.weight(.medium))
                                    Text(relativeParent(candidate, workspace: workspace)).font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormatting.string(candidate.allocatedBytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 9)
                        }
                    }.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: expanded)
    }

    private var settingsSection: some View {
        VStack(spacing: 8) {
            DisclosureGroup(isExpanded: $showRoots) {
                VStack(spacing: 8) {
                    ForEach(model.searchRoots, id: \.path) { root in
                        HStack {
                            Text(root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeSearchRoot(root) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    Button { model.addSearchRoot() } label: { Label("Add project folder", systemImage: "plus") }
                        .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 8)
            } label: {
                Label("Scanned folders", systemImage: "folder.badge.gearshape")
            }
            Label("Generated folders move to Trash. Project roots, Git data, Docker volumes, and application caches are excluded.", systemImage: "lock.shield.fill")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 18)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let message = model.lastMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 12) {
                Label(freeSpaceText, systemImage: "internaldrive").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { confirmation = .folders } label: {
                    if isInitialScan {
                        HStack { ProgressView().controlSize(.small); Text("Scanning…") }.frame(minWidth: 170)
                    } else if model.isCleaning { ProgressView().controlSize(.small).frame(minWidth: 170) }
                    else { Label("Move to Trash · \(ByteFormatting.string(model.selectedBytes))", systemImage: "trash") }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.selectedCandidates.isEmpty || model.isCleaning || model.isScanning)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var freeSpaceText: String {
        model.freeDiskSpace().map { "\(ByteFormatting.string($0)) free" } ?? "Disk unavailable"
    }

    private var isInitialScan: Bool { model.isScanning && model.workspaces.isEmpty }

    private var storageFreeFraction: Double {
        guard let free = model.freeDiskSpace(), let capacity = model.diskCapacity(), capacity > 0 else { return 0 }
        return min(1, max(0.02, Double(free) / Double(capacity)))
    }

    private func toggleExpansion(_ workspace: Workspace) {
        if expandedWorkspaceIDs.contains(workspace.id) { expandedWorkspaceIDs.remove(workspace.id) }
        else { expandedWorkspaceIDs.insert(workspace.id) }
    }

    private func relativeParent(_ candidate: CleanupCandidate, workspace: Workspace) -> String {
        let parent = candidate.url.deletingLastPathComponent().path
        if parent == workspace.url.path { return "Project" }
        return parent.replacingOccurrences(of: workspace.url.path + "/", with: "Project/")
    }
}

private enum CleanupConfirmation: Equatable { case folders, docker }

private struct LoadingRow: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 220 * width, minHeight: 11, maxHeight: 11)
            Spacer()
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 48, height: 11)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.quinary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .redacted(reason: .placeholder)
    }
}

private enum SelectionState { case off, mixed, on }

private struct SelectionCheckbox: View {
    let state: SelectionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .off ? Color.clear : Color.accentColor)
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(state == .off ? Color.secondary : Color.clear, lineWidth: 1.2) }
                if state == .on { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                if state == .mixed { Image(systemName: "minus").font(.caption2.weight(.bold)).foregroundStyle(.white) }
            }.frame(width: 18, height: 18)
        }.buttonStyle(.plain)
    }
}

private struct Panel<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 13, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content.padding(padding)
            .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 0.5) }
    }
}
