import Foundation

struct CompletedDownload: Codable, Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let source: String
    let identifier: String
    let finishedAt: Date
    var bytes: Int64? = nil
}

struct TaskRecord: Codable {
    let id: UUID
    let address: String
    let folder: String
    let video: VideoInfo?
    let selectedFormat: String
    let episodes: [Episode]
    let currentEpisode: Episode?
    let scope: String
    let start: Int
    let end: Int
    let connections: Int
    let container: String
    let permission: Bool
    let phase: String
    let wasRunning: Bool
    let completed: [CompletedDownload]
    var additionalLinks: [String]? = nil
    var parentID: UUID? = nil
    var groupConcurrency: Int? = nil
    var currentVideo: VideoInfo? = nil
    var options: AdvancedOptions? = nil
    var segmentID: String? = nil
    var assignedEpisodeIDs: [String]? = nil
    var plannedEpisodeIDs: [String]? = nil
    var runningChildIDs: [UUID]? = nil
    var archived: Bool? = nil
    var lifecycle: String? = nil
    var checkpoint: TransferProgress? = nil
    var streamCheckpoints: [String: TransferProgress]? = nil
    var resumeAfterExit: Bool? = nil
}

enum TaskHistory {
    private static let upgradeLock = NSLock()
    private static var protectedHistories = Set<URL>()

    static var base: URL {
        let bundle = Bundle.main.bundleIdentifier ?? "local.pili.downloader"
        if bundle.contains(".preview"), let path = Bundle.main.object(forInfoDictionaryKey: "PiliExperimentRoot") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let directory = bundle.contains(".preview") ? "PiliDownloader-Tests-" + bundle : "PiliDownloader"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent(directory)
    }
    static var url: URL { base.appendingPathComponent("tasks.json") }
    static func read(from url: URL = url) throws -> [TaskRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: url))
    }
    static func write(_ records: [TaskRecord], to url: URL = url) throws {
        // Encode before touching disk. Keep the legacy array format readable by older apps.
        let data = try autoreleasepool {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(records)
        }
        try writeEncoded(data, to: url)
    }
    static func writeEncoded(_ data: Data, to url: URL = url) throws {
        upgradeLock.lock()
        defer { upgradeLock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = url.standardizedFileURL
        if !protectedHistories.contains(key), FileManager.default.fileExists(atPath: url.path) {
            let original = try Data(contentsOf: url)
            // A corrupt or newer incompatible history must never become an empty library.
            try autoreleasepool { _ = try JSONDecoder().decode([TaskRecord].self, from: original) }
            if original != data {
                let directory = url.deletingLastPathComponent().appendingPathComponent("history-backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let snapshot = directory.appendingPathComponent("tasks-before-upgrade-\(UUID().uuidString).json")
                guard FileManager.default.createFile(atPath: snapshot.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
                    throw AppFailure.message("无法备份旧版任务历史，已停止写入；原记录保留。")
                }
                guard try Data(contentsOf: snapshot) == original else {
                    throw AppFailure.message("旧版任务历史备份校验失败，已停止写入；原记录保留。")
                }
                protectedHistories.insert(key)
            }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func publicURL(_ url: URL) -> String {
        InputPolicy.canonicalURL(url)
    }
    static func appendSourceLog(folder: URL, message: String) throws {
        let url = folder.appendingPathComponent("下载日志.txt")
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let text = "[\(formatter.string(from: Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw AppFailure.message("无法创建来源日志。") }
        }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        _ = try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
}
