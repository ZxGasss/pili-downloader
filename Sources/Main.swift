import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuObserver: NSObjectProtocol?
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        MemoryPressureMonitor.shared.start()
        DispatchQueue.main.async { ChineseMenus.localize(NSApp.mainMenu) }
        let bundlePath = Bundle.main.bundlePath
        Task.detached(priority: .utility) { _ = ProcessHygiene.terminateStaleMetadataProbes(bundlePath: bundlePath) }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            Task { @MainActor in ChineseMenus.localize(note.object as? NSMenu); ChineseMenus.localize(NSApp.mainMenu) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TaskStore.shared.saveNow()
        let running = AppModel.tasks.filter(\.busy)
        guard !running.isEmpty, !terminationPending else { return terminationPending ? .terminateLater : .terminateNow }
        terminationPending = true
        running.filter { $0.parentID == nil }.forEach { $0.resumeAfterExit = true; $0.pause() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            TaskStore.shared.saveNow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct PiliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("霹雳下载") {
            WorkspaceShell().frame(minWidth: 1060, minHeight: 700)
        }.defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { NotificationCenter.default.post(name: .piliOpenSettings, object: nil) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("外观") {
                Button("颜色与透明度…") { NotificationCenter.default.post(name: .piliOpenSettings, object: nil) }
            }
            CommandGroup(after: .appInfo) {
                Button("使用说明与开源许可") {
                    if let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject var model: AppModel
    @ObservedObject var account: AccountSession
    @State private var loginShown = false
    @State private var settingsExpanded = false
    @State private var logsExpanded = false
    @ObservedObject private var appearance = Appearance.shared
    private var accent: Color { appearance.accent }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.seasonEstimate.total > 1 || !model.runningChildIDs.isEmpty { SeasonDashboard(model: model) }
                    inputCard
                    if let video = model.displayVideo { videoCard(video) }
                    destinationCard
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    DisclosureGroup("下载设置与选集", isExpanded: $settingsExpanded) { downloadSettings }.card()
                    OptionsPanel(model: model)
                    if !model.busy && model.video != nil {
                        Button("重新验证并继续未完成内容") { model.inspect(resumeAfter: true) }
                            .disabled(!model.permissionConfirmed || account.checking)
                    }
                    if !model.completedItems.isEmpty {
                        DisclosureGroup("已完成 \(model.completedItems.count) 个文件（历史记录）") {
                            ForEach(model.completedItems) { item in
                                HStack {
                                    Text(item.title).lineLimit(2)
                                    Spacer()
                                    Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                    DisclosureGroup("活动与日志", isExpanded: $logsExpanded) { terminal }.font(.callout)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            downloadControls.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
            HStack {
                Label(model.phase, systemImage: model.paused ? "pause.circle" : "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HardwareFooter(folder: model.folder)
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }.background(Color(nsColor: .windowBackgroundColor).opacity(appearance.glass ? 0.48 : 1)).tint(accent)
        .sheet(isPresented: $loginShown) {
            LoginSheet(account: account) { model.invalidateVideo(); model.log("账号已授权，请重新解析以刷新可用画质。") }
        }
        .onChange(of: model.displayVideo?.id) { value in if value != nil { settingsExpanded = true } }

    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("下载").font(.system(size: 26, weight: .bold))
                Text("添加链接，确认画质，保存到本地。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Button("全部开始") { store.startAll() }
                Button("全部暂停") { store.pauseAll() }
                Button("全部取消") { store.cancelAll() }
            }.controlSize(.regular)
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }
    private var introduction: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把喜欢的视频，留在本地。").font(.system(size: 27, weight: .bold))
                Text("粘贴链接，选择画质，保存你有权下载的内容。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text("哔哩哔哩").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(accent)
        }
    }
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("01", "视频链接", icon: "link")
                Spacer()
                Button("批量粘贴") {
                    let links = AdvancedOptions.extractLinks(NSPasteboard.general.string(forType: .string) ?? "")
                    if let first = links.first { model.address = first; model.additionalLinks = Array(links.dropFirst()); model.invalidateVideo() }
                    else { model.error = "剪贴板未找到支持的视频链接。" }
                }.disabled(model.busy)
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.additionalLinks.append("") } }
                    label: { Label("增加链接", systemImage: "plus.circle") }.disabled(model.busy)
            }
            HStack(spacing: 10) {
                TextField("粘贴哔哩哔哩视频、番剧或合集链接", text: $model.address)
                    .textFieldStyle(.plain).font(.system(size: 14)).padding(13)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .onSubmit { if !model.busy { model.inspect() } }.disabled(model.busy)
                    .onChange(of: model.address) { _ in model.invalidateVideo() }
                Button { if let value = NSPasteboard.general.string(forType: .string) { model.address = value } }
                    label: { Image(systemName: "doc.on.clipboard").padding(6) }
                    .help("粘贴链接").disabled(model.busy)
                Button(model.busy && !model.downloading ? "解析中…" : "解析视频") { model.inspect() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.address.isEmpty)
            }
            if !model.additionalLinks.isEmpty {
                ScrollView {
                    VStack(spacing: model.additionalLinks.count > 3 ? 4 : 8) {
                        ForEach(model.additionalLinks.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                Text("\(index + 2)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                                TextField("粘贴第 \(index + 2) 条视频或番剧链接", text: $model.additionalLinks[index])
                                    .textFieldStyle(.roundedBorder).font(.system(size: model.additionalLinks.count > 3 ? 12 : 14))
                                Button { model.additionalLinks.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            }.disabled(model.busy)
                        }
                    }.padding(.vertical, 3)
                }.frame(height: min(180, CGFloat(model.additionalLinks.count * (model.additionalLinks.count > 3 ? 29 : 37))))
                HStack {
                    Picker("同时下载链接", selection: $model.groupConcurrency) {
                        ForEach(1...4, id: \.self) { Text("\($0) 条").tag($0) }
                    }.frame(width: 200).disabled(model.busy)
                    Text("同一链接内逐集顺序下载；其他链接可并行。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.children.isEmpty {
                DisclosureGroup("各链接实时进度与历史（\(model.children.count)）") {
                    VStack(spacing: 8) {
                        ForEach(model.children) { child in LinkStatusRow(model: child) }
                    }.padding(.top, 8)
                }
            }
            Text("支持B站视频、番剧、合集和短链接。可用画质取决于内容与账号权限。")
                .font(.caption).foregroundStyle(.secondary)
            if let url = URL(string: model.address), InputPolicy.isSeason(url) {
                HStack {
                    Text("解析列表第几项")
                    TextField("序号", value: $model.episodeIndex, formatter: NumberFormatter()).frame(width: 65)
                    Stepper("", value: $model.episodeIndex, in: 1...9999).labelsHidden()
                    Text("默认第 1 项；也可直接粘贴某一集的播放链接。").foregroundStyle(.secondary)
                }.font(.caption).disabled(model.busy)
                    .onChange(of: model.episodeIndex) { value in
                        if value < 1 || value > 9999 { model.episodeIndex = min(9999, max(1, value)) }
                        if model.scope == "当前集" { model.invalidateVideo() }
                    }
            }
        }.card()
    }
    private func videoCard(_ video: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 18) {
            CachedArtwork(key: "video-" + video.id, poster: model.displayCover)
                .frame(width: 212, height: 126).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                Text(model.displayTitle).font(.headline).lineLimit(2).textSelection(.enabled)
                Text(model.episodeLabel).font(.caption.bold())
                Text("\(video.uploader ?? "哔哩哔哩")  ·  \(video.durationLabel)").font(.caption).foregroundStyle(.secondary)
                Picker("下载画质", selection: $model.selectedFormat) {
                    ForEach(Array(video.choices.enumerated()), id: \.element.id) { index, format in
                        Text(format.label + (index == 0 ? "  ·  最高可用" : "")).tag(format.id)
                    }
                }.disabled(model.busy)
                Text(video.sizeLabel(formatID: model.selectedFormat)).font(.callout.bold())
                if model.scope != "当前集" { Text("此处为当前集大小；列表按网页顺序编号，启用分组后组内顺序下载。").font(.caption2).foregroundStyle(.secondary) }
                Text("仅列出网站向当前会话提供的格式。登录或会员状态变化后请重新解析。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.card()
    }
    private var destinationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("保存位置").font(.caption).foregroundStyle(.secondary)
                Text(model.folder.path).font(.callout).lineLimit(1).truncationMode(.middle).help(model.folder.path)
            }
            Spacer()
            Button("更改…") { model.chooseFolder() }.disabled(model.busy)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
    private var downloadSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("下载连接", selection: $model.connections) {
                    Text("自动（\(DownloadTuning.automatic) 连接）").tag(0)
                    Text("兼容模式（单连接）").tag(1)
                    ForEach([2, 4, 8].filter { $0 <= MemoryBudget.connections }, id: \.self) { Text("\($0) 连接").tag($0) }
                }.frame(width: 270).disabled(model.busy)
                Text("系统活动核心 \(DownloadTuning.activeCores) · 多连接分段 · 原画质合并")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Picker("下载内容", selection: $model.scope) {
                    Text("当前集").tag("当前集"); Text("指定范围").tag("指定范围"); Text("全部集数").tag("整季")
                    Text("奇数集").tag("奇数集"); Text("偶数集").tag("偶数集"); Text("自定义").tag("自定义")
                }.frame(width: 220).disabled(model.busy)
                Picker("容器", selection: $model.container) { Text("MP4").tag("mp4"); Text("MKV").tag("mkv") }.frame(width: 150).disabled(model.busy)
                Spacer()
            }.font(.caption)
            if model.scope == "指定范围" {
                HStack {
                    Text("从第")
                    TextField("开始集", value: $model.episodeIndex, formatter: NumberFormatter()).frame(width: 65)
                    Text("集到第")
                    TextField("结束集", value: $model.episodeEnd, formatter: NumberFormatter()).frame(width: 65)
                    Text("集，按网页列表编号；分组内依次下载").foregroundStyle(.secondary)
                }.font(.callout).disabled(model.busy)
            }
            if model.scope == "自定义" {
                TextField("自定义集数，例如 1,3,5-8", text: $model.options.customEpisodes).disabled(model.busy)
            }
            if !model.episodes.isEmpty { Text("官方剧集／合集列表：\(model.episodes.count) 集，按网页顺序编号。当前任务：\(model.scope == "整季" ? "全部集数" : model.scope)。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var downloadControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("我有权下载此视频，仅作获准用途", isOn: $model.permissionConfirmed)
                .toggleStyle(.checkbox).font(.callout).disabled(model.busy)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { taskControlButtons }.frame(maxWidth: .infinity, alignment: .trailing)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 8)], spacing: 8) { taskControlButtons }
            }
            if !store.batchStatus.isEmpty { Text(store.batchStatus).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var taskControlButtons: some View {
            if model.busy {
                Button("暂停") { model.pause() }.controlSize(.large).disabled(model.paused)
                Button("取消任务") { model.cancel() }.controlSize(.large)
            } else if model.paused || model.lifecycle == .cancelled || model.lifecycle == .failed {
                Button("继续 / 重试失败项") { model.resume() }.controlSize(.large).disabled(!model.permissionConfirmed)
            } else {
                Button("暂停当前") {}.controlSize(.large).disabled(true)
            }
            if model.completedFile != nil { Button("在 Finder 中查看") { model.reveal() }.controlSize(.large) }
            Button { model.fillMissingEpisodes() } label: { Label("补齐缺失集", systemImage: "square.stack.badge.plus") }
                .controlSize(.large)
                .disabled(model.busy || !model.permissionConfirmed || account.checking)
                .help("扫描整季已有成品，只下载缺失集")
            Button { model.download() } label: { Label("开始下载", systemImage: "arrow.down.to.line").padding(.horizontal, 14) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy || (!model.hasMultipleLinks && model.video == nil) || !model.permissionConfirmed)
    }
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { $0.opacity(0.8).frame(width: 8, height: 8).clipShape(Circle()) }
                Text("  下载运行日志").font(.system(size: 10, weight: .medium)).foregroundStyle(.gray)
                Spacer()
                Text(model.phase).font(.caption).foregroundStyle(.white.opacity(0.8))
            }.padding(15).background(.white.opacity(0.04))
            VStack(spacing: 12) {
                HStack {
                    metric("当前流进度", model.progress.percent.map { String(format: "%.1f%%", $0) } ?? "—")
                    Spacer(); metric("下载速度", model.progress.speed)
                    Spacer(); metric("预计剩余", model.progress.eta)
                    Spacer(); metric("当前流已下载／总量", model.progress.sizeLabel)
                }
                if model.busy && model.progress.percent == nil { ProgressView().progressViewStyle(.linear) }
                else { ProgressView(value: model.progress.percent ?? 0, total: 100).tint(Color(red: 0.53, green: 0.91, blue: 0.76))
                    .animation(.linear(duration: 0.35), value: model.progress.percent) }
            }.padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(red: 0.67, green: 0.82, blue: 0.75))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.frame(height: 150).onChange(of: model.logs.last) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }.background(Color(red: 0.055, green: 0.065, blue: 0.09).opacity(appearance.glass ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.gray)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        }
    }
    private func sectionTitle(_ number: String, _ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(accent)
            Text(title).font(.callout.bold())
            Spacer(); Image(systemName: icon).foregroundStyle(.secondary)
        }
    }
}

