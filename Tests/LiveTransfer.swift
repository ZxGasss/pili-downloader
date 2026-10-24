import Foundation

/// A small, unauthenticated public clip. Never reads the user's account or download folder.
@main struct LiveTransfer {
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let info = try JSONDecoder().decode(VideoInfo.self, from: Data(contentsOf: URL(fileURLWithPath: "work/network-probe-safe.json")))
            guard let format = info.choices.last else { throw AppFailure.message("没有公开可下载格式。") }
            let tools = URL(fileURLWithPath: "work/deps", isDirectory: true)
            let engine = DownloadBackend(tools: tools)
            var output: URL?
            var options = AdvancedOptions()
            options.audioID = info.audioChoices.last?.id ?? ""
            try await engine.download(url: URL(string: "https://www.bilibili.com/video/BV1QMTv6uE45")!, format: format,
                folder: root, cookies: [], allParts: false, container: "mp4", connections: 1,
                audioFormat: info.audioChoices.last, duration: info.duration, options: options) { row in
                    if row.hasPrefix("PLFILE:") { output = URL(fileURLWithPath: String(row.dropFirst(7))) }
                }
            guard let output else { throw AppFailure.message("未取得最终文件。") }
            let probe = try await MediaIntegrity.inspect(output, tools: tools)
            let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! NSNumber).int64Value
            let name = options.finalOutputName(title: "公开短片链路验收", episodeIndex: 1, height: probe.height,
                videoCodec: probe.videoCodec, audioCodec: probe.audioCodec, audioChannels: probe.audioChannels,
                audioKbps: probe.audioKbps, bytes: bytes, ext: "mp4")
            let final = try MediaIntegrity.renameCompleted(output, to: name)
            let residuals = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { ["part", "aria2", "ytdl"].contains($0.pathExtension) }
            guard residuals.isEmpty else { throw AppFailure.message("真实下载仍有残留，需检查。") }
            print("LIVE_TRANSFER_PASS bytes=\(bytes) resolution=\(probe.height ?? 0)p video=\(probe.videoCodec ?? "unknown") audio=\(probe.audioCodec ?? "unknown") residuals=0")
            print("OUTPUT " + final.lastPathComponent)
        } catch {
            FileHandle.standardError.write(Data(("LIVE_TRANSFER_FAILED " + InputPolicy.safeLog(error.localizedDescription) + "\n").utf8))
            exit(1)
        }
    }
}
