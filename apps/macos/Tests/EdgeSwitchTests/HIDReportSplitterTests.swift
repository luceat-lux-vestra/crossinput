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
}
