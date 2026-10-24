import SwiftUI

struct MyBilibiliView: View {
    @ObservedObject private var account = AccountSession.shared
    @State private var loginShown = false
    @State private var folders: [BiliFavoriteFolder] = []
    @State private var videos: [BiliFavoriteVideo] = []
    @State private var selectedFolder: Int64?
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var message = ""
    @State private var tmdbSettingsShown = false
    @State private var confirmLegacy = false
    @State private var chromeProfile = "Default"
    @AppStorage("downloads.resumeOnLaunch") private var resumeOnLaunch = false
    let createDownload: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("我的B站").font(.system(size: 28, weight: .bold))
                HStack(spacing: 20) {
                    CachedArtwork(key: "account-avatar", poster: account.avatarURL).frame(width: 48, height: 48).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 7) {
                        Text(account.displayName).font(.headline)
                        Label(account.membership, systemImage: account.isVIP ? "crown.fill" : "person.crop.circle")
                            .foregroundStyle(account.isVIP ? .pink : .secondary)
                        Text(account.loggedIn ? "已登录 · 本机安全会话" : "登录后读取身份和收藏夹").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(account.loggedIn ? "重新验证" : "登录B站") {
                        if account.loggedIn { Task { await account.authorize() } } else { loginShown = true }
                    }.buttonStyle(.borderedProminent).disabled(account.checking)
                    if account.loggedIn { Button("退出登录") { account.logout(); folders = []; videos = [] } }
                }.padding(25).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                if !account.error.isEmpty { Text(account.error).foregroundStyle(.orange) }
                DisclosureGroup("登录方式与Chrome导入") {
                HStack {
                    Picker("Chrome用户", selection: $chromeProfile) { ForEach(ChromeCookieImporter.profiles.isEmpty ? ["Default"] : ChromeCookieImporter.profiles, id: \.self) { Text($0).tag($0) } }.frame(width: 240)
                    Button("从Chrome导入B站登录") { Task { await account.importChrome(profile: chromeProfile) } }.disabled(account.checking)
                }
                Text("由你主动导入，只读取B站会话；系统可能请求Chrome安全存储权限。不支持的加密格式可改用应用内登录。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("我的收藏").font(.title2.bold()); Spacer()
                    Button("读取收藏夹") { loadFolders() }.disabled(!account.loggedIn || loading)
                    if loading { ProgressView().controlSize(.small) }
                }
                Text("只读浏览，不修改或删除B站云端收藏。点击视频会带入下载入口。").font(.callout).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange) }
                ScrollView(.horizontal) {
                    HStack { ForEach(folders) { folder in Button("\(folder.title)（\(folder.count)）") { selectedFolder = folder.id; page = 1; videos = []; loadVideos() }.disabled(loading) } }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], spacing: 22) {
                    ForEach(videos) { video in
                        Button { if let url = video.url { createDownload(url.absoluteString) } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                CachedArtwork(key: "bili-" + video.id, poster: video.cover).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 14))
                                Text(video.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if hasMore { Button("加载更多") { page += 1; loadVideos() }.disabled(loading) }
                Divider()
                DisclosureGroup("本机安全与恢复设置") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("重开应用后继续退出前的下载", isOn: $resumeOnLaunch)
                        Text("默认保留分片和任务，手动继续；启用后会在恢复登录状态后重新解析地址。").font(.caption).foregroundStyle(.secondary)
                        Button("影片识别与分类 · TMDB设置") { tmdbSettingsShown = true }
                        if CredentialStore.hasLegacyCopy {
                            Text("旧版仍有本地明文会话副本；钥匙串迁移后可确认清理。").font(.caption).foregroundStyle(.orange)
                            Button("清理旧版明文会话副本…") { confirmLegacy = true }
                        }
                    }.padding(.top, 12)
                }
            }.padding(24)
        }
        .sheet(isPresented: $loginShown) { LoginSheet(account: account, authorized: {}) }
        .sheet(isPresented: $tmdbSettingsShown) { TMDBSettingsView() }
        .task { if account.loggedIn && folders.isEmpty { loadFolders() } }
        .onChange(of: account.loggedIn) { loggedIn in if loggedIn && folders.isEmpty { loadFolders() } }
        .alert("清理旧版明文会话副本？", isPresented: $confirmLegacy) {
            Button("确认清理", role: .destructive) { do { try CredentialStore.removeLegacyCopy(); message = "旧明文副本已清理，钥匙串会话保留。" } catch { message = error.localizedDescription } }
            Button("取消", role: .cancel) {}
        } message: { Text("只清理旧版会话文件；确认钥匙串已有凭据后才会执行。") }
    }
    private func loadFolders() {
        guard let id = account.userID else { return }
        loading = true; message = ""
        Task {
            defer { loading = false }
            do {
                folders = try await BilibiliProvider.folders(userID: id, cookies: account.cookies)
                if let first = folders.first {
                    selectedFolder = first.id; page = 1
                    let result = try await BilibiliProvider.favorites(folder: first.id, page: 1, cookies: account.cookies)
                    videos = result.0; hasMore = result.1
                } else { message = "没有可读取的收藏夹。" }
            }
            catch { message = InputPolicy.safeLog(error.localizedDescription) }
        }
    }
    private func loadVideos() {
        guard let selectedFolder else { return }
        loading = true; message = ""
        Task {
            defer { loading = false }
            do {
                let result = try await BilibiliProvider.favorites(folder: selectedFolder, page: page, cookies: account.cookies)
                let known = Set(videos.map(\.id)); videos.append(contentsOf: result.0.filter { !known.contains($0.id) })
                hasMore = result.1 && page < 50
            } catch { message = InputPolicy.safeLog(error.localizedDescription) }
        }
    }
}
