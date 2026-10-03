import XCTest
@testable import InputCapture

@available(macOS 15.0, *)
final class CoreHIDTapSurfaceDiagnosticsTests: XCTestCase {
    func testAggregateMetadataDistinguishesMissingLiftSurface() {
        var diagnostics = CoreHIDTapSurfaceDiagnostics()

        diagnostics.observeReport(
            contactPresent: true,
            contactTransition: true
        )
        diagnostics.observeReport(
            contactPresent: true,
            contactTransition: false
        )

        XCTAssertEqual(diagnostics.reports, 2)
        XCTAssertEqual(diagnostics.contactPresentReports, 2)
        XCTAssertEqual(diagnostics.zeroContactReports, 0)
        XCTAssertEqual(diagnostics.contactTransitions, 1)
        XCTAssertEqual(diagnostics.tapDecisions, 0)
        XCTAssertEqual(diagnostics.semanticButtonEvents, 0)
    }

    func testAggregateMetadataRecordsLiftDecisionAndSemanticButtonPair() {
        var diagnostics = CoreHIDTapSurfaceDiagnostics()

        diagnostics.observeReport(
            contactPresent: true,
            contactTransition: true
        )
        diagnostics.observeReport(
            contactPresent: false,
            contactTransition: true
        )
        diagnostics.observeTapDecision()
        diagnostics.observeSemanticButton()
        diagnostics.observeSemanticButton()

        XCTAssertEqual(diagnostics.reports, 2)
        XCTAssertEqual(diagnostics.contactPresentReports, 1)
        XCTAssertEqual(diagnostics.zeroContactReports, 1)
        XCTAssertEqual(diagnostics.contactTransitions, 2)
        XCTAssertEqual(diagnostics.tapDecisions, 1)
        XCTAssertEqual(diagnostics.semanticButtonEvents, 2)
        XCTAssertTrue(
            diagnostics.summary.contains("zeroContactReports=1")
        )
        XCTAssertTrue(
            diagnostics.summary.contains("tapDecisions=1")
        )
        XCTAssertTrue(
            diagnostics.summary.contains("semanticButtons=2")
        )
    }
}
