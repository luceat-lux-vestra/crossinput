import Foundation

final class CoreHIDPointerLeaseRegistry: @unchecked Sendable {
    enum ReservationError: Error, Equatable, Sendable {
        case alreadyOwned
    }

    static let shared = CoreHIDPointerLeaseRegistry()

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    func reserve() throws -> UInt64 {
        try lock.withLock {
            guard activeGeneration == nil else {
                throw ReservationError.alreadyOwned
            }
            nextGeneration &+= 1
            if nextGeneration == 0 {
                nextGeneration = 1
            }
            activeGeneration = nextGeneration
            return nextGeneration
        }
    }

    func release(_ generation: UInt64) {
        lock.withLock {
            guard activeGeneration == generation else { return }
            activeGeneration = nil
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { activeGeneration == generation }
    }

    var hasActiveLease: Bool {
        lock.withLock { activeGeneration != nil }
    }
}
