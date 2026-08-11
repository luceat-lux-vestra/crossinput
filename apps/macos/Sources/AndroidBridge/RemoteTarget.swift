import Foundation
import Protocol

/// Opaque identity for a remote target. The v1 adapter currently derives this
/// from the Android display ID, but application code must not interpret it as
/// an Android identifier.
public struct RemoteTargetID: Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum RemoteTargetKind: String, Sendable, Equatable {
    case phone
    case external
    case virtual
    case unknown
}

public enum RemoteTargetAvailability: String, Sendable, Equatable {
    case available
    case unavailable
}

/// Normalized target model consumed by the application and presentation layers.
/// Raw Android display metadata remains in the CXI v1 compatibility decoder.
public struct RemoteTarget: Identifiable, Sendable, Equatable {
    public let id: RemoteTargetID
    public let name: String
    public let kind: RemoteTargetKind
    public let availability: RemoteTargetAvailability
    public let width: UInt32
    public let height: UInt32
    public let densityDpi: UInt32
    public let rotation: UInt8
    public let uniqueId: String

    public init(id: RemoteTargetID,
                name: String,
                kind: RemoteTargetKind,
                availability: RemoteTargetAvailability,
                width: UInt32,
                height: UInt32,
                densityDpi: UInt32,
                rotation: UInt8,
                uniqueId: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.availability = availability
        self.width = width
        self.height = height
        self.densityDpi = densityDpi
        self.rotation = rotation
        self.uniqueId = uniqueId
    }
}

/// Translates the current CXI v1 display record into the application target
/// model. This is the only macOS-side location that knows the v1 numeric type
/// and desktop flag conventions; it is a compatibility adapter, not product
/// logic. CXI v2 will provide normalized fields directly.
public enum RemoteTargetCatalog {
    private static let v1DesktopType: UInt8 = 7
    private static let v1HdmiType: UInt8 = 2
    private static let v1DesktopFlag: UInt32 = 0x40

    public static func normalize(_ display: DisplayInfo) -> RemoteTarget {
        let isDesktop = display.isDesktop || display.type == v1DesktopType ||
            (display.flags & v1DesktopFlag) != 0
        let kind: RemoteTargetKind
        if isDesktop || display.type == v1HdmiType {
            kind = .external
        } else if display.type == 4 {
            kind = .virtual
        } else if display.type == 1 {
            kind = .phone
        } else {
            kind = .unknown
        }

        // DeX can report a stale OFF state while it is rendering. Availability
        // therefore follows discovery presence in v1; the raw state remains
        // available only to the compatibility decoder.
        return RemoteTarget(
            id: RemoteTargetID(rawValue: display.displayId),
            name: display.name,
            kind: kind,
            availability: .available,
            width: display.width,
            height: display.height,
            densityDpi: display.densityDpi,
            rotation: display.rotation,
            uniqueId: display.uniqueId,
        )
    }

    public static func normalize(_ displays: [DisplayInfo]) -> [RemoteTarget] {
        displays.map(normalize)
    }

    /// Preserves the v1 selection policy while keeping raw display conventions
    /// out of the application controller.
    public static func preferredTarget(in targets: [RemoteTarget], override: Int? = nil) -> RemoteTarget? {
        if let override,
           let rawOverride = UInt32(exactly: override),
           let match = targets.first(where: { $0.id.rawValue == rawOverride }) {
            return match
        }
        if let desktop = targets.first(where: {
            $0.name.caseInsensitiveCompare("Desktop") == .orderedSame ||
                $0.uniqueId.range(of: ",Desktop,", options: .caseInsensitive) != nil
        }) {
            return desktop
        }
        if let external = targets.first(where: { $0.kind == .external }) {
            return external
        }
        return targets.first
    }
}
