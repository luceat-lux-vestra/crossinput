import XCTest
@testable import Diagnostics

final class DiagnosticsTests: XCTestCase {

    private var tempDir: URL!
    private var logFile: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logFile = tempDir.appendingPathComponent("diag.log")
        Diagnostics.logURL = logFile
    }

    override func tearDownWithError() throws {
        Diagnostics.flushSync()
        try? FileManager.default.removeItem(at: tempDir)
        Diagnostics.logURL = {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Ampersand")
            return dir.appendingPathComponent("diag.log")
        }()
    }

    private func readLines() -> [String] {
        Diagnostics.flushSync()
        guard let data = try? Data(contentsOf: logFile) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testConcurrentLogAndFlushLoseNoLines() throws {
        // 20 concurrent tasks, each logging 50 lines with distinct markers,
        // while other tasks flush concurrently. Every line must survive once.
        let group = DispatchGroup()
        for task in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<50 {
                    Diagnostics.log("task=\(task) seq=\(i)")
                    if i.isMultiple(of: 10) { Diagnostics.flush() }
                }
                Diagnostics.flush()
                group.leave()
            }
        }
        group.wait()

        let lines = readLines()
        // Lines carry a timestamp prefix; extract the marker after the first space.
        let markers = lines.map { line in
            String(line.split(separator: " ", maxSplits: 1).last ?? Substring(line))
        }
        var counts: [String: Int] = [:]
        for marker in markers {
            counts[marker, default: 0] += 1
        }
        for task in 0..<20 {
            for i in 0..<50 {
                let marker = "task=\(task) seq=\(i)"
                XCTAssertEqual(counts[marker], 1, "missing or duplicated \(marker)")
            }
        }
    }

    func testEachLineIsWrittenIntact() throws {
        let message = "line with timestamp prefix <a> b</a> #37 root-cause"
        Diagnostics.log(message)
        Diagnostics.flushSync()
        let lines = readLines()
        // Line 1 is the one-time candidate-identity marker (ADR-0012);
        // line 2 must be the logged message itself, intact.
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("candidate identity"),
                      "identity marker expected first: \(lines[0])")
        XCTAssertTrue(lines[1].hasSuffix(message), "line content must survive intact: \(lines[1])")
        XCTAssertTrue(lines[1].hasPrefix("HH:") || lines[1].contains(":"), "timestamp prefix expected")
    }
}
