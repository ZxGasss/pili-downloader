import SwiftUI

struct LinkStatusRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: model.displayCover) { image in image.resizable().scaledToFill() }
                placeholder: { Image(systemName: "play.rectangle") }
                .frame(width: 84, height: 48).clipped().cornerRadius(6)
            VStack(alignment: .leading, spacing: 3) {
                if !model.batchTitle.isEmpty { Text(model.batchTitle).font(.caption.bold()).foregroundStyle(Color.accentColor) }
                Text(model.displayTitle).font(.callout.bold()).lineLimit(2)
                Text([model.episodeLabel, model.phase, model.progress.speed].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if model.downloading { ProgressView(value: model.progress.percent ?? 0, total: 100) }
                if model.seasonEstimate.total > 1 { Text("组内 \(model.seasonEstimate.completed)/\(model.seasonEstimate.total)集 · 剩余\(model.seasonEstimate.label)").font(.caption.monospacedDigit()) }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            Spacer()
        }
    }
}
