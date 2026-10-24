import Foundation
import Darwin

actor MetadataRequestGate {
    static let shared = MetadataRequestGate(limit: 2)
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = max(1, limit) }
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum ProcessHygiene {
    /// Remove only metadata probes whose owning app process has already exited.
    static func terminateStaleMetadataProbes(bundlePath: String) -> Int {
        let tool = bundlePath + "/Contents/Resources/Tools/yt-dlp"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command=", "-ww"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let current = ProcessInfo.processInfo.processIdentifier
        var terminated = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = pid_t(fields[0]), Int(fields[1]) == 1,
                  pid != current else { continue }
            let command = String(fields[2])
            guard command.contains(tool), command.contains("--skip-download") else { continue }
            if kill(pid, SIGTERM) == 0 { terminated += 1 }
        }
        return terminated
    }
}
