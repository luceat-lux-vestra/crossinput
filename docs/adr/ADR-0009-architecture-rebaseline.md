# ADR-0009: Rebaseline CrossInput as a Host-to-Remote Input Bridge

> Status: **accepted**
> Date: 2026-08-10

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

1. CrossInput's core domain is an input bridge, not Samsung DeX.
2. The current supported topology is one-way macOS → Android.
3. DeX is one kind of Android remote target/use case.
4. Transport and input backends are isolated from application/domain logic.
5. Session lifecycle, control-handoff lifecycle, and target lifecycle are
   separate concepts and must not grow into one state machine.
6. CXI should move toward platform-neutral semantic input and opaque target
   identifiers in a future v2; v1 remains the compatibility wire now.
7. The verified ADB/app_process, UHID, and InputManager implementations remain
   in place.
8. Migration is behavior-preserving and limited to real change axes:
   transport, input backend, remote target, control lifecycle, and session
   lifecycle.

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

- **Keep DeX as the core domain**: rejected because phone-screen control and
  future Android targets already exist, and it would make Samsung-specific
  terminology leak into unrelated code.
- **Rewrite the repository around Clean Architecture or an event bus**:
  rejected because it adds structure without a current change axis and raises
  the risk of breaking pointer safety.
- **Replace CXI v1 during the refactor**: rejected because protocol migration
  and behavior-preserving architecture work have different risk profiles.
- **Abstract every class behind a protocol/interface**: rejected; only the
  transport, target normalization, handoff, and injection backend seams are
  justified by current or evidenced change.

## Consequences

Positive:

- Product scope and future work can be discussed without conflating DeX with
  the bridge.
- Session failure, target disappearance, and control return can be handled
  independently.
- ADB, Android hidden APIs, UHID, and HID reports remain replaceable details.
- Existing verified behavior and v1 fixtures remain the regression baseline.

Negative:

- The v1 display record remains platform-leaky until a compatible protocol
  evolution is available.
- Some current source types are migration seams and may retain compatibility
  names temporarily.
- Real-device verification is still required after the refactor; green local
  tests are insufficient for completion.

## Implementation status

The rebaseline boundaries are implemented in the current v1 code:

- `SessionController` is the single owner of `SessionState` transitions and
  stale `RemoteSession` replacement.
- `EdgeSwitchStateMachine` contains only control handoff and pointer-safety
  states. External failures arrive through `forceReturn(.remoteUnavailable)`.
- `ControlHandoffController` combines capture with handoff safety, while
  `InputSender` sends semantic pointer and keyboard messages.
- `AdbTransport` owns ADB process/channel startup; `RemoteSession` owns CXI
  correlation, timeouts, and event dispatch.
- The helper's `PointerDispatcher` selects `UhidPointerInjector` first and
  fails over to `InputManagerPointerInjector`. v1 raw HID handlers remain only
  for compatibility and are not used by the normal Ampersand pointer path.
- `TargetSelectionController` publishes a selection only after a matching
  `DISPLAY_CHANGED` response and ignores stale selection responses.

This implementation status is separate from device verification status below.

## Validation

- Documentation baseline: `product.md`, `architecture.md`, `roadmap.md`, and
  `protocol/v2-design.md`.
- Existing CXI v1 command fixtures remain unchanged; the new v1
  `POINTER_RESULT` response has its own golden fixture and protocol test.
- macOS and Android build/test gates must pass after each code slice.
- On-device regression evidence must cover connection, pointer, keyboard,
  target selection, display disappearance/reappearance, backend paths, and
  emergency recovery before this ADR can be marked fully verified.

## Revisit conditions

Revisit this decision when a production need requires a second transport, a
second host/target family, bidirectional input, or a CXI v2 migration. Such a
change requires its own ADR or a superseding ADR and must not be smuggled into
a routine stabilization refactor.
