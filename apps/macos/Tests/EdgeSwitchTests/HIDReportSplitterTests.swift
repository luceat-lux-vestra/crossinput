import XCTest
@testable import EdgeSwitch

final class HIDReportSplitterTests: XCTestCase {

    // MARK: - Splitting beyond the report limit

    func testSplitsPositiveDeltaAboveLimit() {
        let result = HIDReportSplitter.normalizeForHID(dx: 300, dy: 0)
        XCTAssertEqual(result.reports.map(\.dx), [127, 127, 46])
        XCTAssertEqual(result.reports.map(\.dy), [0, 0, 0])
        XCTAssertEqual(result.deliveredDx, 300)
        XCTAssertEqual(result.deliveredDy, 0)
    }

    func testSplitsNegativeDeltaBelowMinusLimit() {
        let result = HIDReportSplitter.normalizeForHID(dx: -300, dy: 0)
        XCTAssertEqual(result.reports.map(\.dx), [-127, -127, -46])
        XCTAssertEqual(result.deliveredDx, -300)
    }

    func testDeliveredSumEqualsRawInput() {
        let raw: [(dx: Int32, dy: Int32)] = [(300, -250), (-5, 5), (127, 128)]
        for pair in raw {
            let result = HIDReportSplitter.normalizeForHID(dx: pair.dx, dy: pair.dy)
            let sumX = result.reports.reduce(Int32(0)) { $0 + Int32($1.dx) }
            let sumY = result.reports.reduce(Int32(0)) { $0 + Int32($1.dy) }
            XCTAssertEqual(sumX, pair.dx)
            XCTAssertEqual(sumY, pair.dy)
            XCTAssertEqual(result.deliveredDx, pair.dx)
            XCTAssertEqual(result.deliveredDy, pair.dy)
        }
    }

    func testNoZeroZeroReportEmitted() {
        let result = HIDReportSplitter.normalizeForHID(dx: 0, dy: 300)
        for report in result.reports {
            XCTAssertFalse(report.dx == 0 && report.dy == 0)
        }
        XCTAssertEqual(result.reports.map(\.dx), [0, 0, 0])
        XCTAssertEqual(result.reports.map(\.dy), [127, 127, 46])
    }

    // MARK: - Boundary values

    func testBoundaryValues() {
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 127, dy: 0).reports.map(\.dx), [127])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 128, dy: 0).reports.map(\.dx), [127, 1])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: -128, dy: 0).reports.map(\.dx), [-127, -1])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 254, dy: 0).reports.map(\.dx), [127, 127])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 255, dy: 0).reports.map(\.dx), [127, 127, 1])
    }

    func testZeroMovementProducesNoReports() {
        let result = HIDReportSplitter.normalizeForHID(dx: 0, dy: 0)
        XCTAssertTrue(result.reports.isEmpty)
        XCTAssertEqual(result.deliveredDx, 0)
        XCTAssertEqual(result.deliveredDy, 0)
    }

    func testMixedAxesChunkAlignment() {
        let result = HIDReportSplitter.normalizeForHID(dx: 300, dy: 300)
        XCTAssertEqual(result.reports.count, 3)
        XCTAssertEqual(result.reports.map(\.dx), [127, 127, 46])
        XCTAssertEqual(result.reports.map(\.dy), [127, 127, 46])
    }

    func testSingleAxisExceedingOtherAlignedToZero() {
        let result = HIDReportSplitter.normalizeForHID(dx: 200, dy: 3)
        XCTAssertEqual(result.reports.count, 2)
        XCTAssertEqual(result.reports.map(\.dx), [127, 73])
        XCTAssertEqual(result.reports.map(\.dy), [3, 0])
    }

    // MARK: - Extreme values never trap (Int32.min/max)

    func testInt32MaxDoesNotTrap() {
        // abs(Int32.min/max) would overflow in Int32; Int64 promotion avoids it.
        let result = HIDReportSplitter.normalizeForHID(dx: Int32.max, dy: 0)
        XCTAssertEqual(result.reports.count, HIDReportSplitter.maxReportsPerEvent)
        XCTAssertEqual(result.reports.first, HIDRelativeReport(dx: 127, dy: 0))
        XCTAssertEqual(result.deliveredDx, 1024 * 127)
        // Every report is within the descriptor range.
        for report in result.reports {
            XCTAssertTrue(report.dx >= -127 && report.dx <= 127)
            XCTAssertEqual(report.dy, 0)
        }
    }

    func testInt32MinDoesNotTrap() {
        let result = HIDReportSplitter.normalizeForHID(dx: Int32.min, dy: 0)
        XCTAssertEqual(result.reports.count, HIDReportSplitter.maxReportsPerEvent)
        XCTAssertEqual(result.reports.first, HIDRelativeReport(dx: -127, dy: 0))
        XCTAssertEqual(result.deliveredDx, -1024 * 127)
    }

    func testExtremeValuesAcrossBothAxes() {
        let result = HIDReportSplitter.normalizeForHID(dx: Int32.max, dy: Int32.min)
        XCTAssertEqual(result.reports.count, HIDReportSplitter.maxReportsPerEvent)
        let sumX = result.reports.reduce(Int64(0)) { $0 + Int64($1.dx) }
        let sumY = result.reports.reduce(Int64(0)) { $0 + Int64($1.dy) }
        XCTAssertEqual(Int64(result.deliveredDx), sumX, "delivered must equal emitted reports sum")
        XCTAssertEqual(Int64(result.deliveredDy), sumY)
        XCTAssertEqual(result.deliveredDx, 1024 * 127)
        XCTAssertEqual(result.deliveredDy, -1024 * 127)
    }

    func testSmallNegativeBoundaryValues() {
        let cases: [Int32] = [-128, -127, 0, 127, 128]
        for value in cases {
            let result = HIDReportSplitter.normalizeForHID(dx: value, dy: 0)
            let sumX = result.reports.reduce(Int64(0)) { $0 + Int64($1.dx) }
            XCTAssertEqual(Int64(result.deliveredDx), sumX, "dx=\(value)")
        }
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: -128, dy: 0).reports.map(\.dx), [-127, -1])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: -127, dy: 0).reports.map(\.dx), [-127])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 127, dy: 0).reports.map(\.dx), [127])
        XCTAssertEqual(HIDReportSplitter.normalizeForHID(dx: 128, dy: 0).reports.map(\.dx), [127, 1])
    }

    func testDeliveredMatchesEmittedSumWhenCapped() {
        // A huge dy with ordinary dx: cap bounds total reports, delivered reflects
        // only the emitted reports (never raw).
        let result = HIDReportSplitter.normalizeForHID(dx: 10, dy: Int32.max)
        XCTAssertEqual(result.reports.count, HIDReportSplitter.maxReportsPerEvent)
        let sumX = result.reports.reduce(Int64(0)) { $0 + Int64($1.dx) }
        let sumY = result.reports.reduce(Int64(0)) { $0 + Int64($1.dy) }
        XCTAssertEqual(Int64(result.deliveredDx), sumX)
        XCTAssertEqual(Int64(result.deliveredDy), sumY)
    }
}
