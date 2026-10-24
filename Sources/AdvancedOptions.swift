import Foundation

struct AdvancedOptions: Codable {
    var rateMiB = 0
    var retries = 2
    var subtitle = false
    var danmaku = false
    var subtitleLanguages = "zh.*,en"
    var thumbnail = false
    var metadata = false
    var nfo = false
    var keepStreams = false
    var preset = "最高画质"
    var customEpisodes = ""
    var filename = "%(title)s.%(ext)s"
    var audioID = ""
    var movieNaming: Bool? = nil
    var episodeBatchSize: Int? = nil
    var simultaneousBatches: Int? = nil
    var autoRecover: Bool? = nil
    var movieNamingEnabled: Bool { movieNaming ?? true }
    private enum CodingKeys: String, CodingKey {
        case rateMiB, retries, subtitle, danmaku, subtitleLanguages, thumbnail, metadata, nfo, keepStreams
        case preset, customEpisodes, filename, audioID, movieNaming, episodeBatchSize, simultaneousBatches, autoRecover
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rateMiB = try values.decodeIfPresent(Int.self, forKey: .rateMiB) ?? 0
        retries = try values.decodeIfPresent(Int.self, forKey: .retries) ?? 2
        subtitle = try values.decodeIfPresent(Bool.self, forKey: .subtitle) ?? false
        danmaku = try values.decodeIfPresent(Bool.self, forKey: .danmaku) ?? false
        subtitleLanguages = try values.decodeIfPresent(String.self, forKey: .subtitleLanguages) ?? "zh.*,en"
        thumbnail = try values.decodeIfPresent(Bool.self, forKey: .thumbnail) ?? false
        metadata = try values.decodeIfPresent(Bool.self, forKey: .metadata) ?? false
        nfo = try values.decodeIfPresent(Bool.self, forKey: .nfo) ?? false
        keepStreams = try values.decodeIfPresent(Bool.self, forKey: .keepStreams) ?? false
        preset = try values.decodeIfPresent(String.self, forKey: .preset) ?? "最高画质"
        customEpisodes = try values.decodeIfPresent(String.self, forKey: .customEpisodes) ?? ""
        filename = try values.decodeIfPresent(String.self, forKey: .filename) ?? "%(title)s.%(ext)s"
        audioID = try values.decodeIfPresent(String.self, forKey: .audioID) ?? ""
        movieNaming = try values.decodeIfPresent(Bool.self, forKey: .movieNaming)
        episodeBatchSize = try values.decodeIfPresent(Int.self, forKey: .episodeBatchSize)
        simultaneousBatches = try values.decodeIfPresent(Int.self, forKey: .simultaneousBatches)
        autoRecover = try values.decodeIfPresent(Bool.self, forKey: .autoRecover)
    }
    func outputName(format: MediaFormat, episode: Episode?, audio: MediaFormat? = nil, duration: Double? = nil) -> String {
        guard movieNamingEnabled else { return filename }
        let height = format.resolutionHeight ?? 0
        let resolution = height > 0 ? "\(height)p" : "分辨率未知"
        let number = String(format: "%03d", episode?.index ?? 1)
        let title = episode == nil ? "%(title)s" : Self.cleanTitle(episode!.title)
        let videoCodec = Self.videoCodec(format.vcodec)
        let audioCodec = Self.audioCodec(audio ?? (format.acodec == "none" ? nil : format))
        let size = Self.mediaSize(video: format, audio: audio, duration: duration)
        return "\(number) - \(title) - \(resolution) \(videoCodec) - \(audioCodec) - \(size).%(ext)s"
    }
    func finalOutputName(title: String, episodeIndex: Int, height: Int?, videoCodec: String?,
                         audioCodec: String?, audioChannels: Double?, audioKbps: Int?,
                         bytes: Int64, ext: String) -> String {
        let resolution = height.map { "\($0)p" } ?? "分辨率未知"
        let audio = Self.audioSpec(codec: audioCodec, channels: audioChannels, kbps: audioKbps)
        let size = String(format: "%.1fMB", Double(bytes) / 1_048_576)
        return "\(String(format: "%03d", episodeIndex)) - \(Self.cleanTitle(title))"
            + " - \(resolution) \(Self.videoCodec(videoCodec)) - \(audio) - \(size).\(ext.lowercased())"
    }
    static func cleanTitle(_ title: String) -> String {
        InputPolicy.folderName(
            title.replacingOccurrences(of: #"^第[0-9]+[话集]\s*"#,
                                       with: "", options: .regularExpression)
        )
    }
    private static func videoCodec(_ value: String?) -> String {
        let codec = value?.lowercased() ?? ""
        if codec.contains("av01") || codec.hasPrefix("av1") { return "AV1" }
        if codec.contains("hev") || codec.contains("hvc") || codec.contains("hevc") { return "HEVC" }
        if codec.contains("avc") || codec.contains("h264") { return "H.264" }
        if codec.contains("vp9") { return "VP9" }
        return codec.isEmpty ? "编码未知" : codec.uppercased()
    }
    private static func audioCodec(_ format: MediaFormat?) -> String {
        guard let format else { return "无音频" }
        let codec = (format.acodec ?? format.ext ?? "").lowercased()
        let name = codec.contains("flac") ? "FLAC" : codec.contains("opus") ? "Opus"
            : codec.contains("ec-3") || codec.contains("eac3") ? "E-AC-3"
            : codec.contains("ac-3") || codec.contains("ac3") ? "AC-3"
            : codec.contains("aac") || codec.contains("mp4a") ? "AAC" : "音频"
        let channels = format.audio_channels ?? 2
        return name + " " + String(format: "%.1f", channels)
    }
    private static func audioSpec(codec: String?, channels: Double?, kbps: Int?) -> String {
        let raw = codec?.lowercased() ?? ""
        let name = raw.contains("flac") ? "FLAC" : raw.contains("opus") ? "Opus"
            : raw.contains("ec-3") || raw.contains("eac3") ? "E-AC-3"
            : raw.contains("ac-3") || raw.contains("ac3") ? "AC-3"
            : raw.contains("aac") || raw.contains("mp4a") ? "AAC"
            : raw.isEmpty ? "无音频" : raw.uppercased()
        let channelCount = Int((channels ?? 2).rounded())
        let layout = [1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"][channelCount] ?? "\(channelCount)ch"
        return "\(name) \(layout)"
    }
    private static func mediaSize(video: MediaFormat, audio: MediaFormat?, duration: Double?) -> String {
        func bytes(_ format: MediaFormat?) -> Double? {
            guard let format else { return nil }
            if let value = format.filesize, value > 0 { return value }
            if let value = format.filesize_approx, value > 0 { return value }
            if let bitrate = format.tbr, let duration, duration > 0 { return bitrate * 1000 / 8 * duration }
            return nil
        }
        let videoBytes = bytes(video)
        let audioBytes = video.acodec == "none" ? bytes(audio) : nil
        guard let videoBytes else { return "大小待定" }
        let total = videoBytes + (audioBytes ?? 0)
        return String(format: "%.1fMB", total / 1_048_576)
    }
    var arguments: [String] {
        var args = ["--retries", String(min(8, max(0, retries))), "--trim-filenames", "140"]
        if rateMiB > 0 { args += ["--limit-rate", "\(min(1000, rateMiB))M"] }
        if subtitle || danmaku {
            let languages = [subtitle ? subtitleLanguages : nil, danmaku ? "danmaku" : nil].compactMap { $0 }.joined(separator: ",")
            args += ["--write-subs", "--sub-langs", languages]
        }
        if thumbnail { args += ["--write-thumbnail"] }
        if keepStreams { args += ["--keep-video"] }
        return args
    }
    static func extractLinks(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https://(?:[A-Za-z0-9.-]+\.)?(?:bilibili\.com|b23\.tv)/[^\s<>\"，。；）]+"#)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text), let url = try? InputPolicy.videoURL(String(text[r])) else { return nil }
            let clean = InputPolicy.canonicalURL(url)
            return seen.insert(clean).inserted ? clean : nil
        }
    }
    static func selection(_ text: String, maximum: Int) throws -> [Int] {
        var result = Set<Int>()
        for token in text.replacingOccurrences(of: "，", with: ",").split(separator: ",") {
            let bounds = token.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard bounds.count == 1 || bounds.count == 2, let first = Int(bounds[0]), first > 0,
                  let last = Int(bounds.last!), last >= first, last <= maximum else {
                throw AppFailure.message("自定义集数请输入1,3,5-8，且不能超出官方列表。")
            }
            result.formUnion(first...last)
        }
        guard !result.isEmpty else { throw AppFailure.message("请填写自定义集数。") }
        return result.sorted()
    }
    func validateTemplate() throws {
        guard filename.contains("%("), !filename.contains("/"), !filename.contains("\\"),
              !filename.contains(".."), !filename.contains("\n"), filename.count <= 200 else {
            throw AppFailure.message("命名模板须含元数据字段，不得含目录、换行或超过200字符。")
        }
    }
}
