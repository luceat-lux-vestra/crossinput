import CoreGraphics
import EdgeSwitch

/// The display geometry and edge configuration observed for one pointer event.
///
/// This is deliberately a value type so edge detection can only use the
/// display resolved for the current event. A previously observed display is
/// never a valid fallback for handoff decisions.
struct DisplayEdgeConfiguration: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let configuredEdge: ScreenEdge?
}

struct DisplayEdgeCandidate: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let edge: ScreenEdge
}

enum DisplayEdgeResolver {
    static func candidate(
        at location: CGPoint,
        displays: [DisplayEdgeConfiguration],
        threshold: CGFloat
    ) -> DisplayEdgeCandidate? {
        guard let display = displays.first(where: { $0.frame.contains(location) }),
              let configuredEdge = display.configuredEdge,
              let edge = edge(at: location, in: display.frame, threshold: threshold),
              edge == configuredEdge else {
            return nil
        }
        return DisplayEdgeCandidate(displayID: display.displayID, edge: edge)
    }

    private static func edge(
        at location: CGPoint,
        in frame: CGRect,
        threshold: CGFloat
    ) -> ScreenEdge? {
        if location.x <= frame.minX + threshold { return .left }
        if location.x >= frame.maxX - threshold { return .right }
        if location.y <= frame.minY + threshold { return .bottom }
        if location.y >= frame.maxY - threshold { return .top }
        return nil
    }
}
