import Foundation
import Security
import SQLite3
import CommonCrypto
import CryptoKit

/// Explicit, local-only import of Bilibili cookies. Other browsing data is never queried.
enum ChromeCookieImporter {
    static var base: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome") }
    static var profiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
    }
    static func read(profile: String) throws -> [HTTPCookie] {
        guard profiles.contains(profile) else { throw AppFailure.message("未找到Chrome用户目录，请使用应用内登录。") }
        let candidates = [base.appendingPathComponent(profile + "/Network/Cookies"), base.appendingPathComponent(profile + "/Cookies")]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw AppFailure.message("Chrome Cookie数据库不可用，请退出Chrome后重试或使用应用内登录。") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw AppFailure.message("无法只读访问Chrome Cookie数据库，请在系统设置中检查文件访问权限。")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        var statement: OpaquePointer?
        let query = "SELECT host_key,name,path,is_secure,expires_utc,value,encrypted_value FROM cookies WHERE host_key IN ('.bilibili.com','bilibili.com','api.bilibili.com','.api.bilibili.com','www.bilibili.com')"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw AppFailure.message("Chrome Cookie格式不支持，请使用应用内登录。") }
        defer { sqlite3_finalize(statement) }
        var key: Data?
        var result: [HTTPCookie] = []
        func string(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let host = string(0), name = string(1), path = string(2)
            var value = string(5)
            let count = Int(sqlite3_column_bytes(statement, 6))
            if value.isEmpty, count > 0, let bytes = sqlite3_column_blob(statement, 6) {
                let blob = Data(bytes: bytes, count: count)
                if key == nil { key = try encryptionKey() }
                value = try decrypt(blob, key: key!, host: host)
            }
            let seconds = Double(sqlite3_column_int64(statement, 4)) / 1_000_000 - 11_644_473_600
            if !value.isEmpty, seconds <= 0 || seconds > Date().timeIntervalSince1970 {
                var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: host, .path: path,
                    .secure: sqlite3_column_int(statement, 3) == 1 ? "TRUE" : "FALSE"]
                if seconds > 0 { properties[.expires] = Date(timeIntervalSince1970: seconds) }
                if let cookie = HTTPCookie(properties: properties) { result.append(cookie) }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AppFailure.message("Chrome正在更新会话，请退出Chrome后重试。") }
        guard result.contains(where: { $0.name == "SESSDATA" }) else { throw AppFailure.message("此Chrome用户未找到有效B站登录，请登录后重试。") }
        return result
    }
    private static func encryptionKey() throws -> Data {
        var raw: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &raw)
        guard status == errSecSuccess, let password = raw as? Data, !password.isEmpty else { throw AppFailure.message("未获准读取Chrome安全存储，请使用应用内登录；不会绕过系统权限。") }
        var key = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let result = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { secret in salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            } }
        }
        guard result == kCCSuccess else { throw AppFailure.message("Chrome密钥派生失败。") }
        return key
    }
    private static func decrypt(_ blob: Data, key: Data, host: String) throws -> String {
        guard blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8) else { throw AppFailure.message("Chrome使用新的会话加密格式，请使用应用内登录。") }
        let ciphertext = Data(blob.dropFirst(3)), iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: ciphertext.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { target in
            ciphertext.withUnsafeBytes { source in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, ciphertext.count, target.baseAddress, capacity, &written)
            } } }
        }
        guard status == kCCSuccess else { throw AppFailure.message("Chrome会话解密失败，请使用应用内登录。") }
        output.count = written
        let digest = Data(SHA256.hash(data: Data(host.utf8)))
        if output.starts(with: digest) { output.removeFirst(32) }
        guard let value = String(data: output, encoding: .utf8) else { throw AppFailure.message("Chrome会话格式不可读取，请使用应用内登录。") }
        return value
    }
}
