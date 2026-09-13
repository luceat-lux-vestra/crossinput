import Foundation

public struct HIDSeizeSelector: Equatable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let locationID: Int

    public init(vendorID: Int, productID: Int, locationID: Int) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }
}

public struct HIDMouseIdentity: Equatable, Sendable {
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let transport: String?
    public let builtIn: Bool?
    public let productName: String?

    public init(
        vendorID: Int?,
        productID: Int?,
        locationID: Int?,
        transport: String?,
        builtIn: Bool?,
        productName: String?
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.transport = transport
        self.builtIn = builtIn
        self.productName = productName
    }
}

public enum HIDSeizeProbeMode: Equatable, Sendable {
    case list
    case seize(HIDSeizeSelector)
}

public enum HIDSeizeSafetyError: Error, Equatable, CustomStringConvertible, Sendable {
    case usage
    case noMatchingDevice
    case ambiguousMatch(Int)
    case builtInUnknown
    case builtInDevice
    case transportUnknown
    case unsafeTransport(String)

    public var description: String {
        switch self {
        case .usage:
            return "usage: cxi-hid-seize-probe --list | --vendor <id> --product <id> --location <id>"
        case .noMatchingDevice:
            return "no exact external mouse matched vendor/product/location"
        case let .ambiguousMatch(count):
            return "refusing ambiguous selection: \(count) devices matched"
        case .builtInUnknown:
            return "refusing device because Built-In identity is unknown"
        case .builtInDevice:
            return "refusing to seize a device reported as built-in"
        case .transportUnknown:
            return "refusing device because HID transport is unknown"
        case let .unsafeTransport(transport):
            return "refusing transport not explicitly allowed for H0: \(transport)"
        }
    }
}

public enum HIDSeizeSafety {
    public static let allowedTransports: Set<String> = [
        "USB",
        "Bluetooth",
        "Bluetooth Low Energy",
    ]

    public static func parse(arguments: [String]) throws -> HIDSeizeProbeMode {
        if arguments == ["--list"] {
            return .list
        }
        guard arguments.count == 6 else {
            throw HIDSeizeSafetyError.usage
        }

        var values: [String: Int] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard index + 1 < arguments.count,
                  ["--vendor", "--product", "--location"].contains(key),
                  values[key] == nil,
                  let value = parseInteger(arguments[index + 1]) else {
                throw HIDSeizeSafetyError.usage
            }
            values[key] = value
            index += 2
        }

        guard let vendor = values["--vendor"],
              let product = values["--product"],
              let location = values["--location"] else {
            throw HIDSeizeSafetyError.usage
        }
        return .seize(HIDSeizeSelector(
            vendorID: vendor,
            productID: product,
            locationID: location
        ))
    }

    public static func select(
        identities: [HIDMouseIdentity],
        selector: HIDSeizeSelector
    ) throws -> HIDMouseIdentity {
        let matches = identities.filter {
            $0.vendorID == selector.vendorID
                && $0.productID == selector.productID
                && $0.locationID == selector.locationID
        }
        guard !matches.isEmpty else {
            throw HIDSeizeSafetyError.noMatchingDevice
        }
        guard matches.count == 1, let identity = matches.first else {
            throw HIDSeizeSafetyError.ambiguousMatch(matches.count)
        }
        try validate(identity)
        return identity
    }

    public static func validate(_ identity: HIDMouseIdentity) throws {
        guard let builtIn = identity.builtIn else {
            throw HIDSeizeSafetyError.builtInUnknown
        }
        guard !builtIn else {
            throw HIDSeizeSafetyError.builtInDevice
        }
        guard let transport = identity.transport else {
            throw HIDSeizeSafetyError.transportUnknown
        }
        guard allowedTransports.contains(transport) else {
            throw HIDSeizeSafetyError.unsafeTransport(transport)
        }
    }

    private static func parseInteger(_ text: String) -> Int? {
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            return Int(text.dropFirst(2), radix: 16)
        }
        return Int(text, radix: 10)
    }
}
