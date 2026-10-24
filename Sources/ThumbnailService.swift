import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import SwiftUI

actor ThumbnailService {
    static let shared = ThumbnailService()
    private let memory = NSCache<NSString, NSData>()
    private var requests: [String: Task<Data?, Never>] = [:]
    private var leases: [String: Set<UUID>] = [:]
    private var visible = Set<String>()
    private var active = 0
    private let directory: URL
    init() {
        memory.totalCostLimit = MemoryBudget.encodedBytes
        memory.countLimit = 128
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.pili.downloader/thumbnails-v2", isDirectory: true)
    }
    func data(key: String, poster: URL?, file: URL?, prefetch: Bool = false) async -> Data? {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if let hit = memory.object(forKey: hash as NSString) { return hit as Data }
        while requests.count >= 24 && requests[hash] == nil {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        let lease = UUID()
        if !prefetch { visible.insert(hash) }
        leases[hash, default: []].insert(lease)
        let task: Task<Data?, Never>
        if let existing = requests[hash] { task = existing }
        else { task = Task { await self.load(hash: hash, poster: ArtworkURL.normalized(poster?.absoluteString), file: file) }; requests[hash] = task }
        return await withTaskCancellationHandler {
            let result = await task.value
            release(hash: hash, lease: lease)
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { await self.release(hash: hash, lease: lease) }
        }
    }
    private func release(hash: String, lease: UUID) {
        leases[hash]?.remove(lease)
        if leases[hash]?.isEmpty == true {
            leases.removeValue(forKey: hash)
            visible.remove(hash)
            requests.removeValue(forKey: hash)?.cancel()
        }
    }
    private func load(hash: String, poster: URL?, file: URL?) async -> Data? {
        let path = directory.appendingPathComponent(hash + ".jpg")
        if let hit = try? Data(contentsOf: path) {
            memory.setObject(hit as NSData, forKey: hash as NSString, cost: hit.count)
            return hit
        }
        while active >= 1 || (!visible.contains(hash) && !visible.isEmpty) {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        active += 1
        defer { active -= 1 }
        var data: Data?
        if let poster, poster.scheme == "https" {
            var request = URLRequest(url: poster)
            request.timeoutInterval = 15
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
            if let raw = await BoundedImageDownload.fetch(request) {
                data = await Task.detached(priority: .utility) { autoreleasepool { Self.downsample(raw) } }.value
            }
        }
        if data == nil, !Task.isCancelled, let file, FileManager.default.fileExists(atPath: file.path),
           let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools/ffmpeg") {
            data = await Task.detached(priority: .utility) {
                LocalThumbnailWorker.jpeg(file: file, executable: tools)
            }.value
        }
        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
            memory.setObject(data as NSData, forKey: hash as NSString, cost: data.count)
        }
        return data
    }
    private nonisolated static func downsample(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary) else { return nil }
        return jpeg(image)
    }
    private nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
    func trim() {
        memory.removeAllObjects()
        for (key, task) in requests where !visible.contains(key) { task.cancel() }
    }
}

struct CachedArtwork: View {
    let key: String
    let poster: URL?
    var file: URL? = nil
    @State private var artwork: NSImage?
    @State private var loadFinished = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.55), .purple.opacity(0.18), .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.white.opacity(0.5))
                    if loadFinished { Text("封面暂不可用").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                    else { ProgressView().controlSize(.small) }
                }
            }
        }
        .clipped()
        .task(id: key + (poster?.absoluteString ?? "")) {
            loadFinished = false
            let data = await ThumbnailService.shared.data(key: key + (poster?.absoluteString ?? "local"), poster: poster, file: file)
            guard !Task.isCancelled else { return }
            artwork = data.flatMap { ArtworkImageCache.shared.image(key: key + (poster?.absoluteString ?? "local"), data: $0) }
            loadFinished = true
        }
        .onDisappear { artwork = nil }
    }
}
