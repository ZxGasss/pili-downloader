import Foundation
import CryptoKit

enum MediaCategory: String, Codable, CaseIterable {
    case animation = "动画"
    case movie = "电影"
    case series = "剧集"
    case folder = "文件夹"
    case pending = "待确认"
}

struct MediaClassification: Codable, Identifiable {
    var id: String { path }
    let path: String
    let category: MediaCategory
    let confidence: Double
    let reasons: [String]
    let duration: Double?
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
}

struct MediaClassificationReport: Codable {
    let root: String
    let generatedAt: Date
    let total: Int
    let counts: [String: Int]
    let items: [MediaClassification]
}

struct MediaRenameItem: Codable, Identifiable {
    var id: String { oldPath }
    let oldPath: String
    let newPath: String
}

struct MediaRenamePlan: Codable {
    let root: String
    let generatedAt: Date
    let items: [MediaRenameItem]
}

struct MediaFolderPlanItem: Codable, Identifiable {
    var id: String { oldPath }
    let oldPath: String
    let newPath: String
    let category: String
    let duplicate: Bool
}

struct MediaFolderPlan: Codable {
    let root: String
    let generatedAt: Date
    let items: [MediaFolderPlanItem]
}

enum MediaRuleClassifier {
    private static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "flv"]
    private static let animationWords = ["动画", "动漫", "番剧", "国漫", "日漫", "anime", "cartoon"]
    private static let movieWords = ["电影", "影片", "movie", "films", "剧场版"]
    private static let seriesWords = ["电视剧", "剧集", "连续剧", "tv series", "season"]

    static func scan(folder: URL, ffmpeg: URL?) async -> MediaClassificationReport {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var files: [URL] = []
            while let file = enumerator?.nextObject() as? URL, files.count < 5000 {
                guard videoExtensions.contains(file.pathExtension.lowercased()) else { continue }
                files.append(file)
            }
            if files.isEmpty {
                let item = MediaClassification(path: folder.path, category: .folder, confidence: 1,
                                               reasons: ["目录中没有可识别的视频文件"], duration: nil, width: nil, height: nil,
                                               videoCodec: nil, audioCodec: nil)
                return report(root: folder, items: [item])
            }
            let groups = Dictionary(grouping: files) { $0.deletingLastPathComponent().path }
            var items: [MediaClassification] = []
            for file in files {
                let relative = file.path.replacingOccurrences(of: folder.path + "/", with: "")
                var decision = classify(relativePath: relative, duration: nil, siblingCount: groups[file.deletingLastPathComponent().path]?.count ?? 1)
                var metadata = MediaMetadata()
                if decision.category == .pending, let ffmpeg {
                    metadata = probe(file: file, ffmpeg: ffmpeg)
                    decision = classify(relativePath: relative, duration: metadata.duration,
                                        siblingCount: groups[file.deletingLastPathComponent().path]?.count ?? 1)
                }
                items.append(MediaClassification(path: relative, category: decision.category, confidence: decision.confidence,
                                                 reasons: decision.reasons, duration: metadata.duration, width: metadata.width,
                                                 height: metadata.height, videoCodec: metadata.videoCodec, audioCodec: metadata.audioCodec))
            }
            return report(root: folder, items: items)
        }.value
    }

    static func classify(relativePath: String, duration: Double?, siblingCount: Int) -> (category: MediaCategory, confidence: Double, reasons: [String]) {
        let lower = relativePath.lowercased()
        let name = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        if animationWords.contains(where: lower.contains) {
            return (.animation, 0.96, ["路径包含动画分类关键词"])
        }
        if movieWords.contains(where: lower.contains) {
            return (.movie, 0.94, ["路径包含电影分类关键词"])
        }
        if seriesWords.contains(where: lower.contains) {
            return (.series, 0.94, ["路径包含剧集分类关键词"])
        }
        if hasEpisodeMarker(name) {
            return (.series, 0.86, ["文件名含季集或集数编号"])
        }
        if siblingCount > 1 {
            return (.series, 0.72, ["同目录存在多个视频文件，按剧集聚合"])
        }
        if let duration, duration >= 40 * 60 {
            return (.movie, 0.82, ["单个长视频且时长达40分钟以上"])
        }
        return (.pending, 0.35, ["缺少标题、分类路径、季集编号或足够媒体信息"])
    }

    static func save(_ report: MediaClassificationReport, to folder: URL) throws -> (json: URL, csv: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let json = folder.appendingPathComponent("媒体分类报告.json")
        try encoder.encode(report).write(to: json, options: .atomic)
        let csv = folder.appendingPathComponent("媒体分类报告.csv")
        var rows = ["相对路径,分类,置信度,原因,时长秒,宽,高,视频编码,音频编码"]
        for item in report.items {
            let confidence = String(format: "%.2f", item.confidence)
            let duration = item.duration.map { String(format: "%.3f", $0) } ?? ""
            let raw = [item.path, item.category.rawValue, confidence, item.reasons.joined(separator: "；"),
                       duration, item.width.map(String.init) ?? "", item.height.map(String.init) ?? "",
                       item.videoCodec ?? "", item.audioCodec ?? ""]
            let fields = raw.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            rows.append(fields.joined(separator: ","))
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
        return (json, csv)
    }

    private static func report(root: URL, items: [MediaClassification]) -> MediaClassificationReport {
        var counts: [String: Int] = [:]
        for item in items { counts[item.category.rawValue, default: 0] += 1 }
        return MediaClassificationReport(root: root.path, generatedAt: Date(), total: items.count, counts: counts, items: items)
    }

    private static func hasEpisodeMarker(_ name: String) -> Bool {
        name.range(of: #"(?i)(?:S\d+E\d+|第\s*\d+\s*[集话]|(?:EP?|E)\s*\d+)"#, options: .regularExpression) != nil
            || name.range(of: #"^\d{1,3}\s*[-_. ]"#, options: .regularExpression) != nil
    }

    struct MediaMetadata {
        var probed = false
        var duration: Double?
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?
        var audioChannels: Int?
    }

    static func probe(file: URL, ffmpeg: URL?) -> MediaMetadata {
        guard let ffmpeg else { return MediaMetadata() }
        let process = Process(), pipe = Pipe()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-i", file.path]
        process.standardOutput = pipe; process.standardError = pipe
        guard (try? process.run()) != nil else { return MediaMetadata() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        var result = MediaMetadata(probed: true)
        if let match = first(text, #"Duration:\s*(\d+):(\d+):([0-9.]+)"#) {
            result.duration = Double(match[0])! * 3600 + Double(match[1])! * 60 + Double(match[2])!
        }
        if let line = text.split(separator: "\n").first(where: { $0.contains("Video:") }),
           let match = first(String(line), #"(\d{2,5})x(\d{2,5})"#) {
            result.width = Int(match[0]); result.height = Int(match[1])
        }
        if let line = text.split(separator: "\n").first(where: { $0.contains("Video:") }) {
            result.videoCodec = String(line).components(separatedBy: "Video:").last?.split(separator: " ").first.map(String.init)
        }
        if let line = text.split(separator: "\n").first(where: { $0.contains("Audio:") }) {
            let value = String(line)
            result.audioCodec = value.components(separatedBy: "Audio:").last?.split(separator: " ").first.map(String.init)
            if let match = first(value, #"(\d+)\s+channels"#) {
                result.audioChannels = Int(match[0])
            } else if value.contains("stereo") {
                result.audioChannels = 2
            } else if value.contains("mono") {
                result.audioChannels = 1
            }
        }
        return result
    }

    private static func first(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

enum MediaLibraryOrganizer {
    static func plan(folder: URL, ffmpeg: URL?, includeUnchanged: Bool = false) async -> MediaRenamePlan {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var files: [URL] = []
            while let file = enumerator?.nextObject() as? URL, files.count < 5000 {
                if ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "flv"].contains(file.pathExtension.lowercased()) {
                    files.append(file)
                }
            }
            var items: [MediaRenameItem] = []
            for (_, group) in Dictionary(grouping: files, by: { $0.deletingLastPathComponent().path }) {
                var used = Set<Int>()
                let ordered = group.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for (offset, file) in ordered.enumerated() {
                    let metadata = MediaRuleClassifier.probe(file: file, ffmpeg: ffmpeg)
                    let detected = episodeNumber(file.deletingPathExtension().lastPathComponent)
                    var number = detected ?? (offset + 1)
                    while !used.insert(number).inserted { number += 1 }
                    let size = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    let target = file.deletingLastPathComponent().appendingPathComponent(
                        targetName(number: number, title: title(file.deletingPathExtension().lastPathComponent),
                                   metadata: metadata, size: size, ext: file.pathExtension.lowercased()))
                    if includeUnchanged || target.path != file.path { items.append(.init(oldPath: file.path, newPath: target.path)) }
                }
            }
            return MediaRenamePlan(root: folder.path, generatedAt: Date(), items: items)
        }.value
    }

    static func folderPlan(folder: URL, ffmpeg: URL?) async -> MediaFolderPlan {
        let rename = await plan(folder: folder, ffmpeg: ffmpeg, includeUnchanged: true)
        let classification = await MediaRuleClassifier.scan(folder: folder, ffmpeg: ffmpeg)
        let categories = Dictionary(uniqueKeysWithValues: classification.items.map { ($0.path, $0.category) })
        let sourcePaths = Set(rename.items.map(\.oldPath))
        let grouped = Dictionary(grouping: rename.items) { item -> String in
            let relative = item.oldPath.replacingOccurrences(of: folder.path + "/", with: "")
            let category = categories[relative] ?? .pending
            return folder.appendingPathComponent(category.rawValue).appendingPathComponent(URL(fileURLWithPath: item.newPath).lastPathComponent).path
        }
        var items: [MediaFolderPlanItem] = []
        let fm = FileManager.default
        for (targetPath, rows) in grouped {
            if rows.count == 1, let only = rows.first, only.oldPath == targetPath { continue }
            var used = Set<String>()
            var hashes: [String: String] = [:]
            for row in rows.sorted(by: { $0.oldPath.localizedStandardCompare($1.oldPath) == .orderedAscending }) {
                let source = URL(fileURLWithPath: row.oldPath)
                let originalTarget = URL(fileURLWithPath: targetPath)
                let relative = row.oldPath.replacingOccurrences(of: folder.path + "/", with: "")
                let category = categories[relative] ?? .pending
                if source.standardizedFileURL == originalTarget.standardizedFileURL {
                    used.insert(source.path)
                    continue
                }
                var destination = originalTarget
                var duplicate = false
                let occupiedByOther = fm.fileExists(atPath: destination.path) && !sourcePaths.contains(destination.path)
                if let firstHash = hashes[originalTarget.path] {
                    let same = digest(source) == firstHash
                    if same {
                        duplicate = true
                        destination = folder.appendingPathComponent("重复文件").appendingPathComponent(category.rawValue).appendingPathComponent(originalTarget.lastPathComponent)
                    } else {
                        destination = uniqueDestination(originalTarget, used: &used)
                    }
                } else if occupiedByOther {
                    let same = digest(source) == digest(originalTarget)
                    if same {
                        duplicate = true
                        destination = folder.appendingPathComponent("重复文件").appendingPathComponent(category.rawValue).appendingPathComponent(originalTarget.lastPathComponent)
                    } else {
                        destination = uniqueDestination(originalTarget, used: &used)
                    }
                } else {
                    hashes[originalTarget.path] = digest(source)
                }
                destination = uniqueDestination(destination, used: &used)
                if destination.path != row.oldPath {
                    items.append(.init(oldPath: row.oldPath, newPath: destination.path, category: category.rawValue, duplicate: duplicate))
                }
            }
        }
        return MediaFolderPlan(root: folder.path, generatedAt: Date(), items: items)
    }

    static func save(_ plan: MediaFolderPlan, to folder: URL) throws -> (json: URL, csv: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let json = folder.appendingPathComponent("文件夹整理计划.json")
        try encoder.encode(plan).write(to: json, options: .atomic)
        let csv = folder.appendingPathComponent("文件夹整理计划.csv")
        var rows = ["原路径,新路径,分类,重复文件"]
        rows += plan.items.map { item in
            [item.oldPath, item.newPath, item.category, item.duplicate ? "是" : "否"]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
        return (json, csv)
    }

    static func apply(_ plan: MediaFolderPlan) throws -> Int {
        let fm = FileManager.default
        let sources = Set(plan.items.map(\.oldPath))
        guard Set(plan.items.map(\.newPath)).count == plan.items.count else {
            throw AppFailure.message("整理计划有重复目标，未执行。")
        }
        for item in plan.items {
            let target = URL(fileURLWithPath: item.newPath)
            guard !fm.fileExists(atPath: target.path) || sources.contains(target.path) else {
                throw AppFailure.message("目标已存在，未执行整理：\(target.lastPathComponent)")
            }
        }
        var temporary: [(URL, URL, URL)] = []
        do {
            for item in plan.items {
                let source = URL(fileURLWithPath: item.oldPath), target = URL(fileURLWithPath: item.newPath)
                let temp = source.deletingLastPathComponent()
                    .appendingPathComponent(".pili-organize-\(UUID().uuidString).\(source.pathExtension)")
                try fm.moveItem(at: source, to: temp)
                temporary.append((source, temp, target))
            }
            for (_, temp, target) in temporary {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temp, to: target)
            }
            return plan.items.count
        } catch {
            for (source, temp, target) in temporary.reversed() {
                if fm.fileExists(atPath: target.path) { try? fm.moveItem(at: target, to: source) }
                else if fm.fileExists(atPath: temp.path) { try? fm.moveItem(at: temp, to: source) }
            }
            throw error
        }
    }

    private static func uniqueDestination(_ proposed: URL, used: inout Set<String>) -> URL {
        let fm = FileManager.default
        var value = proposed, counter = 2
        while used.contains(value.path) || fm.fileExists(atPath: value.path) {
            let base = proposed.deletingPathExtension().lastPathComponent
            value = proposed.deletingLastPathComponent()
                .appendingPathComponent("\(base) (\(counter)).\(proposed.pathExtension)")
            counter += 1
        }
        used.insert(value.path)
        return value
    }

    private static func digest(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ plan: MediaRenamePlan, to folder: URL) throws -> (json: URL, csv: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let json = folder.appendingPathComponent("媒体重命名计划.json")
        try encoder.encode(plan).write(to: json, options: .atomic)
        let csv = folder.appendingPathComponent("媒体重命名计划.csv")
        var rows = ["原路径,新路径"]
        rows += plan.items.map { item in
            [item.oldPath, item.newPath].map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
        return (json, csv)
    }

    static func apply(_ plan: MediaRenamePlan) throws -> Int {
        let fm = FileManager.default
        let targets = plan.items.map(\.newPath)
        guard Set(targets).count == targets.count else { throw AppFailure.message("重命名计划有重复目标，未执行。") }
        let sources = Set(plan.items.map(\.oldPath))
        for target in targets where fm.fileExists(atPath: target) && !sources.contains(target) {
            throw AppFailure.message("目标文件已存在，未执行任何重命名：\(URL(fileURLWithPath: target).lastPathComponent)")
        }
        var temporary: [(URL, URL)] = []
        do {
            for item in plan.items {
                let source = URL(fileURLWithPath: item.oldPath), target = URL(fileURLWithPath: item.newPath)
                let temp = source.deletingLastPathComponent().appendingPathComponent(".pili-rename-\(UUID().uuidString).\(source.pathExtension)")
                try fm.moveItem(at: source, to: temp)
                temporary.append((temp, target))
            }
            for (temp, target) in temporary { try fm.moveItem(at: temp, to: target) }
            return plan.items.count
        } catch {
            for (temp, target) in temporary.reversed() {
                if fm.fileExists(atPath: target.path) { try? fm.moveItem(at: target, to: temp) }
                if fm.fileExists(atPath: temp.path) {
                    let original = plan.items.first { $0.newPath == target.path }.map { URL(fileURLWithPath: $0.oldPath) }
                    if let original { try? fm.moveItem(at: temp, to: original) }
                }
            }
            throw error
        }
    }

    static func targetName(number: Int, title: String, metadata: MediaRuleClassifier.MediaMetadata,
                           size: Int64, ext: String) -> String {
        let shortSide = [metadata.width, metadata.height].compactMap { $0 }.min()
        let resolution = shortSide.map { "\($0)p" } ?? "分辨率未知"
        let video = codec(metadata.videoCodec, fallback: "编码未知")
        let audioName = metadata.audioCodec.map { codec($0, fallback: "音频") } ?? (metadata.probed ? "无音频" : "音频未知")
        let channels = metadata.audioChannels.map { String(format: "%.1f", Double($0)) } ?? "声道未知"
        let audio = metadata.audioCodec == nil ? audioName : "\(audioName) \(channels)"
        let mb = Double(size) / 1_000_000
        let sizeText = mb >= 1000 ? String(format: "%.2fGB", mb / 1000) : String(format: "%.1fMB", mb)
        return String(format: "%03d", number) + " - \(title) - \(resolution) \(video) - \(audio) - \(sizeText).\(ext)"
    }

    private static func title(_ stem: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,3}\s*-\s*(.*?)\s*-\s*\d{3,4}p\s+"#),
           let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let range = Range(match.range(at: 1), in: stem) {
            return cleanTitle(String(stem[range]))
        }
        let parts = stem.components(separatedBy: " - ")
        let candidate = parts.max { score($0) < score($1) } ?? stem
        return cleanTitle(candidate)
    }

    private static func cleanTitle(_ value: String) -> String {
        var title = value
            .replacingOccurrences(of: #"^\d{1,3}\s*[-_. ]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^(?:S\d+E\d+|第\s*\d+\s*[集话]|EP?\s*\d+)\s*[-_. ：:]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[\d{5,}\]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "未命名" }
        return InputPolicy.folderName(String(title.prefix(100)))
    }

    private static func score(_ value: String) -> Int { value.filter { $0.isLetter || $0.isNumber }.count }
    private static func episodeNumber(_ name: String) -> Int? {
        for pattern in [#"(?i)S\d+E(\d+)"#, #"第\s*(\d+)\s*[集话]"#, #"(?i)^EP?\s*(\d+)"#, #"^(\d{1,3})\s*[-_. ]"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let range = Range(match.range(at: 1), in: name) { return Int(name[range]) }
        }
        return nil
    }
    private static func codec(_ value: String?, fallback: String) -> String {
        let raw = value?.lowercased() ?? ""
        if raw.contains("av01") || raw.hasPrefix("av1") { return "AV1" }
        if raw.contains("hev") || raw.contains("hvc") || raw.contains("hevc") { return "HEVC" }
        if raw.contains("avc") || raw.contains("h264") { return "H.264" }
        if raw.contains("flac") { return "FLAC" }
        if raw.contains("opus") { return "Opus" }
        if raw.contains("eac3") || raw.contains("ec-3") { return "E-AC-3" }
        if raw.contains("ac3") || raw.contains("ac-3") { return "AC-3" }
        if raw.contains("aac") || raw.contains("mp4a") { return "AAC" }
        return raw.isEmpty ? fallback : raw.uppercased()
    }
}
