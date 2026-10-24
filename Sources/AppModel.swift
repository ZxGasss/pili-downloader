import AppKit
import SwiftUI
import Combine

@MainActor final class TaskStore: ObservableObject {
    static let shared = TaskStore()
    @Published var tasks: [AppModel] = []
    @Published var storageError = ""
    @Published var memoryNotice = ""
    @Published var residualCandidates: [ResidualCandidate] = []
    private var auditSignatures = Set<String>()
    private var batchLaunchTask: Task<Void, Never>?
    private var batchGeneration: UUID?
    @Published var batchStatus = ""
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?
    private var lastSnapshot: Data?
    private var writable = true
    var canPersist: Bool { writable }
    private var checkpointTimer: Timer?
    private init() {
        do { for record in try TaskHistory.read() { register(AppModel(record: record, register: false)) } }
        catch { storageError = "历史读取失败，原文件已保留；本次不覆盖历史。"; writable = false }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in if TaskStore.shared.tasks.contains(where: \.busy) { TaskStore.shared.saveNow() } }
        }
    }
    func register(_ model: AppModel) {
        tasks.append(model)
        subscriptions[model.id] = model.objectWillChange.sink { [weak self] _ in self?.saveSoon() }
        saveSoon()
    }
    private func family(_ id: UUID) -> [AppModel] {
        var ids: Set<UUID> = [id]
        var previous = 0
        while previous != ids.count {
            previous = ids.count
            for task in tasks where task.parentID.map(ids.contains) == true { ids.insert(task.id) }
        }
        return tasks.filter { ids.contains($0.id) }
    }
    func canArchive(_ id: UUID) -> Bool {
        writable && tasks.contains { $0.id == id && $0.parentID == nil && !$0.archived }
            && !family(id).contains(where: \.busy)
    }
    @discardableResult func archive(_ id: UUID) -> Bool {
        guard canArchive(id) else { return false }
        return setArchived(id, true)
    }
    @discardableResult func restore(_ id: UUID) -> Bool { setArchived(id, false) }
    @discardableResult func deleteArchived(_ id: UUID) -> Bool {
        guard writable, tasks.contains(where: { $0.id == id && $0.parentID == nil && $0.archived }) else { return false }
        let members = family(id), ids = Set(members.map(\.id))
        guard !members.contains(where: \.busy) else { return false }
        do {
            try MediaLibrary.shared.preserveRecords(members.flatMap(\.completedItems))
            try TaskHistory.write(tasks.filter { !ids.contains($0.id) }.map(\.record))
            for member in members { subscriptions.removeValue(forKey: member.id) }
            tasks.removeAll { ids.contains($0.id) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            lastSnapshot = try encoder.encode(tasks.map(\.record))
            objectWillChange.send()
            return true
        } catch {
            storageError = "永久删除记录失败，记录仍保留：" + InputPolicy.safeLog(error.localizedDescription)
            return false
        }
    }
    private func setArchived(_ id: UUID, _ value: Bool) -> Bool {
        guard writable, tasks.contains(where: { $0.id == id && $0.parentID == nil }) else { return false }
        let members = family(id), ids = Set(members.map(\.id))
        guard !members.contains(where: \.busy) else { return false }
        do {
            let records = tasks.map { task -> TaskRecord in
                var record = task.record
                if ids.contains(task.id) { record.archived = value }
                return record
            }
            try TaskHistory.write(records)
            objectWillChange.send()
            members.forEach { $0.archived = value }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            lastSnapshot = try encoder.encode(records)
            return true
        } catch {
            storageError = "记录更新失败，任务仍保留：" + InputPolicy.safeLog(error.localizedDescription)
            return false
        }
    }
    func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }
    @discardableResult func archiveMany(_ ids: Set<UUID>) throws -> Int {
        guard writable else { throw AppFailure.message("历史当前不可写，未移除记录。") }
        let roots = tasks.filter { ids.contains($0.id) && canArchive($0.id) }
        let members = roots.flatMap { family($0.id) }, allIDs = Set(members.map(\.id))
        guard !roots.isEmpty else { return 0 }
        try MediaLibrary.shared.preserveRecords(members.flatMap(\.completedItems))
        let records = tasks.map { task -> TaskRecord in var record = task.record; if allIDs.contains(task.id) { record.archived = true }; return record }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records); try TaskHistory.writeEncoded(data)
        objectWillChange.send(); members.forEach { $0.archived = true }; lastSnapshot = data
        return roots.count
    }
    @discardableResult func deleteArchivedMany(_ ids: Set<UUID>) throws -> Int {
        guard writable else { throw AppFailure.message("历史当前不可写，未删除记录。") }
        let roots = tasks.filter { ids.contains($0.id) && $0.parentID == nil && $0.archived && !family($0.id).contains(where: \.busy) }
        let members = roots.flatMap { family($0.id) }, allIDs = Set(members.map(\.id))
        guard !roots.isEmpty else { return 0 }
        try MediaLibrary.shared.preserveRecords(members.flatMap(\.completedItems))
        let records = tasks.filter { !allIDs.contains($0.id) }.map(\.record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records); try TaskHistory.writeEncoded(data)
        members.forEach { subscriptions.removeValue(forKey: $0.id) }
        tasks.removeAll { allIDs.contains($0.id) }; lastSnapshot = data
        return roots.count
    }
    func saveNow() {
        guard writable else { return }
        do {
            let snapshot = try autoreleasepool {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(tasks.map(\.record))
            }
            if snapshot != lastSnapshot { try TaskHistory.writeEncoded(snapshot); lastSnapshot = snapshot }
            var posters: [String: String] = [:]
            for task in tasks { for entry in task.completedItems { posters[entry.path] = task.video?.coverURL?.absoluteString } }
            MediaLibrary.shared.ingest(tasks.flatMap(\.completedItems), posters: posters)
        } catch { storageError = "历史保存失败：" + InputPolicy.safeLog(error.localizedDescription) }
    }
    func auditCompletedFolder(_ folder: URL) {
        guard !tasks.contains(where: { $0.busy && $0.folder == folder }) else { return }
        let products = Set(tasks.flatMap(\.completedItems).filter { $0.path.hasPrefix(folder.path + "/") }.map { URL(fileURLWithPath: $0.path) })
        guard !products.isEmpty else { return }
        let signature = products.map(\.path).sorted().joined(separator: "\n")
        guard auditSignatures.insert(signature).inserted, let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools") else { return }
        Task {
            let candidates = await FileOrganizer.residuals(folder: folder, products: Array(products), tools: tools)
            let known = Set(residualCandidates.map(\.id))
            residualCandidates.append(contentsOf: candidates.filter { !known.contains($0.id) })
        }
    }
    func startAll() {
        guard batchLaunchTask == nil, writable, !FileOperationGuard.moving else { return }
        let ids = tasks.filter { $0.parentID == nil && !$0.archived && !$0.busy && $0.phase != "下载完成" && $0.permissionConfirmed && !$0.address.isEmpty }.map(\.id)
        guard !ids.isEmpty else { batchStatus = "没有可开始的任务：请填写链接并确认各任务的下载权限。"; return }
        let generation = UUID(); batchGeneration = generation
        batchStatus = "正在按内存预算启动 \(ids.count) 个任务…"
        batchLaunchTask = Task { @MainActor in
            defer { if batchGeneration == generation { batchLaunchTask = nil; batchGeneration = nil } }
            for id in ids {
                while tasks.filter({ $0.parentID == nil && $0.busy }).count >= MemoryBudget.episodes || AccountSession.shared.checking {
                    do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                }
                guard !Task.isCancelled, let task = tasks.first(where: { $0.id == id }), !task.archived, !task.busy else { continue }
                task.resume()
            }
        }
    }
    func pauseAll() {
        batchGeneration = nil; batchStatus = "已请求全部暂停，下载分片保留。"
        batchLaunchTask?.cancel(); batchLaunchTask = nil
        tasks.filter { $0.parentID == nil && !$0.archived && $0.phase != "下载完成" && !$0.address.isEmpty }.forEach { $0.pause() }
        saveNow()
    }
    func cancelAll() {
        batchGeneration = nil; batchStatus = "已请求取消全部队列和活动任务，成品与分片保留。"
        batchLaunchTask?.cancel(); batchLaunchTask = nil
        tasks.filter { $0.parentID == nil && !$0.archived && $0.phase != "下载完成" && !$0.address.isEmpty }.forEach { $0.cancel() }
        saveNow()
    }
}

@MainActor final class AppModel: ObservableObject, Identifiable {
    let id: UUID
    static var tasks: [AppModel] { TaskStore.shared.tasks }
    private let catalogueProvider: ((URL, [HTTPCookie]) async throws -> [Episode])?
    private let prefetchEnabled: Bool
    init(record: TaskRecord? = nil, register: Bool = true,
         catalogueProvider: ((URL, [HTTPCookie]) async throws -> [Episode])? = nil,
         prefetchEnabled: Bool = true) {
        id = record?.id ?? UUID()
        self.catalogueProvider = catalogueProvider
        self.prefetchEnabled = prefetchEnabled
        if let record {
            address = record.address; folder = URL(fileURLWithPath: record.folder); video = record.video
            selectedFormat = record.selectedFormat; episodes = record.episodes; currentEpisode = record.currentEpisode
            scope = record.scope; episodeIndex = record.start; episodeEnd = record.end
            connections = min(MemoryBudget.connections, max(0, record.connections)); container = record.container; permissionConfirmed = record.permission
            phase = record.wasRunning ? "已中断，可继续" : record.phase
            completedItems = record.completed
            additionalLinks = record.additionalLinks ?? []; parentID = record.parentID
            groupConcurrency = record.groupConcurrency ?? 2
            currentVideo = record.currentVideo
            options = record.options ?? AdvancedOptions()
            if ["%(title).140B [%(id)s].%(ext)s", "%(title).140B.%(ext)s"].contains(options.filename) { options.filename = "%(title)s.%(ext)s" }
            segmentID = record.segmentID; assignedEpisodeIDs = record.assignedEpisodeIDs ?? []
            plannedEpisodeIDs = record.plannedEpisodeIDs ?? []
            runningChildIDs = record.runningChildIDs ?? []
            archived = record.archived ?? false
        paused = record.lifecycle == DownloadLifecycle.paused.rawValue || record.wasRunning
        if paused { phase = "已暂停，可继续" }
        if let saved = record.checkpoint {
            progress = saved; progress.speed = "—"; progress.eta = "—"; progress.bytesPerSecond = nil
        }
        streamProgress = record.streamCheckpoints ?? [:]
        resumeAfterExit = record.resumeAfterExit ?? record.wasRunning
            if record.video != nil { inspectedURL = try? InputPolicy.videoURL(record.address) }
            completedFile = record.completed.last.map { URL(fileURLWithPath: $0.path) }
        }
        if register { TaskStore.shared.register(self) }
    }
    var record: TaskRecord {
        TaskRecord(id: id, address: (try? InputPolicy.videoURL(address)).map(TaskHistory.publicURL) ?? address,
            folder: folder.path, video: video, selectedFormat: selectedFormat, episodes: episodes, currentEpisode: currentEpisode,
            scope: scope, start: episodeIndex, end: episodeEnd, connections: connections, container: container,
            permission: permissionConfirmed, phase: phase, wasRunning: busy, completed: completedItems,
            additionalLinks: additionalLinks.map { (try? InputPolicy.videoURL($0)).map(TaskHistory.publicURL) ?? $0 },
            parentID: parentID, groupConcurrency: groupConcurrency, currentVideo: currentVideo, options: options,
            segmentID: segmentID, assignedEpisodeIDs: assignedEpisodeIDs, plannedEpisodeIDs: plannedEpisodeIDs, runningChildIDs: runningChildIDs, archived: archived,
            lifecycle: lifecycle.rawValue, checkpoint: progress, streamCheckpoints: streamProgress,
            resumeAfterExit: (busy && !paused) || resumeAfterExit)
    }
    @Published var address = ""
    @Published var additionalLinks: [String] = []
    @Published var parentID: UUID?
    @Published var archived = false
    @Published var paused = false
    @Published var resumeAfterExit = false
    @Published var streamProgress: [String: TransferProgress] = [:]
    var episodeFraction: Double {
        let streams = Array(streamProgress.values)
        guard !streams.isEmpty else { return min(0.99, (progress.percent ?? 0) / 100) }
        let knownTotal = streams.reduce(0) { $0 + max(0, $1.total ?? 0) }
        let downloaded = streams.reduce(0) { $0 + max(0, $1.downloaded ?? 0) }
        let selected = displayVideo?.choices.first(where: { $0.id == selectedFormat })
        let audio = displayVideo?.audioChoices.first(where: { options.audioID.isEmpty || $0.id == options.audioID })
        let duration = displayVideo?.duration ?? 0
        let estimatedVideo = selected?.filesize ?? selected?.filesize_approx ?? ((selected?.tbr ?? 0) * 125 * duration)
        let estimatedAudio = selected?.acodec == "none" ? (audio?.filesize ?? audio?.filesize_approx ?? ((audio?.tbr ?? 0) * 125 * duration)) : 0
        let total = max(knownTotal, estimatedVideo + estimatedAudio)
        if selected?.acodec == "none", streams.count < 2, estimatedAudio <= 0 { return 0 }
        if total > 0 { return min(0.99, downloaded / total) }
        return min(0.99, streams.reduce(0) { $0 + ($1.percent ?? 0) / 100 } / Double(max(streams.count, selected?.acodec == "none" ? 2 : 1)))
    }
    var lifecycle: DownloadLifecycle {
        if paused { return .paused }
        if busy { return phase.contains("合并") ? .merging : downloading ? .transferring : .preparing }
        if cancelRequested { return .cancelled }
        if error != nil { return .failed }
        return phase == "下载完成" ? .completed : .idle
    }
    var seasonFraction: Double {
        let active = children.isEmpty ? [self] : children
        let partial = active.filter { $0.downloading && $0.phase != "下载完成" }.map(\.episodeFraction)
        return SeasonProgress.fraction(total: seasonEstimate.total, completed: seasonEstimate.completed, active: partial)
    }
    @Published var groupConcurrency = 2
    @Published var options = AdvancedOptions()
    @Published var segmentID: String?
    @Published var assignedEpisodeIDs: [String] = []
    @Published var plannedEpisodeIDs: [String] = []
    @Published var aggregateSpeed = 0.0
    @Published var activeEpisodeCount = 0
    @Published var seasonEstimate = SeasonEstimate(completed: 0, total: 0, seconds: nil, sampled: false)
    @Published var runningChildIDs: [UUID] = []
    private var lastTransferUpdate = Date.distantPast
    private var speedSamples: [(Date, Double)] = []
    var episodeConcurrencyLimit: Int { min(MemoryBudget.episodes, max(1, options.simultaneousBatches ?? HardwareMonitor.shared.recommendedEpisodeCount)) }
    var activeTransferSpeed: Double { downloading && phase == "正在下载" && Date().timeIntervalSince(lastTransferUpdate) < 6 ? progress.bytesPerSecond ?? 0 : 0 }
    var batchTitle: String {
        let selected = episodes.filter { assignedEpisodeIDs.contains($0.id) }
        guard let first = selected.first, let last = selected.last else { return "" }
        return "第\(first.index)—\(last.index)集"
    }
    var children: [AppModel] { TaskStore.shared.tasks.filter { $0.parentID == id } }
    var hasMultipleLinks: Bool { additionalLinks.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    @Published var video: VideoInfo?
    @Published var selectedFormat = ""
    @Published var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @Published var busy = false
    @Published var downloading = false
    @Published var phase = "准备就绪"
    @Published var progress = TransferProgress()
    @Published var logs: [String] = ["霹雳下载已就绪。粘贴视频链接，开始解析。"]
    @Published var error: String?
    @Published var completedFile: URL?
    @Published var permissionConfirmed = false
    @Published var connections = 0
    @Published var episodeIndex = 1
    @Published var episodeEnd = 1
    @Published var scope = "当前集"
    @Published var episodes: [Episode] = []
    @Published var currentEpisode: Episode?
    @Published var currentVideo: VideoInfo?
    @Published var completedItems: [CompletedDownload] = []
    var displayVideo: VideoInfo? { currentVideo ?? video }
    var displayTitle: String {
        currentEpisode?.title ?? displayVideo?.title ?? (address.isEmpty ? "新下载任务" : "待解析任务")
    }
    var displayCover: URL? { currentEpisode?.coverURL ?? displayVideo?.coverURL }
    var episodeLabel: String {
        let index = currentEpisode?.index ?? displayVideo?.episode_number ?? displayVideo?.playlist_index
        return index.map { "当前第\($0)集" } ?? ""
    }
    @Published var container = "mp4"
    let account = AccountSession.shared
    private var logFile: URL?
    private var lastProgressLog = Date.distantPast
    private let backend = DownloadBackend()
    private var inspectedURL: URL?
    private var operation: Task<Void, Never>?
    private var prefetchOperations: [Task<Void, Never>] = []
    private var cancelRequested = false
    func log(_ message: String) {
        guard !message.isEmpty else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(stamp)] \(InputPolicy.cleanDisplay(InputPolicy.safeLog(message)))")
        if let logFile, let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((logs.last! + "\n").utf8)); try? handle.close()
        }
        if logs.count > 350 { logs.removeFirst(logs.count - 350) }
    }
    func invalidateVideo() {
        guard !busy else { return }
        video = nil; inspectedURL = nil; selectedFormat = ""; completedFile = nil; currentEpisode = nil; currentVideo = nil
        phase = "准备就绪"
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "保存到此处"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
    func inspect(resumeAfter: Bool = false, preserveSelection: Bool = false) {
        guard !FileOperationGuard.moving else { error = "正在整理文件，请等待完成后再下载。"; return }
        guard !busy else { return }
        paused = false
        let previousFormat = resumeAfter || preserveSelection ? video?.choices.first(where: { $0.id == selectedFormat }) : nil
        cancelRequested = false
        error = nil; completedFile = nil; video = nil; selectedFormat = ""; inspectedURL = nil
        let url: URL
        do { url = try InputPolicy.videoURL(address) }
        catch { self.error = error.localizedDescription; return }
        busy = true; phase = "正在读取视频信息"; log("连接哔哩哔哩，读取当前权限下可用的画质…")
        operation = Task {
            var continueDownload = false
            defer {
                busy = false; operation = nil
                if continueDownload && !cancelRequested && !paused { Task { @MainActor in self.download() } }
            }
            do {
                if assignedEpisodeIDs.isEmpty || episodes.isEmpty {
                    if let catalogueProvider { episodes = try await catalogueProvider(url, account.cookies) }
                    else { episodes = try await EpisodeCatalogue.load(url: url, cookies: account.cookies) }
                }
                guard !cancelRequested else { throw AppFailure.message("解析已取消。") }
                if !episodes.isEmpty {
                    if scope == "当前集", let chosen = EpisodeOrder.current(in: episodes, source: url) ?? episodes.first(where: { $0.url.path == url.path }) { episodeIndex = chosen.index }
                    if episodeEnd < episodeIndex { episodeEnd = episodeIndex }
                    currentEpisode = episodes.first(where: { $0.index == episodeIndex })
                }
                let actualURL = currentEpisode?.url ?? url
                let info = try await recovering {
                    try await backend.inspect(url: actualURL, cookies: account.cookies, episodeIndex: episodeIndex, episode: currentEpisode) { [weak self] in self?.log($0) }
                }
                video = info
                selectedFormat = previousFormat.flatMap { previous in
                    info.choices.first(where: { $0.id == previous.id }) ?? info.choices.first(where: { ($0.height ?? 0) <= (previous.height ?? 4320) })
                }?.id ?? info.choices.first?.id ?? ""
                inspectedURL = url
                phase = "已选择最高可用画质"; log("解析完成：\(info.choices.count) 种可用格式。")
                continueDownload = resumeAfter
            } catch { fail(error) }
        }
    }
    func download() {
        guard !FileOperationGuard.moving else { error = "正在整理文件，请等待完成后再下载。"; return }
        guard TaskStore.shared.canPersist else { error = "任务历史当前不可写，请先检查历史读取错误；原文件已保留。"; return }
        if hasMultipleLinks { downloadGroup(); return }
        if inspectedURL == nil, !address.isEmpty, permissionConfirmed { inspect(resumeAfter: true); return }
        guard let video, let format = video.choices.first(where: { $0.id == selectedFormat }),
              let url = inspectedURL, permissionConfirmed, !busy else { return }
        let queue: [Episode]
        guard episodeIndex >= 1, scope != "指定范围" || episodeEnd >= episodeIndex else { error = "结束集必须不小于开始集，且集数从1开始。"; return }
        do {
            try options.validateTemplate()
            if !assignedEpisodeIDs.isEmpty {
                queue = episodes.filter { assignedEpisodeIDs.contains($0.id) }.sorted { $0.index < $1.index }
                guard queue.count == assignedEpisodeIDs.count else { throw AppFailure.message("恢复的分组目录不完整，请重新解析。") }
            } else if episodes.isEmpty {
                guard !["奇数集", "偶数集", "自定义"].contains(scope) else {
                    throw AppFailure.message("此入口尚无可靠集号目录，请改用番剧ss/ep链接或指定连续范围。")
                }
                queue = []
            }
            else if scope == "奇数集" || scope == "偶数集" { queue = episodes.sorted { $0.index < $1.index }.filter { $0.index % 2 == (scope == "奇数集" ? 1 : 0) } }
            else if scope == "自定义" {
                let indexes = try AdvancedOptions.selection(options.customEpisodes, maximum: episodes.map(\.index).max() ?? 0)
                queue = episodes.filter { indexes.contains($0.index) }.sorted { $0.index < $1.index }
                guard queue.count == indexes.count else { throw AppFailure.message("选集含缺失集，请检查官方列表。") }
            } else { queue = try EpisodeOrder.select(episodes, start: episodeIndex, end: scope == "指定范围" ? episodeEnd : nil, all: scope == "整季") }
        }
        catch { self.error = error.localizedDescription; return }
        let seriesTitle = queue.first?.series ?? episodes.first?.series ?? video.title
        adoptExistingMedia(queue, seriesTitle: seriesTitle)
        let singleExisting = queue.isEmpty ? ExistingMedia.find(folder: folder, series: seriesTitle, episode: nil,
                                                                 identifier: video.id, title: video.title) : nil
        if let singleExisting, !completedItems.contains(where: { $0.path == singleExisting.path }) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: singleExisting.path)[.size] as? NSNumber)?.int64Value
            completedItems.append(CompletedDownload(path: singleExisting.path, title: video.title, source: TaskHistory.publicURL(url),
                                                    identifier: video.id, finishedAt: Date(), bytes: bytes))
        }
        let knownExisting = !queue.isEmpty && queue.allSatisfy { episode in
            completedItems.contains { $0.identifier == episode.id && FileManager.default.fileExists(atPath: $0.path) }
        }
        if knownExisting || (queue.isEmpty && singleExisting != nil) {
            completedFile = singleExisting ?? completedItems.last.map { URL(fileURLWithPath: $0.path) }
            progress.percent = 100; progress.speed = "—"; progress.eta = "00:00"
            phase = "下载完成"; error = nil
            log("目标内容已存在，未启动重复下载。")
            TaskStore.shared.saveNow()
            return
        }
        plannedEpisodeIDs = queue.map(\.id)
        if segmentID == nil, queue.count > 1 {
            do { try downloadEpisodes(queue); return }
            catch { self.error = error.localizedDescription; return }
        }
        error = nil; cancelRequested = false; paused = false; busy = true; downloading = true
        DownloadPowerGuard.shared.begin(id)
        prepareRunLog()
        phase = "正在准备下载"; progress = TransferProgress(); log("开始下载：\(format.label)。音视频分流时会分别显示进度。保存位置：\(folder.path)")
        log("活动 CPU 核心：\(DownloadTuning.activeCores)；\(DownloadTuning.connections(connections)) 个下载连接。传输不转码，保留原始画质。")
        let destination = folder
        operation = Task {
            var hasPermit = false
            defer {
                if hasPermit { Task { await DownloadBudget.shared.release(id) } }
                busy = false; downloading = false; operation = nil
                DownloadPowerGuard.shared.end(id)
                TaskStore.shared.saveSoon()
                if phase == "下载完成" { TaskStore.shared.auditCompletedFolder(folder) }
            }
            do {
                downloading = false; phase = "等待下载名额"
                try await DownloadBudget.shared.acquire(id)
                hasPermit = true
                try Task.checkCancellation()
                guard !cancelRequested else { throw CancellationError() }
                downloading = true; phase = "正在准备下载"
                try MediaIntegrity.preflight(folder: destination)
                let targets: [Episode?] = queue.isEmpty ? [nil] : queue.map(Optional.some)
                for target in targets {
                    guard !cancelRequested else { throw AppFailure.message("任务已取消，未完成内容可继续。") }
                    if let target, completedItems.contains(where: { $0.identifier == target.id && FileManager.default.fileExists(atPath: $0.path) }) {
                        if let existing = completedItems.first(where: { $0.identifier == target.id }) {
                            do {
                                _ = try await MediaIntegrity.verify(URL(fileURLWithPath: existing.path), tools: backend.tools)
                                log("第\(target.index)集成品已存在，跳过；不会跳过未完成集。")
                                continue
                            } catch {
                                completedItems.removeAll { $0.path == existing.path }
                                log("第\(target.index)集旧成品校验未通过，将重新下载。")
                            }
                        }
                    }
                    if currentEpisode?.id != target?.id { streamProgress = [:] }
                    currentEpisode = target; currentVideo = nil; progress = TransferProgress()
                    var pendingOutputs: [(URL, VideoInfo?)] = []
                    log("开始：\(target?.title ?? video.title)")
                    try TaskHistory.appendSourceLog(folder: destination, message: "开始 | \(target?.title ?? video.title)")
                try await recovering {
                pendingOutputs.removeAll()
                let selectedAudio = video.audioChoices.first(where: { options.audioID.isEmpty || $0.id == options.audioID })
                    ?? video.audioChoices.first
                try await backend.download(url: target?.url ?? url, format: format, folder: destination, cookies: account.cookies, allParts: target == nil && scope != "当前集", container: container, connections: connections, episodeIndex: episodeIndex, episodeEnd: scope == "指定范围" ? episodeEnd : nil, orderedEpisode: target, seriesTitle: video.title, audioFormat: selectedAudio, duration: video.duration, options: options) { [weak self] row in
                    guard let self else { return }
                    if row.hasPrefix("PLITEM:") {
                        if let metadata = String(row.dropFirst(7)).data(using: .utf8), let info = try? JSONDecoder().decode(VideoInfo.self, from: metadata) {
                            currentVideo = info
                        }
                    } else if let update = TransferProgress.parse(row) {
                        guard !paused && !cancelRequested else { return }
                        let stream = update.streamID ?? progress.streamID ?? "current"
                        progress = update
                        progress.streamID = stream
                        streamProgress[stream] = progress
                        lastTransferUpdate = Date(); refreshEstimate(active: [self])
                        if phase != "正在下载" { phase = "正在下载" }
                        if Date().timeIntervalSince(lastProgressLog) >= 1 || update.percent == 100 {
                            lastProgressLog = Date()
                            log("\(update.fragment) · \(Int(update.percent ?? 0))% · \(update.speed) · 剩余 \(update.eta) · \(update.sizeLabel)")
                        }
                    } else if row.hasPrefix("PLFILE:") {
                        let output = URL(fileURLWithPath: String(row.dropFirst(7)))
                        if output.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") {
                            pendingOutputs.append((output, currentVideo))
                        }
                    } else if row.contains("[Merger]") || row.contains("[Fixup") {
                        phase = "正在合并音视频"; progress.percent = nil
                        log("正在合并音视频")
                    } else {
                        let lower = row.lowercased()
                        if ["error", "failed", "warning", "timed out", "forbidden"].contains(where: lower.contains) {
                            log(row)
                        }
                    }
                }
                }
                    for (output, itemInfo) in pendingOutputs {
                        phase = "正在校验媒体"
                        let probe = try await MediaIntegrity.inspect(output, tools: backend.tools)
                        let title = target?.title ?? itemInfo?.title ?? video.title
                        let index = target?.index ?? itemInfo?.playlist_index ?? episodeIndex
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value
                        var finalOutput = output
                        if options.movieNamingEnabled {
                            let name = options.finalOutputName(
                                title: title, episodeIndex: index, height: probe.height,
                                videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
                                audioChannels: probe.audioChannels, audioKbps: probe.audioKbps,
                                bytes: bytes ?? 0, ext: output.pathExtension
                            )
                            do {
                                finalOutput = try MediaIntegrity.renameCompleted(output, to: name)
                                log("网盘式命名：\(finalOutput.lastPathComponent)")
                            } catch {
                                log("网盘式命名未应用，保留当前文件：\(InputPolicy.safeLog(error.localizedDescription))")
                            }
                        }
                        let source = TaskHistory.publicURL(target?.url ?? itemInfo?.webpage_url.flatMap { try? InputPolicy.videoURL($0) } ?? url)
                        let finalBytes = (try? FileManager.default.attributesOfItem(atPath: finalOutput.path)[.size] as? NSNumber)?.int64Value
                        let entry = CompletedDownload(path: finalOutput.path, title: title, source: source,
                            identifier: target?.id ?? itemInfo?.id ?? video.id, finishedAt: Date(), bytes: finalBytes)
                        let message = "完成 | \(title) | 文件 \(finalOutput.lastPathComponent) | \(probe.report)"
                        log("文件已保存：\(finalOutput.lastPathComponent)")
                        try TaskHistory.appendSourceLog(folder: finalOutput.deletingLastPathComponent(), message: message)
                        if finalOutput.deletingLastPathComponent() != destination { try TaskHistory.appendSourceLog(folder: destination, message: message) }
                        if options.metadata { try JSONEncoder().encode(entry).write(to: finalOutput.deletingPathExtension().appendingPathExtension("来源.json"), options: .atomic) }
                        if options.nfo {
                            let escapedTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                            try "<episodedetails><title>\(escapedTitle)</title><episode>\(index)</episode><uniqueid>\(entry.identifier)</uniqueid></episodedetails>".write(to: finalOutput.deletingPathExtension().appendingPathExtension("nfo"), atomically: true, encoding: .utf8)
                        }
                        completedFile = finalOutput
                        if !completedItems.contains(where: { $0.path == finalOutput.path }) { completedItems.append(entry) }
                        refreshEstimate(active: [self])
                        TaskStore.shared.saveNow()
                    }
                }
                if completedFile == nil {
                    let identifiers = Set(queue.map(\.id))
                    completedFile = completedItems.last(where: {
                        (identifiers.contains($0.identifier) || (queue.isEmpty && $0.source == TaskHistory.publicURL(url))) && FileManager.default.fileExists(atPath: $0.path)
                    }).map { URL(fileURLWithPath: $0.path) }
                }
                guard let completedFile, FileManager.default.fileExists(atPath: completedFile.path) else {
                    throw AppFailure.message("后端结束，但未确认最终文件。请在保存目录检查结果。")
                }
                progress.percent = 100; progress.speed = "—"; progress.eta = "00:00"
                phase = "下载完成"; log("文件已保存：\(completedFile.lastPathComponent)")
            } catch {
                try? TaskHistory.appendSourceLog(folder: destination, message: "未完成 | \(displayTitle) | \(InputPolicy.safeLog(error.localizedDescription))")
                fail(error)
            }
        }
    }
    func fillMissingEpisodes() {
        guard !busy, permissionConfirmed else { return }
        scope = "整季"
        error = nil
        log("补齐缺失集：扫描当前系列全部集数，只下载缺失项。")
        if episodes.isEmpty || video == nil || inspectedURL == nil {
            inspect(resumeAfter: true)
        } else {
            download()
        }
    }
    private func adoptExistingMedia(_ queue: [Episode], seriesTitle: String) {
        var found = 0
        for episode in queue {
            guard let file = ExistingMedia.find(folder: folder, series: seriesTitle, episode: episode,
                                                identifier: episode.id, title: episode.title),
                  !completedItems.contains(where: { $0.path == file.path }) else { continue }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            completedItems.append(CompletedDownload(path: file.path, title: episode.title, source: TaskHistory.publicURL(episode.url),
                                                    identifier: episode.id, finishedAt: Date(), bytes: bytes))
            found += 1
        }
        if found > 0 {
            TaskStore.shared.saveNow()
            log("发现\(found)集旧版成品，已加入完成记录，将优先跳过下载。")
        }
    }
    private func runQueuedDownload() async {
        guard !cancelRequested else { return }
        if video == nil || inspectedURL == nil {
            inspect(preserveSelection: true)
            if let inspection = operation { await inspection.value }
        }
        guard !cancelRequested, error == nil else { return }
        download()
        if let transfer = operation { await transfer.value }
    }
    private func recovering<T>(_ transfer: () async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            guard !cancelRequested else { throw AppFailure.message("任务已取消，分片已保留。") }
            do { return try await transfer() }
            catch {
                let recentErrors = logs.suffix(12).filter { row in
                    ["error", "timed out", "timeout", "connection reset", "unreachable", "429", "403", "401", "404"].contains { row.lowercased().contains($0) }
                }.joined(separator: " ")
                let details = (error.localizedDescription + " " + recentErrors).lowercased()
                let forbidden = ["403", "404", "401", "drm", "会员", "权限", "空间不足", "目录不可写"].contains { details.contains($0) }
                let network = ["timed out", "timeout", "connection reset", "network is unreachable", "temporary failure", "429", "网络连接中断"].contains { details.contains($0) }
                let stalled = (error as? AppFailure).map { if case .transferStalled = $0 { return true }; return false } ?? false
                let canRecover = options.autoRecover ?? true
                guard canRecover, !cancelRequested, !forbidden, attempts < 3, stalled || network else { throw error }
                attempts += 1; backend.invalidateMediaCache(); phase = "等待网络恢复（\(attempts)/3）"
                log("检测到可恢复传输故障，将刷新临时播放地址并续传；第\(attempts)次恢复。")
                for _ in 0..<(2 << (attempts - 1)) {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !cancelRequested else { throw AppFailure.message("任务已取消，不自动恢复。") }
                }
                phase = "正在重新连接"
            }
        }
    }
    private func downloadGroup() {
        guard !busy, permissionConfirmed else { return }
        let urls: [URL]
        do {
            var seen = Set<String>()
            urls = try ([address] + additionalLinks).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(InputPolicy.videoURL).filter { seen.insert(TaskHistory.publicURL($0)).inserted }
        } catch { self.error = error.localizedDescription; return }
        guard !urls.isEmpty else { return }
        let links = urls.map { url -> AppModel in
            let source = TaskHistory.publicURL(url)
            let child = children.first { $0.address == source && $0.segmentID == nil } ?? AppModel(register: false, catalogueProvider: catalogueProvider)
            child.address = source; child.parentID = id; child.folder = folder; child.scope = scope
            child.episodeIndex = episodeIndex; child.episodeEnd = episodeEnd
            child.connections = connections; child.container = container; child.permissionConfirmed = true
            child.options = options
            child.cancelRequested = false
            if !TaskStore.shared.tasks.contains(where: { $0.id == child.id }) { TaskStore.shared.register(child) }
            return child
        }
        startChildren(links, limit: groupConcurrency, title: "组合任务")
    }
    private func downloadEpisodes(_ queue: [Episode]) throws {
        let remaining = queue.filter { episode in
            !completedItems.contains { item in
                guard item.identifier == episode.id, FileManager.default.fileExists(atPath: item.path),
                      let size = (try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.int64Value else { return false }
                return size > 0
            }
        }
        let skipped = queue.count - remaining.count
        guard !remaining.isEmpty else {
            completedFile = queue.compactMap { episode in
                completedItems.last(where: { $0.identifier == episode.id }).map { URL(fileURLWithPath: $0.path) }
            }.last
            progress.percent = 100; progress.speed = "—"; progress.eta = "00:00"
            phase = "下载完成"; error = nil
            log("所选\(queue.count)集均已完成，未启动重复下载。")
            return
        }
        let limit = episodeConcurrencyLimit
        let links = remaining.map { episode -> AppModel in
            let key = episode.id
            let child = children.first { $0.segmentID == key } ?? AppModel(register: false, catalogueProvider: catalogueProvider)
            child.parentID = id; child.segmentID = key; child.address = episode.url.absoluteString; child.folder = folder
            child.episodes = episodes; child.assignedEpisodeIDs = [episode.id]; child.plannedEpisodeIDs = [episode.id]
            child.scope = "当前集"; child.episodeIndex = episode.index; child.episodeEnd = episode.index
            child.video = video; child.selectedFormat = selectedFormat; child.currentEpisode = episode
            child.inspectedURL = try? InputPolicy.videoURL(address)
            child.container = container; child.permissionConfirmed = permissionConfirmed; child.options = options
            child.options.episodeBatchSize = nil; child.connections = max(1, DownloadTuning.connections(connections) / min(limit, remaining.count))
            if options.rateMiB > 0 { child.options.rateMiB = max(1, options.rateMiB / min(limit, remaining.count)) }
            child.cancelRequested = false
            if !TaskStore.shared.tasks.contains(where: { $0.id == child.id }) { TaskStore.shared.register(child) }
            return child
        }
        if skipped > 0 { log("已提前跳过\(skipped)集有效成品。") }
        if prefetchEnabled {
            prefetchOperations.forEach { $0.cancel() }
            prefetchOperations = (0..<2).map { worker in
                Task { @MainActor in
                    let prefetcher = DownloadBackend()
                    for (offset, episode) in remaining.enumerated() where offset % 2 == worker {
                        guard !self.cancelRequested else { break }
                        await prefetcher.prefetch(url: episode.url, cookies: self.account.cookies, episode: episode)
                    }
                    prefetcher.cancel()
                }
            }
        }
        log("多集同时下载：最多\(limit)集并行，后台2路预取后续集信息。")
        startChildren(links, limit: limit, title: "多集同时下载")
    }
    private func startChildren(_ links: [AppModel], limit: Int, title: String) {
        cancelRequested = false; paused = false; error = nil; busy = true; downloading = true
        runningChildIDs = links.map(\.id)
        phase = "\(title)：\(links.count)集"; log("开始\(title)，日志显示在应用内。")
        prepareRunLog()
        let limit = min(200, max(1, limit))
        operation = Task {
            let updater = Task { @MainActor in
                while !Task.isCancelled {
                    let active = links.first(where: { $0.downloading }) ?? links.first(where: { $0.busy })
                    if let active {
                        currentEpisode = active.currentEpisode; currentVideo = active.displayVideo; progress = active.progress
                    }
                    activeEpisodeCount = links.filter(\.downloading).count
                    refreshEstimate(active: links)
                    phase = "\(title)：已完成 \(seasonEstimate.completed)/\(max(1, seasonEstimate.total))集"
                    if Date().timeIntervalSince(lastProgressLog) >= 2 {
                        lastProgressLog = Date()
                        log("\(title) · 完成\(seasonEstimate.completed)/\(seasonEstimate.total)集 · 合计\(ByteCountFormatter.string(fromByteCount: Int64(aggregateSpeed), countStyle: .file))/s · 整体剩余\(seasonEstimate.label)")
                    }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(limit, links.count) {
                    let child = links[next]; next += 1
                    group.addTask { @MainActor in await child.runQueuedDownload() }
                }
                while await group.next() != nil {
                    if next < links.count, !cancelRequested {
                        let child = links[next]; next += 1
                        group.addTask { @MainActor in await child.runQueuedDownload() }
                    }
                }
            }
            updater.cancel()
            if let last = links.last(where: { $0.displayVideo != nil }) {
                currentEpisode = last.currentEpisode; currentVideo = last.displayVideo; progress = last.progress
            }
            for item in links.flatMap(\.completedItems) where !completedItems.contains(where: { $0.path == item.path }) { completedItems.append(item) }
            completedFile = completedItems.last.map { URL(fileURLWithPath: $0.path) }
            let failures = links.filter { $0.phase != "下载完成" }
            phase = paused ? "已暂停，可继续" : cancelRequested ? "已取消，可继续" : failures.isEmpty ? "下载完成" : "组合任务未完成，可继续"
            if !failures.isEmpty && !cancelRequested { error = "有 \(failures.count) 集未完成。再次继续时会跳过已完成文件。" }
            busy = false; downloading = false; operation = nil; TaskStore.shared.saveSoon()
            prefetchOperations.forEach { $0.cancel() }
            prefetchOperations.removeAll()
            refreshEstimate(active: links)
            if phase == "下载完成" { TaskStore.shared.auditCompletedFolder(folder) }
        }
    }
    private func refreshEstimate(active: [AppModel]) {
        let entries = active.count == 1 && active.first === self ? completedItems : active.flatMap(\.completedItems)
        let planned = Set(plannedEpisodeIDs)
        let selected = entries.filter { planned.contains($0.identifier) }
        let finished = Set(selected.map(\.identifier)).count
        let sizes = selected.compactMap { $0.bytes }.reduce(0.0) { $0 + Double($1) }
        let speed = active.reduce(0.0) { $0 + $1.activeTransferSpeed }
        aggregateSpeed = speed
        activeEpisodeCount = active.filter(\.downloading).count
        if speed > 0 {
            speedSamples.append((Date(), speed))
            if speedSamples.count > 30 { speedSamples.removeFirst(speedSamples.count - 30) }
        }
        let cutoff = Date().addingTimeInterval(-30)
        speedSamples.removeAll { $0.0 < cutoff }
        let sustainedSpeed = speed > 0 ? speed : speedSamples.map(\.1).reduce(0, +) / Double(max(1, speedSamples.count))
        let format = video?.choices.first { $0.id == selectedFormat }
        let duration: Double = video?.duration ?? 0
        let videoRate: Double = format?.tbr ?? 0
        let videoFallback: Double = videoRate * 125.0 * duration
        let videoBytes: Double = format?.filesize ?? format?.filesize_approx ?? videoFallback
        let audio = video?.audioChoices.first { options.audioID.isEmpty || $0.id == options.audioID }
        let audioRate: Double = audio?.tbr ?? 0
        let audioFallback: Double = audioRate * 125.0 * duration
        let audioBytes: Double = audio?.filesize ?? audio?.filesize_approx ?? audioFallback
        seasonEstimate = .calculate(total: planned.count, completed: finished, completedBytes: sizes,
            fallbackBytesPerEpisode: videoBytes + audioBytes, activeDownloaded: active.filter(\.downloading).reduce(0) { total, task in
                total + (task.streamProgress.isEmpty ? (task.progress.downloaded ?? 0) : task.streamProgress.values.reduce(0) { $0 + ($1.downloaded ?? 0) })
            }, bytesPerSecond: sustainedSpeed)
    }
    private func fail(_ failure: Error) {
        if paused || cancelRequested {
            error = nil; phase = paused ? "已暂停，可继续" : "已取消，可继续"
            return
        }
        error = InputPolicy.cleanDisplay(InputPolicy.safeLog(failure.localizedDescription))
        phase = "任务未完成"; log(error!)
    }
    func cancel() {
        paused = false
        progress.speed = "已取消"; progress.bytesPerSecond = 0; progress.eta = "—"
        cancelRequested = true; phase = "正在取消"; log("已请求停止当前任务…"); backend.cancel()
        operation?.cancel()
        prefetchOperations.forEach { $0.cancel() }
        prefetchOperations.removeAll()
        for child in children { child.cancel() }
        if !busy { phase = "已取消，可继续" }
    }
    func pause() {
        guard busy else { paused = true; phase = "已暂停，可继续"; TaskStore.shared.saveSoon(); return }
        cancel()
        paused = true; phase = "正在暂停，保留分片"
        progress.speed = "已暂停"; progress.bytesPerSecond = 0; progress.eta = "—"
        for child in children { child.paused = true }
        TaskStore.shared.saveNow()
    }
    func resume() {
        guard !busy, permissionConfirmed else { return }
        guard !FileOperationGuard.moving else { error = "正在整理文件，请稍后继续。"; return }
        paused = false; cancelRequested = false; resumeAfterExit = false
        backend.invalidateMediaCache()
        inspect(resumeAfter: true, preserveSelection: true)
    }
    private func prepareRunLog() {
        let base = TaskHistory.base.appendingPathComponent("Logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = UUID().uuidString
            logFile = base.appendingPathComponent(name + ".log")
            FileManager.default.createFile(atPath: logFile!.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        } catch { log("运行日志无法写入文件；应用内进度仍可查看。") }
    }
    func reveal() {
        if let completedFile { NSWorkspace.shared.activateFileViewerSelecting([completedFile]) }
        else { NSWorkspace.shared.open(folder) }
    }
}
