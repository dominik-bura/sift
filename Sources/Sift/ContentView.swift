import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmation: CleanupConfirmation?
    @State private var showSettings = false
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
                            globalCachesSection
                            worktreesSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
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
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(.secondary)
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(nsImage: SiftAssets.applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(width: 24, height: 24)
                Text(model.applicationName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .tracking(-0.25)
                    .baselineOffset(0.5)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let lastSyncedAt = model.lastSyncedAt {
                        Text(
                            "Last synced \(lastSyncedAt.formatted(.dateTime.day().month(.abbreviated))) · \(lastSyncedAt.formatted(.dateTime.hour().minute()))"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    } else {
                        Text("Not synced yet")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button { model.scan() } label: {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .regular))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("Scan again")
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
                        Text("developer data found").font(.headline).foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(SiftTheme.brandGradient)
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
                Text("Sift is checking Git worktrees, generated dependencies, build output, and Docker images.")
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

    private var globalCachesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("GLOBAL CACHES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clean all") { confirmation = .allGlobals }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.cleanableGlobalStorageCount == 0 ? Color.secondary : SiftTheme.accent)
                            .disabled(model.cleanableGlobalStorageCount == 0 || model.isCleaning)
                    }
                    Panel(padding: 0) {
                        VStack(spacing: 0) {
                            dockerCacheRow
                            ForEach(Array(model.globalCaches.enumerated()), id: \.element.id) { index, cache in
                                Divider().padding(.leading, 52)
                                HStack(spacing: 11) {
                                    Image(systemName: cache.symbolName).foregroundStyle(SiftTheme.accent).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cache.name).font(.callout.weight(.semibold))
                                        if case let .available(_, path) = cache.state {
                                            Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        } else if case let .blocked(_, _, processCount) = cache.state {
                                            Text("\(processCount) running uv command\(processCount == 1 ? " is" : "s are") preventing cache cleanup")
                                                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    if model.cleaningGlobalCacheID == cache.id || cache.state == .checking {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(SiftTheme.accent)
                                            .accessibilityLabel(model.cleaningGlobalCacheID == cache.id ? "Cleaning \(cache.name)" : "Measuring \(cache.name)")
                                    } else if case let .blocked(bytes, _, processCount) = cache.state {
                                        Text(ByteFormatting.string(bytes))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Button("Stop uv") { confirmation = .stopUVProcesses(processCount) }
                                            .disabled(model.isCleaning)
                                            .help("Stop the uv commands so the cache can be cleaned")
                                    } else if case let .failed(message) = cache.state {
                                        Text(message)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                            .lineLimit(1)
                                            .help(message)
                                    } else if cache.bytes > 0 {
                                        Text("up to \(ByteFormatting.string(cache.bytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Button(cache.onlyPrunesUnusedData ? "Prune" : "Clean") { confirmation = .global(cache.id) }
                                            .disabled(model.isCleaning)
                                    } else {
                                        Text("Empty").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 13).padding(.vertical, 10)
                            }
                        }
                    }
                    Text("Sizes are attributed to these folders. APFS clones may cause the space actually released to be smaller.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 20)
    }

    private var dockerCacheRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "shippingbox.fill").foregroundStyle(SiftTheme.accent).frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text("Docker storage").font(.callout.weight(.semibold))
                switch model.dockerState {
                case .checking:
                    EmptyView()
                case let .unavailable(message):
                    Text(message).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                case let .available(_, detail):
                    Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if model.isCleaningDocker || model.dockerState == .checking {
                ProgressView()
                    .controlSize(.small)
                    .tint(SiftTheme.accent)
                    .accessibilityLabel(model.isCleaningDocker ? "Cleaning Docker storage" : "Measuring Docker storage")
            } else if case let .available(bytes, _) = model.dockerState, bytes > 0 {
                Text("up to \(ByteFormatting.string(bytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Clean") { confirmation = .docker }.disabled(model.isCleaning)
            } else if case .available = model.dockerState {
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isScanning && !model.isBackgroundRefreshing {
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
                Text("Worktree values are generated-folder sizes. Actual freed space is measured after permanent deletion.")
                    .font(.caption2).foregroundStyle(.tertiary)
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
                        Text(repository.name).font(.headline).lineLimit(1)
                        Text("\(repository.workspaces.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
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
                Panel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(repository.workspaces.enumerated()), id: \.element.id) { index, workspace in
                            if index > 0 { Divider() }
                            workspaceRow(workspace)
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
                                    Text(workspace.name).font(.headline).lineLimit(1)
                                    Text(workspace.branch).font(.caption)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .siftGlassCapsule().lineLimit(1)
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
                        Text(model.versionLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showSettings = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Close Settings")
                }
                .padding(16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("SOFTWARE UPDATE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            updateRow
                            Text("Sift checks for updates without sending telemetry or storage data.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("WORKTREE CLEANUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Delete immediately").font(.caption.weight(.medium))
                                    Text("Skip macOS Trash for generated worktree folders").font(.caption2).foregroundStyle(.tertiary)
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
                                Text("SCANNED FOLDERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button { model.addSearchRoot() } label: { Label("Add", systemImage: "plus") }
                                    .controlSize(.small)
                            }
                            ForEach(model.searchRoots, id: \.path) { root in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Button { model.removeSearchRoot(root) } label: {
                                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain).help("Stop scanning this folder")
                                }
                            }
                        }

                        Label(model.deletesImmediately ? "Generated worktree folders are deleted permanently. Global cache commands are also permanent." : "Generated worktree folders move to Trash. Global cache commands are permanent and always require confirmation.", systemImage: "lock.shield.fill")
                            .font(.caption2).foregroundStyle(.tertiary)
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
            .font(.caption2).foregroundStyle(.secondary)
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
            if let message = model.lastMessage {
                HStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(updateAvailable ? "Settings · Update available" : "Settings")
                .accessibilityLabel(updateAvailable ? "Settings, update available" : "Settings")
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive").frame(width: 22, height: 22)
                    Text(freeSpaceText)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { confirmation = .folders } label: {
                    if isInitialScan {
                        HStack { ProgressView().controlSize(.small); Text("Scanning…") }.frame(minWidth: 170)
                    } else if model.isCleaning { ProgressView().controlSize(.small).frame(minWidth: 170) }
                    else {
                        Label(
                            "\(model.deletesImmediately ? "Delete" : "Move to Trash") · \(ByteFormatting.string(model.selectedBytes)) selected",
                            systemImage: model.deletesImmediately ? "trash.slash" : "trash"
                        )
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.selectedCandidates.isEmpty || model.isCleaning || isInitialScan)
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
            return "Docker unused images and build cache plus each installed package-manager cache will be cleaned sequentially. Active Docker images, containers, and volumes remain untouched. Active uv processes can prevent uv cleanup; Sift never bypasses uv's cache lock."
        case let .global(id):
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
        case .allGlobals: return "Clean Docker and all global caches?"
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
        .siftGlassSurface(cornerRadius: 11, interactive: false)
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
                    .fill(state == .off ? Color.clear : SiftTheme.accent)
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
            .background {
                BehindWindowContentMaterial(cornerRadius: 13)
            }
    }
}

private extension View {
    @ViewBuilder
    func siftGlassSurface(cornerRadius: CGFloat, interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            glassEffect(.clear.interactive(interactive), in: shape)
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
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder
    func siftGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.clear, in: Capsule())
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

private struct BehindWindowContentMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 0.78
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}

private enum SiftTheme {
    static let accent = Color(red: 0.96, green: 0.29, blue: 0.14)
    static let destructiveAccent = Color(red: 0.96, green: 0.29, blue: 0.14)
    static let warmOrange = Color(red: 1.00, green: 0.49, blue: 0.12)
    static let brandGradient = LinearGradient(
        colors: [warmOrange, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
