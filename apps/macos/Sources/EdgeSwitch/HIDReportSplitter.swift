import Foundation

/// A single relative-movement HID report for the UHID mouse descriptor:
/// buttons u8, dx i8, dy i8, wheel u8 (logical min 0x81 = -127, max 0x7f = 127).
public struct HIDRelativeReport: Sendable, Equatable {
    public let dx: Int8
    public let dy: Int8
    public init(dx: Int8, dy: Int8) {
        self.dx = dx
        self.dy = dy
    }
}

/// Result of normalizing raw deltas into HID-safe reports.
///
/// The state machine's virtual position must equal the movement actually
/// delivered to Android — raw deltas are never clamped away, they are split
/// into multiple reports (raw dx=300 -> reports 127, 127, 46; delivered 300).
public struct DeliveredMovement: Sendable, Equatable {
    public let reports: [HIDRelativeReport]
    /// Sum of all report deltas; equals the raw input when nothing is dropped.
    public let deliveredDx: Int32
    public let deliveredDy: Int32

    public init(reports: [HIDRelativeReport], deliveredDx: Int32, deliveredDy: Int32) {
        self.reports = reports
        self.deliveredDx = deliveredDx
        self.deliveredDy = deliveredDy
    }
}

/// Splits raw pointer deltas into HID report chunks.
///
/// The UHID mouse descriptor caps each report at +/-127 per axis. Large
/// deltas are split into multiple reports so no movement is lost (previously
/// `Int8(clamping:)` silently dropped anything beyond 127). The split must
/// never emit a report with both deltas zero — that would be a wasted send.
public enum HIDReportSplitter {
    /// Maximum magnitude per report axis; matches the descriptor's logical range.
    public static let reportLimit: Int32 = 127

    public static func normalizeForHID(dx: Int32, dy: Int32) -> DeliveredMovement {
        let xChunks = chunks(of: dx)
        let yChunks = chunks(of: dy)
        let count = max(xChunks.count, yChunks.count)
        guard count > 0 else {
            return DeliveredMovement(reports: [], deliveredDx: 0, deliveredDy: 0)
        }
        var reports: [HIDRelativeReport] = []
        reports.reserveCapacity(count)
        for i in 0..<count {
            let x = i < xChunks.count ? xChunks[i] : 0
            let y = i < yChunks.count ? yChunks[i] : 0
            reports.append(HIDRelativeReport(dx: Int8(x), dy: Int8(y)))
        }
        return DeliveredMovement(reports: reports, deliveredDx: dx, deliveredDy: dy)
    }

    /// Splits a single-axis delta into chunks each within +/-reportLimit.
    private static func chunks(of value: Int32) -> [Int32] {
        guard value != 0 else { return [] }
        let magnitude = abs(value)
        let full = magnitude / reportLimit
        let remainder = magnitude % reportLimit
        let sign = value > 0 ? Int32(1) : -1
        var out: [Int32] = []
        out.reserveCapacity(Int(full) + (remainder > 0 ? 1 : 0))
        for _ in 0..<full {
            out.append(sign * reportLimit)
        }
        if remainder > 0 {
            out.append(sign * remainder)
        }
        return out
    }
}
