import Foundation
import CryptoKit

#if !PILI_SHARED_CORE
private actor BiliWBIKeyStore {
    static let shared = BiliWBIKeyStore()
    private var key: String?
    private var fetchedAt = Date.distantPast
    func value(fetch: () async throws -> String) async throws -> String {
        if let key, Date().timeIntervalSince(fetchedAt) < 3_600 { return key }
        let key = try await fetch()
        self.key = key; fetchedAt = Date()
        return key
    }
}

enum BiliAPIFallback {
    struct Result {
        let info: VideoInfo
        let metadata: Data
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    private static func request(_ components: URLComponents, cookies: [HTTPCookie], referer: String) async throws -> [String: Any] {
        guard let url = components.url else { throw AppFailure.message("无法生成哔哩哔哩接口地址。") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        let scoped = cookies.filter { ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")) && ($0.expiresDate == nil || $0.expiresDate! > Date()) }
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: scoped)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw AppFailure.message("哔哩哔哩官方接口暂不可用（\((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure.message("哔哩哔哩官方接口返回格式异常。")
        }
        return object
    }

    private static func codecName(_ value: Any?) -> String {
        let codec = (value as? String ?? "").lowercased()
        if codec.hasPrefix("avc") || codec.hasPrefix("h264") { return "avc1" }
        if codec.hasPrefix("hev") || codec.hasPrefix("hvc") || codec.hasPrefix("hevc") { return "hevc" }
        if codec.hasPrefix("av01") || codec.hasPrefix("av1") { return "av01" }
        return codec.isEmpty ? "video" : codec
    }

    private static func formats(dash: [String: Any], headers: [String: String]) -> [[String: Any]] {
        var formats: [[String: Any]] = []
        for video in dash["video"] as? [[String: Any]] ?? [] {
            let codec = codecName(video["codecs"])
            let id = (video["id"] as? NSNumber)?.intValue ?? 0
            guard let mediaURL = (video["baseUrl"] as? String) ?? (video["base_url"] as? String), !mediaURL.isEmpty else { continue }
            formats.append([
                "format_id": "v\(id)-\(codec)",
                "format_note": "\(Int((video["height"] as? NSNumber)?.doubleValue ?? 0))P",
                "ext": "mp4",
                "url": mediaURL,
                "width": (video["width"] as? NSNumber)?.doubleValue ?? 0,
                "height": (video["height"] as? NSNumber)?.doubleValue ?? 0,
                "fps": Double(video["frameRate"] as? String ?? "") ?? 0,
                "tbr": ((video["bandwidth"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                "vcodec": codec,
                "acodec": "none",
                "filesize": (video["size"] as? NSNumber)?.doubleValue ?? 0,
                "http_headers": headers
            ])
        }
        for audio in dash["audio"] as? [[String: Any]] ?? [] {
            let id = (audio["id"] as? NSNumber)?.intValue ?? 0
            guard let mediaURL = (audio["baseUrl"] as? String) ?? (audio["base_url"] as? String), !mediaURL.isEmpty else { continue }
            formats.append([
                "format_id": "\(id)",
                "format_note": "哔哩哔哩音轨",
                "ext": "m4a",
                "url": mediaURL,
                "tbr": ((audio["bandwidth"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                "vcodec": "none",
                "acodec": "aac",
                "filesize": (audio["size"] as? NSNumber)?.doubleValue ?? 0,
                "http_headers": headers
            ])
        }
        return formats
    }

    private static func result(id: String, title: String, thumbnail: String?, duration: Double, webpage: String,
                               episodeNumber: Int?, uploader: String?, formats: [[String: Any]]) throws -> Result {
        guard formats.contains(where: { ($0["vcodec"] as? String) != "none" }) else {
            throw AppFailure.message("官方播放接口没有可下载的视频轨。")
        }
        var object: [String: Any] = [
            "id": id, "title": title, "thumbnail": thumbnail ?? "", "duration": duration,
            "webpage_url": webpage, "formats": formats, "has_drm": false, "extractor": "bilibili-api"
        ]
        if let episodeNumber { object["episode_number"] = episodeNumber }
        if let uploader { object["uploader"] = uploader }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Result(info: try JSONDecoder().decode(VideoInfo.self, from: data), metadata: data)
    }

    private static func wbiKey(cookies: [HTTPCookie], referer: String) async throws -> String {
        try await BiliWBIKeyStore.shared.value {
            var nav = URLComponents(string: "https://api.bilibili.com/x/web-interface/nav")!
            nav.queryItems = []
            let json = try await request(nav, cookies: cookies, referer: referer)
            guard let wbi = (json["data"] as? [String: Any])?["wbi_img"] as? [String: Any],
                  let image = wbi["img_url"] as? String, let sub = wbi["sub_url"] as? String else {
                throw AppFailure.message("哔哩哔哩签名接口不可用。")
            }
            let lookup = ([image, sub].map { String($0.split(separator: "/").last ?? "").split(separator: ".").first.map(String.init) ?? "" }).joined()
            let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
            guard lookup.count >= 64 else { throw AppFailure.message("哔哩哔哩签名配置异常。") }
            return String(table.map { lookup[lookup.index(lookup.startIndex, offsetBy: $0)] }).prefix(32).description
        }
    }

    private static func signedWBI(_ params: [String: String], cookies: [HTTPCookie], referer: String) async throws -> [URLQueryItem] {
        var clean = params.mapValues { String($0.filter { !"!'()*".contains($0) }) }
        clean["wts"] = String(Int(Date().timeIntervalSince1970))
        let sorted = clean.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var components = URLComponents(); components.queryItems = sorted
        let query = components.percentEncodedQuery ?? ""
        let key = try await wbiKey(cookies: cookies, referer: referer)
        let digest = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return sorted + [URLQueryItem(name: "w_rid", value: digest)]
    }

    private static func inspectVideo(url: URL, cookies: [HTTPCookie], episode: Episode?) async throws -> Result? {
        let bvid = url.lastPathComponent
        guard bvid.lowercased().hasPrefix("bv") else { return nil }
        let referer = "https://www.bilibili.com/video/\(bvid)"
        var cid = episode?.cid
        var title = episode?.title, cover = episode?.thumbnail
        var page = 1
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value {
            page = max(1, Int(value) ?? 1)
        }
        if cid == nil {
            var view = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
            view.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
            let json = try await request(view, cookies: cookies, referer: referer)
            guard json["code"] as? Int == 0, let data = json["data"] as? [String: Any] else {
                throw AppFailure.message(json["message"] as? String ?? "官方视频接口未返回当前视频。")
            }
            let pages = data["pages"] as? [[String: Any]] ?? []
            let selected = pages[safe: page - 1] ?? [:]
            cid = (selected["cid"] as? NSNumber)?.int64Value ?? (data["cid"] as? NSNumber)?.int64Value
            title = title ?? (selected["part"] as? String) ?? (data["title"] as? String)
            cover = cover ?? (data["pic"] as? String)
        }
        guard let cid else { throw AppFailure.message("官方视频接口没有返回 CID。") }
        let query = try await signedWBI([
            "bvid": bvid, "cid": String(cid), "fnval": "4048", "qn": "127"
        ], cookies: cookies, referer: referer)
        var play = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        play.queryItems = query
        let json = try await request(play, cookies: cookies, referer: referer)
        guard json["code"] as? Int == 0, let data = json["data"] as? [String: Any],
              data["is_drm"] as? Bool != true, let dash = data["dash"] as? [String: Any] else {
            throw AppFailure.message(json["message"] as? String ?? "官方视频播放接口未返回可用媒体。")
        }
        let headers = ["Referer": referer, "Origin": "https://www.bilibili.com", "User-Agent": userAgent]
        let duration = ((data["timelength"] as? NSNumber)?.doubleValue ?? 0) / 1000
        return try result(id: bvid, title: title ?? bvid, thumbnail: cover, duration: duration,
                          webpage: referer, episodeNumber: episode?.index, uploader: episode?.series,
                          formats: formats(dash: dash, headers: headers))
    }

    static func inspect(url: URL, cookies: [HTTPCookie], episode: Episode? = nil) async throws -> Result? {
        let path = url.path
        if path.hasPrefix("/video/") { return try await inspectVideo(url: url, cookies: cookies, episode: episode) }
        guard path.hasPrefix("/bangumi/play/"), url.lastPathComponent.hasPrefix("ep"),
              let episodeID = Int(url.lastPathComponent.dropFirst(2)) else { return nil }
        let referer = "https://www.bilibili.com/bangumi/play/ep\(episodeID)"
        var season = URLComponents(string: "https://api.bilibili.com/pgc/view/web/season")!
        season.queryItems = [URLQueryItem(name: "ep_id", value: String(episodeID))]
        let seasonJSON = try await request(season, cookies: cookies, referer: referer)
        guard seasonJSON["code"] as? Int == 0, let seasonResult = seasonJSON["result"] as? [String: Any],
              let rows = seasonResult["episodes"] as? [[String: Any]],
              let targetIndex = rows.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == episodeID }),
              let target = rows[safe: targetIndex], let cid = target["cid"] as? NSNumber else {
            throw AppFailure.message("官方剧集接口未返回当前集。")
        }

        var play = URLComponents(string: "https://api.bilibili.com/pgc/player/web/playurl")!
        play.queryItems = [
            URLQueryItem(name: "ep_id", value: String(episodeID)),
            URLQueryItem(name: "cid", value: cid.stringValue),
            URLQueryItem(name: "qn", value: "127"),
            URLQueryItem(name: "fnval", value: "4048"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "otype", value: "json")
        ]
        let playJSON = try await request(play, cookies: cookies, referer: referer)
        guard playJSON["code"] as? Int == 0, let playResult = playJSON["result"] as? [String: Any] else {
            throw AppFailure.message(playJSON["message"] as? String ?? "官方播放接口未返回可用媒体。")
        }
        guard playResult["is_drm"] as? Bool != true, let dash = playResult["dash"] as? [String: Any] else {
            throw AppFailure.message("官方播放接口未返回可下载的 DASH 媒体。")
        }
        let headers = ["Referer": referer, "Origin": "https://www.bilibili.com", "User-Agent": userAgent]
        var formats: [[String: Any]] = []
        for video in dash["video"] as? [[String: Any]] ?? [] {
            let codec = codecName(video["codecs"])
            let id = (video["id"] as? NSNumber)?.intValue ?? 0
            guard let mediaURL = (video["baseUrl"] as? String) ?? (video["base_url"] as? String), !mediaURL.isEmpty else { continue }
            formats.append([
                "format_id": "v\(id)-\(codec)",
                "format_note": "\(Int((video["height"] as? NSNumber)?.doubleValue ?? 0))P",
                "ext": "mp4",
                "url": mediaURL,
                "width": (video["width"] as? NSNumber)?.doubleValue ?? 0,
                "height": (video["height"] as? NSNumber)?.doubleValue ?? 0,
                "fps": Double(video["frameRate"] as? String ?? "") ?? 0,
                "tbr": ((video["bandwidth"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                "vcodec": codec,
                "acodec": "none",
                "filesize": (video["size"] as? NSNumber)?.doubleValue ?? 0,
                "http_headers": headers
            ])
        }
        for audio in dash["audio"] as? [[String: Any]] ?? [] {
            let id = (audio["id"] as? NSNumber)?.intValue ?? 0
            guard let mediaURL = (audio["baseUrl"] as? String) ?? (audio["base_url"] as? String), !mediaURL.isEmpty else { continue }
            formats.append([
                "format_id": "\(id)",
                "format_note": "哔哩哔哩音轨",
                "ext": "m4a",
                "url": mediaURL,
                "tbr": ((audio["bandwidth"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                "vcodec": "none",
                "acodec": "aac",
                "filesize": (audio["size"] as? NSNumber)?.doubleValue ?? 0,
                "http_headers": headers
            ])
        }
        guard formats.contains(where: { ($0["vcodec"] as? String) != "none" }) else {
            throw AppFailure.message("官方播放接口没有可下载的视频轨。")
        }
        let episodeLabel = target["title"] as? String ?? String(targetIndex + 1)
        let longTitle = target["long_title"] as? String ?? ""
        let title = "第\(episodeLabel)话" + (longTitle.isEmpty ? "" : " \(longTitle)")
        let duration = ((playResult["timelength"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let cover = (target["cover"] as? String) ?? (seasonResult["cover"] as? String)
        var object: [String: Any] = [
            "id": "ep\(episodeID)",
            "title": title,
            "thumbnail": cover ?? "",
            "duration": duration,
            "webpage_url": referer,
            "episode_number": targetIndex + 1,
            "formats": formats,
            "has_drm": false,
            "extractor": "bilibili-api"
        ]
        if let series = seasonResult["season_title"] as? String { object["uploader"] = series }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let info = try JSONDecoder().decode(VideoInfo.self, from: data)
        return Result(info: info, metadata: data)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
