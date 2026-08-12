import CoreGraphics
import EdgeSwitch

struct HostDisplaySnapshot: Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

struct HostDisplayEdgeOption: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    var edge: ScreenEdge?

    var label: String { "\(name) (\(width)×\(height))" }
}

enum HostDisplayEdgeCatalog {
    static func options(
        from snapshots: [HostDisplaySnapshot],
        storedEdge: (CGDirectDisplayID) -> String?
    ) -> [HostDisplayEdgeOption] {
        snapshots.map { snapshot in
            HostDisplayEdgeOption(
                id: snapshot.id,
                name: snapshot.name,
                width: snapshot.width,
                height: snapshot.height,
                edge: screenEdge(from: storedEdge(snapshot.id)))
        }
    }

    static func screenEdge(from value: String?) -> ScreenEdge? {
        value.flatMap(ScreenEdge.init(rawValue:))
    }
}
