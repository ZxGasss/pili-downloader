import Foundation
import AppKit
import CryptoKit

struct LibraryMedia: Codable, Identifiable {
    let id: UUID
    var path: String
    var title: String
    var source: String
    var sourceID: String
    var poster: String?
    var resourceID: String?
    var fingerprint: String?
    var bytes: Int64?
    var category: String
    var importedAt: Date
    var missing: Bool
    var previousPaths: [String]
    var file: URL { URL(fileURLWithPath: path) }
}

struct LibrarySnapshot: Codable {
    var version = 2
    var items: [LibraryMedia]
}

enum MediaIdentity {
    static let extensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts", "flv"]
    static func resource(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
    static func fingerprint(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var hash = SHA256(); hash.update(data: Data(String(size).utf8))
            for offset in Set([UInt64(0), size / 2, size > 65536 ? size - 65536 : 0]) {
                try handle.seek(toOffset: offset)
                hash.update(data: try handle.read(upToCount: 65536) ?? Data())
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
}

@MainActor final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()
    @Published private(set) var items: [LibraryMedia] = []
    @Published var message = ""
    @Published var scanning = false
    private var writable = true
    private var pendingImport = false
    private var imports: [String: CompletedDownload] = [:]
    private var importingPaths = Set<String>()
    private let url: URL
    init(url: URL = TaskHistory.base.appendingPathComponent("media-library-v2.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 2 else { throw AppFailure.message("媒体索引版本不兼容") }
            items = snapshot.items
        } catch { writable = false; message = "媒体索引读取失败，原文件已保留；不会覆盖。" }
    }
    func ingest(_ completed: [CompletedDownload], posters: [String: String] = [:]) {
        guard writable else { return }
        let known = Set(items.map(\.path)).union(importingPaths)
        for entry in completed where !known.contains(entry.path) {
            if imports.count < 5000 || imports[entry.path] != nil { imports[entry.path] = entry }
        }
        guard !imports.isEmpty else { return }
        guard !pendingImport else { return }
        pendingImport = true
        Task {
            while !imports.isEmpty {
                let batch = Array(imports.values); imports.removeAll(keepingCapacity: true)
                var seen = Set(items.map(\.path))
                let fresh = batch.filter { seen.insert($0.path).inserted }
                if fresh.isEmpty { continue }
                importingPaths = Set(fresh.map(\.path))
                let additions = await Task.detached(priority: .utility) {
                    fresh.map { entry in
                        let file = URL(fileURLWithPath: entry.path)
                        return LibraryMedia(id: UUID(), path: entry.path, title: entry.title, source: entry.source,
                            sourceID: entry.identifier, poster: posters[entry.path], resourceID: MediaIdentity.resource(file),
                            fingerprint: MediaIdentity.fingerprint(file), bytes: entry.bytes, category: "未归类",
                            importedAt: entry.finishedAt, missing: !FileManager.default.fileExists(atPath: file.path), previousPaths: [])
                    }
                }.value
                // Finder renames and organizer moves retain the same identity on this volume.
                for var addition in additions {
                    if items.contains(where: { $0.path == addition.path }) { continue }
                    if let key = addition.resourceID, let index = items.firstIndex(where: { $0.resourceID == key }) {
                        items[index].previousPaths.append(items[index].path)
                        items[index].path = addition.path; items[index].missing = addition.missing
                    } else {
                        addition.poster = posters[addition.path]; items.append(addition)
                        // Historical import only indexes records; artwork is demand-loaded by visible cells.
                    }
                }
                save()
                importingPaths.removeAll(keepingCapacity: true)
            }
            pendingImport = false
        }
    }
    func scan(_ folder: URL) async {
        guard writable, !scanning else { return }
        guard !TaskStore.shared.tasks.contains(where: \.busy) else { message = "请先暂停所有下载并等待停止，再扫描媒体目录。"; return }
        scanning = true; message = "正在扫描，原文件保持不变…"
        defer { scanning = false }
        let old = items
        let result = await Task.detached(priority: .utility) {
            var found: [LibraryMedia] = []
            let fm = FileManager.default
            let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var visited = 0
            while let file = enumerator?.nextObject() as? URL, visited < 10000 {
                visited += 1
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      MediaIdentity.extensions.contains(file.pathExtension.lowercased()) else { continue }
                let resource = MediaIdentity.resource(file)
                let fingerprint = MediaIdentity.fingerprint(file)
                let byPath = old.first { $0.path == file.path }
                let byResource = old.first { resource != nil && $0.resourceID == resource }
                // Cross-volume sample hashes are candidates only; never silently merge distinct copies.
                var item = byPath ?? byResource ?? LibraryMedia(id: UUID(), path: file.path, title: file.deletingPathExtension().lastPathComponent,
                    source: "", sourceID: "", poster: nil, resourceID: resource, fingerprint: fingerprint,
                    bytes: values.fileSize.map(Int64.init), category: "未归类", importedAt: Date(), missing: false, previousPaths: [])
                if item.path != file.path { item.previousPaths.append(item.path) }
                item.path = file.path; item.resourceID = resource; item.fingerprint = fingerprint; item.missing = false
                found.append(item)
            }
            return (found, visited >= 10000)
        }.value
        for item in result.0 {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                let oldPath = items[index].path
                items[index] = item
                if oldPath != item.path { updateTaskReferences(from: oldPath, to: item.path) }
            }
            else if !items.contains(where: { $0.path == item.path }) { items.append(item) }
        }
        for index in items.indices { items[index].missing = !FileManager.default.fileExists(atPath: items[index].path) }
        save(); message = "扫描到 \(result.0.count) 个视频，未移动或删除文件。" + (result.1 ? "达到10000项上限，请分目录扫描。" : "")
    }
    func classify(_ id: UUID, category: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].category = category; save()
    }
    func classifyMany(_ categories: [UUID: String]) {
        guard writable else { return }
        var updated = items
        for index in updated.indices { if let category = categories[updated[index].id] { updated[index].category = category } }
        items = updated; save()
    }
    func preserveRecords(_ records: [CompletedDownload]) throws {
        guard writable else { throw AppFailure.message("媒体索引不可写，已停止删除记录。") }
        var updated = items, seen = Set(items.map(\.path))
        for entry in records where seen.insert(entry.path).inserted {
            let file = URL(fileURLWithPath: entry.path)
            updated.append(LibraryMedia(id: UUID(), path: entry.path, title: entry.title, source: entry.source,
                sourceID: entry.identifier, poster: nil, resourceID: MediaIdentity.resource(file), fingerprint: nil,
                bytes: entry.bytes, category: "未归类", importedAt: entry.finishedAt,
                missing: !FileManager.default.fileExists(atPath: entry.path), previousPaths: []))
        }
        guard updated.count != items.count else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(LibrarySnapshot(items: updated)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        items = updated
    }
    func relink(_ id: UUID, to file: URL) async throws {
        guard !TaskStore.shared.tasks.contains(where: \.busy) else { throw AppFailure.message("请先暂停下载，再重新定位媒体。") }
        guard let index = items.firstIndex(where: { $0.id == id }), MediaIdentity.extensions.contains(file.pathExtension.lowercased()),
              !items.contains(where: { $0.id != id && $0.path == file.path }) else { throw AppFailure.message("文件已关联或不是支持的视频。") }
        let identity = await Task.detached { (MediaIdentity.resource(file), MediaIdentity.fingerprint(file)) }.value
        guard !TaskStore.shared.tasks.contains(where: \.busy) else { throw AppFailure.message("下载已开始，本次重定位未提交。") }
        let oldPath = items[index].path
        items[index].previousPaths.append(oldPath)
        items[index].path = file.path; items[index].resourceID = identity.0; items[index].fingerprint = identity.1; items[index].missing = false
        updateTaskReferences(from: oldPath, to: file.path)
        save()
    }
    func trash(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        guard !TaskStore.shared.tasks.contains(where: { $0.busy && (item.path.hasPrefix($0.folder.path + "/") || $0.completedItems.contains(where: { $0.path == item.path })) }) else {
            throw AppFailure.message("目录内有活动任务，请先暂停并等待停止。")
        }
        try FileManager.default.trashItem(at: item.file, resultingItemURL: nil)
        items[index].missing = true; save()
    }
    private func save() {
        guard writable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(LibrarySnapshot(items: items)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = "媒体索引保存失败：" + InputPolicy.safeLog(error.localizedDescription) }
    }
    private func updateTaskReferences(from oldPath: String, to newPath: String) {
        for task in TaskStore.shared.tasks {
            guard !task.busy else { continue }
            task.completedItems = task.completedItems.map { entry in
                guard entry.path == oldPath else { return entry }
                return CompletedDownload(path: newPath, title: entry.title, source: entry.source,
                    identifier: entry.identifier, finishedAt: entry.finishedAt, bytes: entry.bytes)
            }
            if task.completedFile?.path == oldPath { task.completedFile = URL(fileURLWithPath: newPath) }
        }
        TaskStore.shared.saveSoon()
    }
}
