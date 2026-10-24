import Foundation

@main struct Integration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: ".cache/season1376-1.3.json"))
        let episodes = try EpisodeOrder.parseSeason(data)
        precondition(episodes.count == 203)
        let selected = try EpisodeOrder.select(episodes, start: 2, end: 4, all: false)
        precondition(selected.map(\.id) == ["ep247271", "ep247272", "ep247273"])
        precondition(selected.allSatisfy { $0.coverURL?.scheme == "https" })
        let backend = DownloadBackend(tools: root.appendingPathComponent("tools"))
        let metadata = #"{"id":"fixture","title":"自制测试视频","formats":[{"format_id":"v","vcodec":"h264","acodec":"none","height":1080}]}"#
        let format = try JSONDecoder().decode(VideoInfo.self, from: Data(metadata.utf8)).choices[0]
        var currentIDs: [String] = [], files: [String] = []
        for episode in selected {
            try await backend.download(url: episode.url, format: format, folder: root, cookies: [], allParts: false,
                container: "mp4", connections: 1, orderedEpisode: episode) { line in
                if line.hasPrefix("PLITEM:"), let data = String(line.dropFirst(7)).data(using: .utf8),
                   let info = try? JSONDecoder().decode(VideoInfo.self, from: data) {
                    currentIDs.append(info.id)
                    precondition(info.title.contains("测试")); precondition(info.coverURL != nil)
                }
                if line.hasPrefix("PLFILE:") { files.append(String(line.dropFirst(7))) }
            }
        }
        precondition(currentIDs == selected.map(\.id))
        precondition(files.count == 3 && files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n")
        precondition(calls.count == 3)
        for (index, call) in calls.enumerated() {
            let args = try JSONDecoder().decode([String].self, from: Data(call.utf8))
            precondition(args.contains("--continue") && args.contains("--no-overwrites") && args.contains("--no-playlist"))
            precondition(args.last == selected[index].url.absoluteString)
            let template = args[args.firstIndex(of: "-o")! + 1]
            precondition(template.contains(String(format: "%02d", index + 2) + " - "))
        }
        print("PASS: official 203-episode order; 2–4 URLs; realtime metadata events/cover/title; sequential outputs; resume flags")
    }
}
