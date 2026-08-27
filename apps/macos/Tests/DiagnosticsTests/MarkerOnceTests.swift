import XCTest
@testable import Diagnostics

final class MarkerOnceTests: XCTestCase {
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Diagnostics.logURL = dir.appendingPathComponent("diag.log")
        Diagnostics.resetIdentityMarkerForTesting()
    }

    func testMarkerAppearsExactlyOnceAcrossManyLogs() throws {
        for i in 0..<100 { Diagnostics.log("line \(i)") }
        Diagnostics.flushSync()
        let lines = readLines()
        let markers = lines.filter { $0.contains("candidate identity") }
        XCTAssertEqual(markers.count, 1, "marker must appear exactly once, got \(markers.count)")
        XCTAssertTrue(lines[0].contains("candidate identity"), "marker must be first line")
        XCTAssertEqual(lines.count, 101, "expected 1 marker + 100 ordinary lines, got \(lines.count)")
    }

    func testMarkerExactlyOnceUnderConcurrentFirstLog() throws {
        let group = DispatchGroup()
        let total = 20
        for task in 0..<total {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<10 {
                    Diagnostics.log("concurrent task=\(task) seq=\(i)")
                }
                group.leave()
            }
        }
        group.wait()
        Diagnostics.flushSync()
        let lines = readLines()
        let markers = lines.filter { $0.contains("candidate identity") }
        XCTAssertEqual(markers.count, 1,
                       "marker must appear exactly once under concurrency, got \(markers.count)")
        XCTAssertTrue(lines[0].contains("candidate identity"),
                      "marker must precede every ordinary line")
        XCTAssertEqual(lines.count, 1 + total * 10)
    }

    private func readLines() -> [String] {
        Diagnostics.flushSync()
        guard let url = Diagnostics.logURL as URL?,
              let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
