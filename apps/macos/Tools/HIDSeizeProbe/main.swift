import Foundation
import HIDSeizeProbeCore
import IOKit
import IOKit.hid

private enum ProbeError: Error, CustomStringConvertible {
    case managerOpen(IOReturn)
    case selectedDeviceMissing
    case seizeFailed(IOReturn)

    var description: String {
        switch self {
        case let .managerOpen(result):
            return String(format: "IOHIDManagerOpen failed: 0x%08x", UInt32(bitPattern: result))
        case .selectedDeviceMissing:
            return "selected HID device disappeared before exclusive open"
        case let .seizeFailed(result):
            return String(format: "IOHIDDeviceOpen(seize) failed: 0x%08x", UInt32(bitPattern: result))
        }
    }
}

private func integerProperty(_ device: IOHIDDevice, key: CFString) -> Int? {
    guard let value = IOHIDDeviceGetProperty(device, key),
          CFGetTypeID(value) == CFNumberGetTypeID() else {
        return nil
    }
    var number: Int64 = 0
    guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &number) else {
        return nil
    }
    return Int(number)
}

private func stringProperty(_ device: IOHIDDevice, key: CFString) -> String? {
    guard let value = IOHIDDeviceGetProperty(device, key),
          CFGetTypeID(value) == CFStringGetTypeID() else {
        return nil
    }
    return value as? String
}

private func boolRegistryProperty(_ device: IOHIDDevice, key: CFString) -> Bool? {
    let service = IOHIDDeviceGetService(device)
    guard service != MACH_PORT_NULL,
          let value = IORegistryEntryCreateCFProperty(
            service,
            key,
            kCFAllocatorDefault,
            0
          )?.takeRetainedValue() else {
        return nil
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean))
    }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        var number: Int32 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt32Type, &number) else {
            return nil
        }
        return number != 0
    }
    return nil
}

private func isMouse(_ device: IOHIDDevice) -> Bool {
    IOHIDDeviceConformsTo(
        device,
        UInt32(kHIDPage_GenericDesktop),
        UInt32(kHIDUsage_GD_Mouse)
    )
}

private func identity(of device: IOHIDDevice) -> HIDMouseIdentity {
    HIDMouseIdentity(
        vendorID: integerProperty(device, key: kIOHIDVendorIDKey as CFString),
        productID: integerProperty(device, key: kIOHIDProductIDKey as CFString),
        locationID: integerProperty(device, key: kIOHIDLocationIDKey as CFString),
        transport: stringProperty(device, key: kIOHIDTransportKey as CFString),
        builtIn: boolRegistryProperty(device, key: "Built-In" as CFString),
        productName: stringProperty(device, key: kIOHIDProductKey as CFString)
    )
}

private func printable(_ identity: HIDMouseIdentity) -> String {
    "vendor=\(identity.vendorID.map(String.init) ?? "unknown") "
        + "product=\(identity.productID.map(String.init) ?? "unknown") "
        + "location=\(identity.locationID.map(String.init) ?? "unknown") "
        + "transport=\(identity.transport ?? "unknown") "
        + "builtIn=\(identity.builtIn.map(String.init) ?? "unknown") "
        + "name=\(identity.productName ?? "unknown")"
}

private func run() throws {
    let mode = try HIDSeizeSafety.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard managerResult == kIOReturnSuccess else {
        throw ProbeError.managerOpen(managerResult)
    }
    defer {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    let mice = devices.filter(isMouse)
    let identities = mice.map(identity)

    switch mode {
    case .list:
        if identities.isEmpty {
            print("no HID mouse devices enumerated")
        } else {
            for value in identities.sorted(by: { printable($0) < printable($1) }) {
                print(printable(value))
            }
        }

    case let .seize(selector):
        let selectedIdentity = try HIDSeizeSafety.select(
            identities: identities,
            selector: selector
        )
        guard let device = mice.first(where: { identity(of: $0) == selectedIdentity }) else {
            throw ProbeError.selectedDeviceMissing
        }

        print("selected \(printable(selectedIdentity))")
        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        guard seizeResult == kIOReturnSuccess else {
            throw ProbeError.seizeFailed(seizeResult)
        }
        defer {
            let closeResult = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            print(String(
                format: "close result: 0x%08x",
                UInt32(bitPattern: closeResult)
            ))
        }

        // H0 is intentionally bounded: it proves only that the ordinary
        // logged-in Ampersand process can acquire this exact external mouse
        // exclusively. It registers no callbacks and releases immediately.
        print("SEIZE_OK: exact external mouse opened exclusively as the current user")
    }
}

do {
    try run()
} catch {
    fputs("HID seize probe failed: \(error)\n", stderr)
    exit(1)
}
