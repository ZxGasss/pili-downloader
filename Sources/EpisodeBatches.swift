import Foundation

enum EpisodeBatches {
    static func split(_ episodes: [Episode], size: Int) throws -> [[Episode]] {
        guard (1...200).contains(size) else { throw AppFailure.message("每组集数请输入1至200。") }
        let ordered = episodes.sorted { $0.index < $1.index }
        guard Set(ordered.map(\.id)).count == ordered.count, Set(ordered.map(\.index)).count == ordered.count else {
            throw AppFailure.message("集数目录有重复，不能安全分组。")
        }
        return stride(from: 0, to: ordered.count, by: size).map { Array(ordered[$0..<min($0 + size, ordered.count)]) }
    }
}

struct SeasonEstimate {
    let completed: Int
    let total: Int
    let seconds: Double?
    let sampled: Bool
    var label: String {
        guard let seconds, seconds.isFinite else { return "采样中" }
        if seconds == 0 { return "已完成" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        return minutes >= 60 ? "约\(minutes / 60)小时\(minutes % 60)分钟" : "约\(minutes)分钟"
    }
    static func calculate(total: Int, completed: Int, completedBytes: Double, fallbackBytesPerEpisode: Double?,
                          activeDownloaded: Double, bytesPerSecond: Double) -> SeasonEstimate {
        let total = max(0, total), completed = min(max(0, completed), max(0, total))
        if total > 0 && total == completed { return .init(completed: completed, total: total, seconds: 0, sampled: false) }
        let sampled = completed > 0 && completedBytes > 0
        let average = sampled ? completedBytes / Double(completed) : fallbackBytesPerEpisode
        guard total > 0, let average, average > 0, bytesPerSecond > 0 else {
            return .init(completed: completed, total: total, seconds: nil, sampled: sampled)
        }
        // Allow for size variance and merging; this is an estimate, never a promised finish time.
        let remaining = max(average * 0.1, average * Double(total - completed) - max(0, activeDownloaded))
        return .init(completed: completed, total: total, seconds: remaining / bytesPerSecond, sampled: sampled)
    }
}
