import SwiftUI

struct CleanupDashboardView: View {
    let inventory: CleanupInventory
    let observation: CleanupObservation?
    let cleaningIDs: Set<String>
    let cleaningDocker: Bool
    let eligibleCount: Int
    let onClean: (String) -> Void
    let onDocker: () -> Void
    let onCleanEligible: () -> Void
    let onStopUV: (Int) -> Void
    var reviewCacheID: String? = nil
    var blockedCacheIDs: Set<String> = []
    var cleanupErrors: [String: String] = [:]
    var updateInProgress = false
    @State var expandedCategories: Set<CacheCategory> = []
    @State var expandedRows = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CleanupInventoryCard(inventory: inventory)
            if let observation { CleanupObservationView(observation: observation) }
            HStack {
                Text("CACHES & TOOLS").font(.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(SiftChartStyle.secondaryText)
                Spacer()
                Button("Clean eligible…") { onCleanEligible() }
                    .font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(SiftChartStyle.accent)
                    .disabled(eligibleCount == 0)
                    .help("Review \(eligibleCount) eligible cleanup sources. Plugins, simulators, blocked caches, and caches changed in the last 14 days are excluded.")
            }
            VStack(spacing: 0) {
                ForEach(Array(visibleCategories.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { Divider().padding(.horizontal, 12) }
                    categoryPanel(category)
                }
            }.siftStorageSurface()
            Text("Global cleanup is permanent. Every action requires confirmation; stored sizes are not promised savings.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }.padding(.bottom, 22)
            .onAppear { expandReviewedCache() }
            .onChange(of: reviewCacheID) { _, _ in expandReviewedCache() }
    }

    private func expandReviewedCache() {
        guard let id = reviewCacheID, let cache = inventory.caches.first(where: { $0.id == id }) else { return }
        expandedCategories.insert(CacheCategory.containing(cache))
        expandedRows.insert(id)
    }

    private var visibleCategories: [CacheCategory] {
        CacheCategory.allCases.filter { !inventory.caches(in: $0).isEmpty || $0 == .developerTools }
    }

    private func categoryPanel(_ category: CacheCategory) -> some View {
        let caches = inventory.caches(in: category)
        let expanded = expandedCategories.contains(category)
        let measuring = caches.contains { $0.state == .checking } || (category == .developerTools && inventory.docker == .checking)
        let busy = caches.contains { cleaningIDs.contains($0.id) } || (category == .developerTools && cleaningDocker)
        let attention = caches.contains { cache in
            if cache.hasPartialMeasurement { return true }
            if cleanupErrors["cache:" + cache.id] != nil { return true }
            if case .failed = cache.state { return true }
            return false
        } || (category == .developerTools && cleanupErrors["docker"] != nil)
        let count = caches.count + (category == .developerTools ? 1 : 0)
        let skippedCount = Set(caches.flatMap(\.skippedLocations).map(\.path)).count
        let status = CleanupHierarchy.categoryStatus(skippedCount: skippedCount, busy: busy, measuring: measuring, attention: attention)
        let missingSizes = caches.contains { cache in
            if cache.hasPartialMeasurement { return true }
            return switch cache.state { case .checking, .failed, .unavailable: true; default: false }
        }
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedCategories.remove(category) } else { expandedCategories.insert(category) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: category.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(SiftChartStyle.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.rawValue).font(.system(size: 14, weight: .semibold))
                        Text("\(count) source\(count == 1 ? "" : "s")\(status.isEmpty ? "" : " · " + status)")
                            .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if measuring || busy { ProgressView().controlSize(.small) }
                        else if attention { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        Text(categorySizeLabel(category, missingSizes: missingSizes, measuring: measuring))
                            .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: 150, alignment: .trailing)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(SiftChartStyle.mutedText)
                }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(spacing: 0) {
                    Text(category.detail).font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(caches.enumerated()), id: \.element.id) { index, cache in
                            if index > 0 { sourceDivider }
                            cacheRow(cache).id("cache-" + cache.id)
                        }
                        if category == .developerTools {
                            if !caches.isEmpty { sourceDivider }
                            dockerRow
                        }
                    }
                    .padding(.leading, CleanupHierarchy.sourceInset)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SiftChartStyle.rule).frame(width: 1)
                            .padding(.leading, CleanupHierarchy.sourceInset).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }.padding(.bottom, 6)
            }
        }
    }

    private var sourceDivider: some View {
        Divider().overlay(SiftChartStyle.rule)
            .padding(.leading, CleanupHierarchy.sourceTextInset).padding(.trailing, 12)
    }

    private func categorySizeLabel(_ category: CacheCategory, missingSizes: Bool, measuring: Bool) -> String {
        if category == .developerTools, inventory.includesDockerEstimate {
            return "\(ByteFormatting.string(inventory.summaryBytes(in: category))) incl. Docker estimate"
        }
        let bytes = inventory.storedBytes(in: category)
        if bytes == 0 && measuring { return "Measuring…" }
        if bytes == 0 && missingSizes { return "Size unavailable" }
        if bytes == 0 && category == .developerTools {
            if let estimate = inventory.dockerEstimate, estimate > 0 { return "Up to \(ByteFormatting.string(estimate)) estimated" }
            if case .unavailable = inventory.docker, inventory.caches(in: category).isEmpty { return "Docker unavailable" }
        }
        return "\(ByteFormatting.string(bytes)) \(missingSizes ? "measured" : "stored")"
    }

    private func cacheRow(_ cache: GlobalCache) -> some View {
        let expanded = expandedRows.contains(cache.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: cache.symbolName).font(.system(size: 12)).foregroundStyle(SiftChartStyle.accent).frame(width: 16)
                Button {
                    if expanded { expandedRows.remove(cache.id) } else { expandedRows.insert(cache.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(cache.name).font(.caption.weight(.medium)).lineLimit(1)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundStyle(SiftChartStyle.mutedText)
                        }
                        if let changed = cache.lastChangedLabel() {
                            Text(changed).font(.caption2).foregroundStyle(SiftChartStyle.mutedText).lineLimit(1)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Show cleanup details and cache location")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Spacer(minLength: 4)
                if cleaningIDs.contains(cache.id) || cache.state == .checking {
                    ProgressView().controlSize(.small).accessibilityLabel("Measuring or cleaning \(cache.name)")
                } else {
                    switch cache.state {
                    case let .blocked(bytes, _, count):
                        Text("\(ByteFormatting.string(bytes)) stored").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                        Button("Stop uv…") { onStopUV(count) }.buttonStyle(SiftQuietButtonStyle()).disabled(blockedCacheIDs.contains(cache.id))
                    case let .failed(message):
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(message).accessibilityLabel(message)
                        Text("Failed").font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                    case .unavailable:
                        Text("Unavailable").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    case let .available(bytes, _):
                        if bytes > 0 {
                            Text("\(ByteFormatting.string(bytes)) \(cache.hasPartialMeasurement ? "measured" : "stored")").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                            Button(cache.onlyPrunesUnusedData ? "Prune…" : "Clean…") { onClean(cache.id) }
                                .buttonStyle(SiftQuietButtonStyle()).disabled(blockedCacheIDs.contains(cache.id))
                        } else { Text(cache.hasPartialMeasurement ? "Skipped" : "Empty").font(.caption2).foregroundStyle(SiftChartStyle.mutedText) }
                    case .checking: EmptyView()
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 11)
            if let summary = CleanupHierarchy.skippedSummary(cache.skippedLocations) {
                Label(summary, systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CleanupHierarchy.sourceTextInset).padding(.trailing, 12).padding(.bottom, 10)
                    .help(cache.skippedLocations.map { "\($0.path) — \($0.reason)" }.joined(separator: "\n"))
            }
            if let error = cleanupErrors["cache:" + cache.id] {
                Text(error).font(.caption2).foregroundStyle(.orange).padding(.leading, CleanupHierarchy.sourceTextInset).padding(.trailing, 12).padding(.bottom, 8)
            }
            if case let .blocked(_, _, count) = cache.state {
                Text("\(count) running uv command\(count == 1 ? " holds" : "s hold") the cache lock.")
                    .font(.caption2).foregroundStyle(.orange).padding(.leading, CleanupHierarchy.sourceTextInset).padding(.trailing, 12).padding(.bottom, 8)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cleanup details").font(.caption2.weight(.semibold)).foregroundStyle(.primary)
                    Text(cache.detail)
                    if let path = cache.state.path { Text(path).textSelection(.enabled) }
                    if cache.onlyPrunesUnusedData { Text("Stored size is not the amount Prune will remove.") }
                    if !cache.includedInCleanAll { Text("Requires individual review · excluded from bulk cleanup.") }
                    else if cache.skippedByBulkCleanup() { Text("Changed in the last 14 days, so it is probably still in use and would download again · skipped by Clean eligible.") }
                    if cache.lastChangedLabel() != nil { Text("Age is the newest modification date in the cache, not last use.") }
                    if case let .failed(message) = cache.state { Text(message).foregroundStyle(.orange) }
                    if cache.hasPartialMeasurement {
                        Text("Skipped locations are excluded from this size and left untouched by cleanup.")
                        Text("SKIPPED LOCATIONS").font(.caption2.weight(.semibold)).padding(.top, 5)
                        ForEach(cache.skippedLocations) { location in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CleanupHierarchy.skippedName(location)).fontWeight(.medium)
                                Text(location.path).font(.caption2.monospaced()).textSelection(.enabled)
                                Text(CleanupHierarchy.shortReason(location)).foregroundStyle(.orange).help(location.reason)
                            }
                        }
                    }
                }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                    // Explanations wrap instead of truncating when the panel is short.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, CleanupHierarchy.sourceTextInset).padding(.trailing, 12).padding(.bottom, 12)
            }
        }
    }

    private var dockerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").font(.system(size: 12)).foregroundStyle(SiftChartStyle.accent).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Docker").font(.caption.weight(.medium))
                    Text("Cleanup estimate · not VM disk size").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                }
                Spacer(minLength: 4)
                if cleaningDocker || inventory.docker == .checking { ProgressView().controlSize(.small) }
                else if let estimate = inventory.dockerEstimate {
                    if estimate > 0 {
                        Text("Up to \(ByteFormatting.string(estimate))").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                        Button("Clean…") { onDocker() }.buttonStyle(SiftQuietButtonStyle()).disabled(updateInProgress)
                    } else { Text("Empty").font(.caption2).foregroundStyle(SiftChartStyle.mutedText) }
                }
            }
            if case let .unavailable(message) = inventory.docker {
                Text(message).font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            }
            if let error = cleanupErrors["docker"] { Text(error).font(.caption2).foregroundStyle(.orange) }
        }.padding(12)
    }
}

struct CleanupInventoryCard: View {
    let inventory: CleanupInventory
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CLEANUP SOURCES").font(.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(SiftChartStyle.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(inventory.summaryBytes == 0 && inventory.isMeasuring ? "Measuring…" : ByteFormatting.string(inventory.summaryBytes))
                            .font(.system(size: 23, weight: .semibold)).monospacedDigit()
                        if inventory.summaryBytes > 0 || !inventory.isMeasuring {
                            Text(inventory.includesDockerEstimate ? "incl. Docker estimate" : inventory.hasUnmeasuredSources ? "measured" : "stored").font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
                        }
                    }
                }
                Spacer()
                if inventory.hasUnmeasuredSources {
                    Text("Partial results").font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                }
            }
            Canvas { context, size in
                var x: CGFloat = 0
                let visible = inventory.summarySegments.filter { $0.bytes > 0 }
                let usable = max(0, size.width - CGFloat(max(0, visible.count - 1)) * 3)
                for segment in visible {
                    let width = usable * CGFloat(Double(segment.bytes) / Double(max(1, inventory.summaryBytes)))
                    let shape = Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: 3)
                    context.fill(shape, with: .color(SiftChartStyle.inventoryColor(for: segment.id)))
                    x += width + 3
                }
                if visible.isEmpty {
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.primary.opacity(0.06)))
                }
            }.frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(inventory.summarySegments) { segment in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(SiftChartStyle.inventoryColor(for: segment.id)).frame(width: 6, height: 6)
                        Text(segment.name).foregroundStyle(SiftChartStyle.secondaryText)
                        Spacer(minLength: 0)
                        Text(ByteFormatting.string(segment.bytes)).monospacedDigit()
                    }.font(.caption2)
                }
            }
            Text(inventory.includesDockerEstimate
                 ? "Folder sizes + Docker cleanup estimate. Actual space freed may be less; files may share storage."
                 : "Actual space freed depends on what’s removed and whether files share storage.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .help("The combined inventory includes Docker’s cleanup estimate under Developer tools, not its VM disk size. It is not measured disk usage or guaranteed freed space. Pruning may retain data, shared APFS blocks may remain, and Docker may not release host disk space immediately.")
        }.padding(13).siftStorageSurface()
    }
}

struct CleanupObservationView: View {
    let observation: CleanupObservation
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("LAST CLEANUP · OBSERVED").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(SiftChartStyle.secondaryText)
                Spacer()
                Text(observation.date.formatted(.dateTime.hour().minute())).font(.caption2.monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
            }
            HStack {
                Text(observation.operation).font(.caption).lineLimit(1)
                Spacer()
                if let change = observation.freeSpaceChange {
                    Text("\(change > 0 ? "+" : change < 0 ? "−" : "")\(ByteFormatting.string(abs(change))) free space")
                        .font(.caption.monospacedDigit())
                } else { Text("Measurement unavailable").font(.caption).foregroundStyle(SiftChartStyle.secondaryText) }
            }
            Text(observation.movedToTrash ? "Moving to Trash does not release space until Trash is emptied." : "Mac-wide change during cleanup; concurrent cleanups and other apps can affect it.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }.padding(12).siftStorageSurface()
    }
}
