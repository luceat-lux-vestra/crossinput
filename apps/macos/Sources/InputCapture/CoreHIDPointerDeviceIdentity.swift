import Foundation

/// Cross-process identity for the exact HID device selected by the parent.
///
/// A product/vendor tuple is descriptive but not sufficient to distinguish two
/// equal devices. At least one CoreHID matching locator (uniqueID or locationID)
/// is therefore required before ownership can cross a process boundary.
struct CoreHIDPointerDeviceIdentity: Equatable, Sendable {
    private enum EnvironmentKey {
        static let vendorID = "CROSSINPUT_COREHID_VENDOR_ID"
        static let productID = "CROSSINPUT_COREHID_PRODUCT_ID"
        static let uniqueID = "CROSSINPUT_COREHID_UNIQUE_ID"
        static let locationID = "CROSSINPUT_COREHID_LOCATION_ID"
    }

    let vendorID: UInt32
    let productID: UInt32
    let uniqueID: String?
    let locationID: UInt64?

    init?(
        vendorID: UInt32,
        productID: UInt32,
        uniqueID: String?,
        locationID: UInt64?
    ) {
        let normalizedUniqueID = uniqueID?.isEmpty == false ? uniqueID : nil
        guard normalizedUniqueID != nil || locationID != nil else {
            return nil
        }
        self.vendorID = vendorID
        self.productID = productID
        self.uniqueID = normalizedUniqueID
        self.locationID = locationID
    }

    func matches(
        vendorID: UInt32,
        productID: UInt32,
        uniqueID: String?,
        locationID: UInt64?
    ) -> Bool {
        guard self.vendorID == vendorID,
              self.productID == productID else {
            return false
        }
        if let expected = self.uniqueID, expected != uniqueID {
            return false
        }
        if let expected = self.locationID, expected != locationID {
            return false
        }
        return true
    }

    func applying(to environment: [String: String]) -> [String: String] {
        var result = environment
        result[EnvironmentKey.vendorID] = String(vendorID)
        result[EnvironmentKey.productID] = String(productID)
        if let uniqueID {
            result[EnvironmentKey.uniqueID] = uniqueID
        } else {
            result.removeValue(forKey: EnvironmentKey.uniqueID)
        }
        if let locationID {
            result[EnvironmentKey.locationID] = String(locationID)
        } else {
            result.removeValue(forKey: EnvironmentKey.locationID)
        }
        return result
    }

    static func fromEnvironment(
        _ environment: [String: String]
    ) -> CoreHIDPointerDeviceIdentity? {
        guard let vendorRaw = environment[EnvironmentKey.vendorID],
              let vendorID = UInt32(vendorRaw),
              let productRaw = environment[EnvironmentKey.productID],
              let productID = UInt32(productRaw) else {
            return nil
        }

        let uniqueID = environment[EnvironmentKey.uniqueID]
        let locationID = environment[EnvironmentKey.locationID]
            .flatMap(UInt64.init)

        return CoreHIDPointerDeviceIdentity(
            vendorID: vendorID,
            productID: productID,
            uniqueID: uniqueID,
            locationID: locationID
        )
    }
}
