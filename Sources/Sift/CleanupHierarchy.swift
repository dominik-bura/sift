import AppKit

enum CleanupHierarchy {
    static let sourceInset: CGFloat = 22
    static let sourceTextInset: CGFloat = 36

    static func skippedName(_ location: GlobalCache.SkippedLocation) -> String {
        let component = URL(fileURLWithPath: location.path).lastPathComponent
        if component.hasSuffix(".ShipIt") {
            let identifier = String(component.dropLast(".ShipIt".count))
            let knownName = RegenerableCacheService.definitions.first { $0.appNames.contains(identifier) }?.appNames.first
            let installedName = knownName == nil ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension().lastPathComponent : nil
            return "\(knownName ?? installedName ?? identifier) updater"
        }
        if component.hasSuffix("-updater") {
            return "\(component.dropLast("-updater".count)) updater"
        }
        return component
    }

    static func shortReason(_ location: GlobalCache.SkippedLocation) -> String {
        let reason = location.reason.lowercased()
        if reason.contains("permission") || reason.contains("not permitted") { return "Permission denied" }
        if location.reason.hasPrefix("Read error"), let prefix = location.reason.split(separator: ":").first { return String(prefix) }
        return "Unreadable"
    }

    static func skippedSummary(_ locations: [GlobalCache.SkippedLocation]) -> String? {
        guard let first = locations.first else { return nil }
        let more = locations.count > 1 ? " + \(locations.count - 1) more" : ""
        let reason = locations.allSatisfy { shortReason($0) == "Permission denied" } ? "permission denied" : "unreadable"
        return "Skipped \(skippedName(first))\(more) · \(reason)"
    }

    static func categoryStatus(skippedCount: Int, busy: Bool, measuring: Bool, attention: Bool) -> String {
        if busy { return "cleaning" }
        if measuring { return "measuring" }
        if skippedCount > 0 { return "\(skippedCount) location\(skippedCount == 1 ? "" : "s") skipped" }
        return attention ? "needs attention" : ""
    }
}
