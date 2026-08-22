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

    static func edge(
        at location: CGPoint,
        in frame: CGRect,
        threshold: CGFloat
    ) -> ScreenEdge? {
        if location.x <= frame.minX + threshold { return .left }
        if location.x >= frame.maxX - threshold { return .right }
        // Quartz global display coordinates use the upper-left origin:
        // minY is the physical top edge and maxY is the physical bottom edge.
        if location.y <= frame.minY + threshold { return .top }
        if location.y >= frame.maxY - threshold { return .bottom }
        return nil
    }

    /// Returns the cursor position used while holding or restoring a pointer
    /// at an edge. This keeps the warp geometry in the same Quartz coordinate
    /// convention as edge detection.
    static func pointerPosition(
        for edge: ScreenEdge,
        in frame: CGRect,
        at location: CGPoint,
        threshold: CGFloat
    ) -> CGPoint {
        switch edge {
        case .left:   return CGPoint(x: frame.minX + threshold, y: location.y)
        case .right:  return CGPoint(x: frame.maxX - threshold, y: location.y)
        case .top:    return CGPoint(x: location.x, y: frame.minY + threshold)
        case .bottom: return CGPoint(x: location.x, y: frame.maxY - threshold)
        }
    }
}
