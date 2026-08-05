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
///
/// Safety: all magnitude math is done in Int64 so `Int32.min`/`Int32.max`
/// cannot trap (in Swift, `abs(Int32.min)` overflows). A per-event report
/// cap bounds memory; if the cap is hit the excess is dropped and the
/// delivered deltas are the sum of the emitted reports only — never the raw
/// input (the state machine's virtual position tracks delivered deltas).
public enum HIDReportSplitter {
    /// Maximum magnitude per report axis; matches the descriptor's logical range.
    public static let reportLimit: Int32 = 127

    /// Bounds the number of reports generated for a single event. 1024
    /// reports ~ 130 048 px of movement per axis — far beyond any real
    /// mouse delta, while still bounding memory.
    public static let maxReportsPerEvent = 1024

    public static func normalizeForHID(dx: Int32, dy: Int32) -> DeliveredMovement {
        // Int64 promotion: abs(Int32.min) would trap in Int32.
        let xChunks = chunks(of: Int64(dx))
        let yChunks = chunks(of: Int64(dy))
        let count = max(xChunks.count, yChunks.count)
        guard count > 0 else {
            return DeliveredMovement(reports: [], deliveredDx: 0, deliveredDy: 0)
        }
        let capped = min(count, maxReportsPerEvent)
        var reports: [HIDRelativeReport] = []
        reports.reserveCapacity(capped)
        var deliveredDx: Int64 = 0
        var deliveredDy: Int64 = 0
        for i in 0..<capped {
            let x = i < xChunks.count ? xChunks[i] : 0
            let y = i < yChunks.count ? yChunks[i] : 0
            reports.append(HIDRelativeReport(dx: Int8(x), dy: Int8(y)))
            deliveredDx += Int64(x)
            deliveredDy += Int64(y)
        }
        // Capped totals always fit in Int32: <= maxReportsPerEvent * reportLimit.
        return DeliveredMovement(reports: reports,
                                 deliveredDx: Int32(deliveredDx),
                                 deliveredDy: Int32(deliveredDy))
    }

    /// Splits a single-axis delta into chunks each within +/-reportLimit.
    /// Safe for the full Int32 range because `value` is already promoted to
    /// Int64. Generation is bounded by `maxReportsPerEvent`: a pathological
    /// delta cannot allocate millions of chunks.
    private static func chunks(of value: Int64) -> [Int64] {
        guard value != 0 else { return [] }
        let magnitude = abs(value)
        let full = min(magnitude / Int64(reportLimit), Int64(maxReportsPerEvent))
        let remainder = full < Int64(maxReportsPerEvent) ? magnitude % Int64(reportLimit) : 0
        let sign = value > 0 ? Int64(1) : -1
        var out: [Int64] = []
        out.reserveCapacity(Int(full) + (remainder > 0 ? 1 : 0))
        for _ in 0..<full {
            out.append(sign * Int64(reportLimit))
        }
        if remainder > 0 {
            out.append(sign * remainder)
        }
        return out
    }
}
