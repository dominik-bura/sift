import SwiftUI

struct CleanupDashboardView: View {
    let inventory: CleanupInventory
    let observation: CleanupObservation?
    let cleaningID: String?
    let cleaningDocker: Bool
    let isCleaning: Bool
    let eligibleCount: Int
    let onClean: (String) -> Void
    let onDocker: () -> Void
    let onCleanEligible: () -> Void
    let onStopUV: (Int) -> Void
    var reviewCacheID: String? = nil
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
                    .disabled(eligibleCount == 0 || isCleaning)
                    .help("Review \(eligibleCount) eligible cleanup sources. Plugins, simulators, and blocked caches are excluded.")
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
        let busy = caches.contains { $0.id == cleaningID } || (category == .developerTools && cleaningDocker)
        let attention = caches.contains { if case .failed = $0.state { return true }; return false }
        let count = caches.count + (category == .developerTools ? 1 : 0)
        let missingSizes = caches.contains { switch $0.state { case .checking, .failed, .unavailable: true; default: false } }
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedCategories.remove(category) } else { expandedCategories.insert(category) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: category.symbol).foregroundStyle(SiftChartStyle.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.rawValue).font(.callout.weight(.semibold))
                        Text("\(count) source\(count == 1 ? "" : "s")\(busy ? " · cleaning" : measuring ? " · measuring" : attention ? " · needs attention" : "")")
                            .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    }
                    Spacer()
                    if measuring || busy { ProgressView().controlSize(.small) }
                    else if attention { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    Text(categorySizeLabel(category, missingSizes: missingSizes, measuring: measuring))
                        .font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(SiftChartStyle.mutedText)
                }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(spacing: 0) {
                    Text(category.detail).font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
                    ForEach(caches) { cache in
                        Divider().overlay(SiftChartStyle.rule).padding(.horizontal, 12)
                        cacheRow(cache).id("cache-" + cache.id)
                    }
                    if category == .developerTools {
                        Divider().padding(.horizontal, 12)
                        dockerRow
                    }
                }
            }
        }
    }

    private func categorySizeLabel(_ category: CacheCategory, missingSizes: Bool, measuring: Bool) -> String {
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
                Image(systemName: cache.symbolName).font(.system(size: 13)).foregroundStyle(SiftChartStyle.accent).frame(width: 19)
                Button {
                    if expanded { expandedRows.remove(cache.id) } else { expandedRows.insert(cache.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(cache.name).font(.callout.weight(.medium)).lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundStyle(SiftChartStyle.mutedText)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Show cleanup details and cache location")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Spacer(minLength: 4)
                if cleaningID == cache.id || cache.state == .checking {
                    ProgressView().controlSize(.small).accessibilityLabel("Measuring or cleaning \(cache.name)")
                } else {
                    switch cache.state {
                    case let .blocked(bytes, _, count):
                        Text("\(ByteFormatting.string(bytes)) stored").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                        Button("Stop uv…") { onStopUV(count) }.buttonStyle(SiftQuietButtonStyle()).disabled(isCleaning)
                    case let .failed(message):
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(message).accessibilityLabel(message)
                        Text("Failed").font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                    case .unavailable:
                        Text("Unavailable").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    case let .available(bytes, _):
                        if bytes > 0 {
                            Text("\(ByteFormatting.string(bytes)) stored").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                            Button(cache.onlyPrunesUnusedData ? "Prune…" : "Clean…") { onClean(cache.id) }
                                .buttonStyle(SiftQuietButtonStyle()).disabled(isCleaning)
                        } else { Text("Empty").font(.caption2).foregroundStyle(SiftChartStyle.mutedText) }
                    case .checking: EmptyView()
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 11)
            if case let .blocked(_, _, count) = cache.state {
                Text("\(count) running uv command\(count == 1 ? " holds" : "s hold") the cache lock.")
                    .font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text(cache.detail)
                    if let path = cache.state.path { Text(path).textSelection(.enabled) }
                    if cache.onlyPrunesUnusedData { Text("Stored size is not the amount Prune will remove.") }
                    if !cache.includedInCleanAll { Text("Requires individual review · excluded from bulk cleanup.") }
                    if case let .failed(message) = cache.state { Text(message).foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private var dockerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").foregroundStyle(SiftChartStyle.accent).frame(width: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Docker").font(.callout.weight(.medium))
                    Text("Cleanup estimate · not VM disk size").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                }
                Spacer(minLength: 4)
                if cleaningDocker || inventory.docker == .checking { ProgressView().controlSize(.small) }
                else if let estimate = inventory.dockerEstimate {
                    if estimate > 0 {
                        Text("Up to \(ByteFormatting.string(estimate))").font(.caption.monospacedDigit()).foregroundStyle(SiftChartStyle.secondaryText)
                        Button("Clean…") { onDocker() }.buttonStyle(SiftQuietButtonStyle()).disabled(isCleaning)
                    } else { Text("Empty").font(.caption2).foregroundStyle(SiftChartStyle.mutedText) }
                }
            }
            if case let .unavailable(message) = inventory.docker {
                Text(message).font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            }
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
                        Text(inventory.storedBytes == 0 && inventory.isMeasuring ? "Measuring…" : ByteFormatting.string(inventory.storedBytes))
                            .font(.system(size: 23, weight: .semibold)).monospacedDigit()
                        if inventory.storedBytes > 0 || !inventory.isMeasuring {
                            Text("stored").font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
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
                let visible = inventory.segments.filter { $0.bytes > 0 }
                let usable = max(0, size.width - CGFloat(max(0, visible.count - 1)) * 3)
                for segment in visible {
                    let width = usable * CGFloat(Double(segment.bytes) / Double(max(1, inventory.storedBytes)))
                    let shape = Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: 3)
                    context.fill(shape, with: .color(SiftChartStyle.inventoryColor(for: segment.id)))
                    x += width + 3
                }
                if visible.isEmpty {
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.primary.opacity(0.06)))
                }
            }.frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(inventory.segments) { segment in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(SiftChartStyle.inventoryColor(for: segment.id)).frame(width: 6, height: 6)
                        Text(segment.name).foregroundStyle(SiftChartStyle.secondaryText)
                        Spacer(minLength: 0)
                        Text(ByteFormatting.string(segment.bytes)).monospacedDigit()
                    }.font(.caption2)
                }
            }
            Text("Actual space freed depends on what’s removed and whether files share storage.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .help("Stored data in cleanup sources is not guaranteed freed space. Pruning may retain items still needed, and shared APFS blocks may remain after deletion. Docker’s cleanup estimate is separate.")
            if let estimate = inventory.dockerEstimate, estimate > 0 {
                HStack {
                    Text("Docker cleanup estimate").foregroundStyle(SiftChartStyle.secondaryText)
                    Spacer()
                    Text("Up to \(ByteFormatting.string(estimate))").monospacedDigit()
                }.font(.caption2).padding(.top, 2)
            }
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
            Text(observation.movedToTrash ? "Moving to Trash does not release space until Trash is emptied." : "Mac-wide change during cleanup; other apps can affect it.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }.padding(12).siftStorageSurface()
    }
}
