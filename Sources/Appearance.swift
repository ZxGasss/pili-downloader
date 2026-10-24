import SwiftUI
import AppKit

@MainActor final class Appearance: ObservableObject {
    static let shared = Appearance()
    @Published var hue: Double { didSet { UserDefaults.standard.set(hue, forKey: "pili.hue"); rgbHex = nil; updateDockIcon() } }
    @Published var rgbHex: String? { didSet { UserDefaults.standard.set(rgbHex, forKey: "pili.rgb"); updateDockIcon() } }
    @Published var opacity: Double { didSet { UserDefaults.standard.set(opacity, forKey: "pili.opacity") } }
    @Published var glass: Bool { didSet { UserDefaults.standard.set(glass, forKey: "pili.glass") } }
    @Published var mode: String { didSet { UserDefaults.standard.set(mode, forKey: "pili.mode") } }
    var accent: Color {
        if let rgbHex, let value = UInt32(rgbHex, radix: 16) {
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        return Color(hue: hue, saturation: 0.78, brightness: 0.82)
    }
    func setColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        rgbHex = String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }
    private init() {
        let d = UserDefaults.standard
        hue = d.object(forKey: "pili.hue") as? Double ?? 0.65
        rgbHex = d.string(forKey: "pili.rgb")
        opacity = 1
        glass = d.object(forKey: "pili.glass") as? Bool ?? false
        mode = d.string(forKey: "pili.mode") ?? "跟随系统"
    }
    func reset() { hue = 0.65; opacity = 1; glass = false; mode = "跟随系统" }
    func updateDockIcon() {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let image = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = image
        }
    }
}

struct AppearancePanel: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredPlayer") private var preferredPlayer = "IINA"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("外观与颜色").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("主题与颜色").font(.headline)
            HStack {
                Picker("播放应用", selection: $preferredPlayer) { Text("IINA").tag("IINA"); Text("系统默认播放器").tag("系统默认") }
                Button("下载IINA") { NSWorkspace.shared.open(URL(string: "https://iina.io/")!) }
            }
            HStack(spacing: 14) {
                ForEach(Array(zip(["海蓝", "紫色", "翠绿", "橙金", "玫红"], [0.52, 0.70, 0.40, 0.09, 0.94])), id: \.0) { name, hue in
                    Button { appearance.hue = hue } label: {
                        VStack { Circle().fill(Color(hue: hue, saturation: 0.78, brightness: 0.82)).frame(width: 34, height: 34); Text(name).font(.caption) }
                    }.buttonStyle(.plain)
                }
            }
            Slider(value: $appearance.hue, in: 0...1) { Text("自定义色相") }
            HStack {
                ColorPicker("苹果原生色板（色轮／光谱／RGB）", selection: Binding(get: { appearance.accent }, set: { appearance.setColor(NSColor($0)) }), supportsOpacity: false)
                Button("打开完整色板") { NativeColorPanel.shared.open() }
                Button("屏幕取色器") {
                    NSColorSampler().show { color in
                        if let color { Task { @MainActor in appearance.setColor(color) } }
                    }
                }
            }
            Text("支持完整 24 位 RGB 色彩。点击色块打开系统颜色面板，也可用取色器从屏幕选色。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("界面模式", selection: $appearance.mode) {
                ForEach(["跟随系统", "浅色", "深色"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("侧栏毛玻璃", isOn: $appearance.glass)
            Text("毛玻璃仅用于侧栏。主内容、文字与按钮始终保持清晰，窗口不会透出后方文字。")
                .font(.caption).foregroundStyle(.secondary)
            Button("恢复默认外观") { appearance.reset() }
        }.padding(26).frame(width: 550).tint(appearance.accent)
    }
}

struct WindowGlass: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar; view.blendingMode = .withinWindow
        view.state = enabled ? .active : .inactive; view.isHidden = !enabled
    }
}

struct WindowAppearance: NSViewRepresentable {
    var opacity: Double
    final class Host: NSView {
        var opacity = 1.0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() { window?.isOpaque = true; window?.backgroundColor = .windowBackgroundColor; window?.alphaValue = 1 }
    }
    func makeNSView(context: Context) -> Host { let view = Host(); view.opacity = opacity; return view }
    func updateNSView(_ view: Host, context: Context) { view.opacity = opacity; view.apply() }
}

struct GlassCard: ViewModifier {
    @ObservedObject private var appearance = Appearance.shared
    func body(content: Content) -> some View {
        content.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(appearance.glass ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(appearance.glass ? 0.12 : 0.06)))
    }
}

extension View {
    func card() -> some View { modifier(GlassCard()) }
}

@MainActor final class NativeColorPanel: NSObject {
    static let shared = NativeColorPanel()
    func open() {
        let panel = NSColorPanel.shared
        panel.title = "颜色：色轮、光谱与数值"
        panel.color = NSColor(Appearance.shared.accent)
        panel.showsAlpha = false; panel.isContinuous = true; panel.mode = .wheel
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.level = .modalPanel; panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
    }
    @objc private func changed(_ sender: NSColorPanel) { Appearance.shared.setColor(sender.color) }
}
