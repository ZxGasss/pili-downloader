import SwiftUI

struct WorkspaceShell: View {
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var account = AccountSession.shared
    @StateObject private var fallback = TaskStore.shared.tasks.last(where: { $0.parentID == nil && !$0.archived }) ?? AppModel()
    @State private var page = "下载"
    @State private var currentID: UUID?
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var filter = "全部"
    @State private var settingsShown = false
    @State private var archiveShown = false
    @State private var confirmRemove = false
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed = false
    @AppStorage("queue.visible") private var queueVisible = true
    private var current: AppModel {
        store.tasks.first { $0.id == currentID && !$0.archived }
            ?? store.tasks.last { $0.parentID == nil && !$0.archived } ?? fallback
    }
    private var records: [AppModel] {
        store.tasks.filter { task in
            task.parentID == nil && !task.archived
                && (search.isEmpty || (task.displayTitle + task.address).localizedCaseInsensitiveContains(search))
                && (filter == "全部" || (filter == "完成" ? task.phase == "下载完成" : task.phase != "下载完成"))
        }
    }
    private var archivedCount: Int { store.tasks.filter { $0.parentID == nil && $0.archived }.count }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { sidebarCollapsed.toggle() } label: { Label("侧栏", systemImage: "sidebar.left") }
                Spacer()
                Button { queueVisible.toggle() } label: { Label("任务队列", systemImage: "sidebar.right") }.disabled(page != "下载")
                Button { settingsShown = true } label: { Label("设置", systemImage: "gearshape") }
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
            if !sidebarCollapsed { sidebar; Divider() }
            Group {
                switch page {
                case "媒体库": LibraryView(model: current)
                case "我的B站": MyBilibiliView(createDownload: add)
                default:
                    HSplitView {
                        ContentView(model: current, account: current.account).frame(minWidth: 530)
                        if queueVisible { queue.frame(minWidth: 250, idealWidth: 280, maxWidth: 330) }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAppearance(opacity: appearance.opacity))
        .tint(appearance.accent)
        .buttonBorderShape(.roundedRectangle)
        .preferredColorScheme(appearance.mode == "浅色" ? .light : appearance.mode == "深色" ? .dark : nil)
        .sheet(isPresented: $settingsShown) { WorkspaceSettings(model: current) }
        .sheet(isPresented: $archiveShown) { ArchivedRecordsView { currentID = $0; page = "下载" } }
        .alert("移除选中的 \(selection.count) 条记录？", isPresented: $confirmRemove) {
            Button("移除记录，保留文件") {
                do {
                    _ = try store.archiveMany(selection); selection = []
                    if let task = records.last { currentID = task.id } else { add("") }
                } catch { store.storageError = InputPolicy.safeLog(error.localizedDescription) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("活动任务会保留。视频、续传分片和媒体库不删除；记录可从已移除记录恢复。") }
        .onChange(of: selection) { ids in if ids.count == 1 { currentID = ids.first } }
        .onReceive(NotificationCenter.default.publisher(for: .piliOpenSettings)) { _ in settingsShown = true }
        .task {
            appearance.updateDockIcon(); store.saveNow()
            if UserDefaults.standard.bool(forKey: "downloads.resumeOnLaunch") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                for task in store.tasks where task.parentID == nil && task.paused && task.resumeAfterExit && !task.archived { task.resume() }
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(nsImage: AppArtwork.icon).resizable().scaledToFit().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("霹雳下载").font(.system(size: 15, weight: .semibold))
                    Text("2.1.2").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.top, 10)
            VStack(spacing: 6) {
                navigation("下载", icon: "arrow.down.circle")
                navigation("媒体库", icon: "rectangle.stack")
                navigation("我的B站", icon: "person.crop.circle")
            }
            Button { add("") } label: { Label("新建下载", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if !store.storageError.isEmpty { Text(store.storageError).font(.caption).foregroundStyle(.orange) }
            if !store.memoryNotice.isEmpty { Text(store.memoryNotice).font(.caption).foregroundStyle(.orange) }
            Spacer()
            Button { archiveShown = true } label: { Label("已移除记录 \(archivedCount)", systemImage: "archivebox").font(.callout).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            Button { settingsShown = true } label: { Label("设置与说明", systemImage: "gearshape").font(.callout).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            Divider()
            Button { page = "我的B站" } label: {
                HStack(spacing: 9) {
                    CachedArtwork(key: "account-avatar", poster: account.avatarURL).frame(width: 28, height: 28).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.loggedIn ? account.displayName : "登录B站").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(account.membership).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(18).frame(width: 200)
            .background(Color(nsColor: .windowBackgroundColor).opacity(appearance.glass ? 0.88 : 1))
            .background(WindowGlass(enabled: appearance.glass))
    }
    private func navigation(_ name: String, icon: String) -> some View {
        Button { page = name } label: {
            Label(name, systemImage: icon).font(.system(size: 13, weight: page == name ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 12)
                .background(page == name ? appearance.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("任务队列").font(.headline); Spacer(); Text("\(records.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            TextField("搜索任务", text: $search).textFieldStyle(.roundedBorder)
            Picker("状态", selection: $filter) { Text("全部").tag("全部"); Text("进行中").tag("活动"); Text("完成").tag("完成") }.pickerStyle(.segmented).labelsHidden()
            List(selection: $selection) {
                ForEach(records) { task in
                    CompactTaskRow(model: task).tag(task.id).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            .onCommand(#selector(NSText.selectAll(_:))) { selection = Set(records.map(\.id)) }
            .onDeleteCommand { if !selection.isEmpty { confirmRemove = true } }
            HStack {
                Button("全选") { selection = Set(records.map(\.id)) }
                Text("已选 \(selection.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("移除…") { confirmRemove = true }.disabled(selection.isEmpty)
            }.font(.caption)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
    private func add(_ address: String) { let task = AppModel(); task.address = address; currentID = task.id; selection = [task.id]; page = "下载" }
}

struct WorkspaceToolbar: ToolbarContent {
    @Binding var sidebarCollapsed: Bool
    @Binding var queueVisible: Bool
    @Binding var settingsShown: Bool
    let downloadingPage: Bool
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { Button { sidebarCollapsed.toggle() } label: { Label("展开或收起侧栏", systemImage: "sidebar.left") } }
        ToolbarItem(placement: .primaryAction) { Button { queueVisible.toggle() } label: { Label("任务队列", systemImage: "sidebar.right") }.disabled(!downloadingPage) }
        ToolbarItem(placement: .primaryAction) { Button { settingsShown = true } label: { Label("设置", systemImage: "gearshape") } }
    }
}

struct CompactTaskRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedArtwork(key: "task-" + model.id.uuidString, poster: model.displayCover).frame(width: 48, height: 36).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(model.phase).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if model.busy { ProgressView(value: model.progress.percent ?? 0, total: 100).controlSize(.mini) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.phase != "下载完成" {
                Button { if model.busy { model.pause() } else { model.resume() } } label: {
                    Image(systemName: model.busy ? "pause.fill" : "play.fill").font(.caption)
                }.buttonStyle(.borderless).disabled((model.busy && model.paused) || !model.permissionConfirmed || model.address.isEmpty)
            }
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct WorkspaceSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("设置与说明").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }.padding(22)
            TabView {
                AppearancePanel().tabItem { Label("外观", systemImage: "paintpalette") }
                ScrollView { SupportPanel(model: model).padding(24) }.tabItem { Label("自检与整理", systemImage: "wrench.and.screwdriver") }
                UsagePrivacyView().tabItem { Label("使用与隐私", systemImage: "hand.raised") }
            }.padding([.horizontal, .bottom], 18)
        }.frame(width: 760, height: 650)
    }
}

struct UsagePrivacyView: View {
    private let notes = [
        ("独立本地工具", "霹雳下载是独立非官方应用，不代表Bilibili或TMDB，也不暗示其授权或背书。"),
        ("只保存获准内容", "请在内容授权与平台允许的范围内使用。应用不绕过账号、会员、付费、地区或DRM限制。"),
        ("账号留在本机", "凭据保存到系统钥匙串。Chrome会话仅在你主动导入时读取；收藏保持只读。"),
        ("文件操作由你确认", "默认保留视频和分片。分类只改媒体资料；改名、移动及废纸篓操作先预览确认。"),
        ("影视资料来源", "TMDB查询会发送输入的片名，不上传本地视频。每位用户使用自己的API凭据。")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) { Image(nsImage: AppArtwork.icon).resizable().frame(width: 48, height: 48); VStack(alignment: .leading) { Text("霹雳下载").font(.title2.bold()); Text("使用边界清楚，文件由你掌控。").foregroundStyle(.secondary) } }
                ForEach(notes, id: \.0) { note in VStack(alignment: .leading, spacing: 6) { Text(note.0).font(.headline); Text(note.1).font(.callout).foregroundStyle(.secondary) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)) }
                TMDBAttribution()
                Text("作者：潘飘亮 · 请备份重要资料，并遵守平台规则与内容授权约定。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
}
