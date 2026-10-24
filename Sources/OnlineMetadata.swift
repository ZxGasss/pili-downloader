import Foundation

struct FilmMetadata: Codable, Identifiable {
    let id: Int
    let media_type: String?
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let release_date: String?
    let first_air_date: String?
    var genre_ids: [Int]? = nil
    var label: String { title ?? name ?? "未知影片" }
    var year: String { String((release_date ?? first_air_date ?? "").prefix(4)) }
    var poster: URL? { poster_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) } }
    var suggestedCategory: String {
        if genre_ids?.contains(16) == true { return "动画" }
        return media_type == "movie" ? "电影" : media_type == "tv" ? "剧集" : "未归类"
    }
}

@MainActor final class OnlineMetadata: ObservableObject {
    @Published var matches: [String: FilmMetadata] = [:]
    @Published var message = ""
    @Published var busy = false
    private let cache: URL
    init() {
        cache = Bundle.main.bundleIdentifier?.contains(".preview") == true ? TaskHistory.base.appendingPathComponent("metadata-v1.json")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/local.pili.downloader/metadata-v1.json")
        if let data = try? Data(contentsOf: cache), let rows = try? JSONDecoder().decode([String: FilmMetadata].self, from: data) { matches = rows }
    }
    func search(_ text: String, token: String = "") async -> [FilmMetadata] {
        guard !busy else { return [] }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "请输入片名。"; return [] }
        busy = true; message = "正在在线搜索…"
        defer { busy = false }
        do {
            guard let credential = try token.isEmpty ? TMDBAccess.credential() : TMDBCredential(kind: .readToken, value: token) else {
                message = "请先在媒体库打开TMDB设置，申请或导入自己的API凭据。"; return []
            }
            let data = try await TMDBAccess.fetch(path: "/search/multi", query: [URLQueryItem(name: "query", value: text),
                URLQueryItem(name: "language", value: "zh-CN"), URLQueryItem(name: "include_adult", value: "false")], credential: credential)
            struct Results: Decodable { let results: [FilmMetadata] }
            let rows = try JSONDecoder().decode(Results.self, from: data).results.filter { $0.media_type == "movie" || $0.media_type == "tv" }
            message = rows.isEmpty ? "没有匹配结果，请修改片名重试。" : "请选择正确影片，避免误匹配。"
            return rows
        } catch { message = "在线刮削失败：" + error.localizedDescription; return [] }
    }
    @discardableResult func select(_ metadata: FilmMetadata, path: String) -> Bool {
        selectMany([path: metadata])
    }
    @discardableResult func selectMany(_ selections: [String: FilmMetadata]) -> Bool {
        var updated = matches; updated.merge(selections) { _, new in new }
        do {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: cache, options: .atomic)
            matches = updated; message = "影片资料已保存，升级后保留。"
            return true
        } catch { message = "保存资料失败：" + error.localizedDescription; return false }
    }
}
