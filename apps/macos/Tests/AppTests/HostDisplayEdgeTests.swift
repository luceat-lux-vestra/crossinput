import XCTest
@testable import App
import EdgeSwitch

final class HostDisplayEdgeTests: XCTestCase {
    func testCatalogPublishesEveryHostDisplayWithPersistedEdge() {
        let snapshots = [
            HostDisplaySnapshot(id: 11, name: "Studio Display", width: 2560, height: 1440),
            HostDisplaySnapshot(id: 42, name: "Built-in Display", width: 1728, height: 1117),
        ]

        let options = HostDisplayEdgeCatalog.options(from: snapshots) { displayID in
            displayID == 11 ? "right" : nil
        }

        XCTAssertEqual(options.map(\.id), [11, 42])
        XCTAssertEqual(options.map(\.edge), [.right, nil])
        XCTAssertEqual(options.map(\.label), [
            "Studio Display (2560×1440)",
            "Built-in Display (1728×1117)",
        ])
    }

    func testCatalogRejectsUnknownPersistedEdge() {
        let snapshots = [
            HostDisplaySnapshot(id: 7, name: "Display", width: 1920, height: 1080),
        ]

        let options = HostDisplayEdgeCatalog.options(from: snapshots) { _ in "diagonal" }

        XCTAssertEqual(options.first?.edge, nil)
    }
}
