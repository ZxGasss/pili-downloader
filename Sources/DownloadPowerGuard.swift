import Foundation

/// Prevent idle system sleep only while real downloads are active. No persistent power settings.
@MainActor final class DownloadPowerGuard {
    static let shared = DownloadPowerGuard()
    private var owners = Set<UUID>()
    private var activity: NSObjectProtocol?
    func begin(_ id: UUID) {
        owners.insert(id)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "霹雳下载正在下载获授权内容")
        }
    }
    func end(_ id: UUID) {
        owners.remove(id)
        if owners.isEmpty, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
