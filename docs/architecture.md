# CrossInput Architecture

> Status: **Architecture Leap target model proposed by ADR-0016, 2026-09-13.**
>
> [Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> is the authority for sequencing. [ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md)
> is the normative ownership/concurrency decision for #102. This document is the
> implementation-facing overview. Pre-Leap classes/modules/queues/generations and
> diff size are not architectural constraints.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary use case while the built-in phone display remains a supported
secondary target on the same connected Android device.

## Architecture authority

Preserve validated user-visible behavior, device/protocol facts, safety
invariants, reproducible physical evidence, and intentional product scope.
Do not preserve internal abstractions merely to reduce the diff.

The Leap hierarchy remains:

```text
#101 Architecture Leap
├── #114 architecture — target ownership, concurrency, semantic boundaries
├── #115 host         — macOS capability/capture/suppression/control ownership
├── #116 remote       — delivery/Android helper/protocol/backend boundaries
├── #117 app          — composition and presentation ownership
└── #118 quality      — adversarial verification/physical acceptance/legacy purge
```

## Product topology

```text
macOS host
  -> capture + local/remote handoff
  -> platform-neutral semantic input
  -> CXI v1 remote adapter
  -> ADB / app_process transport
  -> Android helper
  -> backend/system routing
```

## Non-negotiable invariants

1. **Local safety** — macOS control is never permanently trapped; local return
   never waits for Android, actor scheduling, or the main thread.
2. **No cross-Control delivery** — stale Control A work cannot reach Control B.
3. **No cross-Session retargeting** — Session A work cannot be redirected to B.
4. **No cross-Target retargeting** — target A ordinary input cannot become B
   input after route mutation.
5. **Held-state safety** — persistent state is cleaned in its old context or the
   Session is treated as untrustworthy.
6. **One suppression owner** — at most one valid SuppressionLease consumes host
   input.
7. **Bounded capture path** — event callbacks remain synchronous/bounded.
8. **Persistent transitions are ordered and semantically classified** — they are
   never silently lost, reordered, or assumed applied from bytes-written alone.
9. **Platform boundaries** — host domain is not Android/CXI/backend-shaped.
10. **Routing honesty** — selected target context does not imply every backend
    explicitly routes to that display.
11. **Payload-safe diagnostics** — no raw input/HID/clipboard payloads in normal
    diagnostics.

## Authoritative lifecycles

### Capability
Owns macOS permission/capability readiness. Loss fails Control local but does not
by itself fail a healthy Session.

### Host capture
Owns CGEventTap/raw observation. Capture and suppression are different lifetimes.

Conceptual split:

- `InputCapabilityController`
- `MacEventTap`
- `MacInputTranslator`
- `EdgeDetector`
- `HostSuppressionController`

### Session
One immutable **SessionHandle** represents one concrete Android/helper/CXI
connection:

```text
open -> closing -> closed
```

Reconnect creates a new handle; old work can reach only the old one. Mutable
`SessionReference` retargeting is removed.

### Target
A confirmed selection creates one immutable **TargetLease** inside exactly one
Session. CXI v1 `SELECT_DISPLAY` mutates helper-global state, so selection is an
ordered remote-state barrier.

### Control
One **ControlLease** represents one remote-ownership period and captures:

- exact SessionHandle;
- exact TargetLease;
- SuppressionLease;
- synchronous InputIngress; and
- asynchronous DeliveryWorker.

Late old callbacks cannot become valid for a replacement ControlLease.

### Delivery
One worker/closing context exists per ControlLease. It is never rebound and owns
ordered semantic delivery, backpressure, semantic outcomes, the confirmed-held
ledger, and terminal cleanup coordination.

### App / presentation
App/UI composes owners and projects state. It does not secretly own Session,
Target, Control, capture, TCC, or delivery lifetimes. `AppModel` is not a
compatibility requirement.

## Runtime data path

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator
  -> ControlLease.InputIngress
  -> DeliveryWorker
  -> RemoteCommandLane
  -> CXI v1 adapter
  -> Android helper
  -> backend/system routing
```

The event callback never waits for remote acknowledgement.

## Fail-closed Control acquisition

1. verify capability + capture;
2. snapshot exact SessionHandle + TargetLease;
3. create bound InputIngress + DeliveryWorker;
4. prepare ControlLease/local-return gate;
5. atomically install SuppressionLease + exact ingress; and
6. only then publish remote ownership.

Failure at any step closes partial resources and remains local. Host suppression
never consumes input without a valid bounded ingress and synchronous return path.

## Synchronous local-return gate

The first return trigger wins:

```text
mark Control closing/closed
  -> close InputIngress
  -> synchronously clear/release active SuppressionLease + ingress slot
  -> following host events pass locally
  -> asynchronously reconcile/cancel/cleanup/diagnose
```

No transport write, actor await, main-thread dispatch, helper response, or remote
cleanup exists inside the local safety boundary.

A stale callback racing closure cannot reopen the ingress. If a non-droppable
event was not remotely admitted, the host boundary fails local rather than
newly swallowing that event. External takeover likewise passes its triggering
event unchanged after suppression release.

Lock ordering is explicit; no arbitrary callback runs under the safety lock.
Deinit is defense in depth only.

## Host suppression and #96

Only HostSuppressionController may consume host input or perform accepted P0
cursor confinement.

#96 remains authoritative: retain P0 confinement, keep the native cursor visible,
accept the cursor-presentation limitation, and do not introduce private
SkyLight/CGS, synthetic click/focus stealing, pointer-jump, custom-cursor, or
equivalent workaround permutations without materially new evidence.

## HandoffPolicy

Handoff becomes a pure policy: facts in, acquire/remain/return decisions out.
ControlCoordinator serializes it. The policy owns no task, queue, lock,
transport, event tap, or callback sequencing.

Validated #45/#37 behavior remains: requested-intent return credit at Android
clamp, accepted inward movement credit, first-event guard, and hysteresis.

## InputIngress / backpressure

InputIngress is a small lock-protected synchronous boundary with no remote I/O or
wait. One ordered semantic lane covers pointer and keyboard input.

| Event class | Coalesce | Shed | Ordering |
| --- | --- | --- | --- |
| relative motion | adjacent only | bounded overload | additive |
| scroll | adjacent only | when additive semantics preserved | additive |
| pointer button down/up | never | never silently | strict |
| key down/up | never | never silently | strict |
| key repeat | no by default | only after proof | strict by default |
| cleanup/release | no lossy treatment | never silently | terminal/strong |

Non-droppable admission failure invokes local return.

## Delivery outcome ownership

Persistent input correctness is semantic, not transport-write-based.

A key/button transition is either:

1. queued and not issued — safe to cancel before wire execution;
2. issued/may have crossed the wire — old Session/closing context owns its
   correlation until semantic resolution or bounded ambiguity timeout; or
3. resolved — `applied`, proven `notApplied`, or `ambiguous`.

Once issued, ordinary Control closure does **not** abandon result accounting.
Late positive results update only the old closing ledger. They can never mutate a
replacement Control/Session ledger.

Generic Task cancellation cannot erase an issued persistent transition. If its
outcome never becomes certain, Session trust is lost for new Target/Control use.

A generic backend `failed` status is not automatically `notApplied`. It is
`notApplied` only when the backend contract proves no semantic application;
otherwise it is ambiguous.

## RemoteCommandLane

Each SessionHandle owns an explicit stateful **RemoteCommandLane** because Swift
actors may reenter across `await`.

It orders target selection, target-dependent pointer input, keyboard under its
honest routing scope, persistent cleanup, and reset/shutdown.

Baseline: one stateful command reaches semantic completion before the next.
Future pipelining requires proof that write/outcome order and target/cleanup/
shutdown barriers cannot be crossed.

Target-dependent commands validate TargetLease at admission and again before wire
execution.

## Target A -> B barrier

```text
local-return Control A
  -> close ordinary A ingress
  -> cancel queued ordinary A work not yet issued
  -> resolve every already-issued persistent A transition
  -> if any remains ambiguous: invalidate/reconnect Session
  -> while A route/lease are still valid:
       terminal cleanup fence for confirmed held state
  -> bounded cleanup result
  -> if trustworthy:
       invalidate TargetLease A
       ordered SELECT_DISPLAY(B)
       helper confirms B
       publish TargetLease B
       allow Control B
  -> otherwise:
       invalidate/reconnect Session instead of reusing it as clean
```

Terminal cleanup is a privileged closing operation and admits no new user input.
Additive motion/scroll may be discarded when no persistent ambiguity exists.

## Routing honesty

Conceptually the remote adapter distinguishes:

- `selectedTarget(TargetLease)`; and
- `sessionRouted(SessionHandle)`.

System-routed UHID must not be described as explicitly targeting an arbitrary
Android display. Keyboard phone-vs-DeX routing remains an evidence question
(#92).

## Persistent keyboard outcomes / #141

Current `KEY_EVENT` fire-and-forget delivery is not the final architecture.
#141 adds an additive CXI v1 semantic outcome contract or equivalent proof.

Held-key state changes only on `applied`. Explicit failure may mean
`notApplied` only if the backend contract proves it; otherwise it is ambiguous.
Timeout/stream loss after send is ambiguous.

Local return never waits for the result. Ambiguity feeds cleanup and Session
trust policy.

## Backend cleanup / #107

Helper teardown is defense in depth, not assumed proof.

Current UHID pointer close attempts a zero-button report, while current
InputManager pointer close only clears local mask/state. #107 must prove actual
Android cleanup semantics or implement bounded explicit release/reset while the
old route remains valid. Keyboard backends carry the same proof obligation.

## Platform-neutral semantic input

#103 finalizes exact SwiftPM target names. Dependency direction is fixed:

```text
                         App / UI
                            |
                 +----------+----------+
                 |                     |
              MacHost                Remote
                 |                     |
                 +---------+-----------+
                           |
                    CrossInputDomain

Remote -> CXI v1 adapter -> ADB transport
```

`CrossInputDomain` contains semantic input and pure policies only. No
CoreGraphics/AppKit/TCC, Android KEYCODE/META, UHID/InputManager, or CXI framing
belongs in that domain.

```text
Mac event
  -> MacInputTranslator
  -> SemanticInputEvent
  -> InputIngress / DeliveryWorker
  -> CXI v1 adapter
  -> helper semantic command
  -> Android backend
```

## Concurrency / blocking / cancellation

### MainActor
Composition/projection/UI only. No synchronous remote wait.

### Event-tap executor
Bounded translation, tiny lock-protected lookup/admission, local suppression and
fail-safe only. No transport I/O, actor/semaphore wait, or main-thread safety
round trip.

### ControlCoordinator
Actor or equivalent explicit serial executor for Control lifecycle and pure
handoff policy. Local return does not wait for it.

### Session / RemoteCommandLane
Owns protocol correlation and bounded async waits/timeouts for stateful remote
commands.

### DeliveryWorker
One async worker per ControlLease; no rebinding.

No target production path intentionally blocks an OS thread on remote progress.
Queued not-issued work may be cancelled. Issued persistent work keeps old
correlation/outcome ownership until resolved or classified ambiguous. Terminal
cleanup is privileged closing work, not ordinary input.

## Failure domains

| Failure | Control | Session/Target |
| --- | --- | --- |
| capability loss | local/blocked | healthy Session/Target may remain |
| event-tap failure | local/blocked | healthy Session/Target may remain |
| ordinary return | local | unchanged if remote state clean |
| non-droppable admission saturation | local | current rejected event was not remotely admitted; classify prior issued persistent state |
| additive timeout | local if required | Session may remain if trustworthy |
| proven not-applied key/button | local/fail-safe | may remain after prior held-state cleanup |
| ambiguous key/button | local immediately | cleanup; invalidate if certainty cannot be restored |
| target change/disappearance | local | reuse Session only after trustworthy old-target reconciliation/cleanup |
| helper/transport disconnect | local immediately | invalidate Session + Target |
| external takeover | local; trigger event unchanged | otherwise unchanged |

## Protocol and transport

CXI v1 remains the Leap compatibility wire. Additive v1 capabilities/results
needed for safety, including #141, are allowed. CXI v2 (#93) remains a separate
migration gate.

ADB/`app_process` remains the default production transport. Alternate transport
#94 remains separately gated.

## Migration map

| Pre-Leap structure | Direction |
| --- | --- |
| `SessionReference` | delete; immutable SessionHandle |
| `SessionController` | SessionManager/reconnect policy |
| `RemoteSession` | async concrete session + RemoteCommandLane |
| `requestBlocking()` | delete |
| `TargetSelectionController` | Target owner + TargetLease + reconciliation/cleanup/select barrier |
| `ControlHandoffController` | ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` sequence machinery | pure HandoffPolicy |
| `TransitionSequenceGate` | delete |
| monolithic `InputCapture` | split capability/capture/translation/edge/suppression |
| Android-shaped host key event | platform-neutral semantic key model |
| `InputSender` | InputIngress + DeliveryWorker/closing context |
| split pointer/keyboard queues | one ordered semantic lane |
| duplicate held-state bookkeeping | outcome-based delivery ledger |
| `AppModel` infrastructure ownership | composition + projection only |

## Verification authority

Automated tests/CI prove deterministic repository/protocol properties. They do
not replace physical evidence for macOS + Samsung behavior.

#102 itself is docs-only and creates no new runtime claim, so it needs no new
physical run. Runtime implementation slices require exact-final-HEAD targeted
physical evidence.

ADR-0016 contains the named invariants, enforcement points, and deterministic
proof matrix. Before #102 is mergeable, exact-final-HEAD review must trace at
least:

1. normal handoff/return;
2. acquisition halfway failure;
3. actor-delayed reconciliation;
4. target A -> B with queued/in-flight ordinary work;
5. target A -> B with issued/held persistent state;
6. target disappearance during reconciliation/cleanup;
7. Session replacement with queued/in-flight work;
8. capability loss;
9. event-tap failure;
10. non-droppable saturation;
11. helper key rejection while Session stays alive;
12. key/button timeout after send;
13. late positive persistent result after Control closes;
14. additive timeout;
15. external takeover;
16. watchdog/emergency return;
17. backend cleanup including InputManager pointer;
18. stale result after replacement; and
19. diagnostics payload isolation.

Any HEAD change invalidates merge-gate evidence.

## Explicit product non-goals

Unless separately approved:

- Android -> macOS pointer/keyboard input;
- Android as a macOS pointing device;
- simultaneous control of multiple Android devices;
- cloud relay/account/server infrastructure;
- root or Knox bypass;
- speculative transport/plugin frameworks; and
- CXI v2 merely to make the Leap cleaner.

## Historical architecture records

ADR-0016 supersedes ADR-0009's internal architecture-preservation/lifecycle/
concurrency migration contract but not retained product/device evidence.

See [roadmap](roadmap.md), [product definition](product.md), the [ADR index](adr/),
[ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md), and
[CXI v2 design](../protocol/v2-design.md).
