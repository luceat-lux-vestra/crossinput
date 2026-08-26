import XCTest
@testable import Diagnostics

final class MarkerOnceTests: XCTestCase {
    func testMarkerAppearsExactlyOnceAcrossManyLogs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logFile = dir.appendingPathComponent("diag.log")
        Diagnostics.logURL = logFile
        Diagnostics.resetIdentityMarkerForTesting()
        for i in 0..<100 { Diagnostics.log("line \(i)") }
        Diagnostics.flushSync()
        let data = try Data(contentsOf: logFile)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let markers = lines.filter { $0.contains("candidate identity") }
        XCTAssertEqual(markers.count, 1, "marker must appear exactly once, got \(markers.count)")
        XCTAssertTrue(lines[0].contains("candidate identity"), "marker must be first line")
        XCTAssertEqual(lines.count, 101, "expected 1 marker + 100 ordinary lines, got \(lines.count)")
        try? FileManager.default.removeItem(at: dir)
    }
}
