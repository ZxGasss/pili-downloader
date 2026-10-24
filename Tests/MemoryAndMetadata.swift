import AppKit
import Foundation
import ImageIO
import Darwin

final class TMDBFixtureProtocol: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct MemoryAndMetadataTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("TEST_FAILED", error.localizedDescription); exit(1) }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw AppFailure.message(message) } }
    static func rss() -> UInt64 {
        var value = proc_taskinfo(); let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &value, Int32(size)) == size else { return 0 }
        return value.pti_resident_size
    }
    @MainActor static func run() async throws {
        try require(MemoryBudget.lowMemory && MemoryBudget.episodes == 2 && MemoryBudget.connections == 4, "8GB policy")
        try require(MemoryBudget.isSmallMachine(bytes: 8 * 1024 * 1024 * 1024) && !MemoryBudget.isSmallMachine(bytes: 16 * 1024 * 1024 * 1024), "memory thresholds")
        try require(ArtworkURL.normalized("http://i0.hdslb.com/a.jpg")?.absoluteString == "https://i0.hdslb.com/a.jpg", "favorite http cover")
        try require(ArtworkURL.normalized("//i1.hdslb.com/b.jpg")?.scheme == "https", "protocol-relative cover")
        try require(ArtworkURL.normalized("file:///private/data") == nil, "reject local poster URL")
        let token = try TMDBCredential(kind: .readToken, value: "Bearer " + String(repeating: "x", count: 40))
        try require(token.request(path: "/authentication").value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "x", count: 40), "bearer header")
        let key = try TMDBCredential.imported(Data(#"{"api_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8))
        try require(key.kind == .apiKey && key.request(path: "/authentication").url?.query?.contains("api_key=") == true, "v3 key import")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TMDBFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        try await TMDBAccess.validate(token, session: session)
        TMDBFixtureProtocol.status = 401
        do { try await TMDBAccess.validate(key, session: session); throw AppFailure.message("401 incorrectly accepted") }
        catch { try require(!error.localizedDescription.contains(key.value), "credential leaked in error") }
        let animation = try JSONDecoder().decode(FilmMetadata.self, from: Data(#"{"id":1,"name":"自有测试","media_type":"tv","genre_ids":[16]}"#.utf8))
        try require(animation.suggestedCategory == "动画", "TMDB animation classification")
        print("PASS: 8GB budget; favorite cover normalization; token/key import/auth/status; TMDB animation category")
        let tools = Bundle.main.resourceURL!.appendingPathComponent("Tools")
        let file = tools.appendingPathComponent("fixture.mp4")
        let bytes = await Task.detached { LocalThumbnailWorker.jpeg(file: file, executable: tools.appendingPathComponent("ffmpeg")) }.value
        guard let bytes, let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { throw AppFailure.message("bounded local thumbnail failed") }
        try require((properties[kCGImagePropertyPixelWidth] as? Int ?? 9999) <= 480, "thumbnail pixel cap")
        let before = rss()
        for i in 0..<1200 {
            autoreleasepool {
                let artwork = ArtworkImageCache.shared.image(key: "owned-\(i % 240)", data: bytes)
                _ = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        let after = rss()
        try require(after <= before + 128 * 1024 * 1024, "decoded image memory grew beyond test budget")
        ArtworkImageCache.shared.trim(); await ThumbnailService.shared.trim()
        print("PASS: bounded external thumbnail; 1200 decoded-image reuse/eviction cycles; RSS delta MiB=\((Double(after)-Double(before))/1048576)")
        let base = TaskHistory.base; try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let preservedFile = base.appendingPathComponent("owned-preserved.mp4"); try Data([1,2,3]).write(to: preservedFile)
        let a = AppModel(), b = AppModel()
        for task in [a,b] { task.phase = "下载完成"; task.completedItems = [.init(path: preservedFile.path, title: "owned", source: "", identifier: "owned", finishedAt: Date())] }
        let ids: Set<UUID> = [a.id,b.id]
        let archived = try TaskStore.shared.archiveMany(ids); try require(archived == 2, "bulk archive")
        let removed = try TaskStore.shared.deleteArchivedMany(ids); try require(removed == 2, "bulk delete")
        try require(FileManager.default.fileExists(atPath: preservedFile.path), "bulk delete touched media")
        try require(MediaLibrary.shared.items.contains { $0.path == preservedFile.path }, "bulk delete lost independent media index")
        print("PASS: bulk archive/delete commits preserve actual media and independent library")
    }
}
