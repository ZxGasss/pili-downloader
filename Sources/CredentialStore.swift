import Foundation

struct RememberedCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Date?
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        secure = cookie.isSecure; expires = cookie.expiresDate
    }
    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

enum CredentialStore {
    // Stable across app replacements and ad-hoc signing changes; contains session cookies only.
    private static var backup: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/local.pili.downloader/session-v1.json")
    }
    static func save(_ cookies: [HTTPCookie]) throws {
        let data = try JSONEncoder().encode(cookies.map(RememberedCookie.init))
        try AccountSecurity.write(data, account: "bilibili.cookies.v1")
    }
    static func load() -> [HTTPCookie] {
        if Bundle.main.bundleIdentifier?.contains(".preview") == true { return [] }
        let data: Data
        do {
            if let stored = try AccountSecurity.read("bilibili.cookies.v1") { data = stored }
            else {
                guard let legacy = try? Data(contentsOf: backup),
                      (try? JSONDecoder().decode([RememberedCookie].self, from: legacy)) != nil else { return [] }
                try AccountSecurity.write(legacy, account: "bilibili.cookies.v1")
                data = legacy
            }
        } catch { return [] }
        guard let rows = try? JSONDecoder().decode([RememberedCookie].self, from: data) else { return [] }
        return rows.compactMap(\.cookie).filter { $0.expiresDate == nil || $0.expiresDate! > Date() }
    }
    static var hasLegacyCopy: Bool { FileManager.default.fileExists(atPath: backup.path) }
    static func removeLegacyCopy() throws {
        guard try AccountSecurity.read("bilibili.cookies.v1") != nil else {
            throw AppFailure.message("尚未确认钥匙串中的凭据，保留旧文件。")
        }
        if hasLegacyCopy { try FileManager.default.removeItem(at: backup) }
    }
    static func clear() {
        try? AccountSecurity.remove("bilibili.cookies.v1")
        if hasLegacyCopy { try? FileManager.default.removeItem(at: backup) }
    }
}
