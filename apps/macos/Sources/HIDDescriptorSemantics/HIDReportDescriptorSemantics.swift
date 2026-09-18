import Foundation

public enum HIDReportDescriptorSemanticsError: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let detail):
            return "malformed HID report descriptor: \(detail)"
        }
    }
}

public struct HIDAxisInputDeclaration: Equatable, Sendable {
    public let usageID: UInt32
    public let reportID: UInt32?
    public let isData: Bool
    public let isVariable: Bool
    public let isRelative: Bool
    public let reportSize: UInt32?
    public let reportCount: UInt32?

    public init(
        usageID: UInt32,
        reportID: UInt32?,
        isData: Bool,
        isVariable: Bool,
        isRelative: Bool,
        reportSize: UInt32?,
        reportCount: UInt32?
    ) {
        self.usageID = usageID
        self.reportID = reportID
        self.isData = isData
        self.isVariable = isVariable
        self.isRelative = isRelative
        self.reportSize = reportSize
        self.reportCount = reportCount
    }
}

public struct HIDPointerXYSemantics: Equatable, Sendable {
    public let xDeclarations: [HIDAxisInputDeclaration]
    public let yDeclarations: [HIDAxisInputDeclaration]

    public init(
        xDeclarations: [HIDAxisInputDeclaration],
        yDeclarations: [HIDAxisInputDeclaration]
    ) {
        self.xDeclarations = xDeclarations
        self.yDeclarations = yDeclarations
    }

    public var xDataVariableDeclarations: [HIDAxisInputDeclaration] {
        xDeclarations.filter { $0.isData && $0.isVariable }
    }

    public var yDataVariableDeclarations: [HIDAxisInputDeclaration] {
        yDeclarations.filter { $0.isData && $0.isVariable }
    }

    /// Strict proof contract for the current built-in-trackpad probe:
    /// exactly one Data/Variable declaration for each X and Y axis,
    /// both Relative, and both from the same report.
    public var provesUnambiguousRelativeXY: Bool {
        let x = xDataVariableDeclarations
        let y = yDataVariableDeclarations
        guard x.count == 1, y.count == 1 else {
            return false
        }
        guard x[0].isRelative, y[0].isRelative else {
            return false
        }
        return normalizedReportID(x[0].reportID) == normalizedReportID(y[0].reportID)
    }

    private func normalizedReportID(_ reportID: UInt32?) -> UInt32 {
        reportID ?? 0
    }
}

public enum HIDReportDescriptorSemantics {
    private static let genericDesktopUsagePage: UInt32 = 0x01
    private static let xUsage: UInt32 = 0x30
    private static let yUsage: UInt32 = 0x31

    private struct UsageRef {
        let explicitPage: UInt32?
        let id: UInt32

        func resolvedPage(defaultPage: UInt32?) -> UInt32? {
            explicitPage ?? defaultPage
        }
    }

    private struct GlobalState {
        var usagePage: UInt32?
        var reportSize: UInt32?
        var reportCount: UInt32?
        var reportID: UInt32?
    }

    private struct LocalState {
        var usages: [UsageRef] = []
        var usageMinimum: UsageRef?
        var usageMaximum: UsageRef?

        mutating func reset() {
            usages.removeAll(keepingCapacity: true)
            usageMinimum = nil
            usageMaximum = nil
        }

        func contains(
            usagePage targetPage: UInt32,
            usageID targetID: UInt32,
            defaultPage: UInt32?
        ) -> Bool {
            if usages.contains(where: {
                $0.resolvedPage(defaultPage: defaultPage) == targetPage && $0.id == targetID
            }) {
                return true
            }

            guard let minimum = usageMinimum, let maximum = usageMaximum else {
                return false
            }

            let minimumPage = minimum.resolvedPage(defaultPage: defaultPage)
            let maximumPage = maximum.resolvedPage(defaultPage: defaultPage)
            guard minimumPage == targetPage, maximumPage == targetPage else {
                return false
            }

            return minimum.id <= targetID && targetID <= maximum.id
        }
    }

    public static func analyzePointerXY(
        descriptor: Data
    ) throws -> HIDPointerXYSemantics {
        let bytes = Array(descriptor)
        var index = 0
        var global = GlobalState()
        var globalStack: [GlobalState] = []
        var local = LocalState()
        var xDeclarations: [HIDAxisInputDeclaration] = []
        var yDeclarations: [HIDAxisInputDeclaration] = []

        while index < bytes.count {
            let prefix = bytes[index]

            if prefix == 0xFE {
                guard index + 2 < bytes.count else {
                    throw HIDReportDescriptorSemanticsError.malformed(
                        "truncated long-item header at offset \(index)"
                    )
                }
                let payloadLength = Int(bytes[index + 1])
                let next = index + 3 + payloadLength
                guard next <= bytes.count else {
                    throw HIDReportDescriptorSemanticsError.malformed(
                        "truncated long-item payload at offset \(index)"
                    )
                }
                index = next
                continue
            }

            let sizeCode = Int(prefix & 0x03)
            let payloadSize: Int
            switch sizeCode {
            case 0:
                payloadSize = 0
            case 1:
                payloadSize = 1
            case 2:
                payloadSize = 2
            case 3:
                payloadSize = 4
            default:
                fatalError("unreachable HID short-item size code")
            }

            let itemType = (prefix >> 2) & 0x03
            let itemTag = (prefix >> 4) & 0x0F
            let payloadStart = index + 1
            let payloadEnd = payloadStart + payloadSize
            guard payloadEnd <= bytes.count else {
                throw HIDReportDescriptorSemanticsError.malformed(
                    "truncated short-item payload at offset \(index)"
                )
            }

            let value = littleEndianUnsigned(
                bytes: bytes,
                start: payloadStart,
                count: payloadSize
            )

            switch itemType {
            case 0: // Main
                if itemTag == 0x08 { // Input
                    let isData = (value & 0x01) == 0
                    let isVariable = (value & 0x02) != 0
                    let isRelative = (value & 0x04) != 0

                    if local.contains(
                        usagePage: genericDesktopUsagePage,
                        usageID: xUsage,
                        defaultPage: global.usagePage
                    ) {
                        xDeclarations.append(
                            HIDAxisInputDeclaration(
                                usageID: xUsage,
                                reportID: global.reportID,
                                isData: isData,
                                isVariable: isVariable,
                                isRelative: isRelative,
                                reportSize: global.reportSize,
                                reportCount: global.reportCount
                            )
                        )
                    }

                    if local.contains(
                        usagePage: genericDesktopUsagePage,
                        usageID: yUsage,
                        defaultPage: global.usagePage
                    ) {
                        yDeclarations.append(
                            HIDAxisInputDeclaration(
                                usageID: yUsage,
                                reportID: global.reportID,
                                isData: isData,
                                isVariable: isVariable,
                                isRelative: isRelative,
                                reportSize: global.reportSize,
                                reportCount: global.reportCount
                            )
                        )
                    }
                }

                // HID local items apply only to the next Main item.
                local.reset()

            case 1: // Global
                switch itemTag {
                case 0x00: // Usage Page
                    global.usagePage = value
                case 0x07: // Report Size
                    global.reportSize = value
                case 0x08: // Report ID
                    global.reportID = value
                case 0x09: // Report Count
                    global.reportCount = value
                case 0x0A: // Push
                    globalStack.append(global)
                case 0x0B: // Pop
                    guard let restored = globalStack.popLast() else {
                        throw HIDReportDescriptorSemanticsError.malformed(
                            "global Pop without matching Push at offset \(index)"
                        )
                    }
                    global = restored
                default:
                    break
                }

            case 2: // Local
                switch itemTag {
                case 0x00: // Usage
                    local.usages.append(decodeUsage(value: value, payloadSize: payloadSize))
                case 0x01: // Usage Minimum
                    local.usageMinimum = decodeUsage(value: value, payloadSize: payloadSize)
                case 0x02: // Usage Maximum
                    local.usageMaximum = decodeUsage(value: value, payloadSize: payloadSize)
                default:
                    break
                }

            case 3: // Reserved
                break

            default:
                fatalError("unreachable HID item type")
            }

            index = payloadEnd
        }

        if !globalStack.isEmpty {
            throw HIDReportDescriptorSemanticsError.malformed(
                "unclosed global Push scope"
            )
        }

        return HIDPointerXYSemantics(
            xDeclarations: xDeclarations,
            yDeclarations: yDeclarations
        )
    }

    private static func decodeUsage(value: UInt32, payloadSize: Int) -> UsageRef {
        if payloadSize == 4 {
            return UsageRef(
                explicitPage: value >> 16,
                id: value & 0xFFFF
            )
        }
        return UsageRef(explicitPage: nil, id: value)
    }

    private static func littleEndianUnsigned(
        bytes: [UInt8],
        start: Int,
        count: Int
    ) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<count {
            value |= UInt32(bytes[start + offset]) << UInt32(offset * 8)
        }
        return value
    }
}
