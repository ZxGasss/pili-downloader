import Foundation

struct MediaFormat: Codable, Identifiable {
    let format_id: String
    let format_note: String?
    let ext: String?
    let height: Double?
    let width: Double?
    let fps: Double?
    let tbr: Double?
    let vcodec: String?
    let acodec: String?
    let has_drm: Bool?
    let filesize: Double?
    let filesize_approx: Double?
    let format: String?
    let dynamic_range: String?
    let quality: Double?
    let asr: Double?
    let audio_channels: Double?
    var id: String { format_id }
    // Use the short edge consistently for landscape and portrait quality labels.
    // Width alone cannot establish a p-label (3840 wide is not 3840p).
    var resolutionHeight: Int? {
        guard let height, height.isFinite, height >= 1, height < Double(Int.max) else { return nil }
        if let width, width.isFinite, width >= 1, width < Double(Int.max) {
            return Int(min(width, height))
        }
        return Int(height)
    }
    var label: String {
        let resolution = resolutionHeight.map { "\($0)p" } ?? (format_note ?? "原始画质")
        let frames = fps.map { " · \(Int($0)) fps" } ?? ""
        let name = format ?? format_note
        let range = dynamic_range == "DV" ? "杜比视界" : (dynamic_range == "HDR10" ? "HDR10" : dynamic_range)
        return [name, resolution + frames, range, vcodec ?? ext, tbr.map { String(format: "%.0f kb/s", $0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var audioLabel: String {
        let codec = acodec ?? ext ?? "音频"
        let platformLabel = format_id == "30251" && codec.lowercased().contains("flac") ? "Hi-Res 无损（平台音轨）"
            : format_id == "30250" ? "杜比音频（平台音轨）" : nil
        let description = format ?? format_note ?? platformLabel ?? (codec.lowercased().contains("flac") ? "FLAC 无损" : codec)
        return [description, asr.map { String(format: "%.1f kHz", $0 / 1000) },
                audio_channels.map { "\(Int($0)) 声道" }, tbr.map { String(format: "%.0f kb/s", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var selector: String { acodec == "none" ? "\(format_id)+bestaudio" : format_id }
}

struct VideoInfo: Codable {
    let id: String
    let title: String
    let thumbnail: String?
    let uploader: String?
    let duration: Double?
    let formats: [MediaFormat]?
    let has_drm: Bool?
    let webpage_url: String?
    let playlist_index: Int?
    let episode_number: Int?
    var coverURL: URL? {
        guard let thumbnail, var parts = URLComponents(string: thumbnail),
              ["http", "https"].contains(parts.scheme ?? "") else { return nil }
        parts.scheme = "https"
        return parts.url
    }
    var choices: [MediaFormat] {
        (formats ?? []).filter { $0.vcodec != nil && $0.vcodec != "none" && $0.has_drm != true }
            .sorted {
                if ($0.height ?? 0) != ($1.height ?? 0) { return ($0.height ?? 0) > ($1.height ?? 0) }
                if ($0.fps ?? 0) != ($1.fps ?? 0) { return ($0.fps ?? 0) > ($1.fps ?? 0) }
                return ($0.tbr ?? 0) > ($1.tbr ?? 0)
            }
    }
    var audioChoices: [MediaFormat] {
        (formats ?? []).filter { $0.vcodec == "none" && $0.acodec != "none" && $0.has_drm != true }
            .sorted { ($0.tbr ?? 0) > ($1.tbr ?? 0) }
    }
    var durationLabel: String {
        guard let duration else { return "时长未知" }
        return String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
    func sizeLabel(formatID: String) -> String {
        guard let video = choices.first(where: { $0.id == formatID }) else { return "大小待解析" }
        var selected = [video]
        if video.acodec == "none" {
            guard let audio = (formats ?? []).filter({ $0.vcodec == "none" && $0.has_drm != true })
                .max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }) else { return "总大小未知（缺少音频大小）" }
            selected.append(audio)
        }
        var total = 0.0, estimated = false
        for format in selected {
            if let size = format.filesize { total += size }
            else if let size = format.filesize_approx { total += size; estimated = true }
            else if let rate = format.tbr, let duration { total += rate * 1000 / 8 * duration; estimated = true }
            else { return "总大小未知（服务器未提供）" }
        }
        return (estimated ? "预计总大小 ≈ " : "音视频合计 ") + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            + "（合并后略有差异）"
    }
}

enum AppFailure: LocalizedError {
    case message(String)
    case transferStalled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .transferStalled: return "传输长时间没有新增数据，已停止当前连接并保留分片。"
        }
    }
}

enum InputPolicy {
    static func folderName(_ value: String) -> String {
        let cleaned = String(value.map { "/:\\%\n\r".contains($0) ? "_" : $0 }.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.controlCharacters))
        return cleaned.isEmpty ? "未命名合集" : cleaned
    }
    static func canonicalURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let query = parts.queryItems?.filter { $0.name == "p" } ?? []
        parts.queryItems = query.isEmpty ? nil : query; parts.fragment = nil
        return parts.url?.absoluteString ?? url.absoluteString
    }
    static func videoURL(_ text: String) throws -> URL {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.range(of: #"(?i)^av[1-9][0-9]*$"#, options: .regularExpression) != nil {
            input = "https://www.bilibili.com/video/av" + input.dropFirst(2)
        } else if input.range(of: #"(?i)^bv[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil {
            input = "https://www.bilibili.com/video/BV" + input.dropFirst(2)
        }
        guard let url = URL(string: input),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              ["www.bilibili.com", "bilibili.com", "m.bilibili.com", "b23.tv"].contains(host),
              host == "b23.tv" ? url.path.count > 1 :
                (url.path.hasPrefix("/video/") || url.path.range(of: #"^/(bangumi/play|cheese/play)/(ss|ep)[0-9]+/?$|^/bangumi/media/md[0-9]+/?$"#, options: .regularExpression) != nil)
        else { throw AppFailure.message("请输入视频、影视番剧 ss/ep/md、课程 ss/ep 或 b23.tv 的 HTTPS 链接。") }
        return url
    }
    static func isSeason(_ url: URL) -> Bool {
        url.path.hasPrefix("/bangumi/play/ss") || url.path.hasPrefix("/bangumi/media/md") || url.path.hasPrefix("/cheese/play/ss")
    }
    static func playlistArguments(url: URL, index: Int, all: Bool, end: Int? = nil) -> [String] {
        if all { return ["--yes-playlist"] }
        if let end { return ["--yes-playlist", "--playlist-items", "\(max(1, index)):\(end)"] }
        return ["--no-playlist", "--playlist-items", String(isSeason(url) ? max(1, index) : 1)]
    }
    static func safeLog(_ line: String) -> String {
        var result = line.replacingOccurrences(of: #"https?://[^\s\"']+"#, with: "[链接已隐藏]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(sessdata|bili_jct|cookie|authorization|token)[^\s]*"#, with: "[凭证已隐藏]", options: .regularExpression)
        return String(result.prefix(1800))
    }
    static func cleanDisplay(_ line: String) -> String {
        var result = line.replacingOccurrences(of: #"(?i)\[BiliBiliBangumi\]\s+[0-9]+:\s+[0-9]+:"#, with: "[视频解析]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\bBV[0-9A-Za-z]{10}\b"#, with: "内容", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:av|ep|ss|md)[0-9]+\b"#, with: "内容", options: .regularExpression)
        return result
    }
}

struct TransferProgress: Codable {
    var streamID: String? = nil
    var percent: Double?
    var speed = "—"
    var eta = "—"
    var fragment = "等待下载"
    var downloaded: Double?
    var total: Double?
    var bytesPerSecond: Double?
    var sizeLabel: String {
        func bytes(_ value: Double?) -> String {
            value.map { ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file) } ?? "未知"
        }
        return "\(bytes(downloaded)) / \(bytes(total))"
    }
    static func parse(_ line: String) -> TransferProgress? {
        if line.contains("CN:"), line.contains("DL:") {
            func field(_ pattern: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { return nil }
                return String(line[range])
            }
            let percent = field(#"\(([\d.]+)%\)"#).flatMap(Double.init)
            let speed = field(#"DL:([^\s\]]+)"#).map { value in
                if let bytes = Double(value.replacingOccurrences(of: "B", with: "")) {
                    return ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
                }
                return value
            }
            let eta = field(#"ETA:([^\s\]]+)"#)
            let connections = field(#"CN:(\d+)"#) ?? "—"
            let downloaded = field(#"\s(\d+)B/"#).flatMap(Double.init)
            let total = field(#"/(\d+)B\("#).flatMap(Double.init)
            return TransferProgress(percent: percent, speed: speed.map { $0 + "/s" } ?? "—",
                                    eta: eta ?? "—", fragment: "多连接下载 · \(connections) 连接", downloaded: downloaded, total: total,
                                    bytesPerSecond: field(#"DL:([\d.]+)B"#).flatMap(Double.init))
        }
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 5, parts[0] == "PLPROGRESS" else { return nil }
        let percent = Double(parts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        let speed = Double(parts[2])
        let eta = Double(parts[3])
        return TransferProgress(streamID: parts[4], percent: percent.map { min(100, max(0, $0)) },
            speed: speed.map { ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file) + "/s" } ?? "—",
            eta: eta.map { String(format: "%02d:%02d", Int(max(0, $0)) / 60, Int(max(0, $0)) % 60) } ?? "—",
            fragment: "媒体流", downloaded: parts.count > 5 ? Double(parts[5]) : nil,
            total: parts.count > 6 ? (Double(parts[6]) ?? (parts.count > 7 ? Double(parts[7]) : nil)) : nil, bytesPerSecond: speed)
    }
}
