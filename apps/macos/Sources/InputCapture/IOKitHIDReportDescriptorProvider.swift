import Foundation
import IOKit.hid

/// Stable C-ABI bridge for the raw HID report descriptor.
///
/// CoreHID's Swift `HIDDeviceClient.descriptor` getter changed ABI between
/// macOS 15 and macOS 27. Directly referencing that Swift symbol makes an
/// otherwise deployment-target-compatible executable fail in dyld on one side
/// or the other. IOKit's IOHID C API exposes the same report descriptor as a
/// device property and has a stable C ABI.
///
/// Safety contract: this provider never guesses. The caller must supply the
/// CoreHID-verified physical identity, including a location ID that can be
/// independently matched in IOKit. Zero or multiple matches, a non-built-in
/// device, or a missing descriptor all fail closed before seizure.
enum IOKitHIDReportDescriptorProvider {
    enum ProviderError: Error, Equatable, Sendable {
        case missingLocationID
        case managerOpen
        case noDevices
        case noExactMatch
        case ambiguousMatch
        case missingDescriptor
    }

    struct DeviceSnapshot: Equatable, Sendable {
        let vendorID: UInt32?
        let productID: UInt32?
        let product: String?
        let locationID: UInt64?
        let isBuiltIn: Bool?
        let descriptor: Data?

        func matches(_ identity: CoreHIDPointerDeviceIdentity) -> Bool {
            guard let expectedLocationID = identity.locationID else {
                return false
            }
            return vendorID == identity.vendorID
                && productID == identity.productID
                && product == "Apple Internal Keyboard / Trackpad"
                && locationID == expectedLocationID
                && isBuiltIn == true
        }
    }

    static func selectDescriptor(
        from snapshots: [DeviceSnapshot],
        matching identity: CoreHIDPointerDeviceIdentity
    ) throws -> Data {
        guard identity.locationID != nil else {
            throw ProviderError.missingLocationID
        }

        let matches = snapshots.filter { $0.matches(identity) }
        guard !matches.isEmpty else {
            throw ProviderError.noExactMatch
        }
        guard matches.count == 1 else {
            throw ProviderError.ambiguousMatch
        }
        guard let descriptor = matches[0].descriptor, !descriptor.isEmpty else {
            throw ProviderError.missingDescriptor
        }
        return descriptor
    }

    static func descriptor(
        matching identity: CoreHIDPointerDeviceIdentity
    ) throws -> Data {
        guard let locationID = identity.locationID else {
            throw ProviderError.missingLocationID
        }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: NSNumber(value: identity.vendorID),
            kIOHIDProductIDKey: NSNumber(value: identity.productID),
            kIOHIDProductKey: "Apple Internal Keyboard / Trackpad",
            kIOHIDLocationIDKey: NSNumber(value: locationID),
            kIOHIDBuiltInKey: true,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                == kIOReturnSuccess else {
            throw ProviderError.managerOpen
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let set = IOHIDManagerCopyDevices(manager) else {
            throw ProviderError.noDevices
        }

        let devices = set as NSSet
        var snapshots: [DeviceSnapshot] = []
        snapshots.reserveCapacity(devices.count)

        for case let device as IOHIDDevice in devices {
            snapshots.append(
                DeviceSnapshot(
                    vendorID: uint32Property(device, key: kIOHIDVendorIDKey),
                    productID: uint32Property(device, key: kIOHIDProductIDKey),
                    product: stringProperty(device, key: kIOHIDProductKey),
                    locationID: uint64Property(device, key: kIOHIDLocationIDKey),
                    isBuiltIn: boolProperty(device, key: kIOHIDBuiltInKey),
                    descriptor: dataProperty(device, key: kIOHIDReportDescriptorKey)
                )
            )
        }

        return try selectDescriptor(from: snapshots, matching: identity)
    }

    private static func property(
        _ device: IOHIDDevice,
        key: String
    ) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func uint32Property(
        _ device: IOHIDDevice,
        key: String
    ) -> UInt32? {
        guard let number = property(device, key: key) as? NSNumber else {
            return nil
        }
        let value = number.uint64Value
        guard value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    private static func uint64Property(
        _ device: IOHIDDevice,
        key: String
    ) -> UInt64? {
        (property(device, key: key) as? NSNumber)?.uint64Value
    }

    private static func stringProperty(
        _ device: IOHIDDevice,
        key: String
    ) -> String? {
        property(device, key: key) as? String
    }

    private static func boolProperty(
        _ device: IOHIDDevice,
        key: String
    ) -> Bool? {
        (property(device, key: key) as? NSNumber)?.boolValue
    }

    private static func dataProperty(
        _ device: IOHIDDevice,
        key: String
    ) -> Data? {
        property(device, key: key) as? Data
    }
}
