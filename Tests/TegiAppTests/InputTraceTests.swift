import Foundation
import Testing
@testable import tegi

private func captureURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "tegi-trace-\(UUID().uuidString)/input.jsonl")
}

private func records(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@Test func stoppingATraceFlushesItsEventsAndStartingAgainPreservesThePreviousCapture() throws {
    let url = captureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let trace = InputTrace(url: url)
    trace.record(["kind": "off"])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try trace.start()
    trace.record(["kind": "touch", "number": 1])
    trace.record(["kind": "scroll", "phase": 1])
    trace.stop()
    trace.record(["kind": "off"])
    #expect(try records(at: url).compactMap { $0["kind"] as? String } == ["header", "touch", "scroll"])
    try trace.start()
    trace.record(["kind": "touch", "number": 2])
    trace.stop()
    #expect(try records(at: url).compactMap { $0["kind"] as? String } == ["header", "touch", "scroll", "header", "touch"])
    try trace.delete()
    #expect(!trace.isRecording)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aTraceStopsAtItsSizeLimitAndReportsWhy() throws {
    let url = captureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let trace = InputTrace(url: url, limit: 2048)
    try trace.start()
    trace.record(["kind": "oversized", "data": String(repeating: "x", count: 3000)])
    let status = trace.status
    #expect(status["recording"] as? Bool == false)
    #expect(status["problem"] is String)
    #expect(try Data(contentsOf: url).count <= 2048)
    try trace.delete()
    try trace.start()
    #expect(trace.isRecording)
    trace.stop()
}
