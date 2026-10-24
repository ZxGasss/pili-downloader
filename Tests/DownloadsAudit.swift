import Foundation

@main struct DownloadsAudit {
    static func main() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: String(CommandLine.arguments[1]), isDirectory: true)
            : home.appendingPathComponent("Downloads", isDirectory: true)
        let source = URL(string: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "https://www.bilibili.com/bangumi/play/ss1376")!
        let episodes = try await EpisodeCatalogue.load(url: source, cookies: [])
        var found = 0
        var missing: [Int] = []
        for episode in episodes {
            let series = episode.series ?? ""
            if ExistingMedia.find(folder: folder, series: series, episode: episode, identifier: episode.id, title: episode.title) != nil {
                found += 1
            } else {
                missing.append(episode.index)
            }
        }
        print("DOWNLOAD_AUDIT total=\(episodes.count) existing=\(found) missing=\(missing.count)")
        print("MISSING_EPISODES", missing.map(String.init).joined(separator: ","))
    }
}
