import Foundation

enum DownloadLifecycle: String, Codable {
    case idle, preparing, transferring, merging, paused, cancelled, failed, completed
}

/// Shared across all windows and seasons. A permit covers one episode, including its merge.
actor DownloadBudget {
    static let shared = DownloadBudget()
    private var active = Set<UUID>()
    let maximumEpisodes = MemoryBudget.episodes
    func acquire(_ id: UUID) async throws {
        while active.count >= maximumEpisodes {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        active.insert(id)
    }
    func release(_ id: UUID) { active.remove(id) }
}

enum SeasonProgress {
    /// Complete files count as one; each active episode contributes at most one fraction.
    static func fraction(total: Int, completed: Int, active: [Double]) -> Double {
        guard total > 0 else { return 0 }
        let finished = min(total, max(0, completed))
        let partial = active.prefix(total - finished).reduce(0) { $0 + min(0.99, max(0, $1.isFinite ? $1 : 0)) }
        return min(1, (Double(finished) + partial) / Double(total))
    }
}
