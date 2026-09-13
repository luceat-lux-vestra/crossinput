# CrossInput Architecture

> Status: **Architecture Leap target model proposed by ADR-0016, 2026-09-13.**
>
> [Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> controls sequencing. [ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md)
> is the normative ownership/concurrency decision for #102. This document is the
> implementation-facing overview.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary use case while the built-in phone display remains a supported
secondary target on the same connected Android device.

## Architecture authority

Preserve:

- validated user-visible behavior;
- device/protocol facts;
- safety invariants;
- reproducible evidence; and
- intentional product scope.

Do **not** preserve pre-Leap classes, mutable references, queue layout,
generation counters, or tests merely to minimize the diff. Architecture Leap
#101 / ADR-0016 authorize broad internal replacement when it improves ownership,
lifecycle correctness, concurrency safety, or testability.

Large changes still ship as coherent independently reviewable slices. Rewrite
freedom is not permission to mix unrelated product/protocol/transport changes.

```text
#101 Architecture Leap
├── #114 architecture — ownership, concurrency, semantic boundaries
├── #115 host         — capability/capture/suppression/control ownership
├── #116 remote       — delivery/helper/protocol/backend boundaries
├── #117 app          — composition/presentation ownership
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

The topology is a product/device fact. It does not freeze current controller or
module names.

## Non-negotiable invariants

1. **Local safety** — macOS control cannot remain trapped; local return never
   waits for Android, an actor, or the main thread.
2. **No cross-Control delivery** — stale Control A work cannot reach Control B.
3. **No cross-Session retargeting** — Session A work cannot be redirected to B.
4. **No cross-Target retargeting** — target A ordinary input cannot become B
   input after route mutation.
5. **Held-state safety** — persistent remote state is cleaned in its old context
   or remote Control remains blocked until a trustworthy clean state is proved.
6. **One suppression owner** — at most one valid SuppressionLease consumes host
   input.
7. **Bounded capture path** — CGEventTap work remains synchronous and bounded.
8. **Persistent transitions are ordered and semantically classified** — they are
   never silently lost, reordered, or assumed applied from bytes-written alone.
9. **Platform boundaries** — CoreGraphics/AppKit/TCC stay out of remote domain
   semantics; Android/CXI/UHID/InputManager stay out of host/domain APIs.
10. **Routing honesty** — selected target context does not imply every backend
    explicitly routes to that display.
11. **Payload-safe diagnostics** — raw input/HID/clipboard payloads do not enter
    normal diagnostics.

## Authoritative lifecycles

The target architecture has six lifecycle owners. They coordinate, but they do
not collapse into a single application state machine or global epoch.

### Capability

Owns macOS permission/capability readiness. Loss blocks or returns Control local.
A healthy Android Session does not fail merely because TCC/capture capability is
unavailable.

### Host capture

Owns CGEventTap/raw observation. Capture lifetime is distinct from host
suppression lifetime.

Conceptual split:

- `InputCapabilityController`
- `MacEventTap`
- `MacInputTranslator`
- `EdgeDetector`
- `HostSuppressionController`

Exact names may change; the responsibilities must remain distinct.

### Session

One immutable **SessionHandle** represents one concrete Android/helper/CXI
connection:

```text
open -> closing -> closed
```

A replacement creates a new handle. Old work retains only the old handle; there
is no mutable `SessionReference` that can redirect it into a newer connection.

A fresh connection identity is **not** automatically a clean remote input state.
If Session A ended with ambiguous persistent key/button state, Session B cannot
become control-capable until the Session recovery/cleanliness fence proves that
Android remote state is neutral.

### Target

A successful selection creates one immutable **TargetLease** inside exactly one
SessionHandle. CXI v1 `SELECT_DISPLAY` mutates helper-global routing state, so
selection is an ordered remote-state barrier rather than presentation state.

### Control

One **ControlLease** represents one remote-ownership period. It captures:

- exact SessionHandle;
- exact TargetLease;
- one SuppressionLease;
- one synchronous InputIngress; and
- one asynchronous DeliveryWorker.

Identity/context is immutable; lifetime is `open -> closed`. A late callback
holding old ingress can only observe rejection.

### Delivery

One delivery/closing context exists per ControlLease. It is never rebound and
owns:

- the ordered semantic lane;
- class-aware backpressure;
- remote semantic outcome accounting;
- confirmed-held ledger;
- terminal cleanup coordination; and
- explicit `applied` / proven `notApplied` / `ambiguous` classification.

### App / presentation

App/UI composes owners and projects state. It issues intents but does not become
the implicit owner of Session, Target, Control, TCC, capture, or delivery.
`AppModel` is not a compatibility requirement.

## Runtime data path

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator
  -> current ControlLease.InputIngress
  -> DeliveryWorker
  -> RemoteCommandLane
  -> CXI v1 adapter
  -> Android helper
  -> backend/system routing
```

The event callback never waits for a remote result.

## Fail-closed Control acquisition

Acquisition order is part of the safety proof:

1. verify capability and capture readiness;
2. snapshot exact SessionHandle + TargetLease;
3. verify Session is control-capable, including any required recovery-cleanliness
   fence;
4. create InputIngress + DeliveryWorker bound to those resources;
5. prepare ControlLease + synchronous local-return gate;
6. atomically install SuppressionLease + exact ingress; and
7. only then publish remote ownership.

Failure at any step closes partial resources and remains local. Host suppression
never starts without both a bounded ingress and synchronous local-return path.

## Synchronous local-return gate

Actor scheduling is not pointer-safety evidence.

The first return trigger wins:

```text
mark Control closing/closed
  -> close InputIngress
  -> synchronously clear/release active SuppressionLease + ingress slot
  -> following host events pass locally
  -> asynchronously reconcile/cancel/resolve/cleanup/diagnose
```

No transport write, actor `await`, main-thread dispatch, helper response, or
remote cleanup exists inside the local safety boundary.

Triggers include normal return, watchdog, emergency shortcut, capability/capture
loss, delivery failure, Session/Target invalidation, external takeover, disable,
disconnect, and teardown.

Lock ordering is explicit. No arbitrary callback runs under the tiny safety lock.
Deinit is defense in depth, never the primary release mechanism.

### Admission result controls suppression

Suppression and ingress admission are one event-boundary decision.

- successfully admitted host input may be consumed under the active
  SuppressionLease;
- additive motion/scroll may be intentionally shed only under the explicit
  bounded-overload policy while Control remains valid; and
- rejected **non-droppable** key/button/repeat input is not consumed. It invokes
  local return and the triggering host event passes through unchanged where
  CGEventTap semantics permit.

A stale callback racing closure cannot reopen ingress or silently swallow a
non-droppable event that failed admission.

### External-control takeover

The triggering takeover event passes through unchanged after suppression release.
Local return must not synthesize restore/park movement that mutates that event.

## Host suppression and #96

Only HostSuppressionController may consume host input or perform accepted P0
cursor confinement.

#96 remains authoritative:

- retain P0 confinement;
- keep the native macOS cursor visible;
- accept/document the cursor-presentation limitation;
- no private SkyLight/CGS production dependency;
- no synthetic click/focus stealing;
- no pointer-jump/custom-cursor workaround merely to mask the limitation; and
- no equivalent cursor-API permutation experiment without materially new
  evidence.

## HandoffPolicy

Handoff becomes pure policy: facts in, acquire/remain/return decisions out.
ControlCoordinator serializes it. HandoffPolicy owns no task, queue, lock,
transport, event tap, diagnostics, or callback sequencing.

Validated #45/#37 behavior remains unless separately superseded:

- requested-intent return credit when Android clamps at the boundary;
- accepted inward movement credit;
- first post-entry movement guard; and
- hysteresis against edge wobble.

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

Non-droppable admission failure returns local and does not silently consume the
triggering host event.

## Delivery outcome ownership

Persistent input correctness is semantic, not transport-write-based.

A key/button transition is either:

1. **queued, not issued** — safe to cancel before wire execution;
2. **issued / may have crossed the wire** — old Session/closing delivery context
   owns its correlation until semantic resolution or bounded ambiguity timeout;
3. **resolved** — `applied`, proven `notApplied`, or `ambiguous`.

Once issued, ordinary Control closure does not abandon result accounting. A late
positive result updates only the old closing ledger. It can never mutate a
replacement Control/Session ledger.

Generic Task cancellation cannot erase an issued persistent transition. If its
outcome cannot be resolved, the old Session is untrustworthy for new remote
Control.

A generic backend `failed` result is not automatically `notApplied`. It may be
classified that way only when the backend contract proves no semantic
application; otherwise it is ambiguous.

Held-state ledger updates occur only from `applied` results.

## RemoteCommandLane

Each SessionHandle owns an explicit stateful **RemoteCommandLane** because Swift
actor isolation is reentrant across `await`.

It orders:

- target selection;
- target-dependent pointer input;
- keyboard under its honest routing scope;
- persistent cleanup; and
- reset/shutdown operations.

Baseline: one stateful command reaches semantic completion before the next.
Future pipelining requires measured need plus proof that write/outcome order and
target/cleanup/shutdown barriers cannot be crossed.

Target-dependent commands validate TargetLease at admission and again immediately
before wire execution.

## Target A -> B barrier

```text
local-return Control A
  -> close ordinary A ingress
  -> cancel queued ordinary A work not yet issued
  -> resolve every already-issued persistent A transition
  -> if any remains ambiguous: invalidate A and enter Session recovery fence
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
       invalidate A and enter recovery fence instead of reusing it as clean
```

Terminal cleanup is privileged closing work and admits no new user input.
Additive motion/scroll may be discarded when no persistent ambiguity exists.

## Session recovery / remote-state cleanliness

A new SessionHandle proves new ownership identity; it does not prove that held
state from the previous helper/backend disappeared.

If a Session closes with ambiguous persistent state, SessionManager enters a
recovery-required condition. A candidate connection/helper may exist for bounded
recovery/discovery/reset, but it does **not** become control-capable and cannot
publish a usable TargetLease for input until a recovery fence proves a neutral
remote state.

Acceptable proof must be backed by backend/platform evidence, for example:

- confirmed cleanup under the old route/backend;
- an explicit reset whose contract proves neutral state;
- backend identity destruction/recreation for which platform evidence proves
  held state is cleared; or
- an equivalent separately reviewed mechanism.

ADB reconnect, helper relaunch, HELLO_ACK, or a fresh SessionHandle alone are not
proof. If no available mechanism can establish cleanliness, remote Control stays
blocked while local macOS control remains fully available.

#107 owns backend-specific cleanup/reset proof and implementation.

## Routing honesty

Conceptually the remote boundary distinguishes:

- `selectedTarget(TargetLease)`; and
- `sessionRouted(SessionHandle)`.

System-routed UHID must not be described as explicitly targeting an arbitrary
Android display. Keyboard phone-vs-DeX routing remains an evidence question
(#92).

## Persistent keyboard outcomes / #141

Current fire-and-forget `KEY_EVENT` delivery is not the final architecture.
#141 adds an additive CXI v1 semantic result contract or equivalent mechanism.

Required semantics distinguish:

- `applied`;
- proven `notApplied`; and
- `ambiguous`.

Timeout/stream loss after send is ambiguous. Generic failure is not promoted to
`notApplied` without backend proof. Outcome accounting for an already-issued
persistent transition survives ordinary Control closure until it resolves or is
classified ambiguous.

Local host return never waits for that result.

## Backend cleanup / #107

Helper teardown is defense in depth, not assumed proof.

Current UHID pointer close attempts a zero-button report, while current
InputManager pointer close only clears local mask/state. #107 must prove actual
Android cleanup semantics or implement bounded explicit release/reset. Keyboard
backends carry the same proof obligation.

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
Bounded translation, tiny lock-protected lookup/admission, local suppression, and
fail-safe only. No transport I/O, actor/semaphore wait, or main-thread safety
round trip.

### ControlCoordinator
Actor or equivalent serial executor for Control lifecycle + pure handoff policy.
Local return does not wait for it.

### SessionManager / concrete Session
Serializes connect/reconnect/recovery/replacement policy. A concrete Session owns
protocol correlation + RemoteCommandLane. A dirty predecessor prevents a
replacement from becoming control-capable until recovery cleanliness is proved.

### DeliveryWorker
One async worker/closing context per ControlLease; no rebinding.

No target production path blocks an OS thread on remote progress. Remote tasks
may perform bounded async waits/timeouts. Capture/local-return do not wait.

Cancellation is commit-point-aware: queued not-issued work may be cancelled;
already-issued persistent work retains old correlation/outcome ownership;
terminal cleanup is privileged closing work; dirty Session replacement remains
non-control-capable until recovery proof succeeds.

## Failure domains

| Failure | Control | Session/Target |
| --- | --- | --- |
| capability loss | local/blocked | healthy Session/Target may remain |
| event-tap failure | local/blocked | healthy Session/Target may remain |
| ordinary return | local | unchanged if remote state clean |
| non-droppable admission saturation | local; triggering event not consumed | classify prior issued persistent state |
| additive timeout | local if required | Session may remain if trustworthy |
| proven not-applied key/button | local/fail-safe | may remain after prior held-state cleanup |
| ambiguous key/button | local immediately | recovery/cleanup required; no new remote Control until clean |
| target change/disappearance | local | reuse only after trustworthy old-target reconciliation/cleanup |
| helper/transport disconnect | local immediately | invalidate; recovery fence if persistent state may be ambiguous |
| external takeover | local; triggering event unchanged | otherwise unchanged |

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
| `SessionController` | SessionManager connect/reconnect/recovery policy |
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

#102 is docs-only and creates no new runtime claim, so it requires no new
physical run. Runtime implementation slices require exact-final-HEAD targeted
physical evidence.

ADR-0016 defines named invariants I1-I11, enforcement points, and deterministic
proof strategy. Exact-final-HEAD architecture review must trace at least:

1. normal handoff/return;
2. acquisition halfway failure;
3. actor-delayed reconciliation;
4. target A -> B with queued/in-flight ordinary work;
5. target A -> B with issued/held persistent state;
6. target disappearance during reconciliation/cleanup;
7. Session replacement with dirty-state recovery before new Control;
8. capability loss;
9. event-tap failure;
10. non-droppable saturation + triggering-event pass-through;
11. helper key rejection while Session remains alive;
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
