import SwiftUI

struct ContentView: View {
    var applicationIcon: NSImage? = nil
    private enum Section: String, CaseIterable { case cleanup = "Clean up", storage = "Storage", memory = "Memory" }
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmation: CleanupConfirmation?
    @State private var showSettings = false
    @State private var expandedWorkspaceIDs = Set<String>()
    @State private var collapsedRepositoryIDs = Set<String>()
    @State private var section: Section = .cleanup
    @State private var cleanupReviewTarget: StorageCleanupTarget?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                appHeader
                sectionPicker
                ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        summary
                        if section == .storage {
                            StorageExplorerView(overview: model.storageOverview, onReviewCleanup: reviewCleanup)
                            DisclosureGroup("Free-space history") {
                                DiskSpaceHistoryView(samples: model.diskHistory.samples).padding(.top, 8)
                            }.font(.caption).padding(.top, 20)
                        } else if section == .memory {
                            MemoryOverviewView(memory: model.memoryOverview)
                        } else {
                            if let target = cleanupReviewTarget {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Reviewing \(target.name)").font(.caption.weight(.semibold))
                                        Text(target.path).font(.caption2).lineLimit(2).truncationMode(.middle)
                                        Text(target.scopeDescription).font(.caption2)
                                        Text("Existing selections unchanged; nothing added automatically.").font(.caption2)
                                    }
                                    Spacer()
                                    Button { cleanupReviewTarget = nil } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel("Dismiss cleanup review")
                                }.foregroundStyle(SiftChartStyle.secondaryText).padding(12).siftStorageSurface().padding(.bottom, 14)
                            }
                            cleanupDashboard
                            if isInitialScan { scanProgress } else { worktreesSection }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                .onChange(of: cleanupReviewTarget) { _, target in
                    guard let target else { return }
                    // Let the destination's expanded category/workspace finish
                    // its layout before resolving the scroll anchor.
                    DispatchQueue.main.async {
                    switch target.kind {
                    case let .cache(id): scroll.scrollTo("cache-" + id, anchor: .center)
                    case let .workspace(id): scroll.scrollTo("workspace-" + id, anchor: .center)
                    }
                    }
                }
                }
                footer
            }

            if showSettings {
                settingsOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }

            if let confirmation {
                confirmationOverlay(confirmation)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: 460, height: 660)
        // Keep the native translucent window, with a darker content bed so
        // nested glass doesn't turn the whole panel into a silver-gray plate.
        .background(colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.08))
        .tint(SiftTheme.accent)
        .onAppear {
            model.refreshDiskSpace()
            model.scanIfStale()
        }
        .task {
            while !Task.isCancelled {
                model.refreshDiskSpace()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .animation(.easeInOut(duration: 0.14), value: confirmation)
        .animation(.easeInOut(duration: 0.14), value: showSettings)
        .onChange(of: section) { _, section in
            if section != .cleanup { cleanupReviewTarget = nil }
        }
    }

    private func confirmationOverlay(_ kind: CleanupConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbolName)
                        .font(.title2).foregroundStyle(kind.isUpdate ? SiftTheme.accent : (kind == .docker ? .blue : .red))
                    Text(kind.title(model: model))
                        .font(.headline)
                }
                Text(kind.message(model: model))
                    .font(.callout).foregroundStyle(SiftChartStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    Button {
                        confirmation = nil
                        switch kind {
                        case .docker: model.pruneDockerImages()
                        case .folders: model.cleanSelected()
                        case .allGlobals: model.cleanAllGlobalCaches()
                        case let .global(id):
                            if let cache = model.globalCaches.first(where: { $0.id == id }) { model.cleanGlobalCache(cache) }
                        case .stopUVProcesses: model.stopUVLockProcesses()
                        case let .update(release): model.installUpdate(release)
                        }
                    } label: {
                        Text(kind.actionTitle(model: model))
                            .frame(maxWidth: .infinity)
                    }
                    .siftConfirmationButton(tint: kind.isUpdate ? SiftTheme.accent : SiftTheme.destructiveAccent)
                    .controlSize(.large)

                    Button("Cancel") { confirmation = nil }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(SiftChartStyle.secondaryText)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20).frame(width: 330)
            .siftGlassSurface(cornerRadius: 18, interactive: false)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        }
        .onExitCommand { confirmation = nil }
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: applicationIcon ?? SiftAssets.applicationIcon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(width: 24, height: 24)
            Text(model.applicationName)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.25)
                .baselineOffset(0.5)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let lastSyncedAt = model.lastSyncedAt, section == .cleanup {
                    Text(
                        "Last synced \(lastSyncedAt.formatted(.dateTime.day().month(.abbreviated))) · \(lastSyncedAt.formatted(.dateTime.hour().minute()))"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(SiftChartStyle.mutedText)
                } else if section == .cleanup {
                    Text("Not synced yet")
                        .font(.caption2)
                        .foregroundStyle(SiftChartStyle.mutedText)
                }

                if section == .storage {
                    StorageExplorerRefreshButton(overview: model.storageOverview, disabled: model.isCleaning)
                } else {
                Button {
                    switch section {
                    case .cleanup: model.scan()
                    case .storage: break // The scoped Storage button observes its own model.
                    case .memory: model.memoryOverview.refresh()
                    }
                } label: {
                    if (section == .cleanup && model.isScanning) || (section == .memory && model.memoryOverview.refreshing) { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .regular))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(SiftChartStyle.secondaryText)
                .disabled(model.isCleaning || (section == .cleanup && model.isScanning) || (section == .memory && model.memoryOverview.refreshing))
                .help("Scan again")
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
    }

    private var sectionPicker: some View {
        FullWidthSegmentedControl(
            labels: Section.allCases.map(\.rawValue),
            selection: Binding(
                get: { Section.allCases.firstIndex(of: section) ?? 0 },
                set: { section = Section.allCases[$0] }
            )
        ).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.bottom, 14)
    }

    @ViewBuilder private var summary: some View {
        if section == .memory {
            MemorySummaryView(memory: model.memoryOverview)
        } else {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.freeDiskSpace().map(ByteFormatting.string) ?? "—")
                    .font(.system(size: 27, weight: .semibold)).monospacedDigit().tracking(-0.6)
                Text("free on this Mac").font(.callout).foregroundStyle(SiftChartStyle.secondaryText)
                Spacer()
                if model.freeDiskSpace() != nil && storageFreeFraction < 0.05 {
                    Text("Low space").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                }
            }
            if let capacity = model.diskCapacity(), let free = model.freeDiskSpace() {
                Text("\(ByteFormatting.string(max(0, capacity - free))) used of \(ByteFormatting.string(capacity))")
                    .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
                if section != .cleanup {
                    StorageBlockBar(fraction: 1 - storageFreeFraction, cells: 48).frame(height: 8)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
        }
    }


    private var cleanupDashboard: some View {
        CleanupDashboardView(
            inventory: CleanupInventory(worktreeBytes: model.workspaces.reduce(0) { $0 + $1.reclaimableBytes },
                                        caches: model.globalCaches, docker: model.dockerState, worktreesUnmeasured: isInitialScan),
            observation: model.lastCleanupObservation,
            cleaningID: model.cleaningGlobalCacheID, cleaningDocker: model.isCleaningDocker,
            isCleaning: model.isCleaning, eligibleCount: model.cleanableGlobalStorageCount,
            onClean: { confirmation = .global($0) },
            onDocker: { confirmation = .docker },
            onCleanEligible: { confirmation = .allGlobals },
            onStopUV: { confirmation = .stopUVProcesses($0) },
            reviewCacheID: reviewedCacheID
        )
    }

    private var reviewedCacheID: String? {
        if case let .cache(id) = cleanupReviewTarget?.kind { return id }
        return nil
    }

    private func reviewCleanup(_ target: StorageCleanupTarget) {
        if case let .workspace(id) = target.kind, let workspace = model.workspaces.first(where: { $0.id == id }) {
            collapsedRepositoryIDs.remove(workspace.repositoryID)
            expandedWorkspaceIDs.insert(workspace.id)
        }
        section = .cleanup
        cleanupReviewTarget = target
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isScanning && !model.isBackgroundRefreshing {
                scanProgress
            }
            if !model.workspaces.isEmpty {
                HStack(spacing: 10) {
                    Text("WORKTREES").font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
                    Text("\(model.workspaces.count)").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
                    Spacer()
                    Menu("Selection") {
                        Button("Select all folders") { model.selectAll() }
                            .disabled(model.selectedCandidateIDs.count == model.candidates.count)
                        Button("Deselect all folders") { model.deselectAll() }.disabled(model.selectedCandidateIDs.isEmpty)
                        Divider()
                        Button("Select folders older than 30 days") { model.selectOlderGeneratedFolders() }
                        Text("Age is modification date, not last use. Review before cleaning.")
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                Text("Generated dependencies and build output · select folders to remove")
                    .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
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
                                .font(.caption).foregroundStyle(SiftChartStyle.secondaryText).multilineTextAlignment(.center)
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
                        .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText).monospacedDigit()
                } else {
                    Text("Discovering Git repositories").font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .siftGlassSurface(cornerRadius: 10, interactive: false)
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
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(repository.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(repository.workspaces.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
                    }
                    Spacer()
                    Text(ByteFormatting.string(repository.reclaimableBytes))
                        .font(.callout.weight(.medium).monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Panel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(repository.workspaces.enumerated()), id: \.element.id) { index, workspace in
                            if index > 0 { Divider() }
                            workspaceRow(workspace).id("workspace-" + workspace.id)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let selectedCount = model.selectedCount(in: workspace)
        let state: SelectionState = selectedCount == 0 ? .off : (selectedCount == workspace.candidates.count ? .on : .mixed)
        let expanded = expandedWorkspaceIDs.contains(workspace.id)

        return VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SelectionCheckbox(state: state) { model.toggleWorkspaceSelection(workspace) }
                    Button { toggleExpansion(workspace) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(workspace.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(workspace.branch).font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .siftGlassCapsule().lineLimit(1)
                                }
                                Text(workspace.url.path).font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormatting.string(workspace.reclaimableBytes))
                                .font(.callout.weight(.medium).monospacedDigit())
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
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
                                Image(systemName: candidate.kind.symbolName).foregroundStyle(SiftChartStyle.secondaryText).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.url.lastPathComponent).font(.callout.weight(.medium))
                                    Text(relativeParent(candidate, workspace: workspace)).font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormatting.string(candidate.allocatedBytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 9)
                        }
                    }
                    .transition(.opacity)
                }
        }
    }

    private var settingsOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showSettings = false }
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(nsImage: SiftAssets.applicationIcon)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.applicationName) Settings").font(.headline)
                        Text(model.versionLabel).font(.caption2.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                    }
                    Spacer()
                    Button { showSettings = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(SiftChartStyle.secondaryText)
                    }
                    .buttonStyle(.plain).help("Close Settings")
                }
                .padding(16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("SOFTWARE UPDATE").font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
                            updateRow
                            Text("Sift checks for updates without sending telemetry or storage data.")
                                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("WORKTREE CLEANUP").font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Delete immediately").font(.caption.weight(.medium))
                                    Text("Skip macOS Trash for generated worktree folders").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                                }
                                Spacer(minLength: 12)
                                Toggle("Delete immediately", isOn: $model.deletesImmediately)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .tint(SiftTheme.accent)
                                    .accessibilityLabel("Delete generated folders immediately")
                            }
                            if model.deletesImmediately {
                                Label("Permanent deletion cannot be undone. Workspace roots, source files, and .git remain protected.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("SCANNED FOLDERS").font(.caption.weight(.semibold)).foregroundStyle(SiftChartStyle.secondaryText)
                                Spacer()
                                Button { model.addSearchRoot() } label: { Label("Add", systemImage: "plus") }
                                    .controlSize(.small)
                            }
                            ForEach(model.searchRoots, id: \.path) { root in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").foregroundStyle(SiftChartStyle.secondaryText)
                                    Text(root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Button { model.removeSearchRoot(root) } label: {
                                        Image(systemName: "minus.circle").foregroundStyle(SiftChartStyle.secondaryText)
                                    }
                                    .buttonStyle(.plain).help("Stop scanning this folder")
                                }
                            }
                        }

                        Label(model.deletesImmediately ? "Generated worktree folders are deleted permanently. Global cache commands are also permanent." : "Generated worktree folders move to Trash. Global cache commands are permanent and always require confirmation.", systemImage: "lock.shield.fill")
                            .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 390)

                Divider()

                HStack {
                    Spacer()
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Label("Quit \(model.applicationName)", systemImage: "power")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SiftChartStyle.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(width: 390)
            .siftGlassSurface(cornerRadius: 18, interactive: false)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .padding(.leading, 16)
            .padding(.bottom, 58)
        }
        .onExitCommand { showSettings = false }
    }

    private var updateRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(SiftChartStyle.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updates").font(.caption.weight(.medium))
                switch model.updateState {
                case .unavailable:
                    Text("Updates unavailable in this build")
                case .idle:
                    Text("Ready to check for updates")
                case .checking:
                    Text("Checking for updates…")
                case .upToDate:
                    Text("Sift is up to date")
                case let .available(release):
                    Text("Version \(release.version) is available")
                case let .downloading(release):
                    Text("Downloading and verifying \(release.version)…")
                case let .failed(message):
                    Text(message)
                }
            }
            .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            .lineLimit(2)
            Spacer(minLength: 6)
            switch model.updateState {
            case .idle, .upToDate, .failed:
                Button("Check now") { Task { await model.checkForUpdates() } }
                    .controlSize(.small)
            case let .available(release):
                VStack(alignment: .trailing, spacing: 3) {
                    Button("Update") { confirmation = .update(release) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Release notes") { model.openRelease(release) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
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
            if let message = model.lastMessage {
                HStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(SiftChartStyle.secondaryText).lineLimit(2).help(message)
                    Spacer(minLength: 4)
                    if !model.lastTrashedURLs.isEmpty {
                        Button("Show in Trash") { model.showLastTrashedItems() }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(SiftTheme.accent)
                    }
                }
            }
            HStack(spacing: 12) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 22, height: 22)
                        .overlay(alignment: .topTrailing) {
                            if case .available = model.updateState {
                                Circle()
                                    .fill(SiftTheme.accent)
                                    .frame(width: 7, height: 7)
                                    .overlay { Circle().stroke(.black.opacity(0.45), lineWidth: 1) }
                                    .offset(x: 2, y: -1)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(SiftChartStyle.secondaryText)
                .help(updateAvailable ? "Settings · Update available" : "Settings")
                .accessibilityLabel(updateAvailable ? "Settings, update available" : "Settings")
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive").frame(width: 22, height: 22)
                    Text(freeSpaceText)
                }
                .font(.caption.weight(.medium)).foregroundStyle(SiftChartStyle.secondaryText)
                Spacer()
                if section == .cleanup {
                    if model.isCleaning {
                        ProgressView().controlSize(.small).accessibilityLabel("Cleanup in progress")
                    } else if model.selectedCandidates.isEmpty {
                        Text(isInitialScan ? "Scanning worktrees…" : "No folders selected")
                            .font(.caption).foregroundStyle(SiftChartStyle.mutedText)
                    } else {
                        CleanupSelectionButton(bytes: model.selectedBytes, deletesImmediately: model.deletesImmediately,
                                               disabled: isInitialScan) { confirmation = .folders }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .siftGlassFooter()
    }

    private var freeSpaceText: String {
        model.freeDiskSpace().map { "\(ByteFormatting.string($0)) free" } ?? "Disk unavailable"
    }

    private var isInitialScan: Bool { model.isScanning && model.workspaces.isEmpty }

    private var updateAvailable: Bool {
        if case .available = model.updateState { return true }
        return false
    }

    private var storageFreeFraction: Double {
        guard let free = model.freeDiskSpace(), let capacity = model.diskCapacity(), capacity > 0 else { return 0 }
        return min(1, max(0, Double(free) / Double(capacity)))
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
    case allGlobals
    case global(String)
    case stopUVProcesses(Int)
    case update(UpdateRelease)

    var isUpdate: Bool {
        if case .update = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .folders: return "trash.fill"
        case .docker: return "shippingbox.fill"
        case .allGlobals: return "externaldrive.badge.xmark"
        case .global: return "externaldrive.badge.xmark"
        case .stopUVProcesses: return "stop.circle.fill"
        case .update: return "arrow.down.app.fill"
        }
    }

    @MainActor func message(model: AppModel) -> String {
        switch self {
        case .folders:
            return model.deletesImmediately
                ? "Only the selected generated folders will be deleted permanently. This cannot be undone. Project files, .git data, and workspace roots remain excluded. The displayed value is their folder-attributed size; Sift will report the actual macOS free-space increase afterward."
                : "Only the selected generated folders will move to macOS Trash. Project files and workspace roots are excluded. Moving items to Trash does not release disk space until Trash is emptied."
        case .docker:
            return "Pruning is permanent and uses only the local Docker Engine. Unused images and build cache are removed; active images, containers, and volumes remain untouched."
        case .allGlobals:
            let names = model.cleanableGlobalCaches.map(\.name) + (model.dockerState.reclaimableBytes > 0 ? ["Docker unused data"] : [])
            return "Eligible sources: \(names.joined(separator: ", ")). Cleanup is permanent. Plugins, simulators, and blocked caches are excluded. Docker containers and volumes, app profiles, and conversations remain protected. Stored sizes are not guaranteed savings."
        case let .global(id):
            if let cache = model.globalCaches.first(where: { $0.id == id }), id == "simulators" || id == "pulumi" || RegenerableCacheService.definitions.contains(where: { $0.id == id }) {
                return "\(cache.detail). Cleanup is permanent. The displayed size is folder-attributed storage, not guaranteed freed space."
            }
            if id == "uv" {
                return "uv requires all active uv commands to stop before its cache can be cleared safely. Cached artifacts will be downloaded or rebuilt later; Sift never bypasses uv's cache lock."
            }
            return "This package manager performs permanent cache cleanup. Cached artifacts may need to be downloaded or rebuilt later; installed tools and project files remain untouched."
        case let .stopUVProcesses(count):
            return "This will terminate \(count) uv command\(count == 1 ? "" : "s") currently holding uv's cache lock. Any development servers or other work started by those commands will stop. Project files and virtual environments remain untouched."
        case .update:
            return "Sift will download the update, verify its checksum, identity, version, and code signature, then replace and relaunch this app."
        }
    }

    @MainActor func title(model: AppModel) -> String {
        switch self {
        case .folders: return model.deletesImmediately ? "Permanently delete selected folders?" : "Move selected folders to Trash?"
        case .docker: return "Remove unused Docker data?"
        case .allGlobals: return "Clean eligible caches?"
        case let .global(id):
            let cache = model.globalCaches.first(where: { $0.id == id })
            return "\(cache?.onlyPrunesUnusedData == true ? "Prune" : "Clean") \(cache?.name ?? "global cache")?"
        case .stopUVProcesses: return "Stop active uv commands?"
        case let .update(release): return "Install Sift \(release.version)?"
        }
    }

    @MainActor func actionTitle(model: AppModel) -> String {
        switch self {
        case .folders:
            return model.deletesImmediately
                ? "Delete \(model.selectedCandidates.count) folders · \(ByteFormatting.string(model.selectedBytes)) selected"
                : "Move \(model.selectedCandidates.count) folders · \(ByteFormatting.string(model.selectedBytes)) to Trash"
        case .docker: return "Prune images and build cache"
        case .allGlobals: return "Clean \(model.cleanableGlobalStorageCount) items"
        case let .global(id):
            return model.globalCaches.first(where: { $0.id == id })?.onlyPrunesUnusedData == true
                ? "Prune unused cache data"
                : "Clear cache permanently"
        case .stopUVProcesses: return "Stop uv commands"
        case .update: return "Download and install update"
        }
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
            .siftStorageSurface()
    }
}

private extension View {
    @ViewBuilder
    func siftGlassSurface(cornerRadius: CGFloat, interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            background {
                shape.fill(.clear).glassEffect(.clear.interactive(interactive), in: shape)
                    .allowsHitTesting(false)
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
    func siftGlassFooter() -> some View {
        if #available(macOS 26.0, *) {
            background {
                Rectangle().fill(.clear).glassEffect(.clear, in: Rectangle()).opacity(0.35).allowsHitTesting(false)
            }
        } else {
            background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder
    func siftGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            background { Capsule().fill(.clear).glassEffect(.clear, in: Capsule()).opacity(0.25).allowsHitTesting(false) }
        } else {
            background(.quaternary, in: Capsule())
        }
    }

    @ViewBuilder
    func siftConfirmationButton(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).tint(tint)
        } else {
            buttonStyle(.bordered).tint(tint)
        }
    }
}

private enum SiftTheme {
    static let accent = SiftChartStyle.accent
    static let destructiveAccent = SiftChartStyle.accent
}
