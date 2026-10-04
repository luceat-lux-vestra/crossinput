import Foundation
import XCTest
@testable import InputCapture

#if canImport(CoreHID)
@available(macOS 15.0, *)
final class CoreHIDPointerOwnershipProcessTests: XCTestCase {
    private static let preparedPrintf =
        "printf '\\006\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000'"
    private static let readyPrintf =
        "printf '\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000'"
    private static let awaitActivation =
        "dd bs=1 count=1 of=/dev/null 2>/dev/null"

    func testParentEOFBeforeActivationNeverCommitsSeizure() async throws {
        let process = makeProcess(
            shell: Self.preparedPrintf + "; " + Self.awaitActivation
        )

        try process.start()
        try await process.awaitPrepared(timeout: .seconds(1))
        XCTAssertFalse(process.seizureMayHaveOccurred)

        let evidence = process.stopAndWait(
            gracefulTimeout: 1,
            forcedTimeout: 1
        )

        XCTAssertTrue(evidence.processExited)
        XCTAssertFalse(evidence.forced)
        XCTAssertFalse(process.seizureMayHaveOccurred)
        XCTAssertFalse(process.isRunning)
    }

    func testParentEOFStopsActivatedHelperGracefully() async throws {
        let process = makeProcess(
            shell: Self.preparedPrintf
                + "; " + Self.awaitActivation
                + "; " + Self.readyPrintf
                + "; cat >/dev/null"
        )

        try process.start()
        try await process.awaitPrepared(timeout: .seconds(1))
        XCTAssertFalse(process.seizureMayHaveOccurred)
        try process.activateSeizure()
        XCTAssertTrue(process.seizureMayHaveOccurred)
        try await process.awaitReady(timeout: .seconds(1))
        XCTAssertTrue(process.isRunning)

        let evidence = process.stopAndWait(
            gracefulTimeout: 1,
            forcedTimeout: 1
        )

        XCTAssertTrue(evidence.processExited)
        XCTAssertFalse(evidence.forced)
        XCTAssertFalse(process.isRunning)
    }

    func testWedgedActivatedHelperFallsBackToSIGKILL() async throws {
        let process = makeProcess(
            shell: Self.preparedPrintf
                + "; " + Self.awaitActivation
                + "; " + Self.readyPrintf
                + "; exec /bin/sleep 10"
        )

        try process.start()
        try await process.awaitPrepared(timeout: .seconds(1))
        try process.activateSeizure()
        try await process.awaitReady(timeout: .seconds(1))
        XCTAssertTrue(process.isRunning)

        let evidence = process.stopAndWait(
            gracefulTimeout: 0.05,
            forcedTimeout: 1
        )

        XCTAssertTrue(evidence.processExited)
        XCTAssertTrue(evidence.forced)
        XCTAssertTrue(process.seizureMayHaveOccurred)
        XCTAssertFalse(process.isRunning)
    }

    func testLaunchFailureIsFailClosed() {
        let process = CoreHIDPointerOwnershipProcess(
            generation: 1,
            launchConfiguration: .init(
                executableURL: URL(
                    fileURLWithPath: "/definitely/not/a/crossinput-helper"
                ),
                arguments: []
            ),
            onEvent: { _, _ in },
            onFailure: { _ in }
        )

        XCTAssertThrowsError(try process.start()) { error in
            guard case CoreHIDPointerOwnershipProcess.StartError.launch =
                    error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(process.seizureMayHaveOccurred)
        XCTAssertFalse(process.isRunning)
    }

    private func makeProcess(
        shell: String
    ) -> CoreHIDPointerOwnershipProcess {
        CoreHIDPointerOwnershipProcess(
            generation: 42,
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", shell]
            ),
            onEvent: { _, _ in },
            onFailure: { _ in }
        )
    }
}
#endif
