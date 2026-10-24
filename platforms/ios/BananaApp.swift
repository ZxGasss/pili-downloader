import SwiftUI
import UIKit
import WebKit
import AVFoundation

struct MobileEntry: Codable, Identifiable {
    var id: String
    var title: String
    var index: Int
    var source: String
    var state: String = "等待下载"
}

final class MobileModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = MobileModel()
    @Published var address = ""
    @Published var entries: [MobileEntry] = []
    @Published var status = "粘贴网页地址或 AV/BV 编号，读取官方列表。"
    @Published var start = "1"
    @Published var end = "1"
    @Published var login = false
    @Published var busy = false
    private var episodes: [Episode] = []
    private var retryCounts: [String: Int] = [:]
    private var completed: Set<String> = []
    private var queue: [Episode] = []
    private var current: Episode?
    private var resumeAfterInspect = false
    var backgroundCompletion: (() -> Void)?
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let parts = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Transfers", isDirectory: true)
    private lazy var transfers: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.pan.banana.transfers.v1")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 86400
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()
    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        if let data = try? Data(contentsOf: root.appendingPathComponent("history.json")), let rows = try? JSONDecoder().decode([MobileEntry].self, from: data) {
            entries = rows; completed = Set(rows.filter { $0.state == "已完成" }.map(\.id))
        }
        address = UserDefaults.standard.string(forKey: "source") ?? ""
        start = UserDefaults.standard.string(forKey: "start") ?? "1"
        end = UserDefaults.standard.string(forKey: "end") ?? "1"
        episodes = entries.compactMap { row in
            guard let url = URL(string: row.source) else { return nil }
            return Episode(id: row.id, index: row.index, title: row.title, thumbnail: nil, url: url, bvid: url.lastPathComponent)
        }
        _ = transfers
        transfers.getAllTasks { tasks in
            guard let id = tasks.first?.taskDescription?.split(separator: "|").first.map(String.init) else { return }
            DispatchQueue.main.async {
                self.current = self.episodes.first { $0.id == id }
                self.queue = self.episodes.filter { $0.id != id && !self.completed.contains($0.id) && $0.index >= (Int(self.start) ?? 1) && $0.index <= (Int(self.end) ?? 1) }
                self.busy = true; self.status = "已重新连接系统后台下载。"
            }
        }
    }
    private func update(_ message: String) { DispatchQueue.main.async { self.status = message } }
    private func save() {
        DispatchQueue.main.async {
            if let data = try? JSONEncoder().encode(self.entries) { try? data.write(to: self.root.appendingPathComponent("history.json"), options: .atomic) }
            UserDefaults.standard.set(self.address, forKey: "source")
            UserDefaults.standard.set(self.start, forKey: "start")
            UserDefaults.standard.set(self.end, forKey: "end")
        }
    }
    private func request(_ address: String) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: address)!); request.timeoutInterval = 25
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        }
        if request.url?.host?.hasSuffix(".bilibili.com") == true {
            let scoped = cookies.filter { $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com") }
            for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }
    private func data(_ address: String) async throws -> Data {
        let prepared = try await request(address)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: prepared) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { continuation.resume(throwing: AppFailure.message("网站暂未返回内容，请检查网络。")); return }
                continuation.resume(returning: data)
            }.resume()
        }
    }
    private func object(_ address: String) async throws -> [String: Any] {
        let response = try JSONSerialization.jsonObject(with: await data(address)) as? [String: Any] ?? [:]
        guard response["code"] as? Int == 0, let body = response["data"] as? [String: Any] else { throw AppFailure.message("网站暂未提供此内容，请检查当前账号权限。") }
        return body
    }
    func inspect() {
        guard !busy else { return }; busy = true
        Task {
            do {
                let url = try InputPolicy.videoURL(address)
                guard url.path.hasPrefix("/video/") else { throw AppFailure.message("iOS开发预览版当前支持投稿、合集及分P；番剧入口仍在适配。") }
                let key = url.lastPathComponent, query = key.hasPrefix("av") ? "aid=\(key.dropFirst(2))" : "bvid=\(key)"
                let raw = try await data("https://api.bilibili.com/x/web-interface/view?\(query)")
                var rows = try EpisodeOrder.parseVideoCollection(raw)
                if rows.isEmpty {
                    let body = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["data"] as? [String: Any] ?? [:]
                    let id = body["bvid"] as? String ?? key
                    rows = [Episode(id: id, index: 1, title: body["title"] as? String ?? "视频", thumbnail: body["pic"] as? String, url: URL(string: "https://www.bilibili.com/video/\(id)")!, bvid: id)]
                }
                let list = rows
                DispatchQueue.main.async {
                    self.episodes = list; if !self.resumeAfterInspect { self.end = String(list.count) }
                    self.entries = list.map { MobileEntry(id: $0.id, title: $0.title, index: $0.index, source: $0.url.absoluteString, state: self.completed.contains($0.id) ? "已完成" : "等待下载") }
                    self.status = "官方列表共\(list.count)集，可选择起止集数。"; self.busy = false; self.save()
                    if self.resumeAfterInspect { self.resumeAfterInspect = false; self.busy = false; self.begin() }
                }
            } catch { update(InputPolicy.safeLog(error.localizedDescription)); DispatchQueue.main.async { self.busy = false; self.resumeAfterInspect = false } }
        }
    }
    func begin() {
        guard !busy, let first = Int(start), let last = Int(end), first > 0, last >= first else { status = "请检查起止集数。"; return }
        if episodes.isEmpty { resumeAfterInspect = true; inspect(); return }
        do { queue = try EpisodeOrder.select(episodes, start: first, end: last, all: false).filter { !completed.contains($0.id) } }
        catch { status = error.localizedDescription; return }
        save(); busy = true; next()
    }
    private func next() {
        guard !queue.isEmpty else { DispatchQueue.main.async { self.busy = false; self.status = "所选内容已完成" }; return }
        current = queue.removeFirst(); guard let item = current else { return }
        update("正在准备第\(item.index)集 · \(item.title)")
        Task {
            do {
                let info = try await object("https://api.bilibili.com/x/web-interface/view?bvid=\(item.bvid ?? item.id)")
                let page = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init) ?? 1
                let pages = info["pages"] as? [[String: Any]] ?? []
                let cid = pages.first(where: { $0["page"] as? Int == page })?["cid"] ?? info["cid"] ?? 0
                let media = try await object("https://api.bilibili.com/x/player/playurl?bvid=\(item.bvid ?? item.id)&cid=\(cid)&qn=127&fnval=4048&fourk=1")
                guard media["is_drm"] as? Int != 1, let dash = media["dash"] as? [String: Any] else { throw AppFailure.message("没有可下载分流，或内容受到保护。") }
                let videos = (dash["video"] as? [[String: Any]] ?? []).filter { ($0["codecs"] as? String ?? "").hasPrefix("avc") }.sorted { ($0["height"] as? Int ?? 0) > ($1["height"] as? Int ?? 0) }
                let audios = (dash["audio"] as? [[String: Any]] ?? []).filter { ($0["codecs"] as? String ?? "").hasPrefix("mp4a") }.sorted { ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0) }
                guard let video = videos.first, let audio = audios.first else { throw AppFailure.message("未提供此预览版支持的H.264/AAC流。") }
                for (kind, row) in [("video", video), ("audio", audio)] {
                    let key = item.id + "." + kind
                    if FileManager.default.fileExists(atPath: parts.appendingPathComponent(key).path) { continue }
                    guard let source = row["baseUrl"] as? String ?? row["base_url"] as? String, source.hasPrefix("https://") else { throw AppFailure.message("未提供安全传输地址。") }
                    let resume = parts.appendingPathComponent(key + ".resume")
                    let task: URLSessionDownloadTask
                    if let data = try? Data(contentsOf: resume) { task = transfers.downloadTask(withResumeData: data) }
                    else { task = transfers.downloadTask(with: try await request(source)) }
                    task.taskDescription = item.id + "|" + kind; task.resume()
                }
                mergeIfReady()
            } catch { update(InputPolicy.safeLog(error.localizedDescription)); DispatchQueue.main.async { self.busy = false } }
        }
    }
    func pause() {
        queue.removeAll()
        transfers.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks {
                task.cancel { data in
                    guard let key = task.taskDescription?.replacingOccurrences(of: "|", with: "."), let data else { return }
                    try? data.write(to: self.parts.appendingPathComponent(key + ".resume"), options: .atomic)
                }
            }
            DispatchQueue.main.async { self.busy = false; self.status = "已暂停，下载分片由系统保留；可继续。" }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription else { return }
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 || (downloadTask.response as? HTTPURLResponse)?.statusCode == 206 else {
            try? FileManager.default.removeItem(at: parts.appendingPathComponent(description.replacingOccurrences(of: "|", with: ".") + ".resume"))
            update("网站拒绝传输，请重新解析后继续。"); DispatchQueue.main.async { self.busy = false }; return
        }
        let destination = parts.appendingPathComponent(description.replacingOccurrences(of: "|", with: "."))
        do { if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: location, to: destination) }; mergeIfReady() }
        catch { update("保存失败：" + error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update("\(current?.title ?? "后台下载") · \(ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)) / \(totalBytesExpectedToWrite > 0 ? ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file) : "未知大小")")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, error.code != NSURLErrorCancelled else { return }
        if let description = task.taskDescription, let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, (retryCounts[description] ?? 0) < 3 {
            retryCounts[description, default: 0] += 1
            let resumed = transfers.downloadTask(withResumeData: data); resumed.taskDescription = description; resumed.resume(); update("网络中断，正在由系统重连续传。")
        } else { update("下载暂未完成，系统保留的分片可继续。请检查网络后重新打开任务。"); DispatchQueue.main.async { self.busy = false } }
    }
    private var merging = false
    private let mergeLock = NSLock()
    private func mergeIfReady() {
        mergeLock.lock(); defer { mergeLock.unlock() }
        guard let item = current, !merging else { return }
        let video = parts.appendingPathComponent(item.id + ".video"), audio = parts.appendingPathComponent(item.id + ".audio")
        guard FileManager.default.fileExists(atPath: video.path), FileManager.default.fileExists(atPath: audio.path) else { return }; merging = true
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        v.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { a.loadValuesAsynchronously(forKeys: ["tracks"]) {
            do {
                let composition = AVMutableComposition()
                guard !v.hasProtectedContent && !a.hasProtectedContent else { throw AppFailure.message("内容受加密保护，无法封装为可播放文件。") }
                guard let vt = v.tracks(withMediaType: .video).first, let at = a.tracks(withMediaType: .audio).first,
                      let targetV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid), let targetA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AppFailure.message("媒体轨道不完整，分轨已保留。") }
                try targetV.insertTimeRange(CMTimeRange(start: .zero, duration: v.duration), of: vt, at: .zero)
                try targetA.insertTimeRange(CMTimeRange(start: .zero, duration: min(v.duration, a.duration)), of: at, at: .zero)
                guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw AppFailure.message("无法创建原画质封装。") }
                let title = String(item.title.map { "/:\\".contains($0) ? "_" : $0 }.prefix(55))
                let output = self.root.appendingPathComponent(String(format: "%03d - %@.mp4", item.index, title))
                guard !FileManager.default.fileExists(atPath: output.path) else { throw AppFailure.message("同名文件已存在，请检查后继续；未覆盖原文件。") }
                export.outputURL = output; export.outputFileType = .mp4; export.exportAsynchronously {
                    self.mergeLock.lock(); self.merging = false; self.mergeLock.unlock()
                    guard export.status == .completed else { self.update("合并未完成，原始分轨已保留。"); return }
                    DispatchQueue.main.async { self.completed.insert(item.id); if let i = self.entries.firstIndex(where: { $0.id == item.id }) { self.entries[i].state = "已完成" }; self.save(); self.next() }
                }
            } catch { self.mergeLock.lock(); self.merging = false; self.mergeLock.unlock(); self.update(error.localizedDescription) }
        } }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil } }
}

struct AccountWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!)); return view }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

final class MobileDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) { MobileModel.shared.backgroundCompletion = completionHandler }
}

@main struct BananaMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileDelegate.self) var delegate
    @StateObject private var model = MobileModel.shared
    var body: some Scene {
        WindowGroup {
            NavigationView {
                List {
                    Section { Text("BY 潘飘亮").font(.headline); Text("iOS开发预览：投稿／合集／分P，H.264/AAC原画质下载；功能与macOS尚未完全一致。").font(.caption) }
                    Section(header: Text("视频来源")) {
                        TextField("粘贴链接或 AV/BV 编号", text: $model.address).autocapitalization(.none).disableAutocorrection(true)
                        Button("解析视频／合集") { model.inspect() }.disabled(model.busy)
                        Button("登录账号（仅保存在本应用）") { model.login = true }
                    }
                    Section(header: Text("选集")) {
                        HStack { Text("从第"); TextField("开始集", text: $model.start).keyboardType(.numberPad); Text("到第"); TextField("结束集", text: $model.end).keyboardType(.numberPad); Text("集") }
                        Button("开始／恢复下载") { model.begin() }.disabled(model.busy)
                        Button("暂停并保留分片") { model.pause() }
                        Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Section(header: Text("下载与历史")) { ForEach(model.entries) { row in VStack(alignment: .leading) { Text("第\(row.index)集 · \(row.title)"); Text(row.state).font(.caption).foregroundColor(.secondary) } } }
                    Section { Text("版本1.5.1 · iOS14及以上\n系统允许的后台传输；手动强退、系统时限与可用空间会影响任务。GPU和实时频率：系统未提供。").font(.caption) }
                }.navigationTitle("大香蕉播放器")
                .sheet(isPresented: $model.login) { NavigationView { AccountWebView().navigationTitle("本应用账号授权").navigationBarItems(trailing: Button("完成") { model.login = false }) } }
            }.navigationViewStyle(StackNavigationViewStyle())
        }
    }
}
