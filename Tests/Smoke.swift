import Foundation

@main struct Smoke {
    @MainActor static func main() async throws {
        for valid in ["https://www.bilibili.com/video/BV1GJ411x7h7", "https://b23.tv/abc", "https://www.bilibili.com/bangumi/play/ss1376?spm_id_from=333.337.0.0", "https://www.bilibili.com/bangumi/play/ep247270"] { _ = try InputPolicy.videoURL(valid) }
        for invalid in ["http://www.bilibili.com/video/a", "https://bilibili.com.evil.test/video/a", "https://user@www.bilibili.com/video/a", "file:///tmp/video", "https://www.bilibili.com/bangumi/play/epwrong", "https://www.bilibili.com/bangumi/play/ss1376/extra"] {
            do { _ = try InputPolicy.videoURL(invalid); fatalError("Invalid URL accepted") } catch {}
        }
        let season = try InputPolicy.videoURL("https://www.bilibili.com/bangumi/play/ss1376")
        for path in ["/bangumi/media/md1376", "/cheese/play/ss100", "/cheese/play/ep100"] {
            _ = try InputPolicy.videoURL("https://www.bilibili.com" + path)
        }
        precondition(InputPolicy.playlistArguments(url: season, index: 3, all: false).last == "3")
        precondition(InputPolicy.playlistArguments(url: season, index: 3, all: true) == ["--yes-playlist"])
        let progress = TransferProgress.parse("PLPROGRESS| 52.1%|1048576|32|100026")!
        precondition(progress.percent == 52.1 && progress.eta == "00:32")
        let native = TransferProgress.parse("PLPROGRESS|50%|100|2|v|100|200|NA")!
        precondition(native.downloaded == 100 && native.total == 200)
        let parallel = TransferProgress.parse("[#123abc 1048576B/2097152B(50%) CN:8 DL:524288B ETA:2s]")!
        precondition(parallel.percent == 50 && parallel.total == 2097152 && parallel.fragment.contains("8"))
        precondition(DownloadTuning.automaticConnections(cores: 1) == 2)
        precondition(DownloadTuning.automaticConnections(cores: 8) == MemoryBudget.connections)
        precondition(DownloadTuning.automaticConnections(cores: 32) == MemoryBudget.connections)
        precondition(DownloadTuning.connections(100) == MemoryBudget.connections)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M1", physicalCores: 8) == 6)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M3", physicalCores: 8) == 10)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M4 Max", physicalCores: 16) == 16)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M5 Ultra", physicalCores: 32) == 20)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M6", physicalCores: 12) == 20)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M3", physicalCores: 8, cpuLoad: 33) == 12)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M3", physicalCores: 8, cpuLoad: 60) == 10)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M3", physicalCores: 8, cpuLoad: 80) == 8)
        precondition(DownloadTuning.recommendedEpisodes(chip: "Apple M3", physicalCores: 8, cpuLoad: 92) == 6)
        let estimate = SeasonEstimate.calculate(total: 203, completed: 13, completedBytes: 13_000,
                                                fallbackBytesPerEpisode: 1_000, activeDownloaded: 0, bytesPerSecond: 1_000)
        precondition(estimate.seconds != nil && estimate.completed == 13 && estimate.total == 203)
        let safe = InputPolicy.safeLog("ERROR https://cdn.example/a?token=secret SESSDATA=private")
        precondition(!safe.contains("secret") && !safe.contains("private"))
        let clean = InputPolicy.cleanDisplay("完成 BV1GJ411x7h7 ep247270 第1集")
        precondition(!clean.contains("BV1") && !clean.contains("ep247") && clean.contains("第1集"))
        let scanRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pili-existing-\(UUID().uuidString)")
        let scanSeries = scanRoot.appendingPathComponent("家庭教师HITMAN REBORN!")
        try FileManager.default.createDirectory(at: scanSeries, withIntermediateDirectories: true)
        let oldFile = scanSeries.appendingPathComponent("107 未来篇 - S01E107 - 4K - 字幕未检测 [247376].mp4")
        try Data([1, 2, 3]).write(to: oldFile)
        let oldEpisode = Episode(id: "ep247376", index: 107, title: "未来篇X：九死一生", thumbnail: nil,
                                 url: URL(string: "https://www.bilibili.com/bangumi/play/ep247376")!, bvid: nil)
        precondition(FileManager.default.fileExists(atPath: scanSeries.path))
        precondition((try? FileManager.default.contentsOfDirectory(atPath: scanSeries.path).count) == 1)
        precondition(scanRoot.appendingPathComponent(InputPolicy.folderName("家庭教师HITMAN REBORN!")).path == scanSeries.path)
        precondition(((try? FileManager.default.attributesOfItem(atPath: oldFile.path))?[.size] as? NSNumber)?.int64Value == 3)
        precondition(ExistingMedia.filenameMatches(oldFile.deletingPathExtension().lastPathComponent, episode: oldEpisode,
                                                   identifier: oldEpisode.id, title: oldEpisode.title, inSeries: true))
        precondition(ExistingMedia.find(folder: scanRoot, series: "家庭教师HITMAN REBORN!", episode: oldEpisode,
                                        identifier: oldEpisode.id, title: oldEpisode.title)?.standardizedFileURL == oldFile.standardizedFileURL)
        try? FileManager.default.removeItem(at: scanRoot)
        let json = #"{"id":"demo","title":"测试","formats":[{"format_id":"a","vcodec":"none","acodec":"aac"},{"format_id":"v720","height":720,"vcodec":"avc1","acodec":"none"},{"format_id":"drm","height":4320,"vcodec":"hevc","has_drm":true},{"format_id":"v1080","height":1080,"vcodec":"avc1","acodec":"none"}]}"#
        let info = try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
        let episodes = [3, 1, 4, 2].map { n in Episode(id: "ep\(n)", index: n, title: "第\(n)话", thumbnail: nil, url: URL(string: "https://www.bilibili.com/bangumi/play/ep\(n)")!, bvid: nil) }
        let selectedEpisodes = try EpisodeOrder.select(episodes, start: 2, end: 4, all: false)
        let allEpisodes = try EpisodeOrder.select(episodes, start: 1, end: nil, all: true)
        precondition(selectedEpisodes.map(\.index) == [2, 3, 4])
        precondition(allEpisodes.map(\.index) == [1, 2, 3, 4])
        do { _ = try EpisodeOrder.select(episodes, start: 4, end: 2, all: false); fatalError("Bad range accepted") } catch {}
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pili-history-test-\(UUID().uuidString)")
        let historyURL = temp.appendingPathComponent("tasks.json")
        let record = TaskRecord(id: UUID(), address: "https://www.bilibili.com/bangumi/play/ss1376", folder: temp.path,
            video: info, selectedFormat: "v1080", episodes: episodes, currentEpisode: episodes[0], scope: "指定范围", start: 2, end: 4,
            connections: 8, container: "mp4", permission: true, phase: "正在下载", wasRunning: true, completed: [])
        try TaskHistory.write([record], to: historyURL)
        let recovered = try TaskHistory.read(from: historyURL)
        precondition(recovered.count == 1 && recovered[0].id == record.id && recovered[0].wasRunning && recovered[0].end == 4)
        let mode = try FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        let originalHistory = try Data(contentsOf: historyURL)
        // A no-op save should not create backups; the first change preserves exact old bytes.
        try TaskHistory.write([record], to: historyURL)
        let backups = temp.appendingPathComponent("history-backups")
        precondition(!FileManager.default.fileExists(atPath: backups.path))
        try TaskHistory.write([], to: historyURL)
        let snapshots = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        precondition(snapshots.count == 1)
        let snapshotData = try Data(contentsOf: snapshots[0])
        precondition(snapshotData == originalHistory)
        let snapshotMode = try FileManager.default.attributesOfItem(atPath: snapshots[0].path)[.posixPermissions] as! NSNumber
        precondition(snapshotMode.intValue == 0o600)
        try TaskHistory.write([record], to: historyURL)
        let subsequentSnapshots = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        precondition(subsequentSnapshots.count == 1)
        // Simulate a truncated legacy file in an isolated folder, never the user's library.
        let brokenURL = temp.appendingPathComponent("broken.json")
        let brokenData = Data("[{truncated".utf8)
        try brokenData.write(to: brokenURL)
        do { try TaskHistory.write([], to: brokenURL); fatalError("Corrupt history overwritten") } catch {}
        let preservedBrokenData = try Data(contentsOf: brokenURL)
        precondition(preservedBrokenData == brokenData)
        try TaskHistory.appendSourceLog(folder: temp, message: "来源 https://www.bilibili.com/video/BVdemo | BVdemo | 完成")
        precondition(FileManager.default.fileExists(atPath: temp.appendingPathComponent("下载日志.txt").path))
        let safeSource = TaskHistory.publicURL(URL(string: "https://www.bilibili.com/video/BVdemo?p=2&token=private")!)
        precondition(safeSource.contains("p=2") && !safeSource.contains("private"))
        try? FileManager.default.removeItem(at: temp)
        precondition(info.choices.map(\.id) == ["v1080", "v720"])
        precondition(info.choices[0].selector == "v1080+bestaudio")
        var lines: [String] = []
        let runner = ProcessRunner()
        try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["one\\rtwo\\n"], timeout: 4) { lines.append($0) }
        precondition(lines == ["one", "two"])
        do {
            try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 4) { _ in }
            fatalError("Nonzero exit accepted")
        } catch {}
        precondition(AdvancedOptions.extractLinks("分享 https://www.bilibili.com/video/BVdemo?tracking=1 和 https://www.bilibili.com/video/BVdemo").count == 1)
        let indexes = try AdvancedOptions.selection("1,3,5-7", maximum: 8)
        let collectionData = try Data(contentsOf: URL(fileURLWithPath: ".cache/ugc-BV1QMTv6uE45.json"))
        let collection = try EpisodeOrder.parseVideoCollection(collectionData)
        precondition(collection.count == 48 && collection.map(\.index) == Array(1...48))
        precondition(collection[0].cid != nil)
        precondition(EpisodeOrder.current(in: collection, source: URL(string: "https://www.bilibili.com/video/BV1QMTv6uE45?tracking=1")!)?.index == 2)
        precondition(EpisodeOrder.current(in: collection, source: URL(string: "https://www.bilibili.com/video/av116844501405113")!)?.index == 2)
        let collectionRange = try EpisodeOrder.select(collection, start: 2, end: 4, all: false)
        precondition(collectionRange.map(\.index) == [2,3,4])
        precondition(TransferFailure.describe(status: 1, rows: ["ERROR: Connection reset by peer"]).contains("网络连接中断"))
        precondition(TransferFailure.describe(status: 1, rows: ["ERROR: HTTP Error 412"]).contains("人机验证"))
        precondition(!TransferFailure.describe(status: 1, rows: ["ERROR: HTTP Error 403"]).contains("登录"))
        precondition(TransferFailure.describe(status: 1, rows: ["ERROR: No space left on device"]).contains("空间不足"))
        precondition(InputPolicy.folderName("..") == "未命名合集")
        precondition(!InputPolicy.folderName("../越界").contains("/"))
        let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pili-legacy-\(UUID().uuidString)")
        let legacySeries = legacyRoot.appendingPathComponent("自制合集")
        try FileManager.default.createDirectory(at: legacySeries, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: legacySeries.appendingPathComponent("旧标题 - S01E02 - 4K - 字幕未检测 [123].f30125.mp4.part"))
        let legacyItem = Episode(id: "ep123", index: 2, title: "新标题", thumbnail: nil, url: URL(string: "https://www.bilibili.com/bangumi/play/ep123")!, bvid: nil)
        precondition(LegacyResume.template(folder: legacyRoot, series: "自制合集", episode: legacyItem) == "自制合集/旧标题 - S01E02 - 4K - 字幕未检测 [123].%(ext)s")
        let unrelated = Episode(id: "ep456", index: 3, title: "其他", thumbnail: nil, url: URL(string: "https://www.bilibili.com/bangumi/play/ep456")!, bvid: nil)
        precondition(LegacyResume.template(folder: legacyRoot, series: "自制合集", episode: unrelated) == nil)
        try FileManager.default.removeItem(at: legacyRoot)
        let avURL = try InputPolicy.videoURL("av8749329")
        let bvURL = try InputPolicy.videoURL("bv1vx411y7Un")
        precondition(avURL.lastPathComponent == "av8749329" && bvURL.lastPathComponent == "BV1vx411y7Un")
        precondition(indexes == [1,3,5,6,7])
        var naming = AdvancedOptions()
        for (width, height, expected) in [(3840, 2160, 2160), (2160, 3840, 2160), (1920, 1080, 1080), (7680, 4320, 4320), (3840, 1600, 1600)] {
            let formatData = Data("{\"format_id\":\"resolution-test\",\"width\":\(width),\"height\":\(height)}".utf8)
            let sample = try JSONDecoder().decode(MediaFormat.self, from: formatData)
            precondition(sample.resolutionHeight == expected)
            precondition(sample.label.contains("\(expected)p"))
            precondition(naming.outputName(format: sample, episode: nil).contains("\(expected)p"))
            precondition(MediaIntegrity.reportedHeight(in: "Stream #0:0: Video: h264, yuv420p, \(width)x\(height), 24 fps") == expected)
        }
        let widthOnly = try JSONDecoder().decode(MediaFormat.self, from: Data(#"{"format_id":"width-only","width":3840}"#.utf8))
        precondition(widthOnly.resolutionHeight == nil)
        precondition(naming.outputName(format: widthOnly, episode: nil).contains("分辨率未知"))
        precondition(naming.outputName(format: info.choices[0], episode: nil).contains("1080p"))
        precondition(!naming.filename.contains("B.%(ext)"))
        let legacyOptions = try JSONDecoder().decode(AdvancedOptions.self, from: Data("{}".utf8))
        precondition(legacyOptions.movieNamingEnabled)
        naming.movieNaming = true
        precondition(naming.outputName(format: info.choices[0], episode: nil).contains("1080p"))
        precondition(!naming.outputName(format: info.choices[0], episode: nil).contains("字幕未检测"))
        precondition(!naming.outputName(format: info.choices[0], episode: nil).contains("%(id)"))
        let namingInfo = try JSONDecoder().decode(VideoInfo.self, from: Data(#"{"id":"n","title":"测试","formats":[{"format_id":"v","height":2160,"vcodec":"hevc","acodec":"none","filesize":120000000},{"format_id":"a","vcodec":"none","acodec":"aac","audio_channels":2,"filesize":3400000}]}"#.utf8))
        let namingEpisode = Episode(id: "ep1", index: 1, title: "第1话 剧情标题", thumbnail: nil,
                                    url: URL(string: "https://www.bilibili.com/bangumi/play/ep1")!, bvid: nil)
        precondition(naming.outputName(format: namingInfo.choices[0], episode: namingEpisode,
                                       audio: namingInfo.audioChoices[0], duration: 1200)
            == "001 - 剧情标题 - 2160p HEVC - AAC 2.0 - 117.7MB.%(ext)s")
        precondition(naming.finalOutputName(
            title: "第1话 剧情标题", episodeIndex: 1, height: 2160,
            videoCodec: "h264", audioCodec: "aac", audioChannels: 2,
            audioKbps: 320, bytes: 761_176_012, ext: "MP4"
        ) == "001 - 剧情标题 - 2160p H.264 - AAC 2.0 - 725.9MB.mp4")
        naming.movieNaming = false
        precondition(!naming.movieNamingEnabled)
        do {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"], timeout: 5, idleTimeout: 0.2) { _ in }
            fatalError("Stalled process accepted")
        } catch AppFailure.transferStalled { }
        try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; print('[Merger] Owned fixture merge', flush=True); time.sleep(1.5)"], timeout: 5, idleTimeout: 0.2) { _ in }
        let special = try JSONDecoder().decode(VideoInfo.self, from: Data(#"{"id":"special","title":"规格测试","formats":[{"format_id":"v1","dynamic_range":"DV","vcodec":"hevc","height":2160},{"format_id":"v2","dynamic_range":"HDR10","vcodec":"hevc","height":2160},{"format_id":"30251","vcodec":"none","acodec":"flac","asr":96000}]}"#.utf8))
        precondition(special.choices.contains { $0.label.contains("杜比视界") })
        precondition(special.choices.contains { $0.label.contains("HDR10") })
        precondition(special.audioChoices[0].audioLabel.contains("Hi-Res") && special.audioChoices[0].audioLabel.contains("96.0"))
        print("PASS: range/order/history/source/security/process; smart links/custom selection; default movie naming and final-size rename; DV/HDR10/Hi-Res labels")
    }
}
