import Foundation
import Darwin
import CFNetwork

enum SystemNetworkPolicy {
    /// Mirror the user's existing system route; never change settings or rotate identities.
    static func arguments(for url: URL) -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
              let first = proxies.first, let kind = first[kCFProxyTypeKey as String] as? String else { return [] }
        if kind == kCFProxyTypeNone as String { return ["--proxy", ""] }
        guard [kCFProxyTypeHTTP as String, kCFProxyTypeHTTPS as String, kCFProxyTypeSOCKS as String].contains(kind),
              let host = first[kCFProxyHostNameKey as String] as? String,
              let port = first[kCFProxyPortNumberKey as String] as? NSNumber, (1...65535).contains(port.intValue) else { return [] }
        var address = URLComponents(); address.scheme = kind == kCFProxyTypeSOCKS as String ? "socks5" : "http"
        address.host = host; address.port = port.intValue
        return address.url.map { ["--proxy", $0.absoluteString] } ?? []
    }
}

enum LegacyResume {
    /// Keep old stream filenames when resuming; never rename a user's existing media.
    static func template(folder: URL, series: String, episode: Episode) -> String? {
        let directory = folder.appendingPathComponent(series, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return nil }
        var identifiers = [episode.id]
        if episode.id.hasPrefix("ep") { identifiers.append(String(episode.id.dropFirst(2))) }
        if let bvid = episode.bvid { identifiers.append(bvid) }
        let pattern = #"^(.*?)(?:\.f[0-9A-Za-z_-]+)?\.(?:mp4|m4a|mkv|webm|flac)(?:\.part)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".part") || name.range(of: #"\.f[0-9A-Za-z_-]+\.(mp4|m4a|mkv|webm|flac)$"#, options: .regularExpression) != nil,
                  identifiers.contains(where: { name.contains("[\($0)]") }),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let range = Range(match.range(at: 1), in: name) else { continue }
            let stem = String(name[range]).replacingOccurrences(of: "%", with: "%%")
            return series + "/" + stem + ".%(ext)s"
        }
        return nil
    }
}

/// No shell interpolation; all process arguments are separate values.
@MainActor final class ProcessRunner {
    private var process: Process?
    private var cancelled = false
    private var stalled = false
    func cancel() {
        cancelled = true
        guard let p = process, p.isRunning else { return }
        terminateChildren(of: p.processIdentifier, signal: SIGTERM)
        p.interrupt()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if p.isRunning {
                self.terminateChildren(of: p.processIdentifier, signal: SIGKILL)
                p.terminate()
            }
        }
    }
    private func terminateChildren(of pid: pid_t, signal: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-\(signal == SIGKILL ? "KILL" : "TERM")", "-P", String(pid)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
    func run(executable: URL, arguments: [String], timeout: Double, acceptedExitCodes: Set<Int32> = [0], idleTimeout: Double? = nil,
             line: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard process == nil else { throw AppFailure.message("已有任务正在执行。") }
        try Task.checkCancellation()
        cancelled = false; stalled = false
        var lastActivity = Date()
        var lastProgressBytes: Double = -1
        var monitoringTransfer = true
        var errorRows: [String] = []
        var timedOut = false
        let p = Process(), pipe = Pipe()
        p.executableURL = executable
        p.arguments = arguments
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONUNBUFFERED": "1"]
        try p.run()
        process = p
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled, p.isRunning { timedOut = true; self.cancel() }
        }
        let watchdog = Task { @MainActor in
            guard let idleTimeout else { return }
            while !Task.isCancelled && p.isRunning {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled, p.isRunning, monitoringTransfer, Date().timeIntervalSince(lastActivity) > idleTimeout {
                    stalled = true; self.cancel(); return
                }
            }
        }
        let receive: @MainActor @Sendable (String) -> Void = { row in
            if ["error", "failed", "forbidden", "timed out", "timeout", "unavailable"].contains(where: { row.lowercased().contains($0) }) {
                errorRows.append(InputPolicy.safeLog(row)); if errorRows.count > 8 { errorRows.removeFirst() }
            }
            if let update = TransferProgress.parse(row), let bytes = update.downloaded {
                monitoringTransfer = true
                if bytes != lastProgressBytes { lastActivity = Date(); lastProgressBytes = bytes }
            } else if row.contains("[Merger]") || row.contains("[Fixup") {
                monitoringTransfer = false; lastActivity = Date()
            } else if row.hasPrefix("PLITEM:") {
                monitoringTransfer = true; lastActivity = Date()
            } else if row.hasPrefix("PLFILE:") { lastActivity = Date() }
            line(row)
        }
        defer { timer.cancel(); watchdog.cancel(); process = nil }
        let status = await Task.detached(priority: .userInitiated) {
            var pending = Data()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let row = String(decoding: pending[..<index], as: UTF8.self)
                    pending.removeSubrange(...index)
                    await receive(row)
                }
                if pending.count > 24_000_000 {
                    p.terminate()
                    pending.removeAll()
                    await line("ERROR: 返回数据超过安全大小限制。")
                    break
                }
            }
            if !pending.isEmpty { await receive(String(decoding: pending, as: UTF8.self)) }
            p.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            return p.terminationStatus
        }.value
        if stalled { throw AppFailure.transferStalled }
        if timedOut { throw AppFailure.message("连接超时（timeout），已保留下载分片，可重新连接后续传。") }
        if cancelled { throw AppFailure.message("任务已取消或超时。未完成的 .part 文件可在下次下载时续传。") }
        guard acceptedExitCodes.contains(status) else { throw AppFailure.message(TransferFailure.describe(status: status, rows: errorRows)) }
    }
}

enum TransferFailure {
    static func describe(status: Int32, rows: [String]) -> String {
        let evidence = rows.joined(separator: " ").lowercased()
        if evidence.contains("no space left") || evidence.contains("disk full") { return "保存磁盘空间不足。释放空间或选择其他目录后继续，下载分片已保留。" }
        if evidence.contains("permission denied") { return "保存目录不可写。请选择有写入权限的文件夹后继续。" }
        if evidence.contains("drm") { return "该内容带有受保护的加密，无法在本应用下载。" }
        if evidence.contains("401") || evidence.contains("not logged in") || evidence.contains("login required") { return "该内容需要有效登录，请在应用内登录后继续。" }
        if evidence.contains("412") || evidence.contains("precondition failed") { return "哔哩哔哩要求人机验证（412）。请在应用内打开登录页面完成网站验证后重新解析；本应用不会模拟验证码或重复登录。" }
        if evidence.contains("403") { return "网站拒绝了本次请求（403）。临时地址可能已失效或当前访问受限；已保留分片，请稍后重新解析后继续。" }
        if evidence.contains("429") { return "网站请求过于频繁（429），正在按恢复策略等待；可降低连接数及同时下载组数。" }
        if evidence.contains("404") { return "该资源地址已失效或内容不存在（404），请重新解析来源网页。" }
        if ["timeout", "timed out", "connection reset", "network is unreachable", "temporary failure"].contains(where: evidence.contains) {
            return "网络连接中断，下载分片已保留，将按自动恢复设置重连续传。"
        }
        if evidence.contains("requested format is not available") { return "所选画质已不可用，请重新解析并选择账号当前可用的画质。" }
        let detail = rows.last.map { String(InputPolicy.safeLog($0).prefix(320)) } ?? "工具没有返回具体原因，已保存诊断记录。"
        return "任务暂未完成，分片已保留。原因：\(detail)（诊断码 \(status)）"
    }
}

actor MetadataCache {
    static let shared = MetadataCache()
    private struct Entry { let data: Data; let createdAt: Date }
    private var entries: [String: Entry] = [:]
    private func key(_ url: URL, _ session: String) -> String { url.absoluteString + "\n" + session }
    func data(for url: URL, session: String) -> Data? {
        guard let entry = entries[key(url, session)],
              Date().timeIntervalSince(entry.createdAt) < 300 else { return nil }
        return entry.data
    }
    func store(_ data: Data, for url: URL, session: String) {
        entries[key(url, session)] = Entry(data: data, createdAt: Date())
    }
    func remove(url: URL, session: String) { entries.removeValue(forKey: key(url, session)) }
}

@MainActor final class DownloadBackend {
    private let runner = ProcessRunner()
    private let overrideTools: URL?
    init(tools: URL? = nil) { overrideTools = tools }
    private var cachedMetadata: Data?
    private var cachedURL: URL?
    private var cachedAt = Date.distantPast
    private var cachedSession = ""
    private func sessionKey(_ cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.domain)|\($0.name)|\($0.value)" }.sorted().joined(separator: "\n")
    }
    var tools: URL { overrideTools ?? Bundle.main.resourceURL!.appendingPathComponent("Tools") }
    var executable: URL { tools.appendingPathComponent("yt-dlp") }
    func cancel() { runner.cancel() }
    func invalidateMediaCache() {
        if let cachedURL {
            let session = cachedSession
            Task { await MetadataCache.shared.remove(url: cachedURL, session: session) }
        }
        cachedMetadata = nil; cachedURL = nil
    }
    private var common: [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-geo-bypass", "--no-colors",
         "--socket-timeout", "20", "--retries", "2", "--fragment-retries", "2", "--no-cache-dir",
         "--ffmpeg-location", tools.path]
    }
    private func withCookies<T>(_ cookies: [HTTPCookie], _ body: ( [String]) async throws -> T) async throws -> T {
        guard !cookies.isEmpty else { return try await body([]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pili-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.txt")
        let rows = cookies.filter { $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com") }.compactMap { c -> String? in
            let values = [c.domain, c.domain.hasPrefix(".") ? "TRUE" : "FALSE", c.path,
                          c.isSecure ? "TRUE" : "FALSE", String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)), c.name, c.value]
            guard !values.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\t") }) else { return nil }
            return values.joined(separator: "\t")
        }
        let data = Data(("# Netscape HTTP Cookie File\n" + rows.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw AppFailure.message("无法创建受限的临时授权文件。") }
        return try await body(["--cookies", url.path])
    }
    func inspect(url: URL, cookies: [HTTPCookie], episodeIndex: Int = 1, episode: Episode? = nil,
                 log: @escaping @MainActor @Sendable (String) -> Void) async throws -> VideoInfo {
        let session = sessionKey(cookies)
        if let data = await MetadataCache.shared.data(for: url, session: session),
           let info = try? JSONDecoder().decode(VideoInfo.self, from: data) {
            cachedMetadata = data; cachedURL = url; cachedAt = Date(); cachedSession = session
            return info
        }
        await MetadataRequestGate.shared.acquire()
        if let fallback = try? await BiliAPIFallback.inspect(url: url, cookies: cookies, episode: episode) {
            cachedMetadata = fallback.metadata; cachedURL = url; cachedAt = Date(); cachedSession = session
            await MetadataCache.shared.store(fallback.metadata, for: url, session: session)
            await MetadataRequestGate.shared.release()
            log("已通过哔哩哔哩官方接口取得视频信息。")
            return fallback.info
        }
        await MetadataRequestGate.shared.release()
        var metadata: Data?
        var previewOnly = false
        var diagnostic: String?
        var primaryError: Error?
        await MetadataRequestGate.shared.acquire()
        do {
        try await withCookies(cookies) { auth in
            try await runner.run(executable: executable,
                arguments: common + SystemNetworkPolicy.arguments(for: url) + auth + InputPolicy.playlistArguments(url: url, index: episodeIndex, all: false) + ["--skip-download", "--print", "PLMETA:%()j", "--", url.absoluteString], timeout: 100) { row in
                    if row.hasPrefix("PLMETA:") { metadata = Data(row.dropFirst(7).utf8) }
                    else {
                        if row.contains("Only preview format") { previewOnly = true }
                        if row.hasPrefix("ERROR:") {
                            diagnostic = InputPolicy.safeLog(row)
                            log(InputPolicy.cleanDisplay(InputPolicy.safeLog(row)))
                        }
                    }
                }
        }
        } catch {
            primaryError = error
        }
        await MetadataRequestGate.shared.release()
        if metadata == nil || previewOnly,
           let fallback = try? await BiliAPIFallback.inspect(url: url, cookies: cookies, episode: episode) {
            cachedMetadata = fallback.metadata; cachedURL = url; cachedAt = Date(); cachedSession = session
            await MetadataCache.shared.store(fallback.metadata, for: url, session: session)
            log("网页解析受限，已通过哔哩哔哩官方播放接口取得可用媒体。")
            return fallback.info
        }
        if let primaryError {
            if let diagnostic { throw AppFailure.message(TransferFailure.describe(status: 1, rows: [diagnostic])) }
            throw primaryError
        }
        guard !previewOnly else { throw AppFailure.message("当前账号仅取得试看内容，请在 App 内重新登录并确认此集权限；不会把试看当作完整剧集。") }
        guard let metadata else { throw AppFailure.message("未取得视频信息；暂不支持此链接或网站拒绝访问。") }
        let info = try JSONDecoder().decode(VideoInfo.self, from: metadata)
        guard info.has_drm != true else { throw AppFailure.message("此内容受 DRM 保护，无法下载。") }
        guard !info.choices.isEmpty else { throw AppFailure.message("当前账号没有可下载的视频格式。") }
        cachedMetadata = metadata; cachedURL = url; cachedAt = Date(); cachedSession = session
        await MetadataCache.shared.store(metadata, for: url, session: session)
        return info
    }
    func prefetch(url: URL, cookies: [HTTPCookie], episode: Episode? = nil) async {
        let session = sessionKey(cookies)
        if await MetadataCache.shared.data(for: url, session: session) != nil { return }
        await MetadataRequestGate.shared.acquire()
        if let fallback = try? await BiliAPIFallback.inspect(url: url, cookies: cookies, episode: episode) {
            await MetadataCache.shared.store(fallback.metadata, for: url, session: session)
            await MetadataRequestGate.shared.release()
            return
        }
        await MetadataRequestGate.shared.release()
        _ = try? await inspect(url: url, cookies: cookies, episode: episode, log: { _ in })
    }
    func download(url: URL, format: MediaFormat, folder: URL, cookies: [HTTPCookie],
                  allParts: Bool, container: String, connections: Int, episodeIndex: Int = 1, episodeEnd: Int? = nil,
                  orderedEpisode: Episode? = nil, seriesTitle: String = "", audioFormat: MediaFormat? = nil,
                  duration: Double? = nil, options: AdvancedOptions = AdvancedOptions(),
                  line: @escaping @MainActor @Sendable (String) -> Void) async throws {
        var input = ["--", url.absoluteString]
        var metadataDirectory: URL?
        let session = sessionKey(cookies)
        if cachedURL != url || cachedSession != session,
           let data = await MetadataCache.shared.data(for: url, session: session) {
            cachedMetadata = data; cachedURL = url; cachedAt = Date(); cachedSession = session
        }
        if !allParts {
            let cachedIsFresh = cachedURL == url && cachedSession == session && Date().timeIntervalSince(cachedAt) < 300
            if !cachedIsFresh {
                await MetadataRequestGate.shared.acquire()
                if let fallback = try? await BiliAPIFallback.inspect(url: url, cookies: cookies, episode: orderedEpisode) {
                    cachedMetadata = fallback.metadata; cachedURL = url; cachedAt = Date(); cachedSession = session
                    await MetadataCache.shared.store(fallback.metadata, for: url, session: session)
                }
                await MetadataRequestGate.shared.release()
            }
        }
        if !allParts, cachedURL == url, cachedSession == session,
           Date().timeIntervalSince(cachedAt) < 300, let selectedMetadata = cachedMetadata {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pili-metadata-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            metadataDirectory = directory
            let file = directory.appendingPathComponent("metadata.json")
            guard FileManager.default.createFile(atPath: file.path, contents: selectedMetadata, attributes: [.posixPermissions: 0o600]) else {
                try? FileManager.default.removeItem(at: directory)
                throw AppFailure.message("无法准备临时视频信息。")
            }
            input = ["--load-info-json", file.path]
            line("复用刚解析的视频信息，跳过重复网页解析。")
        }
        defer { if let metadataDirectory { try? FileManager.default.removeItem(at: metadataDirectory) } }
        try await withCookies(cookies) { auth in
            let base = common + SystemNetworkPolicy.arguments(for: url) + (orderedEpisode != nil ? ["--no-playlist"] : InputPolicy.playlistArguments(url: url, index: episodeIndex, all: allParts && episodeEnd == nil, end: episodeEnd))
            let audio = options.audioID.isEmpty ? "bestaudio" : options.audioID
            let rangeFilter = format.dynamic_range.map { "[dynamic_range=\($0)]" } ?? ""
            let codecFilter = format.vcodec.flatMap { $0 == "none" ? nil : "[vcodec^=\($0.split(separator: ".").first ?? "")]" } ?? ""
            let height = Int(format.height ?? 4320)
            let orderedPrimary = "bestvideo[height<=\(height)]\(rangeFilter)\(codecFilter)+\(audio)"
            let orderedCompatible = "bestvideo[height<=\(height)]\(rangeFilter)+bestaudio/bestvideo[height<=\(height)]+bestaudio/best"
            let selector = (allParts || orderedEpisode != nil)
                ? (orderedPrimary + "/" + orderedCompatible)
                : (format.acodec == "none" ? "\(format.id)+\(audio)" : format.id)
            let safeSeries = InputPolicy.folderName(orderedEpisode?.series ?? seriesTitle)
            let name = options.outputName(format: format, episode: orderedEpisode, audio: audioFormat, duration: duration)
            let modernTemplate = orderedEpisode.map { "\(safeSeries)/" + (options.movieNamingEnabled ? name : "\(String(format: "%02d", $0.index)) - " + name) }
                ?? (allParts ? "%(playlist_title).100B/" + (options.movieNamingEnabled ? name : "%(playlist_index)02d - " + name) : name.replacingOccurrences(of: "%(playlist_index)02d", with: "单集"))
            let previous = orderedEpisode.flatMap { LegacyResume.template(folder: folder, series: safeSeries, episode: $0) }
            if previous != nil { line("检测到旧版未完成分轨，沿用旧文件名续传本集以保留已下载字节；后续新文件使用当前命名，不批量改名。") }
            let template = previous ?? modernTemplate
            let args = base + auth + DownloadTuning.arguments(selection: connections, tools: tools) + options.arguments + ["--newline", "--progress", "--progress-delta", "1", "--no-simulate",
                "--no-overwrites", "--continue", "--no-mtime", "--merge-output-format", container,
                "--replace-in-metadata", "title", #"(?i)\s*\[(?:BV[0-9A-Za-z]{10}|(?:av|ep|ss|md)[0-9]+)\]"#, "",
                "--print", "before_dl:PLITEM:%()j",
                "--progress-template", "download:PLPROGRESS|%(progress._percent_str)s|%(progress.speed)s|%(progress.eta)s|%(info.format_id)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
                "--print", "after_move:PLFILE:%(filepath)s", "-f", selector,
                "-P", folder.path, "-o", template] + input
            try await runner.run(executable: executable, arguments: args, timeout: 43_200, idleTimeout: options.autoRecover == false ? nil : 180, line: line)
        }
    }
}
