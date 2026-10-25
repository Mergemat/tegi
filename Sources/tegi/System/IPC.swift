import Foundation

enum IPC {
    static var path: String { (NSTemporaryDirectory() as NSString).appendingPathComponent("tegi.sock") }

    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    final class Server {
        private let fd: Int32
        private let out = DispatchQueue(label: "tegi.ipc.out")
        private var subscribers: [Int32] = []

        init?(handle: @escaping (String) -> String) {
            guard var addr = IPC.address() else { return nil }
            unlink(IPC.path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard fd >= 0, bound == 0, listen(fd, 8) == 0 else {
                close(fd)
                return nil
            }
            let fd = fd
            Thread.detachNewThread {
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    var on: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    let request = IPC.readLine(client)
                    let reply = DispatchQueue.main.sync { handle(request) }
                    IPC.write(client, reply + "\n")
                    if request == "event-stream" && !reply.hasPrefix("error") {
                        self.out.async { self.subscribers.append(client) }
                    } else {
                        close(client)
                    }
                }
            }
        }

        func broadcast(_ line: String) {
            out.async {
                self.subscribers.removeAll { c in
                    guard !IPC.write(c, line + "\n") else { return false }
                    close(c)
                    return true
                }
            }
        }

        func stop() {
            close(fd)
            unlink(IPC.path)
        }
    }

    static func send(_ request: String) -> String? {
        guard var addr = address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        write(fd, request + "\n")
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private static func readLine(_ fd: Int32) -> String {
        var out = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n"), out.count < 4096 { out.append(byte) }
        return String(decoding: out, as: UTF8.self)
    }

    @discardableResult
    private static func write(_ fd: Int32, _ s: String) -> Bool {
        var bytes = Array(s.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            bytes = bytes.dropFirst(n)
        }
        return true
    }

    static func stream(_ request: String) -> Bool {
        guard var addr = address() else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        write(fd, request + "\n")
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return true }
            FileHandle.standardOutput.write(Data(buf[0..<n]))
        }
    }
}
