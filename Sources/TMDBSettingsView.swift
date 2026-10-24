import SwiftUI
import UniformTypeIdentifiers

struct TMDBSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = TMDBCredential.Kind.readToken
    @State private var value = ""
    @State private var message = ""
    @State private var busy = false
    @State private var configured = false
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("影片识别与分类 · TMDB").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("每位用户使用自己的TMDB凭据，保存到本机钥匙串；不会随安装包分发。").foregroundStyle(.secondary)
            Link("① 前往 TMDB 申请或查看 API", destination: TMDBAccess.applicationURL)
            Text("登录后，在API设置中申请并复制“API读访问令牌”（推荐），或复制“API密钥”。申请用途请如实填写并遵守TMDB条款。").font(.callout)
            Picker("② 凭据类型", selection: $kind) {
                Text("读取访问令牌（推荐）").tag(TMDBCredential.Kind.readToken)
                Text("API Key（v3）").tag(TMDBCredential.Kind.apiKey)
            }.pickerStyle(.segmented)
            SecureField(kind == .readToken ? "粘贴 API Read Access Token" : "粘贴 API Key", text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Button("从文本或JSON文件导入…") { importFile() }
                Button("③ 验证并保存到钥匙串") { save() }.buttonStyle(.borderedProminent).disabled(value.isEmpty)
            }.disabled(busy)
            HStack {
                Label(configured ? "本机已有凭据" : "尚未配置", systemImage: configured ? "checkmark.shield.fill" : "key")
                Spacer()
                Button("验证已保存的连接") { testSaved() }.disabled(!configured || busy)
                Button("移除本机凭据…", role: .destructive) { confirmClear = true }.disabled(!configured || busy)
            }.font(.callout)
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            Text("使用：媒体库 → 视频右键 → 匹配影片资料。确认正确影片后，按TMDB资料归入电影、剧集或动画；不会自动移动或删除视频。").font(.callout)
            Text("查询会将输入的片名发送至TMDB，不上传本地视频。").font(.caption).foregroundStyle(.secondary)
            TMDBAttribution()
        }.padding(28).frame(width: 650)
        .task { refresh() }
        .alert("移除本机TMDB凭据？", isPresented: $confirmClear) {
            Button("移除", role: .destructive) { do { try TMDBAccess.clear(); configured = false; message = "本机凭据已移除，已有影片资料保留。" } catch { message = error.localizedDescription } }
            Button("取消", role: .cancel) {}
        } message: { Text("只移除本机保存的API凭据，不删除TMDB账号或媒体。") }
    }
    private func refresh() {
        do { configured = try TMDBAccess.credential() != nil }
        catch { message = "钥匙串暂不可访问，请解锁后重试。" }
    }
    private func save() {
        busy = true; message = "正在验证…"
        Task {
            defer { busy = false }
            do {
                let credential = try TMDBCredential(kind: kind, value: value)
                try await TMDBAccess.validate(credential)
                try TMDBAccess.save(credential)
                value = ""; configured = true; message = "连接验证通过，已保存到本机钥匙串。可以匹配影片并分类。"
            } catch { message = error.localizedDescription }
        }
    }
    private func testSaved() {
        busy = true; message = "正在测试连接…"
        Task {
            defer { busy = false }
            do {
                guard let credential = try TMDBAccess.credential() else { refresh(); return }
                try await TMDBAccess.validate(credential); message = "已保存凭据连接正常。"
            } catch { message = error.localizedDescription }
        }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max
            guard size <= 32768 else { throw AppFailure.message("凭据文件超过32KB，请选择仅含凭据的文本或JSON。") }
            let credential = try TMDBCredential.imported(Data(contentsOf: file))
            kind = credential.kind; value = credential.value; message = "已导入，验证通过后才会替换原配置。"
        } catch { message = error.localizedDescription }
    }
}

struct TMDBAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("TMDB.svg"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 90, height: 20)
            }
            Link("The Movie Database (TMDB)", destination: URL(string: "https://www.themoviedb.org")!)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption2).foregroundStyle(.secondary)
            Link("API条款与商业授权", destination: URL(string: "https://developer.themoviedb.org/docs/faq")!).font(.caption)
        }
    }
}
