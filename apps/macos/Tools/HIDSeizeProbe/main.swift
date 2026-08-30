import Foundation
import IOKit
import IOKit.hid

private struct Selector {
    let vendorID: Int
    let productID: Int
    let locationID: Int
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case managerOpen(IOReturn)
    case noMatchingDevice
    case ambiguousMatch(Int)
    case builtInDevice
    case unsafeTransport(String)
    case seizeFailed(IOReturn)

    var description: String {
        switch self {
        case .usage:
            return "usage: cxi-hid-seize-probe --list | --vendor <id> --product <id> --location <id>"
        case let .managerOpen(result):
            return String(format: "IOHIDManagerOpen failed: 0x%08x", UInt32(bitPattern: result))
        case .noMatchingDevice:
            return "no exact external mouse matched vendor/product/location"
        case let .ambiguousMatch(count):
            return "refusing ambiguous selection: \(count) devices matched"
        case .builtInDevice:
            return "refusing to seize a device reported as built-in"
        case let .unsafeTransport(transport):
            return "refusing transport not explicitly allowed for H0: \(transport)"
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
    guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &number) else { return nil }
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
          let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
        return nil
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean))
    }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        var number: Int32 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt32Type, &number) else { return nil }
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

private func identity(_ device: IOHIDDevice) -> String {
    let vendor = integerProperty(device, key: kIOHIDVendorIDKey as CFString)
    let product = integerProperty(device, key: kIOHIDProductIDKey as CFString)
    let location = integerProperty(device, key: kIOHIDLocationIDKey as CFString)
    let name = stringProperty(device, key: kIOHIDProductKey as CFString) ?? "unknown"
    let transport = stringProperty(device, key: kIOHIDTransportKey as CFString) ?? "unknown"
    let builtIn = boolRegistryProperty(device, key: "Built-In" as CFString)
    return "vendor=\(vendor.map(String.init) ?? "unknown") product=\(product.map(String.init) ?? "unknown") location=\(location.map(String.init) ?? "unknown") transport=\(transport) builtIn=\(builtIn.map(String.init) ?? "unknown") name=\(name)"
}

private func parseInteger(_ text: String) -> Int? {
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
        return Int(text.dropFirst(2), radix: 16)
    }
    return Int(text, radix: 10)
}

private func parseSelector(_ arguments: [String]) throws -> Selector? {
    if arguments == ["--list"] { return nil }
    guard arguments.count == 6 else { throw ProbeError.usage }
    var values: [String: Int] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard index + 1 < arguments.count,
              ["--vendor", "--product", "--location"].contains(key),
              values[key] == nil,
              let value = parseInteger(arguments[index + 1]) else {
            throw ProbeError.usage
        }
        values[key] = value
        index += 2
    }
    guard let vendor = values["--vendor"],
          let product = values["--product"],
          let location = values["--location"] else {
        throw ProbeError.usage
    }
    return Selector(vendorID: vendor, productID: product, locationID: location)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let selector = try parseSelector(arguments)
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard managerResult == kIOReturnSuccess else { throw ProbeError.managerOpen(managerResult) }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    let mice = devices.filter(isMouse)

    guard let selector else {
        if mice.isEmpty {
            print("no HID mouse devices enumerated")
        } else {
            for device in mice.sorted(by: { identity($0) < identity($1) }) {
                print(identity(device))
            }
        }
        return
    }

    let matches = mice.filter { device in
        integerProperty(device, key: kIOHIDVendorIDKey as CFString) == selector.vendorID
            && integerProperty(device, key: kIOHIDProductIDKey as CFString) == selector.productID
            && integerProperty(device, key: kIOHIDLocationIDKey as CFString) == selector.locationID
    }
    guard !matches.isEmpty else { throw ProbeError.noMatchingDevice }
    guard matches.count == 1, let device = matches.first else { throw ProbeError.ambiguousMatch(matches.count) }

    // Fail closed. Candidate H must never take the built-in trackpad away from macOS.
    guard boolRegistryProperty(device, key: "Built-In" as CFString) != true else {
        throw ProbeError.builtInDevice
    }
    let transport = stringProperty(device, key: kIOHIDTransportKey as CFString) ?? "unknown"
    let allowedTransports = Set(["USB", "Bluetooth", "Bluetooth Low Energy"])
    guard allowedTransports.contains(transport) else {
        throw ProbeError.unsafeTransport(transport)
    }

    print("selected \(identity(device))")
    let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard seizeResult == kIOReturnSuccess else { throw ProbeError.seizeFailed(seizeResult) }
    defer {
        let closeResult = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        print(String(format: "close result: 0x%08x", UInt32(bitPattern: closeResult)))
    }

    // H0 only proves whether an ordinary CrossInput process can acquire the exact
    // external mouse exclusively. Do not hold the device or migrate input yet.
    print("SEIZE_OK: exact external mouse opened exclusively as the current user")
}

do {
    try run()
} catch {
    fputs("HID seize probe failed: \(error)\n", stderr)
    exit(1)
}
