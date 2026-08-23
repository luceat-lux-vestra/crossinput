import XCTest
@testable import EdgeSwitch

final class TransitionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StateTransition] = []

    var transitions: [StateTransition] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ transition: StateTransition) {
        lock.lock(); defer { lock.unlock() }
        storage.append(transition)
    }
}

final class EdgeSwitchStateMachineTests: XCTestCase {
    private func makeRemoteActive(edge: ScreenEdge) -> EdgeSwitchStateMachine {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        XCTAssertEqual(machine.state, .localActive)
        machine.pointerAtEdge(edge)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.flushCallbacks()
        return machine
    }

    func testHandoffStateContainsOnlyControlStates() {
        let states: Set<HandoffState> = [
            .disabled, .localActive, .edgeArmed, .remoteActive, .returning,
        ]
        XCTAssertEqual(states.count, 5)
    }

    func testActivationDoesNotModelSessionLifecycle() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.activate()
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(collector.transitions.map(\.reason), [.activation])
    }

    func testMovementIntoAndroidNeverReturnsOnAllEdges() {
        let movements: [(ScreenEdge, Int32, Int32)] = [
            (.left, -500, 0), (.right, 500, 0), (.top, 0, -500), (.bottom, 0, 500),
        ]
        for (edge, dx, dy) in movements {
            let machine = makeRemoteActive(edge: edge)
            machine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
            machine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
            XCTAssertEqual(machine.state, .remoteActive, "edge \(edge)")
        }
    }

    func testReturnRequiresBoundaryAndHysteresisOnAllEdges() {
        let cases: [(ScreenEdge, Int32, Int32, Int32, Int32)] = [
            (.left, -300, 0, 300, 0),
            (.right, 300, 0, -300, 0),
            (.top, 0, -300, 0, 300),
            (.bottom, 0, 300, 0, -300),
        ]
        for (edge, intoX, intoY, backX, backY) in cases {
            let machine = makeRemoteActive(edge: edge)
            machine.pointerMoved(dx: CGFloat(intoX), dy: CGFloat(intoY))
            machine.pointerMoved(dx: CGFloat(backX), dy: CGFloat(backY))
            machine.pointerMoved(dx: CGFloat(backX > 0 ? 59 : backX < 0 ? -59 : 0),
                                 dy: CGFloat(backY > 0 ? 59 : backY < 0 ? -59 : 0))
            XCTAssertEqual(machine.state, .remoteActive, "edge \(edge) before hysteresis")
            machine.pointerMoved(dx: CGFloat(backX > 0 ? 1 : backX < 0 ? -1 : 0),
                                 dy: CGFloat(backY > 0 ? 1 : backY < 0 ? -1 : 0))
            XCTAssertEqual(machine.state, .localActive, "edge \(edge) after hysteresis")
        }
    }

    func testFirstMovementNeverReturnsAndDoesNotPoisonBaseline() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testZeroDeliveredMovementDoesNotConsumeFirstEvent() {
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: 0, dy: 0)
        machine.pointerMoved(dx: 100, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 161, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Issue #45: intent-based return credit

    /// Entry event plus the fully-absorbed (requested, delivered=(0,0))
    /// pull-back direction for each edge.
    private static let issue45Cases: [(ScreenEdge, (Int32, Int32), (Int32, Int32))] = [
        (.left, (-5, 0), (40, 0)),
        (.right, (5, 0), (-40, 0)),
        (.top, (0, -5), (0, 40)),
        (.bottom, (0, 5), (0, -40)),
    ]

    func testBoundaryClampedPullBackStillReturnsOnRequestedIntent() {
        // A helper cursor pinned at its display bound reports zero accepted
        // movement for a pull-back it fully absorbed while still acknowledging
        // delivery. Crediting only accepted movement pinned the virtual axis
        // at the boundary forever; requested intent must accumulate and fire
        // the boundary-crossed return.
        for (edge, entry, blockedPullBack) in Self.issue45Cases {
            let machine = makeRemoteActive(edge: edge)
            machine.pointerMoved(dx: CGFloat(entry.0), dy: CGFloat(entry.1)) // spends first-move exemption

            machine.pointerMoved(requestedDx: CGFloat(blockedPullBack.0),
                                 requestedDy: CGFloat(blockedPullBack.1),
                                 deliveredDx: 0, deliveredDy: 0)
            XCTAssertEqual(machine.state, .remoteActive, "edge \(edge) returned before hysteresis")

            machine.pointerMoved(requestedDx: CGFloat(blockedPullBack.0),
                                 requestedDy: CGFloat(blockedPullBack.1),
                                 deliveredDx: 0, deliveredDy: 0)
            XCTAssertEqual(machine.state, .localActive, "edge \(edge) did not return on absorbed intent")
        }
    }

    func testPinnedInwardPushDoesNotAdvanceVirtualPosition() {
        // Inward movement credited only what the bound-clamped helper accepted:
        // repeated fully-absorbed inward pushes must not inflate the position.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 10, dy: 0) // spends first-move exemption

        for _ in 0..<100 {
            machine.pointerMoved(requestedDx: 500, requestedDy: 0, deliveredDx: 0, deliveredDy: 0)
        }
        XCTAssertEqual(machine.state, .remoteActive)

        // The position sits near its entry offset, so a sub-hysteresis
        // pull-back stays remote and one more crosses the threshold. Crediting
        // the +500 requests would have inflated the position enough to swallow
        // both pull-backs and stay remoteActive.
        machine.pointerMoved(requestedDx: -59, requestedDy: 0, deliveredDx: -59, deliveredDy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(requestedDx: -100, requestedDy: 0, deliveredDx: -100, deliveredDy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testPartiallyAbsorbedPullBackCreditsFullRequestedIntent() {
        // What the wall eats cannot slow the user's exit: partial absorption
        // in the return direction still credits the whole requested delta.
        // Delivered-only crediting would leave the position at -10 (no return).
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 10, dy: 0) // position 10

        machine.pointerMoved(requestedDx: -80, requestedDy: 0,
                             deliveredDx: -20, deliveredDy: 0) // credit -80 -> -70 <= -60
        XCTAssertEqual(machine.state, .localActive)
    }

    func testFirstEventBlockedPullBackIsExemptThenAccumulatesOnIntent() {
        // The issue #37 exemption also covers an intent-credited blocked
        // pull-back: the very first event never returns, later ones do.
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(requestedDx: 300, requestedDy: 0, deliveredDx: 0, deliveredDy: 0)
        XCTAssertEqual(machine.state, .remoteActive)

        machine.pointerMoved(requestedDx: 61, requestedDy: 0, deliveredDx: 0, deliveredDy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testZeroRequestedAndDeliveredDoesNotConsumeFirstEvent() {
        let machine = makeRemoteActive(edge: .top)
        machine.pointerMoved(requestedDx: 0, requestedDy: 0, deliveredDx: 0, deliveredDy: 0)
        machine.pointerMoved(dx: 0, dy: 100)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 0, dy: 161)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testRemoteUnavailableForcesSafeLocalReturn() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.forceReturn(reason: .remoteUnavailable)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(collector.transitions.map(\.reason), [.remoteUnavailable, .remoteUnavailable])
    }

    func testExternalControlTakeoverForcesSafeLocalReturn() {
        let machine = makeRemoteActive(edge: .right)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.forceReturn(reason: .externalControlTakeover)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(
            collector.transitions.map(\.reason),
            [.externalControlTakeover, .externalControlTakeover])
    }

    func testRemoteUnavailableWhileAlreadyLocalDoesNotInventSessionState() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.forceReturn(reason: .remoteUnavailable)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
    }

    func testEmergencyReturnIsIndependentOfSessionLifecycle() {
        let machine = makeRemoteActive(edge: .right)
        machine.emergencyReturn()
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
    }

    func testStaleTransitionIsRejected() {
        var gate = TransitionSequenceGate()
        let current = StateTransition(sequence: 11, from: .remoteActive,
                                      to: .returning, reason: .remoteUnavailable)
        let stale = StateTransition(sequence: 10, from: .edgeArmed,
                                    to: .remoteActive, reason: .edgeEntered)

        XCTAssertTrue(gate.shouldApply(current))
        XCTAssertFalse(gate.shouldApply(stale))
        XCTAssertEqual(gate.lastAppliedSequence, 11)
    }

    func testIssue37MovementAccountingUsesOnlyDeliveredHidReports() {
        let machine = makeRemoteActive(edge: .left)
        let movement = HIDReportSplitter.normalizeForHID(dx: -300, dy: 0)
        for report in movement.reports {
            machine.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(movement.deliveredDx, -300)
        XCTAssertEqual(machine.state, .remoteActive)

        // A failed report contributes nothing to the virtual position.
        let failed = HIDReportSplitter.normalizeForHID(dx: 0, dy: 0)
        XCTAssertEqual(failed.deliveredDx, 0)
        XCTAssertEqual(failed.deliveredDy, 0)
    }

    func testOneHundredEdgeHandoffCyclesStaySafe() {
        let edges: [ScreenEdge] = [.left, .right, .top, .bottom]

        for cycle in 0..<100 {
            let machine = EdgeSwitchStateMachine()
            let edge = edges[cycle % edges.count]
            let intoAndroid: (Int32, Int32)
            let backToMac: (Int32, Int32)

            switch edge {
            case .left: intoAndroid = (-120, 0); backToMac = (181, 0)
            case .right: intoAndroid = (120, 0); backToMac = (-181, 0)
            case .top: intoAndroid = (0, -120); backToMac = (0, 181)
            case .bottom: intoAndroid = (0, 120); backToMac = (0, -181)
            }

            machine.activate()
            machine.pointerAtEdge(edge)
            XCTAssertEqual(machine.state, .remoteActive, "cycle \(cycle) entered \(edge)")

            // The first event is the post-capture event and must not return.
            machine.pointerMoved(dx: CGFloat(intoAndroid.0), dy: CGFloat(intoAndroid.1))
            XCTAssertEqual(machine.state, .remoteActive, "cycle \(cycle) returned on entry")

            // Cross the boundary and hysteresis in the direction of macOS.
            machine.pointerMoved(dx: CGFloat(backToMac.0), dy: CGFloat(backToMac.1))
            XCTAssertEqual(machine.state, .localActive, "cycle \(cycle) did not return safely")

            machine.deactivate()
            XCTAssertEqual(machine.state, .disabled, "cycle \(cycle) did not deactivate")
        }
    }

    func testCallbackSequencesRemainMonotonicAcrossConcurrentCommands() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        let group = DispatchGroup()
        for index in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) {
                    machine.activate()
                } else {
                    machine.forceReturn(reason: .remoteUnavailable)
                }
                group.leave()
            }
        }
        group.wait()
        machine.flushCallbacks()
        let sequences = collector.transitions.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
    }
}
