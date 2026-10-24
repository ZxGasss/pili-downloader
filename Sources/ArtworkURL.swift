import Foundation

enum ArtworkURL {
    static func normalized(_ raw: String?) -> URL? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        guard var components = URLComponents(string: raw), components.host != nil else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard components.scheme?.lowercased() == "https", components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}
