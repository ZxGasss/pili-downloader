import Foundation

struct TMDBCredential: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case readToken, apiKey }
    let kind: Kind
    let value: String
    init(kind: Kind, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = kind == .readToken && trimmed.lowercased().hasPrefix("bearer ") ? String(trimmed.dropFirst(7)) : trimmed
        guard normalized.count >= 16, normalized.count <= 4096,
              !normalized.contains(where: \.isWhitespace), !normalized.contains("://") else {
            throw AppFailure.message("请粘贴 API 凭据本身，不是网页地址或整段说明。")
        }
        self.kind = kind; self.value = normalized
    }
    static func imported(_ data: Data) throws -> TMDBCredential {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { throw AppFailure.message("凭据文件需为小于32KB的UTF-8文本或JSON。") }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for key in ["api_read_access_token", "read_access_token", "token"] {
                if let value = object[key] { return try .init(kind: .readToken, value: value) }
            }
            if let value = object["api_key"] { return try .init(kind: .apiKey, value: value) }
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isKey = value.count == 32 && value.allSatisfy(\.isHexDigit)
        return try .init(kind: isKey ? .apiKey : .readToken, value: value)
    }
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        components.queryItems = query + (kind == .apiKey ? [.init(name: "api_key", value: value)] : [])
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        if kind == .readToken { request.setValue("Bearer " + value, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

enum TMDBAccess {
    static let applicationURL = URL(string: "https://www.themoviedb.org/settings/api")!
    static func credential() throws -> TMDBCredential? {
        if let data = try AccountSecurity.read("tmdb.credential.v1") { return try JSONDecoder().decode(TMDBCredential.self, from: data) }
        if let data = try AccountSecurity.read("tmdb.read-token"), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return try .init(kind: .readToken, value: value)
        }
        if let legacy = UserDefaults.standard.string(forKey: "tmdb.readToken"), !legacy.isEmpty { return try .init(kind: .readToken, value: legacy) }
        return nil
    }
    static func fetch(path: String, query: [URLQueryItem] = [], credential: TMDBCredential, session supplied: URLSession? = nil) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = supplied ?? URLSession(configuration: configuration)
        defer { if supplied == nil { session.invalidateAndCancel() } }
        do {
            let (data, response) = try await session.data(for: credential.request(path: path, query: query))
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return data
            case 401, 403: throw AppFailure.message("TMDB凭据无效或未获授权，请检查复制的类型与内容。")
            case 429: throw AppFailure.message("TMDB请求过于频繁，请稍后重试。")
            default: throw AppFailure.message("TMDB服务暂不可用，请稍后重试。")
            }
        } catch let failure as AppFailure { throw failure }
        catch { throw AppFailure.message("无法连接TMDB，请检查网络后重试；原配置保留。") }
    }
    static func validate(_ credential: TMDBCredential, session: URLSession? = nil) async throws {
        let data = try await fetch(path: "/authentication", credential: credential, session: session)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["success"] as? Bool == true else {
            throw AppFailure.message("TMDB未确认此凭据有效，原配置保留。")
        }
    }
    static func save(_ credential: TMDBCredential) throws {
        try AccountSecurity.write(try JSONEncoder().encode(credential), account: "tmdb.credential.v1")
        UserDefaults.standard.removeObject(forKey: "tmdb.readToken")
    }
    static func clear() throws {
        try AccountSecurity.remove("tmdb.credential.v1")
        try AccountSecurity.remove("tmdb.read-token")
        UserDefaults.standard.removeObject(forKey: "tmdb.readToken")
    }
}
