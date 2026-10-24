import SwiftUI

struct PosterWall: View {
    @ObservedObject private var store = TaskStore.shared
    @State private var search = ""
    @State private var error = ""
    @StateObject private var metadata = OnlineMetadata()
    @State private var token = ""
    @State private var target: CompletedDownload?
    @State private var query = ""
    @State private var candidates: [FilmMetadata] = []
    private var items: [CompletedDownload] {
        var seen = Set<String>()
        return store.tasks.flatMap(\.completedItems).filter { seen.insert($0.path).inserted && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    private func cover(_ entry: CompletedDownload) -> URL? {
        for task in store.tasks {
            if let episode = task.episodes.first(where: { $0.id == entry.identifier }) { return episode.coverURL }
            if task.completedItems.contains(where: { $0.path == entry.path }) { return task.video?.coverURL }
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("海报墙 · BY 潘飘亮").font(.title.bold()); Spacer(); TextField("搜索片名", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260) }
            DisclosureGroup("在线刮削设置 · TMDB") {
                SecureField("API Read Access Token", text: $token).textFieldStyle(.roundedBorder)
                Link("获取 TMDB 访问令牌", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption2)
            }
            Text("下载成品可在线匹配电影或剧集，匹配后保存片名、年份与简介。").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            if items.isEmpty { Text("完成下载后，成品会出现在这里。").foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 18)], spacing: 20) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            CachedArtwork(key: "legacy-" + item.path, poster: metadata.matches[item.path]?.poster ?? cover(item), file: URL(fileURLWithPath: item.path))
                                .frame(height: 200).clipped().cornerRadius(12)
                            Text(metadata.matches[item.path]?.label ?? item.title).font(.callout.bold()).lineLimit(2)
                            if let film = metadata.matches[item.path] {
                                Text("\(film.media_type == "tv" ? "剧集" : "电影") · \(film.year)").font(.caption).foregroundStyle(.secondary)
                                Text(film.overview ?? "").font(.caption).lineLimit(3).help(film.overview ?? "")
                            }
                            Button(metadata.matches[item.path] == nil ? "在线刮削" : "修正匹配") {
                                query = item.title; candidates = []; target = item
                            }
                            HStack {
                                Button("播放") { error = Playback.play(URL(fileURLWithPath: item.path)) ?? "" }
                                Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                            }
                        }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }.padding(28)
        .sheet(item: $target) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("为下载成品匹配影片").font(.title2.bold())
                HStack {
                    TextField("输入准确片名", text: $query).textFieldStyle(.roundedBorder)
                    Button("在线搜索") { Task { candidates = await metadata.search(query, token: token) } }.disabled(metadata.busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(metadata.message).font(.caption)
                List(candidates) { film in
                    HStack {
                        VStack(alignment: .leading) { Text(film.label + " · " + film.year); Text(film.overview ?? "").font(.caption).lineLimit(3) }
                        Spacer()
                        Button("使用此资料") { metadata.select(film, path: item.path); target = nil }
                    }.padding(.vertical, 6)
                }
                Button("关闭") { target = nil }
            }.padding(24).frame(width: 650, height: 480)
        }
    }
}

struct EntryChooser: View {
    let choose: (String, Bool) -> Void
    @State private var remember = false
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.98)
            VStack(spacing: 24) {
                Text("霹雳下载").font(.largeTitle.bold())
                Text("BY 潘飘亮").tracking(2).foregroundStyle(.secondary)
                Text("今天，从哪里开始？").font(.title2)
                HStack(spacing: 20) {
                    Button { choose("下载器", remember) } label: { Label("进入下载器", systemImage: "arrow.down.circle").padding(18) }
                    Button { choose("海报墙", remember) } label: { Label("进入海报墙", systemImage: "rectangle.grid.2x2").padding(18) }
                }.buttonStyle(.borderedProminent)
                Toggle("下次直接进入此界面", isOn: $remember).toggleStyle(.checkbox)
            }
        }
    }
}
