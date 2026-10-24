import SwiftUI

struct SeasonDashboard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("整季下载概况", systemImage: "square.stack.3d.up")
                Spacer()
                Text("已完成 \(model.seasonEstimate.completed)/\(model.seasonEstimate.total)集").monospacedDigit()
            }.font(.headline)
            HStack {
                Text("整季预计剩余：\(model.seasonEstimate.label)").font(.title3.bold())
                Spacer()
                Text("总速度 \(ByteCountFormatter.string(fromByteCount: Int64(max(0, model.aggregateSpeed)), countStyle: .file))/s").font(.callout.monospacedDigit())
            }
            ProgressView(value: model.seasonFraction, total: 1)
            Text("整季进度 \(Int(model.seasonFraction * 100))% · 已完成文件 + 活跃集字节估算；合并校验后才计为完成").font(.caption).foregroundStyle(.secondary)
            Text("当前同时下载 \(model.activeEpisodeCount) 集 · 上限 \(model.episodeConcurrencyLimit) 集 · \(HardwareMonitor.shared.chip) CPU \(HardwareSample.percent(HardwareMonitor.shared.sample.cpu)) 推荐 \(HardwareMonitor.shared.recommendedEpisodeCount) 集")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ForEach(model.children.filter { model.runningChildIDs.contains($0.id) && ($0.downloading || $0.busy) }) { child in
                LinkStatusRow(model: child)
            }
            Text("时间为动态估算，依据已完成集大小和实测总速度；未知时显示采样中。音视频切换、合并、网络变化会影响结果。")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }
}
