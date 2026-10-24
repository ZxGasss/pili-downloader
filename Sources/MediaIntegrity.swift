import Foundation

struct MediaProbe {
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Double?
    let audioKbps: Int?
    let duration: Double?
    let report: String
}

@MainActor enum MediaIntegrity {
    static func verify(_ file: URL, tools: URL) async throws -> String {
        try await inspect(file, tools: tools).report
    }
    static func inspect(_ file: URL, tools: URL) async throws -> MediaProbe {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw AppFailure.message("成品为空，未标记完成。") }
        var lines: [String] = []
        try await ProcessRunner().run(executable: tools.appendingPathComponent("ffmpeg"),
            arguments: ["-hide_banner", "-nostdin", "-i", file.path], timeout: 30, acceptedExitCodes: [0, 1]) { lines.append($0) }
        let text = lines.joined(separator: "\n")
        guard text.contains("Input #"), text.contains("Video:"), text.contains("Audio:"), text.contains("Duration:"), !text.contains("Duration: N/A") else {
            throw AppFailure.message("成品容器、时长或音视频轨校验失败；保留文件，请检查媒体信息。")
        }
        let report = lines.filter { $0.contains("Duration:") || $0.contains("Video:") || $0.contains("Audio:") }.joined(separator: " | ")
        let videoLine = lines.first(where: { $0.contains("Video:") }) ?? ""
        let audioLine = lines.first(where: { $0.contains("Audio:") }) ?? ""
        let video = captures(#"Video:\s*([A-Za-z0-9_.-]+).*?,\s*(\d{2,5})x(\d{2,5})"#, in: videoLine)
        let audio = captures(#"Audio:\s*([A-Za-z0-9_.-]+).*?(\d+)\s*Hz,\s*([^,]+)"#, in: audioLine)
        let bitrate = captures(#"Audio:.*?(\d+)\s*kb/s"#, in: audioLine).flatMap { Int($0[0]) }
        let duration = captures(#"\bDuration:\s*(\d+):(\d+):([0-9.]+)"#, in: text).flatMap {
            Double($0[0])! * 3600 + Double($0[1])! * 60 + Double($0[2])!
        }
        return MediaProbe(
            height: reportedHeight(in: videoLine),
            videoCodec: video?[0],
            audioCodec: audio?[0],
            audioChannels: audio.map { channelCount($0[2]) },
            audioKbps: bitrate,
            duration: duration,
            report: report
        )
    }
    static func reportedHeight(in videoLine: String) -> Int? {
        guard let values = captures(#"Video:\s*[A-Za-z0-9_.-]+.*?,\s*(\d{2,5})x(\d{2,5})"#, in: videoLine),
              values.count >= 2, let width = Int(values[0]), let height = Int(values[1]) else { return nil }
        return min(width, height)
    }
    static func renameCompleted(_ output: URL, to targetName: String) throws -> URL {
        let directory = output.deletingLastPathComponent()
        let target = directory.appendingPathComponent(targetName)
        if target.standardizedFileURL == output.standardizedFileURL { return output }
        guard !targetName.contains("/"), !targetName.contains(":"), targetName.utf8.count <= 255 else {
            throw AppFailure.message("最终文件名含非法字符或超过255字节。")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw AppFailure.message("已存在同名成品，保留当前文件且不覆盖。")
        }

        let oldStem = output.deletingPathExtension().lastPathComponent
        let sidecarExtensions: Set<String> = ["vtt", "srt", "ass", "ssa", "json", "nfo", "jpg", "jpeg", "png", "webp"]
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        let sidecars = siblings.filter {
            sidecarExtensions.contains($0.pathExtension.lowercased())
                && $0.lastPathComponent.hasPrefix(oldStem + ".")
        }

        var moves = [(output, target)]
        for sidecar in sidecars {
            let suffix = String(sidecar.lastPathComponent.dropFirst(oldStem.count))
            let newName = target.deletingPathExtension().lastPathComponent + suffix
            let destination = directory.appendingPathComponent(newName)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw AppFailure.message("附属文件已存在同名目标，保留当前文件且不覆盖。")
            }
            moves.append((sidecar, destination))
        }

        var completed: [(URL, URL)] = []
        do {
            for (source, destination) in moves {
                try FileManager.default.moveItem(at: source, to: destination)
                completed.append((source, destination))
            }
        } catch {
            for (source, destination) in completed.reversed() where FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: destination, to: source)
            }
            throw error
        }
        return target
    }
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }
    private static func channelCount(_ layout: String) -> Double {
        let value = layout.trimmingCharacters(in: .whitespaces).lowercased()
        if value.contains("stereo") { return 2 }
        if value.contains("mono") { return 1 }
        if value.contains("quad") { return 4 }
        if value.contains("5.1") { return 6 }
        if value.contains("7.1") { return 8 }
        return captures(#"(\d+)\s*channels?"#, in: value).flatMap { Double($0[0]) } ?? 2
    }
    static func preflight(folder: URL, expectedBytes: Int64 = 0) throws {
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw AppFailure.message("保存目录不可写或磁盘已离线，请重新连接并选择目录。") }
        let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        if capacity > 0, capacity < max(100_000_000, expectedBytes) { throw AppFailure.message("磁盘剩余空间不足，请释放空间后继续。") }
    }
}
