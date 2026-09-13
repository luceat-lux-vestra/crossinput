import XCTest
@testable import HIDSeizeProbeCore

final class HIDSeizeProbeCoreTests: XCTestCase {
    func testListModeIsExplicit() throws {
        XCTAssertEqual(
            try HIDSeizeSafety.parse(arguments: ["--list"]),
            .list
        )
    }

    func testSelectorAcceptsDecimalAndHexAndOrderIsIrrelevant() throws {
        XCTAssertEqual(
            try HIDSeizeSafety.parse(arguments: [
                "--location", "0x30",
                "--vendor", "0x10",
                "--product", "32",
            ]),
            .seize(HIDSeizeSelector(vendorID: 16, productID: 32, locationID: 48))
        )
    }

    func testDuplicateSelectorFlagFailsClosed() {
        XCTAssertThrowsError(try HIDSeizeSafety.parse(arguments: [
            "--vendor", "1",
            "--vendor", "2",
            "--location", "3",
        ])) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .usage)
        }
    }

    func testExactMatchIsRequired() {
        let identities = [externalMouse(vendor: 1, product: 2, location: 3)]
        XCTAssertThrowsError(try HIDSeizeSafety.select(
            identities: identities,
            selector: HIDSeizeSelector(vendorID: 1, productID: 2, locationID: 4)
        )) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .noMatchingDevice)
        }
    }

    func testAmbiguousIdentityFailsClosed() {
        let identity = externalMouse(vendor: 1, product: 2, location: 3)
        XCTAssertThrowsError(try HIDSeizeSafety.select(
            identities: [identity, identity],
            selector: HIDSeizeSelector(vendorID: 1, productID: 2, locationID: 3)
        )) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .ambiguousMatch(2))
        }
    }

    func testBuiltInDeviceIsRejected() {
        XCTAssertThrowsError(try HIDSeizeSafety.validate(HIDMouseIdentity(
            vendorID: 1,
            productID: 2,
            locationID: 3,
            transport: "USB",
            builtIn: true,
            productName: "internal"
        ))) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .builtInDevice)
        }
    }

    func testUnknownBuiltInStatusIsRejected() {
        XCTAssertThrowsError(try HIDSeizeSafety.validate(HIDMouseIdentity(
            vendorID: 1,
            productID: 2,
            locationID: 3,
            transport: "USB",
            builtIn: nil,
            productName: "unknown"
        ))) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .builtInUnknown)
        }
    }

    func testUnknownTransportIsRejected() {
        XCTAssertThrowsError(try HIDSeizeSafety.validate(HIDMouseIdentity(
            vendorID: 1,
            productID: 2,
            locationID: 3,
            transport: nil,
            builtIn: false,
            productName: "external"
        ))) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .transportUnknown)
        }
    }

    func testUnapprovedTransportIsRejected() {
        XCTAssertThrowsError(try HIDSeizeSafety.validate(HIDMouseIdentity(
            vendorID: 1,
            productID: 2,
            locationID: 3,
            transport: "SPI",
            builtIn: false,
            productName: "external"
        ))) { error in
            XCTAssertEqual(error as? HIDSeizeSafetyError, .unsafeTransport("SPI"))
        }
    }

    func testKnownExternalUSBMouseIsAccepted() throws {
        let identity = externalMouse(vendor: 1, product: 2, location: 3)
        XCTAssertEqual(
            try HIDSeizeSafety.select(
                identities: [identity],
                selector: HIDSeizeSelector(vendorID: 1, productID: 2, locationID: 3)
            ),
            identity
        )
    }

    private func externalMouse(vendor: Int, product: Int, location: Int) -> HIDMouseIdentity {
        HIDMouseIdentity(
            vendorID: vendor,
            productID: product,
            locationID: location,
            transport: "USB",
            builtIn: false,
            productName: "test mouse"
        )
    }
}
