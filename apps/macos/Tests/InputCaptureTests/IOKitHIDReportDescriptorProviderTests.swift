import Foundation
import XCTest
@testable import InputCapture

final class IOKitHIDReportDescriptorProviderTests: XCTestCase {
    private let descriptor = Data([0x05, 0x01, 0x09, 0x02])

    func testSelectsOnlyExactBuiltInLocationMatch() throws {
        let identity = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: "corehid-id",
                locationID: 456
            )
        )
        let snapshots = [
            snapshot(locationID: 999),
            snapshot(locationID: 456),
        ]

        XCTAssertEqual(
            try IOKitHIDReportDescriptorProvider.selectDescriptor(
                from: snapshots,
                matching: identity
            ),
            descriptor
        )
    }

    func testMissingLocationFailsClosed() throws {
        let identity = try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: "corehid-id",
                locationID: nil
            )
        )

        XCTAssertThrowsError(
            try IOKitHIDReportDescriptorProvider.selectDescriptor(
                from: [snapshot(locationID: 456)],
                matching: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? IOKitHIDReportDescriptorProvider.ProviderError,
                .missingLocationID
            )
        }
    }

    func testAmbiguousExactMatchesFailClosed() throws {
        let identity = try exactIdentity()

        XCTAssertThrowsError(
            try IOKitHIDReportDescriptorProvider.selectDescriptor(
                from: [snapshot(locationID: 456), snapshot(locationID: 456)],
                matching: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? IOKitHIDReportDescriptorProvider.ProviderError,
                .ambiguousMatch
            )
        }
    }

    func testMissingDescriptorFailsClosed() throws {
        let identity = try exactIdentity()

        XCTAssertThrowsError(
            try IOKitHIDReportDescriptorProvider.selectDescriptor(
                from: [snapshot(locationID: 456, descriptor: nil)],
                matching: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? IOKitHIDReportDescriptorProvider.ProviderError,
                .missingDescriptor
            )
        }
    }

    func testWrongProductOrExternalDeviceCannotMatch() throws {
        let identity = try exactIdentity()
        let wrongProduct = IOKitHIDReportDescriptorProvider.DeviceSnapshot(
            vendorID: 1452,
            productID: 123,
            product: "Other Trackpad",
            locationID: 456,
            isBuiltIn: true,
            descriptor: descriptor
        )
        let external = IOKitHIDReportDescriptorProvider.DeviceSnapshot(
            vendorID: 1452,
            productID: 123,
            product: "Apple Internal Keyboard / Trackpad",
            locationID: 456,
            isBuiltIn: false,
            descriptor: descriptor
        )

        XCTAssertThrowsError(
            try IOKitHIDReportDescriptorProvider.selectDescriptor(
                from: [wrongProduct, external],
                matching: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? IOKitHIDReportDescriptorProvider.ProviderError,
                .noExactMatch
            )
        }
    }

    private func exactIdentity() throws -> CoreHIDPointerDeviceIdentity {
        try XCTUnwrap(
            CoreHIDPointerDeviceIdentity(
                vendorID: 1452,
                productID: 123,
                uniqueID: "corehid-id",
                locationID: 456
            )
        )
    }

    private func snapshot(
        locationID: UInt64,
        descriptor: Data? = Data([0x05, 0x01, 0x09, 0x02])
    ) -> IOKitHIDReportDescriptorProvider.DeviceSnapshot {
        IOKitHIDReportDescriptorProvider.DeviceSnapshot(
            vendorID: 1452,
            productID: 123,
            product: "Apple Internal Keyboard / Trackpad",
            locationID: locationID,
            isBuiltIn: true,
            descriptor: descriptor
        )
    }
}
