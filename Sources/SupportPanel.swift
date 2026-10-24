import SwiftUI
import AppKit

@MainActor enum SupportActions {
    static let email = "2463570866@qq.com"
    static let qq = "2463570866"
    static var contactURL: URL { URL(string: "https://wpa.qq.com/msgrd?v=3&uin=\(qq)&site=qq&menu=yes")! }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.3" }
    static func redact(_ text: String) -> String { InputPolicy.safeLog(text).replacingOccurrences(of: NSHomeDirectory(), with: "用户目录") }
    static func feedback() -> Bool {
        var url = URLComponents(); url.scheme = "mailto"; url.path = email
        url.queryItems = [.init(name: "subject", value: "[霹雳下载反馈] \(version) - 使用问题"),
            .init(name: "body", value: "问题描述：\n复现步骤：\n期望结果：\n实际结果：\n应用版本：\(version)\nmacOS：\(ProcessInfo.processInfo.operatingSystemVersionString)\n请自行检查内容后发送，诊断文件由你手动添加。")]
        return url.url.map { NSWorkspace.shared.open($0) } ?? false
    }
    static func export(model: AppModel) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "霹雳下载-脱敏诊断-\(version).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: [String: Any] = ["version": version, "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "phase": model.phase, "error": redact(model.error ?? "无"), "logs": model.logs.map(redact),
            "connections": model.connections, "completedCount": model.completedItems.count]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

struct SupportPanel: View {
    @ObservedObject var model: AppModel
    @State private var result = ""
    @State private var classifying = false
    @State private var organizing = false
    @State private var renamePlan: MediaRenamePlan?
    @State private var confirmRename = false
    @State private var folderPlan: MediaFolderPlan?
    @State private var confirmFolderOrganize = false
    @State private var organizingFolder = false
    @State private var checking = false
    var body: some View {
        DisclosureGroup("自检、隐私与问题反馈") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Button(checking ? "自检中…" : "重新自检") { check() }.disabled(checking)
                    Button("反馈问题（打开邮件）") {
                        result = SupportActions.feedback() ? "已请求打开邮件，请检查内容后自行发送。" : "未能打开邮件应用，请复制邮箱。"
                    }
                    Button("复制邮箱") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SupportActions.email, forType: .string) }
                    Button("联系作者 QQ") { result = NSWorkspace.shared.open(SupportActions.contactURL) ? "已请求打开QQ联系页面；如未唤起QQ，可复制号码添加。" : "无法打开，请复制QQ号码添加。" }
                    Button("复制QQ号") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SupportActions.qq, forType: .string); result = "已复制QQ：\(SupportActions.qq)" }
                    Button("导出脱敏诊断") { do { try SupportActions.export(model: model) } catch { result = error.localizedDescription } }
                    Button(classifying ? "分类中…" : "扫描并分类当前目录") {
                        classifying = true; result = "正在本地扫描…"
                        let folder = model.folder
                        let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools")
                        Task {
                            let report = await MediaRuleClassifier.scan(folder: folder, ffmpeg: tools?.appendingPathComponent("ffmpeg"))
                            do {
                                let files = try MediaRuleClassifier.save(report, to: folder)
                                result = "分类完成：\(report.total) 项；报告 \(files.csv.lastPathComponent)"
                            } catch { result = "分类报告保存失败：\(error.localizedDescription)" }
                            classifying = false
                        }
                    }.disabled(classifying)
                    Button(organizing ? "生成计划中…" : "预览重命名") {
                        organizing = true; result = "正在生成本地重命名计划…"
                        let folder = model.folder
                        let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools")
                        Task {
                            let plan = await MediaLibraryOrganizer.plan(folder: folder, ffmpeg: tools?.appendingPathComponent("ffmpeg"))
                            do {
                                let files = try MediaLibraryOrganizer.save(plan, to: folder)
                                renamePlan = plan
                                result = plan.items.isEmpty ? "当前目录已符合命名规则，无需重命名。" : "重命名预览：\(plan.items.count) 项；计划 \(files.csv.lastPathComponent)"
                            } catch { result = "重命名计划保存失败：\(error.localizedDescription)" }
                            organizing = false
                        }
                    }.disabled(organizing || model.busy)
                    Button("执行重命名") { confirmRename = true }
                        .disabled(organizing || model.busy || renamePlan?.items.isEmpty != false)
                    Button(organizingFolder ? "整理计划中…" : "预览整理文件夹") {
                        organizingFolder = true; result = "正在生成本地整理计划…"
                        let folder = model.folder
                        let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools")
                        Task {
                            let plan = await MediaLibraryOrganizer.folderPlan(folder: folder, ffmpeg: tools?.appendingPathComponent("ffmpeg"))
                            do {
                                let files = try MediaLibraryOrganizer.save(plan, to: folder)
                                folderPlan = plan
                                result = plan.items.isEmpty ? "文件夹已整理，无需移动。" : "整理预览：\(plan.items.count) 项；计划 \(files.csv.lastPathComponent)"
                            } catch { result = "整理计划保存失败：\(error.localizedDescription)" }
                            organizingFolder = false
                        }
                    }.disabled(organizingFolder || model.busy)
                    Button("执行整理") { confirmFolderOrganize = true }
                        .disabled(organizingFolder || model.busy || folderPlan?.items.isEmpty != false)
                }
                Text("本地保存任务历史、外观、会话与来源日志；不保存账号密码。诊断不含凭证，不后台上传或发信。")
                    .font(.caption).foregroundStyle(.secondary)
                if !result.isEmpty { Text(result).font(.caption).textSelection(.enabled) }
            }.padding(.top, 10)
        }.card()
        .alert("执行媒体重命名？", isPresented: $confirmRename) {
            Button("执行", role: .destructive) {
                guard let plan = renamePlan else { return }
                organizing = true; result = "正在重命名…"
                Task {
                    do {
                        let count = try await FileOperationGuard.perform { try MediaLibraryOrganizer.apply(plan) }
                        result = "重命名完成：\(count) 项"
                        renamePlan = nil
                    } catch { result = "重命名失败：\(error.localizedDescription)" }
                    organizing = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按预览计划重命名 \(renamePlan?.items.count ?? 0) 个文件；失败会尝试恢复原名，旧文件不删除。")
        }
        .confirmationDialog("执行文件夹整理？", isPresented: $confirmFolderOrganize, titleVisibility: .visible) {
            Button("执行", role: .destructive) {
                guard let plan = folderPlan else { return }
                organizingFolder = true; result = "正在整理文件夹…"
                Task {
                    do {
                        let count = try await FileOperationGuard.perform { try MediaLibraryOrganizer.apply(plan) }
                        result = "整理完成：移动 \(count) 项；重复文件集中在“重复文件”目录。"
                        folderPlan = nil
                    } catch { result = "整理失败：\(error.localizedDescription)" }
                    organizingFolder = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按分类移动 \(folderPlan?.items.count ?? 0) 个视频文件，并处理同名同内容/同名不同内容；执行前已生成计划。")
        }
    }
    private func check() {
        checking = true; result = ""
        Task { @MainActor in
            var rows: [String] = []
            let tools = Bundle.main.resourceURL!.appendingPathComponent("Tools")
            for tool in ["yt-dlp", "ffmpeg", "aria2c"] {
                var version = ""
                do {
                    try await ProcessRunner().run(executable: tools.appendingPathComponent(tool), arguments: [tool == "ffmpeg" ? "-version" : "--version"], timeout: 45) {
                        if version.isEmpty { version = String($0.prefix(150)) }
                    }
                    rows.append("通过：\(version)")
                } catch { rows.append("失败：\(tool) 自检未通过，\(SupportActions.redact(error.localizedDescription))") }
            }
            do { try MediaIntegrity.preflight(folder: model.folder); rows.append("通过：目录可写，空间满足最低预留。") }
            catch { rows.append("失败：\(error.localizedDescription)") }
            do { _ = try TaskHistory.read(); rows.append("通过：任务历史可读取。") } catch { rows.append("失败：历史损坏，原文件保留。") }
            rows.append(model.account.loggedIn ? "账号：已登录；具体内容需解析确认权限。" : "账号：未登录，可使用匿名权限内容。")
            result = rows.joined(separator: "\n"); checking = false
        }
    }
}
