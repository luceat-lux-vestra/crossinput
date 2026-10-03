import Testing
@testable import InputCapture

@Suite("CoreHID pointer lease registry")
struct CoreHIDPointerLeaseRegistryTests {
    @Test("only one local lease can be reserved")
    func rejectsConcurrentReservation() throws {
        let registry = CoreHIDPointerLeaseRegistry()
        let generation = try registry.reserve()

        #expect(registry.isCurrent(generation))
        #expect(
            throws: CoreHIDPointerLeaseRegistry.ReservationError.alreadyOwned
        ) {
            try registry.reserve()
        }
    }

    @Test("release is idempotent")
    func releaseIsIdempotent() throws {
        let registry = CoreHIDPointerLeaseRegistry()
        let generation = try registry.reserve()

        registry.release(generation)
        registry.release(generation)

        #expect(!registry.hasActiveLease)
        #expect(try registry.reserve() > generation)
    }

    @Test("stale release cannot clear newer ownership")
    func staleReleaseCannotClearNewerLease() throws {
        let registry = CoreHIDPointerLeaseRegistry()
        let oldGeneration = try registry.reserve()
        registry.release(oldGeneration)

        let newGeneration = try registry.reserve()
        registry.release(oldGeneration)

        #expect(registry.isCurrent(newGeneration))
        #expect(
            throws: CoreHIDPointerLeaseRegistry.ReservationError.alreadyOwned
        ) {
            try registry.reserve()
        }
    }

    @Test("generations advance across successful ownership periods")
    func generationAdvances() throws {
        let registry = CoreHIDPointerLeaseRegistry()
        let first = try registry.reserve()
        registry.release(first)
        let second = try registry.reserve()

        #expect(second > first)
    }
}
