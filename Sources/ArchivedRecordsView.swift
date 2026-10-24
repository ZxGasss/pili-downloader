import SwiftUI

struct ArchivedRecordsView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false
    @State private var message = ""
    let onRestore: (UUID) -> Void
    private var records: [AppModel] { store.tasks.filter { $0.parentID == nil && $0.archived } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("已移除记录").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("仅管理任务记录。视频和续传分片保留，媒体库中的资料也保留。").foregroundStyle(.secondary)
            HStack {
                Button("全选（⌘A）") { selection = Set(records.map(\.id)) }
                Button("取消选择") { selection = [] }
                Text("已选 \(selection.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复已选") {
                    for id in selection { if store.restore(id) { onRestore(id) } }; selection = []
                }.disabled(selection.isEmpty)
                Button("删除已选记录…", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
            }
            List(selection: $selection) {
                ForEach(records) { task in
                    HStack {
                        VStack(alignment: .leading) { Text(task.displayTitle).lineLimit(2); Text(task.phase).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).tag(task.id)
                }
            }
            .onCommand(#selector(NSText.selectAll(_:))) { selection = Set(records.map(\.id)) }
            .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
            if !message.isEmpty { Text(message).foregroundStyle(.orange) }
        }.padding(26).frame(width: 760, height: 560)
        .alert("删除选中的 \(selection.count) 条记录？", isPresented: $confirmDelete) {
            Button("只删除记录", role: .destructive) {
                do { let count = try store.deleteArchivedMany(selection); selection = []; message = "已删除 \(count) 条记录，视频和分片未动。" }
                catch { message = InputPolicy.safeLog(error.localizedDescription) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("不可恢复这些任务记录；不会删除视频、续传分片或媒体库条目。") }
    }
}
