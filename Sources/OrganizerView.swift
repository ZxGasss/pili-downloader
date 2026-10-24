import SwiftUI

struct OrganizerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library = MediaLibrary.shared
    @State private var plan: MediaRenamePlan?
    @State private var residuals: [ResidualCandidate] = []
    @State private var folder: URL?
    @State private var working = false
    @State private var message = ""
    @State private var confirmRename = false
    @State private var confirmCleanup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("文件检查与整理").font(.system(size: 32, weight: .bold))
                Text("先看证据，再整理。视频保留在原处，冲突和不确定项等待你确认。").foregroundStyle(.secondary)
                HStack {
                    Button("选择目录并检查全部视频") { selectFolder() }.buttonStyle(.borderedProminent)
                    if working { ProgressView().controlSize(.small) }
                }.disabled(working || TaskStore.shared.tasks.contains(where: \.busy))
                if !message.isEmpty { Text(message).textSelection(.enabled).foregroundStyle(.secondary) }
                if let plan, !plan.items.isEmpty {
                    Text("分辨率纠正预览 · \(plan.items.count) 项").font(.title2.bold())
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: item.oldPath).lastPathComponent).foregroundStyle(.secondary)
                            Text("→ " + URL(fileURLWithPath: item.newPath).lastPathComponent)
                        }.font(.callout).textSelection(.enabled)
                    }
                    Button("确认按实测分辨率纠正文件名") { confirmRename = true }.disabled(working)
                }
                if !residuals.isEmpty {
                    Text("已核验成品对应残留 · \(residuals.count) 项").font(.title2.bold())
                    ForEach(residuals) { item in Text(item.file.lastPathComponent).font(.caption).textSelection(.enabled) }
                    Button("将预览中的残留移到废纸篓", role: .destructive) { confirmCleanup = true }.disabled(working)
                }
                Divider()
                Text("本地分类与整理").font(.title2.bold())
                SupportPanel(model: model)
                Text("未匹配的 .part 保留续传；仅凭扩展名不会删除。检查记录保存在本机，不上传媒体。").font(.caption).foregroundStyle(.secondary)
            }.padding(36)
        }
        .alert("纠正预览中的文件名？", isPresented: $confirmRename) {
            Button("执行纠正") {
                guard let plan, !TaskStore.shared.tasks.contains(where: \.busy) else { return }
                do { let count = try MediaLibraryOrganizer.apply(plan); message = "已纠正 \(count) 个文件名。"; self.plan = nil
                    if let folder { Task { await library.scan(folder) } }
                } catch { message = InputPolicy.safeLog(error.localizedDescription) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("只更改预览中的名称；目标冲突即停止，不覆盖文件。") }
        .alert("把这些残留移到废纸篓？", isPresented: $confirmCleanup) {
            Button("移到废纸篓", role: .destructive) {
                working = true
                Task {
                    defer { working = false }
                    do { let count = try await FileOrganizer.trashResiduals(residuals); message = "\(count) 个已核验残留已移到废纸篓。"; residuals = [] }
                    catch { message = InputPolicy.safeLog(error.localizedDescription) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("执行前会重新检查成品完整性和残留是否变化。没有对应完整成品的分片会保留。") }
    }
    private func selectFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        folder = selected; working = true; message = "正在用 mdls 和视频轨探测逐个核验，原文件不变…"
        Task {
            defer { working = false }
            let tools = Bundle.main.resourceURL!.appendingPathComponent("Tools")
            do {
                let (result, reports) = try await FileOrganizer.resolutionPlan(folder: selected, tools: tools)
                plan = result
                let directory = TaskHistory.base.appendingPathComponent("Diagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try reports.joined(separator: "\n").write(to: directory.appendingPathComponent("file-check-\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
                await library.scan(selected)
                let products = library.items.filter { $0.path.hasPrefix(selected.path + "/") && !$0.missing }.map(\.file)
                residuals = await FileOrganizer.residuals(folder: selected, products: products, tools: tools)
                message = "检查 \(reports.count) 个视频；\(result.items.count) 个名称待纠正，\(residuals.count) 个残留可确认清理。未修改原文件。"
            } catch { message = InputPolicy.safeLog(error.localizedDescription) }
        }
    }
}

struct FileOrganizerSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Spacer(); Button("完成") { dismiss() } }.padding()
            OrganizerView(model: model)
        }.frame(width: 840, height: 650)
    }
}

struct ResidualReviewView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = false
    @State private var message = ""
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("下载完成后的残留检查").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
            Text("下面的残留均有已核验的对应成品。未完成任务的分片不会进入清理清单。").foregroundStyle(.secondary)
            ScrollView { LazyVStack(alignment: .leading) { ForEach(store.residualCandidates) { item in Text(item.file.lastPathComponent).font(.callout).padding(.vertical, 5) } } }
            if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            Button("将这些残留移到废纸篓", role: .destructive) { confirmation = true }
                .disabled(working || store.residualCandidates.isEmpty || store.tasks.contains(where: \.busy))
        }.padding(28).frame(width: 650, height: 440)
        .alert("确认清理预览中的残留？", isPresented: $confirmation) {
            Button("移到废纸篓", role: .destructive) {
                working = true
                Task {
                    defer { working = false }
                    do {
                        let count = try await FileOrganizer.trashResiduals(store.residualCandidates)
                        store.residualCandidates = []; message = "已将 \(count) 个残留移到废纸篓。"
                    } catch { message = InputPolicy.safeLog(error.localizedDescription) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("会再次核验成品和残留状态；视频成品不在此清单中。") }
    }
}
