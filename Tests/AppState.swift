import AppKit
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "检查失败",
           file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("TEST_FAILED \(file):\(line): \(message())\n".utf8))
        exit(1)
    }
}

@main struct AppStateTests {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("TEST_FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        check(Bundle.main.bundleIdentifier?.contains(".preview") == true)
        let root = TaskHistory.base
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(catalogueProvider: { _, _ in [] })
        model.address = "https://www.bilibili.com/video/BVfixtureA"
        model.additionalLinks = ["https://www.bilibili.com/video/BVfixtureB"]
        model.folder = root; model.permissionConfirmed = true
        model.download()
        while model.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        check(model.phase == "下载完成", model.error ?? model.phase)
        check(model.children.count == 2 && model.completedItems.count == 2)
        check(model.children.allSatisfy { $0.displayVideo?.title.contains("测试") == true && $0.displayCover != nil })
        TaskStore.shared.saveNow()
        let records = try TaskHistory.read()
        check(records.count == 3 && records.filter { $0.parentID == model.id }.count == 2)
        var interrupted = model.children[0].record
        // Encode the crash marker without touching real history or account data.
        let data = try JSONEncoder().encode(interrupted)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["wasRunning"] = true
        interrupted = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let restored = AppModel(record: interrupted, register: false)
        check(restored.paused && restored.phase == "已暂停，可继续" && restored.completedItems.count == 1 && restored.displayCover != nil)
        let fixture = HTTPCookie(properties: [.name: "pili_owned_fixture", .value: "synthetic-only", .domain: ".bilibili.com", .path: "/", .expires: Date().addingTimeInterval(300)])!
        let remembered = RememberedCookie(fixture)
        let roundTrip = try JSONDecoder().decode(RememberedCookie.self, from: JSONEncoder().encode(remembered))
        check(roundTrip.cookie?.name == "pili_owned_fixture" && roundTrip.cookie?.value == "synthetic-only")
        let sequence = (1...24).map { Episode(id: "ep\($0)", index: $0, title: "测试第\($0)集", thumbnail: "https://example.invalid/\($0).jpg", url: URL(string: "https://www.bilibili.com/bangumi/play/ep\($0)")!, bvid: nil) }
        let grouped = AppModel(catalogueProvider: { _, _ in sequence }, prefetchEnabled: false)
        grouped.address = "https://www.bilibili.com/bangumi/play/ss999999"
        grouped.folder = root.appendingPathComponent("batches"); try FileManager.default.createDirectory(at: grouped.folder, withIntermediateDirectories: true)
        grouped.scope = "整季"; grouped.permissionConfirmed = true
        grouped.options.episodeBatchSize = nil; grouped.options.simultaneousBatches = 2; grouped.options.movieNaming = false
        grouped.download()
        var observedPeak = 0
        while grouped.busy || grouped.phase == "已选择最高可用画质" {
            observedPeak = max(observedPeak, grouped.activeEpisodeCount)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        for _ in 0..<100 where Set(grouped.completedItems.map(\.identifier)).count < 24 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(grouped.phase == "下载完成", grouped.error ?? grouped.phase)
        check(grouped.episodeConcurrencyLimit == 2 && observedPeak == 2)
        check(grouped.children.count == 24 && grouped.children.allSatisfy { $0.assignedEpisodeIDs.count == 1 })
        check(Set(grouped.completedItems.map(\.identifier)).count == 24)
        check(grouped.seasonEstimate.completed == 24)
        let events = try String(contentsOf: grouped.folder.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let starts = events.filter { $0["event"] as? String == "start" }.map { $0["id"] as! String }
        check(starts.count == 24 && Set(starts).count == 24)
        for episode in 1...24 { check(starts.filter { $0 == "ep\(episode)" }.count == 1) }
        print("PASS: two-link group completes; child metadata/thumb; durable relationships/files; interrupted restoration; session-cookie roundtrip")
        print("PASS: 24 episodes are independent; peak concurrency is exactly 2; all files validated; aggregate completion")
        let fill = AppModel(catalogueProvider: { _, _ in sequence }, prefetchEnabled: false)
        fill.address = "https://www.bilibili.com/bangumi/play/ss999998"
        fill.folder = root.appendingPathComponent("fill-missing")
        let fillSeries = fill.folder.appendingPathComponent("自制解析测试")
        try FileManager.default.createDirectory(at: fillSeries, withIntermediateDirectories: true)
        for index in 1...18 {
            try Data([1, 2, 3]).write(to: fillSeries.appendingPathComponent(String(format: "%03d - 测试第%d集.mp4", index, index)))
        }
        fill.permissionConfirmed = true
        fill.options.movieNaming = false
        fill.fillMissingEpisodes()
        while fill.busy || fill.phase == "已选择最高可用画质" { try await Task.sleep(nanoseconds: 50_000_000) }
        check(fill.phase == "下载完成", fill.error ?? fill.phase)
        check(fill.children.count == 6 && Set(fill.children.compactMap { $0.currentEpisode?.index }) == Set(19...24))
        check(fill.completedItems.count == 24)
        print("PASS: fill-missing found 18 existing episodes and downloaded only episodes 19–24")
        let retry = AppModel(catalogueProvider: { _, _ in [] })
        retry.address = "https://www.bilibili.com/video/BVrecovery"; retry.folder = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: retry.folder, withIntermediateDirectories: true)
        try Data().write(to: retry.folder.appendingPathComponent("recover-once"))
        retry.permissionConfirmed = true
        retry.inspect(resumeAfter: true)
        while retry.busy || retry.phase == "已选择最高可用画质" { try await Task.sleep(nanoseconds: 100_000_000) }
        check(retry.phase == "下载完成", retry.error ?? retry.phase)
        check(retry.logs.contains { $0.contains("第1次恢复") })
        check(retry.completedItems.count == 1)
        let pausable = AppModel(catalogueProvider: { _, _ in [] })
        pausable.address = "https://www.bilibili.com/video/BVpauseTest"
        pausable.folder = root.appendingPathComponent("pause-resume")
        try FileManager.default.createDirectory(at: pausable.folder, withIntermediateDirectories: true)
        try Data().write(to: pausable.folder.appendingPathComponent("slow-fixture"))
        pausable.permissionConfirmed = true
        pausable.inspect(resumeAfter: true)
        let part = pausable.folder.appendingPathComponent("owned-resume.part")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: part.path), pausable.progress.downloaded ?? 0 > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(pausable.busy && FileManager.default.fileExists(atPath: part.path), "pause fixture never started")
        pausable.pause()
        for _ in 0..<200 {
            if !pausable.busy { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(!pausable.busy && pausable.paused, "pause did not stop the transfer")
        check(FileOrganizer.protectedByRecoverableTask(part), "paused task's part must be excluded from cleanup")
        let pausedBytes = try Data(contentsOf: part).count
        try await Task.sleep(nanoseconds: 500_000_000)
        let stoppedBytes = try Data(contentsOf: part).count
        check(pausedBytes > 0 && pausedBytes == stoppedBytes, "paused fixture kept growing")
        let pausedRecord = pausable.record
        let pausedRestoration = AppModel(record: pausedRecord, register: false)
        check(pausedRestoration.paused && pausedRestoration.progress.downloaded == pausable.progress.downloaded)
        pausable.resume()
        for _ in 0..<500 {
            if !pausable.busy && pausable.phase == "下载完成" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(pausable.phase == "下载完成", pausable.error ?? pausable.phase)
        check(!FileManager.default.fileExists(atPath: part.path), "completed fixture left its owned part")
        print("PASS: pause stops process and byte growth; checkpoint restores; resume completes and leaves no owned part")
        check(SeasonProgress.fraction(total: 200, completed: 20, active: [0.5, 0.5]) == 0.105)
        check(SeasonProgress.fraction(total: 26, completed: 26, active: [0.9]) == 1)
        let library = MediaLibrary(url: root.appendingPathComponent("test-media-library.json"))
        let mediaRoot = root.appendingPathComponent("media-identity")
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let first = mediaRoot.appendingPathComponent("before.mp4")
        try Data(repeating: 7, count: 4096).write(to: first)
        await library.scan(mediaRoot)
        check(library.items.count == 1)
        let stableID = library.items[0].id
        let renamed = mediaRoot.appendingPathComponent("after.mp4")
        try FileManager.default.moveItem(at: first, to: renamed)
        await library.scan(mediaRoot)
        check(library.items.count == 1 && library.items[0].id == stableID && library.items[0].path == renamed.path)
        let reloadedLibrary = MediaLibrary(url: root.appendingPathComponent("test-media-library.json"))
        check(reloadedLibrary.items.first?.id == stableID)
        let residual = mediaRoot.appendingPathComponent("after.f30125.mp4.part")
        check(FileOrganizer.matchingProduct(for: residual, products: [renamed]) == renamed)
        check(FileOrganizer.matchingProduct(for: mediaRoot.appendingPathComponent("after.f30125.mp4.part.aria2"), products: [renamed]) == renamed)
        check(FileOrganizer.matchingProduct(for: mediaRoot.appendingPathComponent("after.tmp"), products: [renamed]) == nil)
        check(FileOrganizer.matchingProduct(for: mediaRoot.appendingPathComponent("unknown.mp4.part"), products: [renamed]) == nil)
        check(FileOrganizer.matchingProduct(for: renamed, products: [renamed]) == nil)
        print("PASS: media identity survives Finder rename and reload; unknown parts and final videos never qualify for cleanup")
        let keychainFixture = Data("isolated-test-cookie".utf8)
        try AccountSecurity.write(keychainFixture, account: "owned-fixture")
        let keychainRead = try AccountSecurity.read("owned-fixture")
        check(keychainRead == keychainFixture)
        try AccountSecurity.remove("owned-fixture")
        let clearedKeychainRead = try AccountSecurity.read("owned-fixture")
        check(clearedKeychainRead == nil)
        print("PASS: isolated preview Keychain write/read/clear; production credentials untouched")
        var globalGroups: [AppModel] = []
        for number in 0..<2 {
            let task = AppModel(catalogueProvider: { _, _ in Array(sequence.prefix(6)) }, prefetchEnabled: false)
            task.address = "https://www.bilibili.com/bangumi/play/ss\(999990 + number)"
            task.folder = root.appendingPathComponent("global-limit-\(number)")
            try FileManager.default.createDirectory(at: task.folder, withIntermediateDirectories: true)
            task.scope = "整季"; task.permissionConfirmed = true
            task.options.simultaneousBatches = 4; task.options.movieNaming = false
            globalGroups.append(task); task.download()
        }
        var globalPeak = 0
        for _ in 0..<2000 {
            globalPeak = max(globalPeak, globalGroups.flatMap(\.children).filter(\.downloading).count)
            if globalGroups.allSatisfy({ !$0.busy && $0.phase == "下载完成" }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(globalGroups.allSatisfy { $0.phase == "下载完成" && $0.completedItems.count == 6 })
        check(globalPeak > 0 && globalPeak <= 4, "global episode concurrency exceeded four")
        print("PASS: two seasons share the four-episode global budget; 12 files complete")
        let sampler = HardwareSampler()
        _ = sampler.read(folder: root)
        try await Task.sleep(nanoseconds: 150_000_000)
        var sample = sampler.read(folder: root)
        // macOS may return cached host ticks across short intervals; wait for a real delta.
        for _ in 0..<15 where sample.cpu == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            sample = sampler.read(folder: root)
        }
        check((sample.cpu ?? -1) >= 0 && (sample.cpu ?? 101) <= 100)
        check(sample.memory > 0 && sample.memory <= ProcessInfo.processInfo.physicalMemory)
        check(sample.capacity > 0 && sample.free <= sample.capacity && sample.appMemory > 0)
        check(sample.diskRead != nil && sample.diskWrite != nil)
        check(ProcessorCatalog.match("Apple M3")?.name == "Apple M3")
        check(ProcessorCatalog.match("Apple M3 Max")?.name == "Apple M3 Max")
        check(ProcessorCatalog.match("Apple M5 Ultra")?.name == "Apple M5 Ultra")
        check(ProcessorCatalog.match("Apple M6")?.name == "Apple M6")
        check(ProcessorCatalog.match("Apple A18 Pro")?.name == "Apple A18 Pro")
        check(ProcessorCatalog.match("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")?.name == "Intel Core i7")
        let fixed = FixedFrequencyReader.current
        check((fixed.performance ?? 0) > 2 && (fixed.efficiency ?? 0) > 1 && (fixed.gpu ?? 0) > 0.5)
        check(MediaIntegrity.reportedHeight(in: "Stream #0:0: Video: h264, 3840x2160, 23.98 fps") == 2160)
        check(MediaIntegrity.reportedHeight(in: "Stream #0:0: Video: hevc, 1080x1920, 30 fps") == 1080)
        check(!HardwareMonitor.shared.mainScreenLabel.isEmpty)
        print("PASS: transient transfer automatically retried once and validated; hardware CPU/memory/storage/disk counters sampled without privileges")
    }
}
