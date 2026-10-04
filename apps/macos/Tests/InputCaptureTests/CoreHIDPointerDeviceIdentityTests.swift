import XCTest
@testable import InputCapture

final class CoreHIDPointerDeviceIdentityTests: XCTestCase {
    func testRequiresSpecificCrossProcessLocator() {
        XCTAssertNil(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1,
                productID: 2,
                uniqueID: nil,
                locationID: nil
            )
        )
    }

    func testEnvironmentRoundTripPreservesExactIdentity() throws {
        let identity = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: "internal-trackpad",
                locationID: 456
            )
        )

        let environment = identity.applying(to: ["KEEP": "value"])
        let decoded = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity.fromEnvironment(environment)
        )

        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(environment["KEEP"], "value")
    }

    func testMatchingRequiresEveryAvailableLocator() throws {
        let identity = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: "internal-trackpad",
                locationID: 456
            )
        )

        XCTAssertTrue(
            identity.matches(
                vendorID: 1452,
                productID: 123,
                uniqueID: "internal-trackpad",
                locationID: 456
            )
        )
        XCTAssertFalse(
            identity.matches(
                vendorID: 1452,
                productID: 123,
                uniqueID: "other",
                locationID: 456
            )
        )
        XCTAssertFalse(
            identity.matches(
                vendorID: 1452,
                productID: 123,
                uniqueID: "internal-trackpad",
                locationID: 999
            )
        )
    }

    func testLocationOnlyIdentityRoundTrips() throws {
        let identity = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: nil,
                locationID: 456
            )
        )

        XCTAssertEqual(
            CoreHIDPointerDeviceIdentity.fromEnvironment(
                identity.applying(to: [:])
            ),
            identity
        )
    }
}
