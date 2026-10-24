import Foundation

@main struct BiliAPIFallbackProbe {
    static func main() async throws {
        let url = URL(string: "https://www.bilibili.com/bangumi/play/ep247270")!
        let result = try await BiliAPIFallback.inspect(url: url, cookies: [])
        guard let result else { throw AppFailure.message("fallback did not match") }
        precondition(result.info.choices.count > 0 && result.info.audioChoices.count > 0)
        let object = try JSONSerialization.jsonObject(with: result.metadata) as? [String: Any]
        let formats = object?["formats"] as? [[String: Any]] ?? []
        guard let video = formats.first(where: { ($0["vcodec"] as? String) != "none" }),
              let raw = video["url"] as? String, let mediaURL = URL(string: raw),
              let headers = video["http_headers"] as? [String: String] else {
            throw AppFailure.message("fallback metadata missing direct media")
        }
        var request = URLRequest(url: mediaURL)
        request.timeoutInterval = 20
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        precondition([200, 206].contains(status) && !data.isEmpty)
        let ugcURL = URL(string: "https://www.bilibili.com/video/BV1QMTv6uE45")!
        let episode = Episode(id: "BV1QMTv6uE45", index: 2, title: "老二竟然喜欢上了她！背叛了兄弟？", thumbnail: nil,
                              url: ugcURL, bvid: "BV1QMTv6uE45", series: "南瓜娃救爷爷", cid: 39563235240)
        let started = Date()
        let ugc = try await BiliAPIFallback.inspect(url: ugcURL, cookies: [], episode: episode)
        let elapsed = Date().timeIntervalSince(started)
        precondition(ugc?.info.title.contains("老二") == true && (ugc?.info.choices.count ?? 0) > 0)
        print("BILI_API_FALLBACK_PASS title=\(result.info.title) video=\(result.info.choices.count) audio=\(result.info.audioChoices.count) range=\(status) bytes=\(data.count) ugc=\(ugc?.info.choices.count ?? 0) ugc_ms=\(Int(elapsed * 1000))")
    }
}
