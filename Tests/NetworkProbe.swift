import Foundation

@main struct NetworkProbe {
    @MainActor static func main() async throws {
        let url = URL(string: "https://www.bilibili.com/video/BV1QMTv6uE45")!
        let engine = DownloadBackend(tools: URL(fileURLWithPath: "work/deps", isDirectory: true))
        let info = try await engine.inspect(url: url, cookies: []) { line in
            if line.hasPrefix("ERROR:") { print(InputPolicy.safeLog(line)) }
        }
        try JSONEncoder().encode(info).write(to: URL(fileURLWithPath: "work/network-probe-safe.json"), options: .atomic)
        print("LIVE_METADATA_PASS", info.id, "formats", info.choices.count, "top", info.choices.first?.label ?? "none")
    }
}
