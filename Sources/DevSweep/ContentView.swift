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
                    VStack(spacing: 0) {
                        summary
                        if isInitialScan {
                            loadingState
                        } else {
                            dockerCard
                            globalCachesSection
                            worktreesSection
                            settingsSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                footer
            }

            if let confirmation {
                confirmationOverlay(confirmation)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: 460, height: 660)
        .background(.ultraThinMaterial)
        .tint(DevSweepTheme.accent)
        .task { if model.workspaces.isEmpty { model.scan() } }
        .animation(.easeInOut(duration: 0.14), value: confirmation)
    }

    private func confirmationOverlay(_ kind: CleanupConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbolName)
                        .font(.title2).foregroundStyle(kind.isUpdate ? DevSweepTheme.accent : (kind == .docker ? .blue : .red))
                    Text(kind.title(model: model))
                        .font(.headline)
                }
                Text(kind.message)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    Button {
                        confirmation = nil
                        switch kind {
                        case .docker: model.pruneDockerImages()
                        case .folders: model.cleanSelected()
                        case let .global(id):
                            if let cache = model.globalCaches.first(where: { $0.id == id }) { model.cleanGlobalCache(cache) }
                        case let .update(release): model.installUpdate(release)
                        }
                    } label: {
                        Text(kind.actionTitle(model: model))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(kind.isUpdate ? DevSweepTheme.accent : .red)
                    .controlSize(.large)

                    Button("Cancel") { confirmation = nil }
                        .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                }
            }
            .padding(20).frame(width: 330)
            .devSweepGlassSurface(cornerRadius: 18, interactive: false)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        }
        .onExitCommand { confirmation = nil }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DevSweepTheme.brandGradient)
                    Image(systemName: "paintbrush.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Text("DevSweep").font(.title2.weight(.bold))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Button { model.scan() } label: {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("Scan again")

                    if let lastSyncedAt = model.lastSyncedAt {
                        Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Not synced yet")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
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
                            Capsule().fill(DevSweepTheme.brandGradient)
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
                switch model.dockerState {
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                        .tint(DevSweepTheme.accent)
                        .accessibilityLabel("Checking Docker")
                case let .available(bytes, _) where bytes > 0:
                    Button("Clean") { confirmation = .docker }.disabled(model.isCleaning)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var globalCachesSection: some View {
        Group {
            if !model.globalCaches.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("GLOBAL CACHES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("Permanent cleanup").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Panel(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.globalCaches.enumerated()), id: \.element.id) { index, cache in
                                if index > 0 { Divider().padding(.leading, 52) }
                                HStack(spacing: 11) {
                                    Image(systemName: cache.symbolName).foregroundStyle(.orange).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cache.name).font(.callout.weight(.semibold))
                                        Text(cache.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        if case let .available(_, path) = cache.state {
                                            Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    if cache.bytes > 0 {
                                        Text(ByteFormatting.string(cache.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Button("Clean") { confirmation = .global(cache.id) }
                                            .disabled(model.isCleaning)
                                    } else {
                                        Text("Empty").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 13).padding(.vertical, 10)
                            }
                        }
                    }
                    Text("Package-manager commands remove caches permanently; they never touch installed tools or project files.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 20)
            }
        }
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
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isCollapsed { collapsedRepositoryIDs.remove(repository.id) }
                    else { collapsedRepositoryIDs.insert(repository.id) }
                }
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
                VStack(spacing: 8) {
                    ForEach(repository.workspaces) { workspace in workspaceCard(workspace) }
                }
                .transition(.opacity)
            }
        }
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
                        ForEach(Array(workspace.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index == 0 {
                                Divider()
                            } else {
                                Divider().padding(.horizontal, 13)
                            }
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
                    }
                    .transition(.opacity)
                }
            }
        }
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
            Label("Generated worktree folders move to Trash. Global cache commands are separate, permanent, and require confirmation.", systemImage: "lock.shield.fill")
                .font(.caption2).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 3)
            updateRow
        }
        .padding(.top, 18)
    }

    private var updateRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.versionLabel).font(.caption.weight(.medium))
                switch model.updateState {
                case .unavailable:
                    Text("Updates are enabled in GitHub release builds")
                case .idle:
                    Text("Ready to check GitHub for updates")
                case .checking:
                    Text("Checking GitHub…")
                case .upToDate:
                    Text("DevSweep is up to date")
                case let .available(release):
                    Text("Version \(release.version) is available")
                case let .downloading(release):
                    Text("Downloading and verifying \(release.version)…")
                case let .failed(message):
                    Text(message)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .lineLimit(2)
            Spacer(minLength: 6)
            switch model.updateState {
            case .idle, .upToDate, .failed:
                Button("Check") { Task { await model.checkForUpdates() } }
                    .controlSize(.small)
            case let .available(release):
                VStack(alignment: .trailing, spacing: 3) {
                    Button("Update") { confirmation = .update(release) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Release notes") { model.openRelease(release) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
            case .checking, .downloading:
                ProgressView().controlSize(.small)
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
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
        .devSweepGlassFooter()
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
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedWorkspaceIDs.contains(workspace.id) { expandedWorkspaceIDs.remove(workspace.id) }
            else { expandedWorkspaceIDs.insert(workspace.id) }
        }
    }

    private func relativeParent(_ candidate: CleanupCandidate, workspace: Workspace) -> String {
        let parent = candidate.url.deletingLastPathComponent().path
        if parent == workspace.url.path { return "Project" }
        return parent.replacingOccurrences(of: workspace.url.path + "/", with: "Project/")
    }
}

private enum CleanupConfirmation: Equatable {
    case folders
    case docker
    case global(String)
    case update(UpdateRelease)

    var isUpdate: Bool {
        if case .update = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .folders: return "trash.fill"
        case .docker: return "shippingbox.fill"
        case .global: return "externaldrive.badge.xmark"
        case .update: return "arrow.down.app.fill"
        }
    }

    var message: String {
        switch self {
        case .folders:
            return "Only the selected generated folders will move to macOS Trash. Project files and workspace roots are excluded."
        case .docker:
            return "Docker image pruning is permanent and is allowed only for a local Unix-socket Docker Engine. All containers and volumes remain untouched."
        case .global:
            return "This package manager performs permanent cache cleanup. Cached artifacts may need to be downloaded or rebuilt later; installed tools and project files remain untouched."
        case .update:
            return "DevSweep will download the release from GitHub, verify its checksum, identity, version, and code signature, then replace and relaunch this app."
        }
    }

    @MainActor func title(model: AppModel) -> String {
        switch self {
        case .folders: return "Move selected folders to Trash?"
        case .docker: return "Remove unused Docker images?"
        case let .global(id): return "Clean \(model.globalCaches.first(where: { $0.id == id })?.name ?? "global cache")?"
        case let .update(release): return "Install DevSweep \(release.version)?"
        }
    }

    @MainActor func actionTitle(model: AppModel) -> String {
        switch self {
        case .folders: return "Move \(model.selectedCandidates.count) folders · \(ByteFormatting.string(model.selectedBytes)) to Trash"
        case .docker: return "Prune unused images"
        case .global: return "Clean cache permanently"
        case .update: return "Download and install update"
        }
    }
}

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
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .off ? Color.clear : DevSweepTheme.accent)
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(state == .off ? Color.secondary : Color.clear, lineWidth: 1.2) }
                if state == .on { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                if state == .mixed { Image(systemName: "minus").font(.caption2.weight(.bold)).foregroundStyle(.white) }
            }.frame(width: 18, height: 18)
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement()
        .accessibilityLabel(state == .off ? "Select" : "Deselect")
        .accessibilityAddTraits(.isButton)
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
            .devSweepGlassSurface(cornerRadius: 13, interactive: true)
    }
}

private extension View {
    @ViewBuilder
    func devSweepGlassSurface(cornerRadius: CGFloat, interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            background(Color.primary.opacity(0.045), in: shape)
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.11), lineWidth: 0.5)
                }
        } else {
            background(
                .quinary.opacity(0.6),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    func devSweepGlassFooter() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

private enum DevSweepTheme {
    static let accent = Color(red: 0.96, green: 0.29, blue: 0.14)
    static let warmOrange = Color(red: 1.00, green: 0.49, blue: 0.12)
    static let brandGradient = LinearGradient(
        colors: [warmOrange, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
