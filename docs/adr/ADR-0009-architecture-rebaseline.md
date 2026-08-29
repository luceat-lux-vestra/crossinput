# ADR-0009: Rebaseline CrossInput as a Host-to-Remote Input Bridge

> Status: **accepted; product-positioning statements superseded by ADR-0013**
> Date: 2026-08-10
>
> ADR-0013 supersedes this ADR only where it defines Samsung DeX as incidental
> to the product. The architecture decisions on lifecycle separation,
> transport/backend boundaries, normalized targets, and behavior-preserving
> migration remain accepted.

## Context

CrossInput's verified implementation began as a DeX-focused proof of input
delivery. The technology is now broader: the macOS host captures input, the
Android helper discovers a target display, and the selected target receives
semantic pointer and keyboard input. Existing code and documentation still
mix product terminology, connection lifecycle, handoff lifecycle, raw Android
display metadata, and backend details.

The next feature work should not destabilize the verified v0.1.x paths. The
rebaseline therefore needs to clarify responsibility boundaries while
preserving behavior and CXI v1 compatibility.

## Decision

1. CrossInput's core domain is an input bridge, not Samsung DeX. **Superseded for product positioning by ADR-0013; retained as historical context for the architecture rebaseline.**
2. The current supported topology is one-way macOS → Android.
3. DeX is one kind of Android remote target/use case. **Superseded for product positioning by ADR-0013, which makes DeX the primary use case while retaining other selectable displays.**
4. Transport and input backends are isolated from application/domain logic.
5. Session lifecycle, control-handoff lifecycle, and target lifecycle are separate concepts and must not grow into one state machine.
6. CXI should move toward platform-neutral semantic input and opaque target identifiers in a future v2; v1 remains the compatibility wire now.
7. The verified ADB/app_process, UHID, and InputManager implementations remain in place.
8. Migration is behavior-preserving and limited to real change axes: transport, input backend, remote target, control lifecycle, and session lifecycle.

## Boundary contract

```text
Host input
  → Control handoff
    → Remote session
      → CXI v1
        → Android target discovery / input dispatcher
          → selected injection backend
```

Edge-switch code must not call ADB. Session controllers must not know UHID
descriptors. macOS application code must not interpret Android display flags or
own HID report construction. The helper owns Android-specific normalization and
backend choice.

## Alternatives considered

- **Keep DeX as the core domain**: rejected at the time because phone-screen control and future Android targets already existed. ADR-0013 later refined this into a DeX-first, Android-capable product position without making the architecture DeX-only.
- **Rewrite the repository around Clean Architecture or an event bus**: rejected because it adds structure without a current change axis and raises the risk of breaking pointer safety.
- **Replace CXI v1 during the refactor**: rejected because protocol migration and behavior-preserving architecture work have different risk profiles.
- **Abstract every class behind a protocol/interface**: rejected; only the transport, target normalization, handoff, and injection backend seams are justified by current or evidenced change.

## Consequences

Positive:

- Session failure, target disappearance, and control return can be handled independently.
- ADB, Android hidden APIs, UHID, and HID reports remain isolated implementation details.
- Existing verified behavior and v1 fixtures remain the regression baseline.

Negative:

- The v1 display record remains platform-leaky until a compatible protocol evolution is available.
- Some current source types are migration seams and may retain compatibility names temporarily.
- Real-device verification is still required after the refactor; green local tests are insufficient for completion.

## Implementation status

The rebaseline boundaries are implemented in the current v1 code:

- `SessionController` is the single owner of `SessionState` transitions and stale `RemoteSession` replacement. A connecting session remains private until HELLO and capability negotiation succeed; reconnect exhaustion tears down the transport and enters a terminal failed state.
- `EdgeSwitchStateMachine` contains only control handoff and pointer-safety states. External failures arrive through `forceReturn(.remoteUnavailable)`.
- `ControlHandoffController` combines capture with handoff safety, while `InputSender` sends semantic pointer and keyboard messages.
- `AdbTransport` owns ADB process/channel startup; `RemoteSession` owns CXI correlation, timeouts, and event dispatch.
- The helper's `PointerDispatcher` owns pointer backend selection. The current AUTO policy, refined after this ADR, prefers system-routed UHID for desktop sink candidates such as DeX so the visible pointer follows InputReader; non-desktop targets use `InputManagerPointerInjector` explicit-display routing, and desktop UHID failure may fall back to InputManager. See ADR-0010 and `docs/architecture.md` for the current policy.
- `TargetSelectionController` publishes a selection only after a matching `DISPLAY_CHANGED` response and ignores stale selection responses. Initial refresh awaits that confirmation before the application enables capture.
- `SessionController` ignores events as well as disconnect callbacks from a replaced `RemoteSession`.
- `HELLO_ACK` advertises additive v1 capabilities. The current app rejects an old helper before input begins when required semantic pointer capabilities are unavailable. The packaged app does not yet auto-deploy a matching helper.
- `InputSender` bounds admission and coalesces adjacent movement and scroll into semantic delivery batches (see ADR-0011), keeps keyboard and release paths independent, and cancels stale batches on local return. External-control takeover also drains queued key releases and releases accepted held pointer buttons without delaying local pointer recovery.
- `DisplayDiscovery` merges the public display list with optionally detected system-visible display IDs so a Samsung DeX virtual display is selectable; the hidden API is isolated behind the existing runtime-reflection adapter and falls back to the public list when unavailable.
- `PointerDispatcher` serializes target selection, metric refresh, injection, and shutdown across the helper stdin and display-callback threads.

This implementation status is separate from device verification status below.

## Validation

- Documentation baseline: `product.md`, `architecture.md`, `roadmap.md`, and `protocol/v2-design.md`.
- Existing CXI v1 command fixtures remain unchanged; additive semantic pointer responses have their own fixtures/tests.
- A legacy two-byte `HELLO_ACK` remains decodable for v1 compatibility tooling, but the current application rejects it when required capabilities are missing.
- macOS and Android build/test gates must pass after each code slice.
- On-device regression evidence must cover connection, pointer, keyboard, target selection, display disappearance/reappearance, backend paths, and emergency recovery before device-dependent behavior is declared verified. Display-removal propagation remains tracked in issue #17.
- The post-rebase source audit and its separate physical-verification status are recorded in [`architecture-rebaseline-2026-08-13.md`](../research/architecture-rebaseline-2026-08-13.md).

## Revisit conditions

Revisit the retained architecture decisions when a production need requires a second transport, a second host/target family, bidirectional input, or a CXI v2 migration. Such a change requires its own ADR or a superseding ADR and must not be smuggled into a routine stabilization refactor.

For current product scope and future-extension policy, see ADR-0013.
