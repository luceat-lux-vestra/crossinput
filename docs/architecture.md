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

Preserve validated behavior, device/protocol facts, safety invariants,
reproducible evidence, and intentional product scope. Do **not** preserve
pre-Leap classes, mutable references, queue layout, generation counters, or
structure-coupled tests merely to minimize the diff.

Architecture Leap #101 / ADR-0016 authorize broad internal replacement when it
improves ownership, lifecycle correctness, concurrency safety, or testability.
Large changes still ship as coherent reviewable slices; rewrite freedom is not
permission to mix unrelated product/protocol/transport work.

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

This topology is a product/device fact. It does not require preserving current
controller classes, queue shapes, mutable references, or generation counters.

## Non-negotiable invariants

ADR-0016 defines the normative invariant set. The implementation-facing summary
is:

1. **Local safety** — macOS control cannot remain trapped; local return never
   waits for Android, an actor, or the main thread.
2. **No cross-Control delivery** — stale Control A work cannot execute as Control
   B work or overtake B's stateful commands.
3. **No cross-Session retargeting** — Session A work cannot redirect into B.
4. **No cross-Target retargeting** — target A ordinary input cannot become B
   input after route mutation.
5. **One suppression owner** — at most one valid SuppressionLease consumes host
   input.
6. **Bounded capture path** — CGEventTap work remains synchronous and bounded.
7. **Persistent transitions are semantically classified** — key/button state is
   never silently lost, reordered, or assumed applied from bytes-written alone.
8. **Cleanup never blocks local return** — remote cleanup is bounded asynchronous
   closing work.
9. **Ambiguous persistent state is never reused as clean** — a fresh transport,
   helper, or SessionHandle is not proof of neutral Android input state.
10. **Payload-safe diagnostics** — raw pointer/key/HID/clipboard payloads do not
    enter normal diagnostics.
11. **Routing honesty** — selected Target context does not imply every backend
    explicitly routes to that display.
12. **No dirty Control overlap** — replacement Control cannot start while a
    predecessor remote-close fence still owns issued stateful work, persistent
    outcomes, or terminal cleanup.
13. **Acquisition races fail closed** — capability/capture, Session, or Target
    invalidation racing acquisition cannot leave suppression active under an
    invalid prepared owner.

## Authoritative lifecycles

The target architecture has six authoritative lifecycle owners. Coordination is
through immutable handles/leases, one-way validity, and explicit barriers — not
a global state machine or universal epoch.

### Capability

Owns macOS permission/capability readiness. Capability loss blocks or returns
Control local. A healthy Android Session does not fail merely because host
capability is unavailable.

### Host capture

Owns CGEventTap/raw observation. Capture and suppression are separate lifetimes.

Conceptual host split:

- `InputCapabilityController`
- `MacEventTap`
- `MacInputTranslator`
- `EdgeDetector`
- `HostSuppressionController`

Exact names may change; these responsibilities must remain distinct.

### Session

One immutable **SessionHandle** represents one concrete Android/helper/CXI
connection:

```text
open -> closing -> closed
```

A replacement creates a new handle. Old work retains only the old handle; no
mutable `SessionReference` may redirect it into a newer connection.

A fresh SessionHandle is **not** automatically clean remote state. If its
predecessor ended with ambiguous persistent state, a candidate replacement stays
non-control-capable until the Session recovery cleanliness fence proves Android
input state neutral.

### Target

A confirmed target selection creates one immutable **TargetLease** inside exactly
one SessionHandle. CXI v1 `SELECT_DISPLAY` mutates helper-global route state, so
selection is an ordered remote-state barrier, not presentation-only state.

### Control

One **ControlLease** represents one remote-ownership period. Its local activation
guard is one-way:

```text
prepared -> active -> closing -> closed
     \----------------> closing
```

It captures:

- exact SessionHandle;
- exact TargetLease;
- one SuppressionLease;
- one synchronous InputIngress;
- one asynchronous DeliveryWorker/closing context; and
- one pre-created remote-close fence/return handle that can be armed
  synchronously without actor scheduling.

Identity/context is immutable. A late callback holding old ingress only sees
closed/rejected admission.

### Delivery

One delivery/closing context exists per ControlLease. It is never rebound and
owns:

- one ordered semantic lane;
- class-aware backpressure;
- semantic outcome accounting;
- confirmed-held ledger;
- retirement of previously issued stateful commands;
- the predecessor **remote-close fence**; and
- terminal cleanup coordination.

Closing delivery may outlive host suppression but may never admit new ordinary
user input.

### App / presentation

App/UI composes owners and projects their states. It may issue intents but does
not become the hidden owner of Session, Target, Control, capability, capture,
delivery, or remote-close state. `AppModel` is not a compatibility requirement.

## Runtime data path

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator
  -> current active ControlLease.InputIngress
  -> DeliveryWorker
  -> RemoteCommandLane
  -> CXI v1 adapter
  -> Android helper
  -> backend/system routing
```

The event callback never waits for a remote result.

## Fail-closed Control acquisition

Acquisition has an explicit local linearization point:

1. verify host capability + capture readiness;
2. snapshot exact SessionHandle + TargetLease;
3. verify the context is control-capable: no Session recovery requirement and no
   predecessor remote-close fence pending;
4. create a **prepared** ControlLease, InputIngress, DeliveryWorker, synchronous
   return handle, and close fence bound to those exact resources;
5. establish one-way invalidation linkage so capability/capture, Session, or
   Target invalidation can synchronously move the prepared/active lease toward
   `closing` before async reconciliation;
6. immediately before suppression installation, revalidate captured
   validity/readiness;
7. atomically install SuppressionLease + exact ingress **only if** the lease can
   linearize `prepared -> active`; and
8. only then publish/project remote ownership.

The `prepared -> active` transition plus host suppression installation is one
bounded local critical section, or an equivalent CAS/rollback protocol with the
same proof.

Concurrent invalidation is fail-closed:

- invalidation-first moves the lease out of `prepared`, so suppression
  installation cannot succeed;
- activation-first may briefly win, but the same invalidation synchronously
  invokes local return and releases suppression; and
- no fallible remote operation belongs after suppression installation.

Any setup failure synchronously releases installed suppression/ingress, closes
partial resources, and remains local. Actor/UI projection is not the authority
for host safety.

## Synchronous local-return gate

Actor scheduling is neither pointer-safety evidence nor remote-reacquisition
exclusion.

The first return trigger wins. The bounded local sequence is:

```text
move ControlLease to closing
  -> synchronously arm/publish predecessor remote-close fence
  -> close InputIngress
  -> synchronously clear/release active SuppressionLease + ingress slot
  -> following host events pass locally
  -> asynchronously resolve close fence / reconcile actor state / diagnostics
```

The close fence is armed **before** actor reconciliation so an immediate acquire
request cannot race ahead of return processing.

No transport write, actor `await`, main-thread dispatch, helper response, or
remote cleanup exists inside the local safety boundary.

Triggers include normal return, watchdog, emergency shortcut, capability/capture
loss, delivery failure, Session/Target invalidation, external takeover, disable,
disconnect, and teardown.

Lock ordering must be explicit. No arbitrary callback runs under the tiny safety
lock. Deinit is defense in depth, never the primary release mechanism.

### Admission result controls suppression

Suppression and ingress admission form one event-boundary decision:

- successfully admitted host input may be consumed under the active
  SuppressionLease;
- additive motion/scroll may be intentionally shed only under explicit bounded
  overload while Control remains valid; and
- rejected **non-droppable key/button state transitions** are not consumed. They
  invoke synchronous local return and the triggering host event passes through
  unchanged where CGEventTap semantics permit.

Key-repeat is strict by default but is non-persistent policy; #106 fixes exact
triggering-repeat handling without creating unmatched local persistent state.

A stale callback racing closure cannot reopen ingress or silently swallow a
persistent transition that failed admission.

### External-control takeover

The triggering takeover event passes through unchanged after suppression release.
Local return must not synthesize pointer restore/park movement that alters it.

## Local return versus remote close

Local host control is restored immediately, but the predecessor Control may still
own remote state. Its bounded **remote-close fence** cannot complete until:

1. every previously issued stateful lane command from that Control has retired at
   the RemoteCommandLane boundary so none can execute after a replacement
   Control's first command;
2. every already-issued persistent transition has a semantic outcome or bounded
   ambiguity classification;
3. the closing context has its final confirmed-held ledger; and
4. terminal cleanup/release of known persistent state has completed under the
   old routing/backend context or cleanliness has been classified untrustworthy.

Queued ordinary work that was never issued may be cancelled/sheared off by
class policy. Additive motion/scroll is non-persistent, but already-issued
additive work still needs an ordered retirement boundary so it cannot execute
after replacement-Control commands.

While the fence is pending:

- host input is already local;
- old ordinary ingress is permanently closed;
- **no replacement ControlLease is acquired on that Session/Target context**;
- late semantic results update only the old closing context;
- clean completion re-enables remote acquisition; and
- inability to prove a clean ordered close sends the Session into recovery
  instead of allowing immediate re-entry.

This rule covers normal return just as strictly as target change. Immediate edge
re-entry while predecessor close is pending stays local. The user never waits
synchronously for the fence.

## Host suppression and #96

Only HostSuppressionController may consume host input or perform accepted P0
cursor confinement.

#96 remains authoritative: retain P0 confinement, keep the native macOS cursor
visible, accept the cursor-presentation limitation, and do not introduce private
SkyLight/CGS, synthetic click/focus stealing, pointer-jump/custom-cursor
workarounds, or equivalent experiments without materially new evidence.

## HandoffPolicy

Handoff becomes pure policy: facts in, acquire/remain/return decisions out.
ControlCoordinator serializes it. HandoffPolicy owns no task, queue, lock,
transport, event tap, diagnostics, or callback sequencing.

Validated #45/#37 behavior remains only where the selected pointer-routing path has authority to interpret relative movement as boundary progress:

- requested-intent return credit when Android clamps at the boundary;
- accepted inward movement credit;
- first post-entry movement guard; and
- hysteresis against edge wobble.

System-routed UHID desktop targets do **not** have that authority: Android InputReader may accelerate/clamp relative reports and the semantic delivery result is not a screen-coordinate observation. Their remote-boundary authority is therefore `none`; current DeX return is explicit/fail-safe, and #145 owns any future portable authoritative automatic-return signal.

An `acquire` decision remains subject to host readiness, clean Session/Target
context, `prepared -> active` linearization, and predecessor remote-close
exclusion.

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
triggering persistent host event.

## Persistent delivery outcome ownership

A key/button transition is either:

1. **queued, not issued** — safe to cancel before wire execution;
2. **issued / may have crossed the wire** — old Session/closing delivery context
   owns correlation until semantic resolution or bounded ambiguity timeout; or
3. **resolved** — `applied`, proven `notApplied`, or `ambiguous`.

Once issued, ordinary Control closure does not abandon result accounting. Generic
Task cancellation cannot erase the transition. A late positive result updates
only the old closing ledger and can never mutate replacement Control/Session
state.

A generic backend `failed` result is not automatically `notApplied`; that
classification requires proof that no semantic application occurred. Timeout or
stream loss after send is ambiguous.

Held-state ledger changes only on `applied`. A failed/notApplied release leaves a
previous confirmed held item present for terminal cleanup.

## RemoteCommandLane

Each SessionHandle owns an explicit stateful **RemoteCommandLane** because Swift
actor isolation is reentrant across `await`.

It orders target selection, target-dependent pointer input, keyboard under its
honest routing scope, persistent cleanup/reset, and shutdown.

Baseline: one stateful command reaches semantic completion before the next.
Future pipelining requires measured need plus proof that write/outcome order and
target/cleanup/shutdown barriers cannot be crossed.

Target-dependent commands validate TargetLease at admission and again immediately
before wire execution.

Cancellation cannot let old already-issued stateful work semantically commit
after a later close/selection/replacement barrier unnoticed.

## Target A -> B barrier

```text
local-return Control A
  -> ordinary A ingress closes
  -> synchronously arm A remote-close exclusion
  -> cancel queued ordinary A work not yet issued
  -> finish A remote-close fence:
       retire all previously issued A stateful lane work
       resolve issued persistent transitions
       derive final confirmed-held ledger
       terminal cleanup confirmed held state while A route/lease stays valid
  -> if clean:
       invalidate TargetLease A
       ordered SELECT_DISPLAY(B)
       helper confirms B
       publish TargetLease B
       allow Control B
  -> if ambiguous/untrustworthy:
       invalidate Session and enter Session recovery fence
```

Terminal cleanup is privileged closing work and admits no new user input.

## Session recovery / remote-state cleanliness

A new connection identity does not prove held state from the previous
helper/backend disappeared.

If a Session closes with ambiguous persistent state or cannot prove its ordered
close, SessionManager enters a recovery-required condition. A candidate
connection/helper may exist for bounded recovery/discovery/reset, but it does
**not** become control-capable and cannot publish a usable TargetLease/ControlLease
until a recovery fence proves neutral remote state.

Acceptable proof is backend/platform-specific, for example:

- confirmed cleanup under the old routing/backend context;
- an explicit reset whose contract proves neutral state;
- backend identity destruction/recreation where platform evidence proves held
  state is cleared; or
- an equivalent separately reviewed mechanism.

ADB reconnect, helper relaunch, HELLO_ACK, or a fresh SessionHandle alone are not
proof. If no mechanism can establish cleanliness, remote Control stays blocked
while local macOS control remains available.

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
#141 adds an additive CXI v1 semantic outcome contract or equivalent mechanism.

Required semantics distinguish `applied`, proven `notApplied`, and `ambiguous`.
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

Serializes high-level Control lifecycle, HandoffPolicy, and logical
remote-control eligibility. The local activation/close guard exposed to
acquisition/return must linearize activation and arm close exclusion without
waiting for actor scheduling. Actor state reconciles that local fact; it does not
create it.

### SessionManager / concrete Session

Serializes connect/reconnect/recovery/replacement. Publishes only clean
control-capable Sessions. Concrete Session owns protocol correlation +
RemoteCommandLane.

### DeliveryWorker

One async worker/closing context per ControlLease. It owns that Control's
remote-close fence and is never rebound.

No target production path blocks an OS thread on remote progress. Remote tasks
may perform bounded async waits/timeouts. Capture/local-return do not wait.

Cancellation is commit-point-aware:

- queued not-issued work may be cancelled by class policy;
- already-issued stateful work must retire at the lane boundary before
  predecessor close is complete;
- already-issued persistent work additionally retains old correlation/outcome
  ownership;
- terminal cleanup is privileged closing work;
- synchronously armed predecessor remote-close blocks replacement Control; and
- dirty Session replacement remains non-control-capable until recovery proof
  succeeds.

Generic Task cancellation is not an ownership model.

## Failure domains

| Failure | Host action | Remote consequence |
| --- | --- | --- |
| capability loss | local/blocked | healthy Session may remain; prior close still gates re-entry |
| event-tap failure | local/blocked | Session reusable only after predecessor close proves clean |
| invalidation racing acquisition | stay/return local | activation loses CAS or active lease synchronously closes |
| ordinary return | local immediately | no new Control until remote-close fence is clean |
| non-droppable admission saturation | local; triggering transition not consumed | classify/close prior issued state |
| additive timeout | local if required | reuse only if lane ordering remains trustworthy and close proves clean |
| proven not-applied key/button | local/fail-safe | ledger unchanged for transition; close prior confirmed holds |
| ambiguous key/button | local immediately | recovery if remote-close cannot prove neutral state |
| target change/disappearance | local | switch only after clean old close; otherwise recovery |
| helper/transport disconnect | local immediately | invalidate; recovery fence if state may be dirty |
| external takeover | local; triggering event unchanged | predecessor remote-close still runs |

A lower-domain failure is not reclassified as an unrelated lifecycle failure
merely to reuse an existing API.

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
| `TargetSelectionController` | Target owner + TargetLease + close/cleanup/select barriers |
| `ControlHandoffController` | ControlCoordinator + ControlLease + local activation/close guard |
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

ADR-0016 defines invariants I1-I13, enforcement points, and deterministic proof
strategy. Exact-final-HEAD architecture review must trace at least:

1. normal handoff/return;
2. acquisition halfway failure;
3. Session/Target/capability invalidation racing acquisition before/during
   suppression installation;
4. local return while ControlCoordinator is delayed;
5. target A -> B with queued/in-flight ordinary work;
6. target A -> B with issued/held persistent state;
7. target disappearance during reconciliation/cleanup;
8. Session replacement with queued/in-flight delivery and dirty-state recovery
   before replacement becomes control-capable;
9. capability loss;
10. event-tap failure;
11. non-droppable saturation + triggering-transition pass-through;
12. helper key rejection while Session remains alive;
13. key/button timeout after send;
14. late positive persistent result after Control closes;
15. immediate re-entry attempt while predecessor close is pending and actor
   reconciliation is deliberately delayed;
16. already-issued additive work at return, including additive timeout;
17. external takeover;
18. watchdog/emergency return;
19. backend cleanup including InputManager pointer;
20. stale result after replacement; and
21. diagnostics payload isolation.

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
