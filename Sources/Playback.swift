import AppKit

@MainActor enum Playback {
    static func play(_ file: URL) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return "文件不存在，磁盘可能未连接。" }
        let preferred = UserDefaults.standard.string(forKey: "preferredPlayer") ?? "IINA"
        if preferred == "IINA" {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") else {
                return "尚未安装IINA。请从iina.io安装，或在设置中选择系统播放器。"
            }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else if !NSWorkspace.shared.open(file) { return "无法打开播放器，请先设置可用的播放应用。" }
        return nil
    }
}
