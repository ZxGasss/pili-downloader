import Foundation
import Darwin

/// Never accumulates an unbounded HTTP body, even if a poster URL serves the wrong resource.
final class BoundedImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var session: URLSession?
    private var buffer = Data()
    private var finished = false
    static func fetch(_ request: URLRequest) async -> Data? {
        let worker = BoundedImageDownload()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { worker.start(request, continuation: $0) }
        } onCancel: { worker.finish(nil) }
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        lock.unlock()
        session.dataTask(with: request).resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= MemoryBudget.imageBytes else {
            completionHandler(.cancel); finish(nil); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = buffer.count + data.count > MemoryBudget.imageBytes
        if !finished && !overflow { buffer.append(data) }
        lock.unlock()
        if overflow { finish(nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = error == nil ? buffer : nil; lock.unlock()
        finish(data)
    }
    private func finish(_ data: Data?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; buffer = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(returning: data)
    }
}

enum LocalThumbnailWorker {
    /// Decode outside the GUI process. One worker, one thread, bounded output and wall time.
    static func jpeg(file: URL, executable: URL) -> Data? {
        autoreleasepool {
            let executable = executable.deletingLastPathComponent().appendingPathComponent("PiliThumbnail")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = [file.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let started = Date()
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            timer.setEventHandler {
                guard process.isRunning else { return }
                var usage = proc_taskinfo()
                let size = MemoryLayout<proc_taskinfo>.size
                let count = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &usage, Int32(size))
                if Date().timeIntervalSince(started) > 10 || (count == size && usage.pti_resident_size > 256 * 1024 * 1024) {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            timer.resume()
            defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
            var output = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 32768), !chunk.isEmpty {
                if output.count + chunk.count > 1024 * 1024 { kill(process.processIdentifier, SIGKILL); break }
                output.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !output.isEmpty, output.count <= 1024 * 1024 else { return nil }
            return output
        }
    }
}
