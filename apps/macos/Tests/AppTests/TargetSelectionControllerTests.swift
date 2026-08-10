import XCTest
@testable import App
import AndroidBridge
import Protocol

@MainActor
final class TargetSelectionControllerTests: XCTestCase {
    private let phone = RemoteTarget(
        id: RemoteTargetID(rawValue: 1), name: "Phone", kind: .phone,
        availability: .available, width: 1080, height: 2400,
        densityDpi: 420, rotation: 0, uniqueId: "phone")

    private let dex = RemoteTarget(
        id: RemoteTargetID(rawValue: 2), name: "DeX", kind: .external,
        availability: .available, width: 1920, height: 1080,
        densityDpi: 160, rotation: 0, uniqueId: "dex")

    func testFailedSelectionDoesNotPublishSelectedState() async throws {
        let reference = SessionReference()
        let controller = TargetSelectionController(session: reference,
                                                     selectRequest: { _ in
            throw SelectionFailure.rejected
        })
        controller.applySnapshot([phone], autoSelect: false)
        controller.select(phone)

        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(controller.selectedTarget)
        XCTAssertEqual(controller.state, .available)
    }

    func testTargetRemovalInvalidatesPendingSelection() async throws {
        let reference = SessionReference()
        let controller = TargetSelectionController(session: reference,
                                                     selectRequest: { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            throw SelectionFailure.rejected
        })
        controller.applySnapshot([phone], autoSelect: false)
        controller.select(phone)
        controller.applySnapshot([], autoSelect: false)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(controller.selectedTarget)
        XCTAssertEqual(controller.state, .unavailable)
    }

    func testStaleSelectionResponseCannotOverwriteNewerSelection() async throws {
        let reference = SessionReference()
        let phoneID = phone.id
        let controller = TargetSelectionController(session: reference,
                                                     selectRequest: { id in
            // Make A complete after B, so this exercises the response token
            // rather than relying on request completion order.
            if id == phoneID {
                try await Task.sleep(nanoseconds: 100_000_000)
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return CxiFrame(type: .displayChanged, requestId: 1,
                            payload: Self.displayPayload(for: id))
        })
        controller.applySnapshot([phone, dex], autoSelect: false)

        controller.select(phone)
        try await Task.sleep(nanoseconds: 5_000_000)
        controller.select(dex)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.selectedTarget?.id, dex.id)
        XCTAssertEqual(controller.state, .selected(dex.id))
    }

    func testRefreshOwnsDisplayListNormalization() async throws {
        let reference = SessionReference()
        let targetID = dex.id
        let controller = TargetSelectionController(session: reference, listRequest: {
            CxiFrame(type: .displayList, requestId: 7,
                     payload: Self.displayListPayload(for: targetID))
        })

        try await controller.refresh()

        XCTAssertEqual(controller.targets.map(\.id), [dex.id])
        XCTAssertEqual(controller.targets.first?.kind, .phone)
        XCTAssertEqual(controller.state, .available)
    }

    nonisolated private static func displayPayload(for id: RemoteTargetID) -> Data {
        var payload = Data()
        func appendU32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            payload.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        func appendString(_ value: String) {
            let bytes = Data(value.utf8)
            appendU32(UInt32(bytes.count))
            payload.append(bytes)
        }

        appendU32(id.rawValue)
        payload.append(1) // phone display type; normalization only needs the id here.
        appendU32(0)
        payload.append(1)
        appendU32(1080)
        appendU32(2400)
        appendU32(420)
        payload.append(0)
        appendString("target")
        appendString("target-\(id.rawValue)")
        appendU32(0)
        return payload
    }

    nonisolated private static func displayListPayload(for id: RemoteTargetID) -> Data {
        var payload = Data()
        var count = UInt32(1).littleEndian
        payload.append(Data(bytes: &count, count: MemoryLayout<UInt32>.size))
        payload.append(displayPayload(for: id))
        return payload
    }

    private enum SelectionFailure: Error {
        case rejected
    }
}
