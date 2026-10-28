import Foundation

/// A bounded local JSONL capture. The callbacks enqueue snapshots; only the writer queue touches the file.
final class InputTrace {
    private let url: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "tegi.input-trace")
    private let lock = NSLock()
    private var enabled: UUID?
    private var writerID: UUID?
    private var file: FileHandle?
    private var bytes = 0
    private var sequence = 0
    private var problem: String?

    init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "tegi/input-trace.jsonl"), limit: Int = 64 * 1024 * 1024) {
        self.url = url
        self.limit = limit
    }

    var isRecording: Bool { lock.withLock { enabled != nil } }

    func start() throws {
        try queue.sync {
            guard file == nil else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            do { bytes = Int(try handle.seekToEnd()) }
            catch { try? handle.close(); throw error }
            file = handle
            sequence = 0
            problem = nil
            writerID = UUID()
            lock.withLock { enabled = writerID }
            write(["kind": "header", "schema": 1, "run": writerID!.uuidString,
                   "arrival": ProcessInfo.processInfo.systemUptime,
                   "os": ProcessInfo.processInfo.operatingSystemVersionString,
                   "clocks": "arrival: system uptime seconds; touch: callback seconds; native: CGEvent nanoseconds"])
        }
    }

    func stop() {
        lock.withLock { enabled = nil }
        queue.sync { close() }
    }

    func delete() throws {
        stop()
        try queue.sync {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            bytes = 0
            problem = nil
        }
    }

    var status: [String: Any] {
        queue.sync {
            ["recording": file != nil, "path": url.path,
             "bytes": (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? bytes, "limit": limit,
             "problem": problem as Any? ?? NSNull()]
        }
    }

    func record(_ fields: [String: Any], arrival: Double = ProcessInfo.processInfo.systemUptime) {
        guard let id = lock.withLock({ enabled }) else { return }
        queue.async {
            // A callback racing stop/start belongs to its original recording, never the next one.
            guard self.writerID == id, self.file != nil else { return }
            var record = fields
            record["arrival"] = arrival
            self.write(record)
        }
    }

    private func write(_ fields: [String: Any]) {
        guard let file else { return }
        do {
            var record = fields
            record["sequence"] = sequence
            sequence += 1
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0a)
            guard data.count <= limit - bytes else {
                problem = "Capture reached its size limit; stop and delete it before recording again."
                close()
                return
            }
            try file.write(contentsOf: data)
            bytes += data.count
        } catch {
            problem = error.localizedDescription
            close()
        }
    }

    private func close() {
        lock.withLock { enabled = nil }
        do { try file?.synchronize() }
        catch { problem = error.localizedDescription }
        do { try file?.close() }
        catch { problem = error.localizedDescription }
        file = nil
        writerID = nil
    }
}
