import XCTest
import Protocol
@testable import AndroidBridge

final class RemoteTargetTests: XCTestCase {
    func testV1DesktopRecordBecomesAnExternalTarget() {
        let display = DisplayInfo(
            displayId: 6,
            type: 7,
            flags: 0x40,
            state: 1,
            width: 1920,
            height: 1080,
            densityDpi: 160,
            rotation: 0,
            name: "Desktop",
            uniqueId: "local:6",
            layerStack: 6
        )

        let target = RemoteTargetCatalog.normalize(display)

        XCTAssertEqual(target.id, RemoteTargetID(rawValue: 6))
        XCTAssertEqual(target.kind, .external)
        XCTAssertEqual(target.availability, .available)
        XCTAssertEqual(target.width, 1920)
    }

    func testSelectionPreservesOverrideThenExternalThenFirstPolicy() {
        let phone = makeTarget(id: 0, kind: .phone)
        let external = makeTarget(id: 6, kind: .external)

        XCTAssertEqual(
            RemoteTargetCatalog.preferredTarget(in: [phone, external], override: 0)?.id,
            phone.id
        )
        XCTAssertEqual(
            RemoteTargetCatalog.preferredTarget(in: [phone, external])?.id,
            external.id
        )
        XCTAssertEqual(
            RemoteTargetCatalog.preferredTarget(in: [phone], override: 99)?.id,
            phone.id
        )
    }

    func testEmptyCatalogHasNoSelection() {
        XCTAssertNil(RemoteTargetCatalog.preferredTarget(in: []))
    }

    private func makeTarget(id: UInt32, kind: RemoteTargetKind) -> RemoteTarget {
        RemoteTarget(
            id: RemoteTargetID(rawValue: id),
            name: "target",
            kind: kind,
            availability: .available,
            width: 1,
            height: 1,
            densityDpi: 1,
            rotation: 0,
            uniqueId: "local:\(id)"
        )
    }
}
