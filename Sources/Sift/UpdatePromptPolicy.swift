import Foundation

/// Per-release choices survive restart without turning reminders into an
/// automatic installation policy. The gear/manual Update action stays usable.
struct UpdatePromptPolicy: Codable, Equatable {
    var lastPresentedVersion: String?
    var skippedVersion: String?
    var reminderVersion: String?
    var remindAfter: Date?

    func allowsAutomaticUpdate(version: String, now: Date) -> Bool {
        skippedVersion != version && (reminderVersion != version || remindAfter.map { now >= $0 } != false)
    }

    func shouldPresent(version: String, now: Date) -> Bool {
        guard skippedVersion != version else { return false }
        if reminderVersion == version, let remindAfter { return now >= remindAfter }
        return lastPresentedVersion != version
    }
    mutating func presented(_ version: String) {
        lastPresentedVersion = version
        if reminderVersion == version { reminderVersion = nil; remindAfter = nil }
    }
    mutating func remindTomorrow(_ version: String, now: Date) {
        if skippedVersion == version { skippedVersion = nil }
        reminderVersion = version
        remindAfter = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
    }
    mutating func skip(_ version: String) {
        skippedVersion = version
        if reminderVersion == version { reminderVersion = nil; remindAfter = nil }
    }
    mutating func deferredForCleanup(_ version: String) {
        if lastPresentedVersion == version { lastPresentedVersion = nil }
    }
}

struct UpdateExecution: Sendable {
    var check: @Sendable () async throws -> UpdateRelease?
    var download: @Sendable (UpdateRelease) async throws -> URL
    var install: @MainActor @Sendable (URL) throws -> Void

    static func live(service: UpdateService) -> Self {
        Self(check: { try await service.checkForUpdate() },
             download: { try await service.downloadAndStage($0) },
             install: { try service.launchInstaller(for: $0) })
    }
}
