import Foundation

@MainActor enum FileOperationGuard {
    private(set) static var moving = false
    static func perform<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard !moving, !TaskStore.shared.tasks.contains(where: \.busy) else {
            throw AppFailure.message("请先暂停所有下载并等待停止，再执行文件整理。")
        }
        moving = true
        defer { moving = false }
        return try await Task.detached(priority: .utility, operation: operation).value
    }
}

struct ResidualCandidate: Identifiable {
    var id: String { file.path }
    let file: URL
    let completed: URL
    let bytes: Int64
    let modified: Date
}

enum FileOrganizer {
    @MainActor static func protectedByRecoverableTask(_ file: URL) -> Bool {
        TaskStore.shared.tasks.contains { task in
            // Older histories persisted phase text but did not persist errors/lifecycle.
            let legacyStopped = ["未完成", "中断", "暂停", "取消"].contains { task.phase.contains($0) }
            let recoverable = task.busy || task.paused || task.error != nil || task.lifecycle == .cancelled || legacyStopped
            return recoverable && file.standardizedFileURL.path.hasPrefix(task.folder.standardizedFileURL.path + "/")
        }
    }
    /// Only exact basename/format-track associations qualify. Never guess from season titles.
    static func matchingProduct(for residual: URL, products: [URL]) -> URL? {
        let name = residual.lastPathComponent
        guard ["part", "ytdl", "aria2"].contains(residual.pathExtension.lowercased()) else { return nil }
        var core = residual
        while ["part", "ytdl", "aria2"].contains(core.pathExtension.lowercased()) { core = core.deletingPathExtension() }
        var stem = core.lastPathComponent
        if let range = stem.range(of: #"\.f[0-9A-Za-z_-]+\.(?:mp4|m4a|webm)$"#, options: .regularExpression) {
            stem = String(stem[..<range.lowerBound])
        } else if let range = stem.range(of: #"\.(?:mp4|mkv|webm|m4a)$"#, options: .regularExpression) {
            stem = String(stem[..<range.lowerBound])
        }
        guard !name.isEmpty, !stem.isEmpty else { return nil }
        let matches = products.filter {
            $0.deletingLastPathComponent() == residual.deletingLastPathComponent()
                && $0.deletingPathExtension().lastPathComponent == stem
        }
        return matches.count == 1 ? matches[0] : nil
    }
    @MainActor static func residuals(folder: URL, products: [URL], tools: URL) async -> [ResidualCandidate] {
        let candidates = await Task.detached(priority: .utility) {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var result: [ResidualCandidate] = []; var visited = 0
            while let file = files?.nextObject() as? URL, visited < 10000 {
                visited += 1
                guard let product = matchingProduct(for: file, products: products),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                result.append(ResidualCandidate(file: file, completed: product, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
            return result
        }.value
        var verified = Set<URL>()
        for product in Set(candidates.map(\.completed)) {
            if (try? await MediaIntegrity.inspect(product, tools: tools)) != nil { verified.insert(product) }
        }
        return candidates.filter { verified.contains($0.completed) && !protectedByRecoverableTask($0.file) }
    }
    @MainActor static func trashResiduals(_ candidates: [ResidualCandidate]) async throws -> Int {
        guard !TaskStore.shared.tasks.contains(where: \.busy) else { throw AppFailure.message("请先暂停所有任务并等待停止，避免清理续传分片。") }
        guard candidates.allSatisfy({ !protectedByRecoverableTask($0.file) }) else { throw AppFailure.message("目录内有可恢复任务，这些分片需要保留，请勿清理。") }
        let tools = Bundle.main.resourceURL!.appendingPathComponent("Tools")
        // Recheck product and file attributes immediately before the user-approved operation.
        for candidate in candidates {
            _ = try await MediaIntegrity.inspect(candidate.completed, tools: tools)
            let values = try candidate.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == candidate.bytes,
                  values.contentModificationDate == candidate.modified else { throw AppFailure.message("残留文件已变化，已停止清理，请重新预览。") }
        }
        for candidate in candidates {
            guard !TaskStore.shared.tasks.contains(where: \.busy) else { throw AppFailure.message("检测到新下载任务，停止清理。") }
            guard !protectedByRecoverableTask(candidate.file) else { throw AppFailure.message("检测到可恢复任务，已保留其分片。") }
            try FileManager.default.trashItem(at: candidate.file, resultingItemURL: nil)
        }
        return candidates.count
    }
    @MainActor static func resolutionPlan(folder: URL, tools: URL) async throws -> (MediaRenamePlan, [String]) {
        let files = await Task.detached(priority: .utility) {
            let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var result: [URL] = []; var visited = 0
            while let file = entries?.nextObject() as? URL, visited < 10000 {
                visited += 1
                guard MediaIdentity.extensions.contains(file.pathExtension.lowercased()),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                result.append(file)
            }
            return result.sorted { $0.path < $1.path }
        }.value
        var plan: [MediaRenameItem] = []; var reports: [String] = []
        for file in files {
            try Task.checkCancellation()
            var spotlight: [String] = []
            try? await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/mdls"),
                arguments: ["-name", "kMDItemPixelWidth", "-name", "kMDItemPixelHeight", "-name", "kMDItemCodecs", file.path], timeout: 10) { spotlight.append($0) }
            do {
                let probe = try await MediaIntegrity.inspect(file, tools: tools)
                reports.append(file.lastPathComponent + " | " + spotlight.joined(separator: " ") + " | ffmpeg: " + probe.report)
                guard let height = probe.height else { continue }
                let revised = file.lastPathComponent.replacingOccurrences(of: #"\b[0-9]{3,5}p\b"#, with: "\(height)p", options: .regularExpression)
                if revised != file.lastPathComponent {
                    plan.append(MediaRenameItem(oldPath: file.path, newPath: file.deletingLastPathComponent().appendingPathComponent(revised).path))
                }
            } catch { reports.append(file.lastPathComponent + " | 检查失败，保留原文件：" + InputPolicy.safeLog(error.localizedDescription)) }
        }
        return (MediaRenamePlan(root: folder.path, generatedAt: Date(), items: plan), reports)
    }
}
