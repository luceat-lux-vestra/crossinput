# ADR-0017: Android-Owned Return Boundary Authority

> Status: proposed for issue #145 implementation

## Context

The DeX AUTO pointer path uses a system-routed relative UHID mouse so Android's
real InputReader pointer sprite follows the injected device. The historical
handoff policy accumulated relative HID/requested deltas on macOS and treated
that virtual distance as if it were Android screen-space travel.

Issue #145 physical evidence disproved that invariant. In one correlated run
macOS emitted `boundaryCrossed` while the SurfaceFlinger Sprite was still about
550 px inside the 1920 px DeX viewport. A separate bounded campaign proved that
the target-layer Sprite is observable after InputReader/acceleration, that direct
Binder `--hwclayers` sampling is materially cheaper than host `adb shell
dumpsys`, and that a real edge clamp is distinguishable from interior motion:
the affected device produced an 8-sample final plateau at x=1916, versus a
longest interior repeat of one sample, followed by 114 px of reverse recovery.

## Decision

For system-routed UHID desktop control, Android owns return-boundary authority.

macOS may use movement direction as **intent**, but it must not infer actual DeX
screen position from relative HID/requested deltas.

Control acquisition becomes two-stage:

1. host edge detection enters `edgeArmed` while macOS input remains local;
2. macOS sends additive CXI v1 `BOUNDARY_WATCH_START` with a unique Control
   token, selected target, and remote return edge;
3. the helper validates target/backend/oracle readiness;
4. only a matching `BOUNDARY_WATCH_READY` allows `edgeArmed -> remoteActive`
   and suppression installation.

A preparation failure or stale response remains local.

For explicit-display InputManager targets the helper reports
`DELIVERED_COORDINATES`; the existing delivered-coordinate policy remains
authoritative. For system-routed UHID desktop targets the helper reports
`COMPOSITOR`; normal return is driven only by a validated asynchronous
`BOUNDARY_REACHED` event.

The compositor watcher:

- is isolated behind a runtime-detected Android adapter;
- filters Sprite observations by the selected target's dynamic layerStack;
- polls only while fresh return-direction pointer intent exists;
- never blocks semantic pointer delivery;
- counts a plateau sample only when new return-direction input arrived since the
  previous sample;
- resets on inward movement;
- emits at most one boundary event per Control token; and
- fails closed on target/backend change, parser ambiguity, Binder/dump failure,
  or stale lifecycle state.

Runtime watcher loss while remote control is active causes immediate local
return. Local return never waits for remote STOP/cleanup.

## Alternatives rejected

### Tune returnHysteresis or scale relative UHID deltas

Rejected. The underlying coordinate invariant is false after Android pointer
acceleration/clamping, so threshold tuning cannot make it authoritative.

### Poll SurfaceFlinger synchronously for every pointer request

Rejected. Direct Binder samples measured roughly 26 ms p50 on the affected
device. Synchronous use would add unacceptable input-path latency.

### Host-side adb dumpsys polling

Rejected for production. The bounded campaign measured roughly 100 ms p50 and
incurs host/ADB/shell overhead.

### Absolute UHID mouse / synthetic cursor alignment / VirtualMouse

Rejected by earlier #145 capability work: they do not preserve the current
native DeX mouse path or cannot target the existing DeX display without broader
privilege/semantic changes.

## Consequences

- CXI v1 gains additive capability/messages; protocol fixtures and both codecs
  are authoritative.
- `EdgeSwitchStateMachine` no longer owns UHID desktop screen-distance
  estimation.
- Control preparation has a remote asynchronous phase while host input remains
  local.
- helper target/backend lifecycle now invalidates boundary-watch state.
- exact-final-HEAD physical verification is required before merge.
- SurfaceFlinger text format remains a runtime-detected non-SDK dependency; any
  parse/access loss returns local instead of falling back to guessed distance.

## Validation

Required implementation proof:

- codec/fixture parity in Swift/Kotlin;
- stale Session/Target/Control-token events cannot return a replacement Control;
- preparation failure never installs suppression;
- pointer delivery remains non-blocking while the watcher samples;
- UHID -> InputManager failover invalidates compositor authority;
- inward movement resets a plateau candidate;
- runtime oracle failure returns local;
- exact final PR HEAD reproduces full DeX edge access and returns only at the
  visible boundary with acceptable perceived latency.

## Revisit conditions

Revisit if Android exposes a stable, lower-cost post-InputReader cursor-position
API available to the shell/app_process model, or if the product stops using the
system-routed UHID native cursor path.
