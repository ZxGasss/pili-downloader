import Foundation

struct BiliFavoriteFolder: Identifiable {
    let id: Int64
    let title: String
    let count: Int
}
struct BiliFavoriteVideo: Identifiable {
    let id: String
    let title: String
    let cover: URL?
    var url: URL? { URL(string: "https://www.bilibili.com/video/" + id) }
}

/// Read-only account endpoints. Download parsing continues through the established backend.
enum BilibiliProvider {
    private static func get(_ path: String, query: [URLQueryItem], cookies: [HTTPCookie]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.bilibili.com" + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let scoped = cookies.filter { $0.domain == ".bilibili.com" || $0.domain == "api.bilibili.com" }
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: scoped)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 0, let result = object["data"] as? [String: Any] else {
            throw AppFailure.message("收藏读取失败，请检查登录状态或稍后重试。")
        }
        return result
    }
    static func folders(userID: Int64, cookies: [HTTPCookie]) async throws -> [BiliFavoriteFolder] {
        let data = try await get("/x/v3/fav/folder/created/list-all", query: [.init(name: "up_mid", value: String(userID))], cookies: cookies)
        return (data["list"] as? [[String: Any]] ?? []).compactMap {
            guard let id = ($0["id"] as? NSNumber)?.int64Value else { return nil }
            return BiliFavoriteFolder(id: id, title: $0["title"] as? String ?? "收藏夹", count: $0["media_count"] as? Int ?? 0)
        }
    }
    static func favorites(folder: Int64, page: Int, cookies: [HTTPCookie]) async throws -> ([BiliFavoriteVideo], Bool) {
        guard (1...50).contains(page) else { return ([], false) }
        let data = try await get("/x/v3/fav/resource/list", query: [.init(name: "media_id", value: String(folder)),
            .init(name: "pn", value: String(page)), .init(name: "ps", value: "20"), .init(name: "platform", value: "web")], cookies: cookies)
        let items = (data["medias"] as? [[String: Any]] ?? []).compactMap { item -> BiliFavoriteVideo? in
            guard let bvid = item["bvid"] as? String, bvid.hasPrefix("BV"), bvid.count == 12 else { return nil }
            return BiliFavoriteVideo(id: bvid, title: item["title"] as? String ?? "视频", cover: ArtworkURL.normalized(item["cover"] as? String))
        }
        return (items, data["has_more"] as? Bool ?? false)
    }
}
