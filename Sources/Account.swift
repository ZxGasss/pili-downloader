import SwiftUI
import WebKit

@MainActor final class AccountSession: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = AccountSession()
    @Published var displayName = "未登录"
    @Published var avatarURL: URL?
    @Published var userID: Int64?
    @Published var membership = "账号未验证"
    @Published var loggedIn = false
    @Published var isVIP = false
    @Published var checking = false
    @Published var error = ""
    private(set) var cookies: [HTTPCookie] = []
    private let store = WKWebsiteDataStore.nonPersistent()
    override init() {
        super.init()
        Task { @MainActor in
            for cookie in CredentialStore.load() { await store.httpCookieStore.setCookie(cookie) }
            let existing = await store.httpCookieStore.allCookies()
            if !existing.isEmpty { await authorize() }
        }
    }
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()
    func openLogin() {
        error = ""
        webView.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
    }
    func authorize() async {
        checking = true; error = ""
        defer { checking = false }
        let all = await store.httpCookieStore.allCookies()
        let scoped = all.filter { ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")) && ($0.expiresDate == nil || $0.expiresDate! > Date()) }
        var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        // A dedicated ephemeral URLSession cannot receive cookies from Safari or Chrome.
        let apiCookies = scoped.filter { c in
            let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return (c.domain.hasPrefix(".") ? ("api.bilibili.com" == domain || "api.bilibili.com".hasSuffix("." + domain)) : domain == "api.bilibili.com") && "/x/web-interface/nav".hasPrefix(c.path)
        }
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: apiCookies)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["code"] as? Int == 0, let user = json["data"] as? [String: Any], user["isLogin"] as? Bool == true
            else { throw AppFailure.message("尚未确认登录，请在页面完成扫码或账号登录后再授权。") }
            cookies = scoped
            displayName = user["uname"] as? String ?? "哔哩哔哩用户"
            avatarURL = (user["face"] as? String).flatMap(URL.init(string:))
            userID = (user["mid"] as? NSNumber)?.int64Value
            loggedIn = true
            if let vip = user["vipStatus"] as? Int {
                isVIP = vip == 1
                membership = isVIP ? "大会员" : "普通账号"
            } else if let vip = user["vip"] as? [String: Any], let status = vip["status"] as? Int {
                isVIP = status == 1; membership = isVIP ? "大会员" : "普通账号"
            } else { isVIP = false; membership = "会员状态未知" }
            try CredentialStore.save(scoped)
        } catch {
            loggedIn = false; isVIP = false; membership = "登录状态待验证"
            self.error = InputPolicy.safeLog(error.localizedDescription)
        }
    }
    func logout() {
        CredentialStore.clear()
        cookies = []; loggedIn = false; isVIP = false; displayName = "未登录"; membership = "账号未验证"; error = ""
        avatarURL = nil; userID = nil
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
    func importChrome(profile: String) async {
        checking = true; error = ""
        do {
            let imported = try await Task.detached(priority: .userInitiated) { try ChromeCookieImporter.read(profile: profile) }.value
            for cookie in imported { await store.httpCookieStore.setCookie(cookie) }
            try CredentialStore.save(imported)
            await authorize()
        } catch { self.error = InputPolicy.safeLog(error.localizedDescription) }
        checking = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let host = url.host?.lowercased() ?? ""
        // Keep the dedicated login view on Bilibili; no arbitrary external navigation.
        decisionHandler(url.scheme == "https" && (host == "bilibili.com" || host.hasSuffix(".bilibili.com")) ? .allow : .cancel)
    }
}

struct LoginBrowser: NSViewRepresentable {
    let account: AccountSession
    func makeNSView(context: Context) -> WKWebView { account.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct LoginSheet: View {
    @ObservedObject var account: AccountSession
    let authorized: () -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("登录哔哩哔哩").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
            Text("在官方页面主动登录。应用不保存账号密码，会话凭据保存在系统钥匙串；升级后重新验证，会话过期才需登录。退出登录会清除此应用的会话。")
                .font(.callout).foregroundStyle(.secondary)
            LoginBrowser(account: account).frame(minHeight: 450)
            if !account.error.isEmpty { Text(account.error).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("授权仅用于账号验证和你有权下载的视频。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(account.checking ? "验证中…" : "授权此登录用于下载") {
                    Task { await account.authorize(); if account.loggedIn && account.error.isEmpty { authorized(); dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(account.checking)
            }
        }.padding(22).frame(width: 780, height: 650).onAppear { account.openLogin() }
    }
}
