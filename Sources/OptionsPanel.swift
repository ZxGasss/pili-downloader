import SwiftUI
import AppKit

struct OptionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var hardware = HardwareMonitor.shared
    @State private var search = ""
    var body: some View {
        DisclosureGroup("高级选集、音频与附属文件") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("网络停滞时自动恢复（最多3次，手动取消不恢复）", isOn: Binding(get: { model.options.autoRecover != false }, set: { model.options.autoRecover = $0 }))
                HStack {
                    Text("多集同时下载")
                    TextField("1–200", value: Binding(get: { model.options.simultaneousBatches ?? hardware.recommendedEpisodeCount }, set: { model.options.simultaneousBatches = min(200, max(1, $0)) }), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                    Stepper("集", value: Binding(get: { model.options.simultaneousBatches ?? hardware.recommendedEpisodeCount }, set: { model.options.simultaneousBatches = min(200, max(1, $0)) }), in: 1...200)
                }
                Text("\(hardware.chip) 当前CPU \(HardwareSample.percent(hardware.sample.cpu))，推荐同时下载 \(hardware.recommendedEpisodeCount) 集；可手动调整1–200集。当前有效并发：\(model.episodeConcurrencyLimit)集。每集独立下载，后台预取后续集信息，不中断当前传输。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("媒体预设", selection: $model.options.preset) {
                    ForEach(["最高画质", "最佳兼容", "最小体积", "自定义"], id: \.self) { Text($0) }
                }.onChange(of: model.options.preset) { value in
                    guard let choices = model.video?.choices else { return }
                    let chosen = value == "最佳兼容" ? choices.first(where: { $0.vcodec?.hasPrefix("avc") == true })
                        : value == "最小体积" ? choices.min(by: { ($0.tbr ?? .greatestFiniteMagnitude) < ($1.tbr ?? .greatestFiniteMagnitude) }) : choices.first
                    if let chosen { model.selectedFormat = chosen.id }
                }
                if let video = model.displayVideo, !video.audioChoices.isEmpty {
                    Picker("音频规格", selection: $model.options.audioID) {
                        Text("自动最佳音频").tag("")
                        ForEach(video.audioChoices) { audio in Text(audio.audioLabel).tag(audio.id) }
                    }
                    Text("Hi-Res、杜比及无损以平台返回的音轨和标识为准；未提供的采样率与位深不推测。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Stepper("任务限速：\(model.options.rateMiB == 0 ? "不限" : "\(model.options.rateMiB) MiB/s")", value: $model.options.rateMiB, in: 0...1000)
                    Stepper("重试：\(model.options.retries) 次", value: $model.options.retries, in: 0...8)
                }
                HStack {
                    Toggle("保存字幕", isOn: $model.options.subtitle)
                    Toggle("保存弹幕 XML", isOn: $model.options.danmaku)
                    Toggle("保存封面", isOn: $model.options.thumbnail)
                }
                if model.options.subtitle { TextField("字幕语言，例如 zh.*,en", text: $model.options.subtitleLanguages) }
                HStack {
                    Toggle("来源元数据", isOn: $model.options.metadata)
                    Toggle("媒体库 NFO", isOn: $model.options.nfo)
                    Toggle("保留原始分轨", isOn: $model.options.keepStreams)
                }
                if !model.options.movieNamingEnabled { TextField("文件命名模板", text: $model.options.filename) }
                Toggle("专业网盘命名（集号/标题/规格/声音/大小）", isOn: Binding(
                    get: { model.options.movieNamingEnabled },
                    set: { model.options.movieNaming = $0 }
                ))
                Text(model.options.movieNamingEnabled ? "已开启：例如 001 - 剧情标题 - 2160p HEVC - AAC 2.0 - 123.4MB.mp4。默认开启，旧成品和旧分片保持原命名。" : "已关闭：保留自定义或默认命名；旧文件不重命名。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.options.movieNamingEnabled ? "下载完成后按真实分辨率、编码、音轨和成品大小校正文件名；不覆盖同名文件。" : "使用片名命名并限制长度；已有文件不覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.episodes.isEmpty {
                    TextField("搜索官方集数标题", text: $search)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.episodes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { episode in
                                HStack {
                                    Text("第\(episode.index)集").frame(width: 64, alignment: .leading)
                                    Text(episode.title).lineLimit(1)
                                    Spacer()
                                    Button("选择") { model.scope = "当前集"; model.episodeIndex = episode.index; model.inspect() }
                                }.font(.caption)
                            }
                        }
                    }.frame(maxHeight: 170)
                }
            }.padding(.top, 10).disabled(model.busy)
        }.card()
    }
}
