import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library = MediaLibrary.shared
    @StateObject private var metadata = OnlineMetadata()
    @State private var search = ""
    @State private var category = "全部"
    @State private var target: LibraryMedia?
    @State private var candidates: [FilmMetadata] = []
    @State private var query = ""
    @State private var message = ""
    @State private var trashTarget: LibraryMedia?
    @State private var tmdbSettingsShown = false
    @State private var organizerShown = false
    @State private var identifyShown = false
    private var filtered: [LibraryMedia] {
        library.items.filter { (category == "全部" || $0.category == category) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    private func match(_ item: LibraryMedia) -> FilmMetadata? {
        metadata.matches[item.id.uuidString] ?? metadata.matches[item.path]
            ?? item.previousPaths.compactMap { metadata.matches[$0] }.first
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("媒体库").font(.system(size: 28, weight: .bold))
                        Text("\(library.items.count) 个本地视频").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加文件夹") { scan() }.disabled(library.scanning)
                    Button("识别分类") { identifyShown = true }.buttonStyle(.borderedProminent)
                    Menu {
                        Button("TMDB设置") { tmdbSettingsShown = true }
                        Button("文件检查与整理") { organizerShown = true }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
                    if library.scanning { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 18) {
                    Picker("分类", selection: $category) {
                        ForEach(["全部", "电影", "剧集", "动画", "未归类"], id: \.self) { Text($0 == "未归类" ? "待识别" : $0).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 440)
                    Spacer()
                    TextField("搜索片名", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
                if !library.message.isEmpty { Text(library.message).font(.caption).foregroundStyle(.secondary) }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange) }
                if filtered.isEmpty {
                    VStack(spacing: 14) { Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 48, weight: .ultraLight)); Text("下载完成的视频会自动加入，也可以扫描已有文件夹。") }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(55)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 20)], spacing: 24) {
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            CachedArtwork(key: item.id.uuidString, poster: match(item)?.poster ?? item.poster.flatMap(URL.init(string:)), file: item.missing ? nil : item.file)
                                .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: item.missing ? "externaldrive.badge.exclamationmark" : "play.circle.fill")
                                        .font(.system(size: 30)).foregroundStyle(.white).shadow(radius: 6).padding(12)
                                }
                                .onTapGesture { if !item.missing { message = Playback.play(item.file) ?? "" } }
                            Text(match(item)?.label ?? item.title.replacingOccurrences(of: #"\s+-\s+[0-9]{3,5}p.*$"#, with: "", options: .regularExpression)).font(.callout.weight(.semibold)).lineLimit(2)
                            Text(item.missing ? "文件待找回" : item.category).font(.caption).foregroundStyle(item.missing ? .orange : .secondary)
                        }
                        .contextMenu {
                            Button("播放") { message = Playback.play(item.file) ?? "" }.disabled(item.missing)
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.file]) }
                            Menu("归类为") { ForEach(["电影", "剧集", "动画", "未归类"], id: \.self) { name in Button(name) { library.classify(item.id, category: name) } } }
                            Button("重新定位文件…") { relink(item) }
                            Button("匹配影片资料…") { target = item; query = item.title; candidates = [] }
                            Divider()
                            Button("将视频移到废纸篓…", role: .destructive) { trashTarget = item }.disabled(item.missing)
                        }
                    }
                }
            }.padding(24)
        }
        .alert("将视频文件移到废纸篓？", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let item = trashTarget { do { try library.trash(item.id) } catch { message = InputPolicy.safeLog(error.localizedDescription) } }
                trashTarget = nil
            }
            Button("取消", role: .cancel) { trashTarget = nil }
        } message: { Text(trashTarget?.file.lastPathComponent ?? "") }
        .sheet(item: $target) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text("匹配影片资料").font(.title2.bold())
                TextField("片名", text: $query).textFieldStyle(.roundedBorder)
                HStack {
                    Button("查询 TMDB") {
                        Task {
                            candidates = await metadata.search(query)
                        }
                    }
                    Button("关闭") { target = nil }
                }
                Text(metadata.message).font(.caption).foregroundStyle(.secondary)
                ScrollView { ForEach(candidates) { film in
                    Button("\(film.label) · \(film.year) · \(film.suggestedCategory)") {
                        if metadata.select(film, path: item.id.uuidString) { library.classify(item.id, category: film.suggestedCategory); target = nil }
                    }.buttonStyle(.plain).padding(8)
                } }
                Text("凭据在媒体库“TMDB设置”中申请和导入。确认匹配后分类，不会移动文件。").font(.caption).foregroundStyle(.secondary)
                TMDBAttribution()
            }.padding(26).frame(width: 520, height: 460)
        }
        .sheet(isPresented: $tmdbSettingsShown) { TMDBSettingsView() }
        .sheet(isPresented: $identifyShown) { BatchIdentificationView() }
        .sheet(isPresented: $organizerShown) {
            FileOrganizerSheet(model: model)
        }
    }
    private func scan() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let folder = panel.url { Task { await library.scan(folder) } }
    }
    private func relink(_ item: LibraryMedia) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK, let file = panel.url {
            Task { do { try await library.relink(item.id, to: file) } catch { message = InputPolicy.safeLog(error.localizedDescription) } }
        }
    }
}
