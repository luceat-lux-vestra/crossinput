import Foundation

/// Test-only v1 report accounting model. Production macOS code sends semantic
/// pointer events; the equivalent report encoder lives in the Android helper.
struct HIDRelativeReport: Equatable {
    let dx: Int8
    let dy: Int8
}

struct DeliveredMovement: Equatable {
    let reports: [HIDRelativeReport]
    let deliveredDx: Int32
    let deliveredDy: Int32
}

enum HIDReportSplitter {
    static let reportLimit: Int32 = 127
    static let maxReportsPerEvent = 1024

    static func normalizeForHID(dx: Int32, dy: Int32) -> DeliveredMovement {
        let xChunks = chunks(of: Int64(dx))
        let yChunks = chunks(of: Int64(dy))
        let count = max(xChunks.count, yChunks.count)
        guard count > 0 else { return DeliveredMovement(reports: [], deliveredDx: 0, deliveredDy: 0) }
        let capped = min(count, maxReportsPerEvent)
        var reports: [HIDRelativeReport] = []
        reports.reserveCapacity(capped)
        var deliveredDx: Int64 = 0
        var deliveredDy: Int64 = 0
        for index in 0..<capped {
            let x = index < xChunks.count ? xChunks[index] : 0
            let y = index < yChunks.count ? yChunks[index] : 0
            reports.append(HIDRelativeReport(dx: Int8(x), dy: Int8(y)))
            deliveredDx += Int64(x)
            deliveredDy += Int64(y)
        }
        return DeliveredMovement(reports: reports,
                                 deliveredDx: Int32(deliveredDx),
                                 deliveredDy: Int32(deliveredDy))
    }

    private static func chunks(of value: Int64) -> [Int64] {
        guard value != 0 else { return [] }
        let magnitude = abs(value)
        let full = min(magnitude / Int64(reportLimit), Int64(maxReportsPerEvent))
        let remainder = full < Int64(maxReportsPerEvent) ? magnitude % Int64(reportLimit) : 0
        let sign: Int64 = value > 0 ? 1 : -1
        var result: [Int64] = []
        result.reserveCapacity(Int(full) + (remainder > 0 ? 1 : 0))
        for _ in 0..<full { result.append(sign * Int64(reportLimit)) }
        if remainder > 0 { result.append(sign * remainder) }
        return result
    }
}
