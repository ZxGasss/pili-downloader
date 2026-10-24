import SwiftUI

struct IdentificationGroup: Identifiable {
    let id = UUID()
    let query: String
    var mediaIDs: [UUID]
}

enum MediaIdentification {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\bS\d{1,2}E\d{1,3}\b.*$|\s+-\s+\d{3,5}p.*$|\.[A-Za-z0-9]{2,4}$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^\d{1,3}\s*[-_. ]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func groups(_ items: [LibraryMedia]) -> [IdentificationGroup] {
        let folders = Dictionary(grouping: items, by: { $0.file.deletingLastPathComponent().path })
        var result: [IdentificationGroup] = []
        for (folder, files) in folders.sorted(by: { $0.key < $1.key }) {
            let name = URL(fileURLWithPath: folder).lastPathComponent
            let generic = ["downloads", "下载", "电影", "剧集", "动画", "movies", "tv", "videos"].contains(name.lowercased())
            if files.count > 1 && !generic {
                result.append(.init(query: clean(name), mediaIDs: files.map(\.id)))
            } else {
                result.append(contentsOf: files.map { .init(query: clean($0.title), mediaIDs: [$0.id]) })
            }
        }
        return Array(result.prefix(100))
    }
}

struct BatchIdentificationView: View {
    @ObservedObject private var library = MediaLibrary.shared
    @StateObject private var metadata = OnlineMetadata()
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [IdentificationGroup] = []
    @State private var results: [UUID: [FilmMetadata]] = [:]
    @State private var choices: [UUID: String] = [:]
    @State private var busy = false
    @State private var message = ""
    @State private var operation: Task<Void, Never>?
    private func identity(_ film: FilmMetadata) -> String { (film.media_type ?? "") + String(film.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("影片识别与分类").font(.title2.bold()); Spacer(); Button("关闭") { operation?.cancel(); dismiss() } }
            Text("同一目录按整部/整季查询一次。只预选唯一的同名匹配；不确定的请手动选择。应用分类不会移动文件。").foregroundStyle(.secondary)
            HStack {
                Button("开始识别未分类视频") { identify() }.buttonStyle(.borderedProminent).disabled(busy || groups.isEmpty)
                Button("应用已确认的分类") { apply() }.disabled(busy || choices.values.allSatisfy(\.isEmpty))
                if busy { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            List(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.query) · \(group.mediaIDs.count) 个文件").font(.headline)
                    Picker("匹配结果", selection: Binding(get: { choices[group.id] ?? "" }, set: { choices[group.id] = $0 })) {
                        Text("暂不分类 / 需要确认").tag("")
                        ForEach(results[group.id] ?? [], id: \.id) { film in Text("\(film.label) · \(film.year) · \(film.suggestedCategory)").tag(identity(film)) }
                    }.disabled(busy)
                }.padding(.vertical, 8)
            }
            TMDBAttribution()
        }.padding(26).frame(width: 800, height: 640)
        .onAppear { groups = MediaIdentification.groups(library.items.filter { $0.category == "未归类" && !$0.missing }); if groups.isEmpty { message = "没有待识别的视频。" } }
        .onDisappear { operation?.cancel() }
    }
    private func identify() {
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            for (index, group) in groups.enumerated() {
                guard !Task.isCancelled else { return }
                message = "正在识别 \(index + 1)/\(groups.count)：\(group.query)"
                let matches = await metadata.search(group.query)
                guard !Task.isCancelled else { return }
                results[group.id] = matches
                let exact = matches.filter { MediaIdentification.normalized($0.label) == MediaIdentification.normalized(group.query) }
                if exact.count == 1 { choices[group.id] = identity(exact[0]) }
                if matches.isEmpty && metadata.message.contains("凭据") { message = metadata.message; return }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
            message = "识别完成。核对匹配后应用，未确认项保留未归类。"
        }
    }
    private func apply() {
        var matches: [String: FilmMetadata] = [:], categories: [UUID: String] = [:]
        for group in groups {
            guard let film = results[group.id]?.first(where: { identity($0) == choices[group.id] }) else { continue }
            for id in group.mediaIDs { matches[id.uuidString] = film; categories[id] = film.suggestedCategory }
        }
        guard metadata.selectMany(matches) else { message = metadata.message; return }
        library.classifyMany(categories); message = "已分类 \(categories.count) 个视频，原文件未移动。"
    }
}
