import Foundation

/// Stable, UI-independent contract usable by future native clients. Credential data is excluded.
public enum PiliSharedCore {
    public static func partition(episodesJSON: Data, size: Int) throws -> Data {
        let episodes = try JSONDecoder().decode([Episode].self, from: episodesJSON)
        return try JSONEncoder().encode(EpisodeBatches.split(episodes, size: size))
    }
    public static func remainingSeconds(total: Int, completed: Int, completedBytes: Double,
                                        estimatedBytesPerEpisode: Double?, activeDownloaded: Double,
                                        bytesPerSecond: Double) -> Double? {
        SeasonEstimate.calculate(total: total, completed: completed, completedBytes: completedBytes,
            fallbackBytesPerEpisode: estimatedBytesPerEpisode, activeDownloaded: activeDownloaded, bytesPerSecond: bytesPerSecond).seconds
    }
    public static func extractLinks(_ text: String) -> [String] { AdvancedOptions.extractLinks(text) }
    public static func columnCount(availableWidth: Double, largerText: Bool = false) -> Int {
        // Recalculate from the usable window/hinge segment, not a fixed device model or PPI table.
        if availableWidth < (largerText ? 900 : 700) { return 1 }
        return availableWidth >= 1200 && !largerText ? 3 : 2
    }
}
