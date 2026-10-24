import SwiftUI
import Darwin
import IOKit
import Metal
import CoreGraphics

struct HardwareSample {
    var date = Date()
    var cpu: Double?
    var gpu: Double?
    var memory: UInt64 = 0
    var appMemory: UInt64 = 0
    var diskRead: Double?
    var diskWrite: Double?
    var networkDown: Double?
    var networkUp: Double?
    var capacity: UInt64 = 0
    var free: UInt64 = 0
    var cpuFrequency: UInt64 = 0
    var gpuCores: Int?
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "未提供" }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    static func rate(_ value: Double?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file) + "/秒" } ?? "采样中" }
    static func frequency(_ mhz: Double?) -> String {
        guard let mhz, mhz > 0 else { return "待授权" }
        return mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }
}

struct ProcessorSpec {
    let name: String
    let year: String
    let cpu: String
    let gpu: String
}

enum ProcessorCatalog {
    static let all: [ProcessorSpec] = [
        .init(name: "Apple M6", year: "2026", cpu: "12核", gpu: "12核"),
        .init(name: "Apple M5 Ultra", year: "2026", cpu: "36核", gpu: "80核"),
        .init(name: "Apple M5 Max", year: "2026", cpu: "18核", gpu: "40核"),
        .init(name: "Apple M5 Pro", year: "2026", cpu: "12–18核", gpu: "12–20核"),
        .init(name: "Apple M5", year: "2025", cpu: "10核", gpu: "10核"),
        .init(name: "Apple M4 Ultra", year: "待官方核实", cpu: "待核实", gpu: "待核实"),
        .init(name: "Apple M4 Max", year: "2024", cpu: "14/16核", gpu: "32/40核"),
        .init(name: "Apple M4 Pro", year: "2024", cpu: "12/14核", gpu: "16/20核"),
        .init(name: "Apple M4", year: "2024", cpu: "10核", gpu: "10核"),
        .init(name: "Apple M3 Ultra", year: "2025", cpu: "28/32核", gpu: "60/80核"),
        .init(name: "Apple M3 Max", year: "2023", cpu: "14/16核", gpu: "30/40核"),
        .init(name: "Apple M3 Pro", year: "2023", cpu: "11/12核", gpu: "14/18核"),
        .init(name: "Apple M3", year: "2023", cpu: "8核", gpu: "8/10核"),
        .init(name: "Apple M2 Ultra", year: "2023", cpu: "24核", gpu: "60/76核"),
        .init(name: "Apple M2 Max", year: "2023", cpu: "12核", gpu: "30/38核"),
        .init(name: "Apple M2 Pro", year: "2023", cpu: "10/12核", gpu: "16/19核"),
        .init(name: "Apple M2", year: "2022", cpu: "8核", gpu: "8/10核"),
        .init(name: "Apple M1 Ultra", year: "2022", cpu: "20核", gpu: "48/64核"),
        .init(name: "Apple M1 Max", year: "2021", cpu: "10核", gpu: "24/32核"),
        .init(name: "Apple M1 Pro", year: "2021", cpu: "8/10核", gpu: "14/16核"),
        .init(name: "Apple M1", year: "2020", cpu: "8核", gpu: "7/8核"),
        .init(name: "Apple A18 Pro", year: "2024", cpu: "6核", gpu: "6核"),
        .init(name: "Apple A18", year: "2024", cpu: "6核", gpu: "5核"),
        .init(name: "Apple A17 Pro", year: "2023", cpu: "6核", gpu: "6核"),
        .init(name: "Apple A16 Bionic", year: "2022", cpu: "6核", gpu: "5核"),
        .init(name: "Intel Xeon W", year: "2019–2020", cpu: "8–28核", gpu: "Radeon Pro"),
        .init(name: "Intel Core i9", year: "2018–2020", cpu: "6–10核", gpu: "UHD/独显"),
        .init(name: "Intel Core i7", year: "2017–2020", cpu: "4–8核", gpu: "UHD/独显"),
        .init(name: "Intel Core i5", year: "2017–2020", cpu: "4–6核", gpu: "UHD/独显"),
        .init(name: "Intel Core i3", year: "2018–2020", cpu: "4核", gpu: "UHD")
    ]
    private static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "(r)", with: "").replacingOccurrences(of: "(tm)", with: "")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
    static func match(_ chip: String) -> ProcessorSpec? {
        let value = normalized(chip)
        return all.filter {
            let name = normalized($0.name)
            return value == name || value.hasPrefix(name + " ") || value.hasPrefix(name + "-")
        }
            .max { normalized($0.name).count < normalized($1.name).count }
    }
}

struct FixedFrequencies {
    var performance: Double?
    var efficiency: Double?
    var gpu: Double?
    var cpuLabel: String {
        let values = [performance.map { String(format: "P %.2f GHz", $0) }, efficiency.map { String(format: "E %.2f GHz", $0) }].compactMap { $0 }
        return values.isEmpty ? "系统未提供" : values.joined(separator: " / ")
    }
    var gpuLabel: String { gpu.map { String(format: "%.2f GHz", $0) } ?? "系统未提供" }
}

enum FixedFrequencyReader {
    static let current = read()
    private static func frequencies(_ hex: String) -> [Double] {
        guard let data = Data(hexString: hex) else { return [] }
        var values: [Double] = []
        var offset = 0
        while offset + 8 <= data.count {
            let raw = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { value, pair in
                value | UInt32(pair.element) << UInt32(pair.offset * 8)
            }
            let hz = Double(raw)
            if hz >= 100_000_000, hz <= 6_000_000_000 { values.append(hz) }
            offset += 8
        }
        return values
    }
    private static func read() -> FixedFrequencies {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-w0", "-p", "IODeviceTree"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return FixedFrequencies() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        func property(_ key: String, limit: Double) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: "\"\(key)\" = <([0-9a-fA-F]+)>"),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return frequencies(String(text[range])).filter { $0 <= limit }.max().map { $0 / 1_000_000_000 }
        }
        return FixedFrequencies(performance: property("voltage-states5-sram", limit: 6_000_000_000),
                                efficiency: property("voltage-states1-sram", limit: 4_000_000_000),
                                gpu: property("perf-states", limit: 2_000_000_000))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let value = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(value); index = next
        }
        self = Data(bytes)
    }
}

/// A single, read-only sampler shared by every window. No privileged helper or shell polling.
final class HardwareSampler {
    private var priorCPU: (UInt64, UInt64)?
    private var priorDisk: (UInt64, UInt64, TimeInterval)?
    private var priorNetwork: (UInt64, UInt64, TimeInterval)?
    private func properties(_ className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let entry = IOIteratorNext(iterator); if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var raw: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = raw?.takeRetainedValue() as? [String: Any] { result.append(dictionary) }
        }
        return result
    }
    static func text(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "待识别" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "待识别" }
        return String(cString: buffer)
    }
    static func integer(_ name: String) -> Int? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
    private func networkBytes() -> (UInt64, UInt64) {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return (0, 0) }
        defer { freeifaddrs(interfaces) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let raw = item.ifa_data,
                  String(cString: item.ifa_name).hasPrefix("en") else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }
    func read(folder: URL) -> HardwareSample {
        var sample = HardwareSample()
        var cpu = host_cpu_load_info(), cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = cpu.cpu_ticks
            let total = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.2) + UInt64(ticks.3)
            let idle = UInt64(ticks.2)
            if let previous = priorCPU, total > previous.0, idle >= previous.1 {
                sample.cpu = min(100, max(0, 100 * (1 - Double(idle - previous.1) / Double(total - previous.0))))
            }
            priorCPU = (total, idle)
        }
        var vm = vm_statistics64(), vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmResult == KERN_SUCCESS {
            let used = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            sample.memory = min(ProcessInfo.processInfo.physicalMemory, (used - min(used, UInt64(vm.purgeable_count))) * UInt64(vm_kernel_page_size))
        }
        var task = mach_task_basic_info(), taskCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let taskResult = withUnsafeMutablePointer(to: &task) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(taskCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskCount) }
        }
        if taskResult == KERN_SUCCESS { sample.appMemory = task.resident_size }
        let gpus = properties("IOAccelerator")
        let utilization = gpus.compactMap { ($0["PerformanceStatistics"] as? [String: Any])?["Device Utilization %"] as? NSNumber }.map(\.doubleValue)
        sample.gpu = utilization.max().map { min(100, max(0, $0)) }
        sample.gpuCores = (gpus.first?["gpu-core-count"] as? NSNumber)?.intValue
        let disks = properties("IOBlockStorageDriver").compactMap { $0["Statistics"] as? [String: Any] }
        let reads = disks.compactMap { ($0["Bytes (Read)"] as? NSNumber)?.uint64Value }.reduce(0, +)
        let writes = disks.compactMap { ($0["Bytes (Write)"] as? NSNumber)?.uint64Value }.reduce(0, +)
        let now = ProcessInfo.processInfo.systemUptime
        if !disks.isEmpty {
            if let previous = priorDisk, now > previous.2, reads >= previous.0, writes >= previous.1 {
                sample.diskRead = Double(reads - previous.0) / (now - previous.2)
                sample.diskWrite = Double(writes - previous.1) / (now - previous.2)
            }
            priorDisk = (reads, writes, now)
        }
        let (received, sent) = networkBytes()
        if let previous = priorNetwork, now > previous.2, received >= previous.0, sent >= previous.1 {
            sample.networkDown = Double(received - previous.0) / (now - previous.2)
            sample.networkUp = Double(sent - previous.1) / (now - previous.2)
        }
        priorNetwork = (received, sent, now)
        if let storage = try? FileManager.default.attributesOfFileSystem(forPath: folder.path) {
            sample.capacity = (storage[.systemSize] as? NSNumber)?.uint64Value ?? 0
            sample.free = (storage[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        }
        var frequency: UInt64 = 0, frequencySize = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.cpufrequency", &frequency, &frequencySize, nil, 0) == 0 { sample.cpuFrequency = frequency }
        return sample
    }
}

@MainActor final class HardwareMonitor: ObservableObject {
    static let shared = HardwareMonitor()
    @Published private(set) var sample = HardwareSample()
    @Published private(set) var history: [HardwareSample] = []
    let chip = HardwareSampler.text("machdep.cpu.brand_string")
    let model = HardwareSampler.text("hw.model")
    let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "待识别"
    var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    private var observers = 0
    private var task: Task<Void, Never>?
    var modelYear: String { ["Mac15,12": "2024", "Mac15,13": "2024"][model] ?? "待识别" }
    var matchedChip: ProcessorSpec? { ProcessorCatalog.match(chip) }
    var recommendedEpisodeCount: Int {
        DownloadTuning.recommendedEpisodes(chip: chip, physicalCores: ProcessInfo.processInfo.processorCount, cpuLoad: sample.cpu)
    }
    var fixedFrequencies: FixedFrequencies { FixedFrequencyReader.current }
    var performanceCores: Int? { HardwareSampler.integer("hw.perflevel0.physicalcpu") }
    var efficiencyCores: Int? { HardwareSampler.integer("hw.perflevel1.physicalcpu") }
    var mainScreenLabel: String {
        let id = CGMainDisplayID()
        let width = CGDisplayPixelsWide(id), height = CGDisplayPixelsHigh(id)
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return "\(width)×\(height)" + (hz > 0 ? String(format: "@%.0fHz", hz) : "")
    }
    func start() {
        observers += 1; guard task == nil else { return }
        let sampler = HardwareSampler()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let target = self.folder
                let next = await Task.detached(priority: .utility) { autoreleasepool { sampler.read(folder: target) } }.value
                guard !Task.isCancelled else { break }
                self.sample = next; self.history.append(next)
                if self.history.count > 60 { self.history.removeFirst(self.history.count - 60) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func stop() { observers = max(0, observers - 1); if observers == 0 { task?.cancel(); task = nil } }
}

struct HardwareFooter: View {
    let folder: URL
    @ObservedObject private var monitor = HardwareMonitor.shared
    @State private var expanded = false
    @AppStorage("showPiliMainDisplay") private var showMainDisplay = false
    @AppStorage("showPiliFixedFrequency") private var showFixedFrequency = false
    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .trailing, spacing: 3) {
                Text("CPU型号 \(monitor.chip) · GPU型号 \(monitor.gpuName) · \(monitor.modelYear == "待识别" ? monitor.model : monitor.modelYear) · 版本 \(SupportActions.version)")
                Text(footerLine)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }.font(.caption2).foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).help("点击查看硬件与实时性能")
        .popover(isPresented: $expanded, arrowEdge: .top) {
            HardwareDashboard(monitor: monitor, showMainDisplay: $showMainDisplay, showFixedFrequency: $showFixedFrequency)
        }
        .onAppear { monitor.folder = folder; monitor.start() }
        .onChange(of: folder) { monitor.folder = $0 }
        .onDisappear { monitor.stop() }
    }
    private var footerLine: String {
        var parts: [String] = []
        if showMainDisplay { parts.append("主屏 \(monitor.mainScreenLabel)") }
        if showFixedFrequency { parts.append("固定频率 \(monitor.fixedFrequencies.cpuLabel) / GPU \(monitor.fixedFrequencies.gpuLabel)") }
        parts.append("↓ \(HardwareSample.rate(monitor.sample.networkDown))")
        parts.append("↑ \(HardwareSample.rate(monitor.sample.networkUp))")
        parts.append("CPU \(HardwareSample.percent(monitor.sample.cpu))")
        parts.append("GPU \(HardwareSample.percent(monitor.sample.gpu))")
        return parts.joined(separator: " · ")
    }
}

struct HardwareDashboard: View {
    @ObservedObject var monitor: HardwareMonitor
    @Binding var showMainDisplay: Bool
    @Binding var showFixedFrequency: Bool
    private var s: HardwareSample { monitor.sample }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "waveform.path.ecg").foregroundStyle(Color.accentColor); Text("设备与实时性能").font(.title3.bold()); Spacer(); Text("每2秒更新").font(.caption).foregroundStyle(.secondary) }
            Text("\(monitor.chip) · \(monitor.model) · 机型年份：\(monitor.modelYear)\(monitor.matchedChip.map { " · \($0.cpu) CPU / \($0.gpu) GPU" } ?? "")").font(.callout)
            Text("\(ProcessInfo.processInfo.operatingSystemVersionString) · 版本 \(SupportActions.version)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                graph("CPU", value: HardwareSample.percent(s.cpu), values: monitor.history.map(\.cpu), color: .cyan)
                graph("GPU", value: HardwareSample.percent(s.gpu), values: monitor.history.map(\.gpu), color: .purple)
            }
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                row("处理器", "\(ProcessInfo.processInfo.processorCount) 核心" + (monitor.performanceCores.map { " · \($0)P" } ?? "") + (monitor.efficiencyCores.map { "+\($0)E" } ?? ""))
                row("图形处理器", monitor.gpuName + (s.gpuCores.map { " · \($0) 核心" } ?? ""))
                row("主屏", monitor.mainScreenLabel)
                row("固定最高频率", "CPU \(monitor.fixedFrequencies.cpuLabel) / GPU \(monitor.fixedFrequencies.gpuLabel)")
                row("系统内存（估算）", "\(HardwareSample.bytes(s.memory)) / \(HardwareSample.bytes(ProcessInfo.processInfo.physicalMemory))")
                row("本应用驻留内存", HardwareSample.bytes(s.appMemory))
                row("保存卷可用／总容量", "\(HardwareSample.bytes(s.free)) / \(HardwareSample.bytes(s.capacity))")
                row("网络下载速率", HardwareSample.rate(s.networkDown))
                row("网络上传速率", HardwareSample.rate(s.networkUp))
                row("磁盘读取／写入", "\(HardwareSample.rate(s.diskRead)) / \(HardwareSample.rate(s.diskWrite))")
            }.font(.callout).monospacedDigit()
            HStack {
                Toggle("右下角显示主屏参数", isOn: $showMainDisplay)
                Toggle("右下角显示固定频率", isOn: $showFixedFrequency)
            }
            DisclosureGroup("处理器识别表（\(ProcessorCatalog.all.count) 款）") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(ProcessorCatalog.all.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.year) · CPU \(item.cpu) · GPU \(item.gpu)")
                                .font(.caption).foregroundStyle(item.name == monitor.matchedChip?.name ? .primary : .secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }.font(.caption)
            HStack(spacing: 16) {
                graph("读取", value: HardwareSample.rate(s.diskRead), values: monitor.history.map(\.diskRead), color: .green, normalized: false)
                graph("写入", value: HardwareSample.rate(s.diskWrite), values: monitor.history.map(\.diskWrite), color: .orange, normalized: false)
            }
            Text("CPU 为全机平均负载；GPU 为可读取设备的最高负载；磁盘为系统块设备合计（含虚拟设备），不是测速。内存按活动、联动及压缩页估算，与活动监视器口径可能不同。年份仅显示已核对机型的推出年份，非生产日期。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 560)
    }
    private func row(_ name: String, _ value: String) -> some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
    private func graph(_ name: String, value: String, values: [Double?], color: Color, normalized: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(name).font(.caption); Spacer(); Text(value).font(.caption.bold()).monospacedDigit() }
            Canvas { context, size in
                let ceiling = normalized ? 100 : max(1, values.compactMap { $0 }.max() ?? 1)
                var line = Path(); var connected = false
                for (i, value) in values.enumerated() {
                    guard let value else { connected = false; continue }
                    let point = CGPoint(x: CGFloat(i) / 59 * size.width, y: size.height * (1 - min(1, max(0, value / ceiling))))
                    if connected { line.addLine(to: point) } else { line.move(to: point); connected = true }
                }
                context.stroke(line, with: .color(color), lineWidth: 1.8)
            }.frame(height: 42).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity)
    }
}
