import AppKit
import Foundation

@MainActor enum AppArtwork {
    static let icon: NSImage = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns") else { return NSImage() }
        return NSImage(contentsOf: url) ?? NSImage()
    }()
}

@MainActor final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.totalCostLimit = MemoryBudget.decodedBytes; cache.countLimit = 24 }
    func image(key: String, data: Data) -> NSImage? {
        if let image = cache.object(forKey: key as NSString) { return image }
        return autoreleasepool {
            guard let image = NSImage(data: data) else { return nil }
            let cost = max(1, Int(image.size.width) * Int(image.size.height) * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        }
    }
    func trim() { cache.removeAllObjects() }
}

@MainActor final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    private var source: DispatchSourceMemoryPressure?
    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            let critical = source.data.contains(.critical)
            Task { @MainActor in
                ArtworkImageCache.shared.trim()
                await ThumbnailService.shared.trim()
                if critical {
                    TaskStore.shared.memoryNotice = "系统内存压力过高，下载已安全暂停，分片保留；释放内存后可继续。"
                    TaskStore.shared.tasks.filter { $0.parentID == nil && $0.busy }.forEach { $0.pause() }
                }
            }
        }
        self.source = source; source.resume()
    }
}
