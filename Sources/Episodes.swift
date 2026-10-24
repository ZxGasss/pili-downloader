import Foundation

struct Episode: Codable, Identifiable, Equatable {
    let id: String
    let index: Int
    let title: String
    let thumbnail: String?
    let url: URL
    let bvid: String?
    var series: String? = nil
    var aid: Int64? = nil
    var cid: Int64? = nil
    var coverURL: URL? {
        guard let thumbnail, var parts = URLComponents(string: thumbnail) else { return nil }
        parts.scheme = "https"; return parts.url
    }
}

enum EpisodeOrder {
    static func current(in episodes: [Episode], source: URL) -> Episode? {
        let canonical = InputPolicy.canonicalURL(source)
        return episodes.first { InputPolicy.canonicalURL($0.url).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            ?? episodes.first { source.lastPathComponent.lowercased() == "av\($0.aid ?? -1)" }
    }
    static func parseVideoCollection(_ data: Data) throws -> [Episode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0,
              let result = root["data"] as? [String: Any] else {
            throw AppFailure.message("无法读取官方合集列表，请检查网络或内容权限。")
        }
        if let season = result["ugc_season"] as? [String: Any], let sections = season["sections"] as? [[String: Any]] {
            var entries: [Episode] = []; var seen = Set<String>()
            for row in sections.flatMap({ $0["episodes"] as? [[String: Any]] ?? [] }) {
                let archive = row["arc"] as? [String: Any] ?? [:]
                guard let bvid = row["bvid"] as? String, seen.insert(bvid).inserted,
                      let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { continue }
                entries.append(Episode(id: bvid, index: entries.count + 1,
                    title: row["title"] as? String ?? archive["title"] as? String ?? "未命名视频",
                    thumbnail: archive["pic"] as? String ?? season["cover"] as? String,
                    url: url, bvid: bvid, series: season["title"] as? String,
                    aid: (row["aid"] as? NSNumber)?.int64Value, cid: (row["cid"] as? NSNumber)?.int64Value))
            }
            if !entries.isEmpty { return entries }
        }
        guard let pages = result["pages"] as? [[String: Any]], pages.count > 1, let bvid = result["bvid"] as? String else { return [] }
        return pages.enumerated().compactMap { offset, page in
            let number = page["page"] as? Int ?? offset + 1
            return Episode(id: "\(bvid)-p\(number)", index: number,
                title: page["part"] as? String ?? "第\(number)集", thumbnail: page["first_frame"] as? String ?? result["pic"] as? String,
                url: URL(string: "https://www.bilibili.com/video/\(bvid)?p=\(number)")!, bvid: bvid, series: result["title"] as? String,
                cid: (page["cid"] as? NSNumber)?.int64Value)
        }
    }
    static func select(_ episodes: [Episode], start: Int, end: Int?, all: Bool) throws -> [Episode] {
        let sorted = episodes.sorted { $0.index < $1.index }
        guard start >= 1, end == nil || end! >= start else { throw AppFailure.message("起止集数无效：结束集必须不小于开始集。") }
        if all { return sorted }
        let selected = sorted.filter { $0.index >= start && $0.index <= (end ?? start) }
        guard selected.count == (end ?? start) - start + 1 else { throw AppFailure.message("所选范围超出官方正片列表，请检查集数。") }
        return selected
    }
    static func parseSeason(_ data: Data) throws -> [Episode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0,
              let result = root["result"] as? [String: Any], let rows = result["episodes"] as? [[String: Any]] else {
            throw AppFailure.message("无法取得官方正片列表，请检查登录、网络或该内容权限。")
        }
        return rows.enumerated().compactMap { offset, row in
            guard let number = row["id"] as? Int else { return nil }
            let label = row["title"] as? String ?? String(offset + 1)
            return Episode(id: "ep\(number)", index: Int(label) ?? offset + 1,
                title: "第\(label)话 " + (row["long_title"] as? String ?? ""), thumbnail: row["cover"] as? String,
                url: URL(string: "https://www.bilibili.com/bangumi/play/ep\(number)")!, bvid: row["bvid"] as? String,
                series: result["title"] as? String, cid: (row["cid"] as? NSNumber)?.int64Value)
        }.sorted { $0.index < $1.index }
    }
}

#if !PILI_SHARED_CORE
enum EpisodeCatalogue {
    static func load(url: URL, cookies: [HTTPCookie]) async throws -> [Episode] {
        let isVideo = url.path.hasPrefix("/video/")
        guard isVideo || url.path.hasPrefix("/bangumi/play/") else { return [] }
        let item = url.lastPathComponent
        let key = isVideo ? (item.lowercased().hasPrefix("av") ? "aid" : "bvid") : (item.hasPrefix("ss") ? "season_id" : "ep_id")
        let number = key == "bvid" ? item : String(item.dropFirst(2))
        guard key == "bvid" || Int(number) != nil else { return [] }
        var parts = URLComponents(string: isVideo ? "https://api.bilibili.com/x/web-interface/view" : "https://api.bilibili.com/pgc/view/web/season")!
        parts.queryItems = [URLQueryItem(name: key, value: number)]
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 20
        let scoped = cookies.filter { ($0.domain == ".bilibili.com" || $0.domain == "api.bilibili.com") && ($0.expiresDate == nil || $0.expiresDate! > Date()) }
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: scoped)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.message("官方剧集列表暂不可用。") }
        return try isVideo ? EpisodeOrder.parseVideoCollection(data) : EpisodeOrder.parseSeason(data)
    }
}
#endif
