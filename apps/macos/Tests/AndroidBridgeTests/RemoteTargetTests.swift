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

    func testAndroid12VirtualDesktopRecordIsRecognizedWithoutDesktopFlag() {
        let display = DisplayInfo(
            displayId: 2,
            type: 5,
            flags: 0x20000182,
            state: 2,
            width: 1920,
            height: 1080,
            densityDpi: 160,
            rotation: 0,
            name: "Desktop",
            uniqueId: "virtual:android,1000,Desktop,0",
            layerStack: 2
        )

        XCTAssertTrue(display.isDesktop)
        XCTAssertEqual(RemoteTargetCatalog.normalize(display).kind, .external)
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

    func testDesktopIsPreferredWhenBothExternalRecordsArePresent() {
        let hdmi = makeTarget(id: 6, kind: .external, name: "HDMI Screen", uniqueId: "local:1")
        let desktop = makeTarget(id: 2, kind: .external, name: "Desktop", uniqueId: "virtual:android,1000,Desktop,0")

        XCTAssertEqual(RemoteTargetCatalog.preferredTarget(in: [hdmi, desktop])?.id, desktop.id)
    }

    func testEmptyCatalogHasNoSelection() {
        XCTAssertNil(RemoteTargetCatalog.preferredTarget(in: []))
    }

    private func makeTarget(id: UInt32,
                            kind: RemoteTargetKind,
                            name: String = "target",
                            uniqueId: String? = nil) -> RemoteTarget {
        RemoteTarget(
            id: RemoteTargetID(rawValue: id),
            name: name,
            kind: kind,
            availability: .available,
            width: 1,
            height: 1,
            densityDpi: 1,
            rotation: 0,
            uniqueId: uniqueId ?? "local:\(id)"
        )
    }
}
