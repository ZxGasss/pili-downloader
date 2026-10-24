import Foundation
import Darwin

enum DownloadTuning {
    // Network concurrency is bounded independently of the number of CPU cores.
    static func automaticConnections(cores: Int) -> Int { min(MemoryBudget.connections, max(2, cores)) }
    static var activeCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var automatic: Int { automaticConnections(cores: activeCores) }
    static func connections(_ selection: Int) -> Int { selection == 0 ? automatic : min(MemoryBudget.connections, max(1, selection)) }
    static func recommendedEpisodes(chip: String, physicalCores: Int, cpuLoad: Double? = nil) -> Int {
        let name = chip.lowercased()
        let base: Int
        let variant: Int
        if name.contains("apple") {
            switch true {
            case name.contains("m6"): base = 20
            case name.contains("m5"): base = 16
            case name.contains("m4"): base = 12
            case name.contains("m3"): base = 10
            case name.contains("m2"): base = 8
            case name.contains("m1"): base = 6
            case name.contains("a18"): base = 4
            default: base = 4
            }
            variant = name.contains("ultra") ? 6 : name.contains("max") ? 4 : name.contains("pro") ? 2 : 0
        } else if name.contains("xeon") {
            base = 6; variant = 0
        } else if name.contains("i9") {
            base = 6; variant = 0
        } else if name.contains("i7") {
            base = 5; variant = 0
        } else if name.contains("i5") {
            base = 4; variant = 0
        } else {
            base = physicalCores >= 12 ? 6 : physicalCores >= 8 ? 4 : 3
            variant = 0
        }
        let hardwareBase = min(20, max(2, base + variant))
        guard let cpuLoad, cpuLoad.isFinite else { return hardwareBase }
        switch cpuLoad {
        case ..<35: return min(20, hardwareBase + 2)
        case ..<55: return min(20, hardwareBase + 1)
        case ..<70: return hardwareBase
        case ..<85: return max(3, hardwareBase - 2)
        default: return max(2, hardwareBase - 4)
        }
    }
    static func recommendedEpisodeCount(cpuLoad: Double? = nil) -> Int {
        var size = 0
        let chip: String
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            chip = sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : ""
        } else { chip = "" }
        return recommendedEpisodes(chip: chip, physicalCores: ProcessInfo.processInfo.processorCount, cpuLoad: cpuLoad)
    }
    static func arguments(selection: Int, tools: URL) -> [String] {
        let count = connections(selection)
        guard count > 1 else { return ["--concurrent-fragments", "1"] }
        return ["--downloader", "http,https:" + tools.appendingPathComponent("aria2c").path,
                "--downloader-args", "aria2c:-x\(count) -s\(count) -j1 -k1M --summary-interval=1 --show-console-readout=true --human-readable=false --enable-color=false --max-tries=3 --retry-wait=1 --connect-timeout=10 --timeout=20",
                "--concurrent-fragments", String(count)]
    }
}
