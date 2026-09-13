# ADR-0016: Architecture Leap Ownership and Concurrency Model

> Status: **proposed**
> Date: 2026-09-13
> Issue: #102
> Epic: #101
>
> This ADR supersedes the **internal architecture-preservation, lifecycle, and
> concurrency implementation contract** of ADR-0009. It does not supersede
> validated product scope, CXI v1 compatibility, DeX/Android routing evidence,
> ADR-0010 backend facts, ADR-0011 backpressure evidence, ADR-0012 physical
> evidence policy, or the accepted #96 macOS cursor-presentation disposition.

## Context

The pre-Leap architecture contains several useful local boundaries, but the
system as a whole still relies on cross-layer coordination by mutable shared
references, raw counters, multiple queues, locks, callback ordering, and manual
stale-work checks.

Examples include:

- `SessionReference.generation` guarding a mutable pointer to the current
  connection;
- `ControlHandoffController.controlEpoch`, suppression generations, and
  `TransitionSequenceGate` cooperating across different executors;
- `TargetSelectionController.selectionToken` independently rejecting stale
  selection completions;
- `InputCapture` owning macOS capture mechanics, suppression, edge detection,
  watchdog/emergency behavior, remote-held key bookkeeping, Android key
  semantics, and cursor confinement in one type;
- `InputSender` owning separate pointer and keyboard queues, generation checks,
  held-button state, backpressure, semantic-to-wire translation, and delivery;
- `SessionConnection.requestBlocking()` bridging async request execution through
  a blocking semaphore;
- `AppModel` coordinating Session, Target, Control, TCC/capture failure,
  reconnect, display refresh, edge configuration, diagnostics projection, and
  presentation;
- CXI v1 target selection mutating helper-global routing state while later
  pointer/keyboard messages implicitly depend on that state; and
- CXI v1 pointer transitions receiving `POINTER_RESULT` while `KEY_EVENT` is
  currently fire-and-forget, so the host cannot distinguish helper-accepted
  keyboard transitions from helper-side drops/rejections that leave the
  Session alive.

Architecture Leap #101 explicitly permits replacement or deletion of existing
classes/modules where that is safer and easier to reason about. Diff size and
pre-Leap class preservation are not design constraints.

The design preserves validated product behavior, device/protocol facts, safety
invariants, and reproducible evidence — not old implementation shape.

## Decision summary

The target architecture is built around **owned lifecycle resources**:

1. Capability
2. Host capture
3. Session
4. Target
5. Control
6. Delivery

Each lifecycle has one authoritative owner. Coordination occurs through typed
handles/leases and explicit ordering boundaries rather than a universal epoch or
cross-layer generation choreography.

The critical design choices are:

- immutable identity + one-way invalidation for Session/Target/Control handles;
- no mutable `SessionReference` that can redirect stale work into a replacement;
- target selection as an ordered remote-state barrier;
- one ControlLease per remote-ownership period;
- a synchronous idempotent local-return gate independent of actor/Android
  scheduling;
- one bounded synchronous InputIngress on the event-tap boundary;
- one ordered semantic delivery lane per ControlLease;
- async remote requests only — no semaphore bridge;
- explicit semantic outcomes for persistent input transitions;
- helper/backend cleanup as defense in depth, never as an unproved assumption;
- platform-neutral semantic input before the remote adapter boundary; and
- application state as composition/presentation projection, not lifecycle
  ownership.

## 1. Authoritative lifecycles

### Capability

Owns whether macOS has the capabilities required to observe/suppress input.
Capability loss blocks Control and returns/stays local. It does not become a
Session failure.

### Host capture

Owns the CGEventTap and raw host-event observation lifetime. Capture can exist in
listen-only mode while Control is local.

### Session

Represents one concrete Android/helper/CXI connection instance. A replacement
connection is a new Session, never a mutation of the old identity.

### Target

Represents one confirmed selected remote routing context inside exactly one
Session.

### Control

Represents one period in which CrossInput is authorized to transition from
local to remote ownership and suppress local host input.

### Delivery

Represents one bounded remote-input pipeline scoped to exactly one Control and
its captured Session/Target context.

These lifecycles are intentionally separate. Do not collapse them into one
application state machine or one global generation counter.

## 2. Handles and leases: immutable identity, one-way lifetime

A concrete Session is represented by a **SessionHandle** whose identity and
connection reference never change. Its lifetime may transition only toward
closure:

```text
open -> closing -> closed
```

Once closed, the handle never points at or becomes a replacement connection.

`SessionReference`-style mutable-current indirection is not part of the target
design. When reconnect/replacement occurs:

1. old SessionHandle is invalidated/shut down;
2. outstanding work can only still reference that old handle;
3. a new SessionHandle is created and separately published.

The same principle applies to TargetLease and ControlLease: their identity and
captured owner references are immutable; validity may move only from open/valid
to closed/invalid.

Typed IDs may exist for diagnostics/tests. Correctness must not depend on
comparing unrelated raw `UInt64` counters across layers.

## 3. Target selection is remote state, not presentation state

CXI v1 `SELECT_DISPLAY` mutates helper-global routing state. A selected target is
therefore not just a UI field.

A successful selection creates a **TargetLease** that is:

- scoped to exactly one SessionHandle;
- created only after helper confirmation;
- immutable in identity/target metadata;
- valid only while that Session and selected route remain valid; and
- checked by every command whose semantics depend on selected-target routing.

### Routing ownership is not the same as routing claim

Binding a ControlLease to a selected TargetLease means “this Control was acquired
under this selected-target context.” It does **not** permit code to claim that
every backend explicitly routes to that display.

The remote adapter must classify routing scope honestly, for example:

- `selectedTarget(TargetLease)` — command semantics depend on the confirmed
  selected target; or
- `sessionRouted(SessionHandle)` — backend/system policy routes the command at
  Session/system scope and cannot honestly promise explicit selected-display
  routing.

This distinction matters for the current keyboard path: phone-vs-DeX keyboard
routing remains a physical-evidence question (#92), and system-routed UHID must
not be described as explicitly targeting an arbitrary display ID.

Control may still be bound to a TargetLease for product/lifecycle context while
the remote adapter reports a narrower or system-routed delivery scope.

## 4. Target change requires a cleanup fence before route mutation

A target change must not let old-target persistent state leak across
`SELECT_DISPLAY`.

The safe A -> B sequence is:

1. invoke the active ControlLease local-return gate;
2. stop admitting ordinary input for A;
3. cancel/shear off queued **ordinary** A delivery;
4. while TargetLease A is still valid and route A is still current, enqueue one
   **terminal cleanup fence** for any confirmed remotely held persistent state;
5. wait only under a bounded remote-cleanup policy for that terminal fence;
6. if cleanup is confirmed (or there is provably nothing persistent to clean),
   invalidate TargetLease A;
7. enqueue `SELECT_DISPLAY(B)` on the same stateful RemoteCommandLane, after the
   old-target fence;
8. publish TargetLease B only after helper confirmation; and
9. only then permit a new ControlLease for B.

If step 4/5 cannot establish a trustworthy old-target state — timeout, stream
loss, helper/backend ambiguity, or route disappearance that prevents required
cleanup — **do not select B on the same Session as if it were clean**. Invalidate
that Session and reconnect/re-establish remote state instead.

This is deliberately conservative for persistent state. Additive motion/scroll
samples may be discarded without requiring this escalation because they do not
represent held remote state.

A TargetLease is invalidated before **new ordinary A input** can be admitted, but
not so early that its own terminal cleanup becomes impossible. Terminal cleanup
is a privileged final operation of the closing Control/Target context; no new
user input shares that privilege.

## 5. One ControlLease is the authority for remote ownership

Entering remote control creates one **ControlLease** with immutable identity and
captured owner references. Operational state is one-way:

```text
open -> closed
```

It binds:

- current SessionHandle;
- current TargetLease;
- one host SuppressionLease;
- one synchronous InputIngress; and
- one asynchronous DeliveryWorker.

No input callback may infer remote authority from global booleans or a mutable
“current session” reference. It must possess the current lease-bound ingress.

Late callbacks holding an old ingress can only observe closed/rejected admission;
they can never become valid for a replacement ControlLease.

### Control acquisition ordering

Acquisition is fail-closed:

1. verify capability readiness and capture availability;
2. snapshot the exact SessionHandle + TargetLease context;
3. create InputIngress and DeliveryWorker bound to those exact handles;
4. prepare a ControlLease/local-return safety handle;
5. atomically install the SuppressionLease + exact ingress into the host
   suppression boundary; and
6. only after that installation succeeds, publish Control as remote-owned.

If any step fails, close/cancel partial resources and remain local.

The host suppression boundary must never enter a state where it consumes input
without already having a valid bounded ingress and synchronous local-return
path.

## 6. Synchronous local-return gate

Actor scheduling is **not** part of the pointer-safety proof.

Every open ControlLease exposes an idempotent, thread-safe local-return gate that
can be triggered by:

- normal boundary return;
- watchdog;
- emergency shortcut;
- event-tap/capture loss;
- capability loss;
- remote delivery failure;
- Session invalidation/replacement;
- Target invalidation/change;
- external-control takeover;
- user disable/disconnect; or
- teardown.

The first caller wins. The bounded local sequence is:

1. atomically mark ControlLease closing/closed so no new owner can treat it as
   remote-valid;
2. close InputIngress immediately so concurrent capture callbacks cannot admit
   more remote work;
3. synchronously release/clear HostSuppressionController's active
   SuppressionLease and current-ingress slot so subsequent host events pass
   locally; and
4. schedule — **without waiting** — ControlCoordinator reconciliation,
   DeliveryWorker cancellation, remote cleanup, diagnostics, and any Session
   trust decision.

Steps 1-3 are the safety boundary and must be bounded/local. No transport write,
actor await, main-thread dispatch, helper response, or remote cleanup is allowed
inside that critical local-return path.

Implementations must define lock ordering so the gate cannot deadlock with the
CGEventTap callback or HostSuppressionController. Do not invoke arbitrary
callbacks while holding the tiny safety-state lock.

Deinitialization is never the primary safety mechanism; explicit close +
watchdog/emergency release are required.

### External-control takeover special case

When another controller's triggering event causes takeover, local return must
not synthesize a pointer restore/park that alters that triggering event. The
triggering event passes through unchanged after suppression ownership is
released.

## 7. Host responsibilities are split by mechanism and policy

The pre-Leap `InputCapture` responsibilities are separated conceptually into:

- **InputCapabilityController** — Accessibility/Input Monitoring capability
  status/request/recovery;
- **MacEventTap** — event-tap lifecycle and raw event observation;
- **MacInputTranslator** — raw macOS event -> semantic input;
- **EdgeDetector** — edge/hysteresis observation used to request handoff;
- **HostSuppressionController** — event consumption, accepted P0 cursor
  confinement, watchdog, emergency release, external-control takeover, and
  SuppressionLease ownership.

Exact type names are not frozen by this ADR, but these responsibilities must not
collapse back into one implicit owner.

Only HostSuppressionController may consume local host input or perform the
accepted P0 cursor-confinement mutations.

The accepted #96 product decision remains authoritative:

- keep P0-style confinement;
- keep native Mac cursor visible;
- accept/document the cursor-presentation limitation;
- no private SkyLight/CGS production dependency;
- no synthetic click/focus stealing;
- no pointer-jump workaround;
- no custom cursor solely to mask #96; and
- no equivalent cursor-API permutation experiments without materially new
  evidence.

## 8. Handoff policy is pure

Replace the internally queued/callback-sequenced handoff orchestration with a
pure **HandoffPolicy** model.

Inputs are facts:

- enabled/disabled;
- edge entered;
- entry edge;
- requested/accepted movement acknowledgement;
- explicit normal/failure return reason.

Outputs are decisions:

- acquire remote ownership;
- remain remote/local; or
- return local.

HandoffPolicy contains no transport, event tap, lock, task, queue, diagnostics,
or callback sequencing.

ControlCoordinator owns policy serialization. Therefore sequence counters used
only to defend callbacks from another internal state-machine queue disappear.

Validated behavior remains unless deliberately superseded with new evidence:

- #45 requested-intent return credit when Android clamps accepted movement;
- inward movement credits confirmed accepted movement;
- #37 first post-entry movement cannot instantly return; and
- return hysteresis prevents accidental edge wobble.

## 9. Capture hot path uses one synchronous bounded InputIngress

CGEventTap callbacks cannot `await` and must remain bounded/nonblocking.

Each open ControlLease therefore owns one small lock-protected
**InputIngress**. It:

- admits semantic events in O(1) or otherwise strictly bounded work;
- coalesces only event classes whose semantics allow it;
- performs no transport I/O;
- performs no remote await/semaphore wait;
- returns an immediate admission result; and
- becomes permanently closed when its ControlLease ends.

A small lock here is intentional. An actor hop from the event callback would
weaken the hot-path/safety contract rather than improve ownership.

## 10. One ordered semantic input lane per ControlLease

The target architecture does not retain independent pointer and keyboard
DispatchQueues.

One ControlLease owns one ordered semantic lane so persistent state transitions
cannot reorder merely because they belong to different device classes.

Default admission semantics:

| Event class | Coalesce | Shed | Required ordering |
| --- | --- | --- | --- |
| relative motion | adjacent only | yes under bounded overload | additive |
| scroll | adjacent only | yes when additive semantics preserved | additive |
| pointer button down/up | never | never silently | strict |
| key down/up | never | never silently | strict |
| key repeat | no shedding by default | only with later proof | strict by default |
| cleanup/release | no lossy treatment | never silently | terminal/strong |

If InputIngress cannot admit a non-droppable state transition, invoke the
ControlLease local-return gate. Do not silently lose the transition.

## 11. DeliveryWorker is asynchronous and per-Control

Each ControlLease owns one **DeliveryWorker**. It is never rebound to a new
Session, Target, or Control.

Responsibilities:

- drain exactly that ControlLease's InputIngress;
- serialize semantic input according to the ordered-lane contract;
- translate semantic input to CXI v1 at the remote adapter boundary;
- await explicit semantic outcomes where defined;
- return movement acknowledgement facts to ControlCoordinator/HandoffPolicy;
- maintain the host-side ledger of **confirmed** remotely held persistent
  inputs;
- classify explicit failure vs cancellation vs ambiguous outcome; and
- perform/coordinate terminal cleanup after local return without blocking local
  control.

`SessionConnection.requestBlocking()` and semaphore-based async-to-sync bridges
are removed. Capture never waits for remote completion.

## 12. Stateful RemoteCommandLane

Swift actor isolation alone is insufficient because actor methods are reentrant
across `await` points.

Each SessionHandle owns an explicit **RemoteCommandLane** for helper-global or
stateful operations whose relative order affects correctness, including:

- target selection;
- target-dependent pointer input;
- keyboard input under its honest routing scope;
- persistent held-input cleanup; and
- shutdown/reset operations that alter backend state.

### Baseline execution contract

The baseline implementation executes one stateful command through completion
before starting the next. This is intentionally simple and matches the current
pointer request/response model.

The architectural requirement is **total stateful ordering + explicit barriers**,
not “serial forever.” A future measured optimization may use bounded pipelining
only if it proves all of the following:

- command write order remains deterministic;
- persistent transition outcome/commit order cannot reorder;
- Target selection is a barrier that drains all earlier target-dependent work
  before route mutation;
- shutdown/reset is a barrier;
- stale/invalid TargetLease work is rejected before write; and
- cancellation cannot allow an earlier command to semantically commit after a
  later barrier.

No optimization is justified merely for elegance; measure latency/throughput
first.

### Lease validation

Every selected-target-dependent command carries its TargetLease. Validate it:

1. at command admission; and
2. again immediately before wire execution.

Already-executing old-target work is ordered before the cleanup/selection fence.
Late old-target ordinary work after closure/invalidation is rejected and never
written.

For a fire-and-forget legacy command, “write completed” is not a semantic
outcome. Persistent input is not allowed to rely on that weaker definition in
the final architecture.

Read-only/discovery operations may use a separate safe request path only when
there is no helper-global ordering dependency.

## 13. Persistent remote state and ambiguous outcomes

Persistent remote state includes at least keys and pointer buttons.

A timeout, stream failure, target disappearance, or missing semantic result after
a state-changing command can leave the host unable to prove whether the remote
transition happened.

The architecture must preserve that uncertainty instead of inventing a known
state.

Rules:

- DeliveryWorker updates its held ledger only from a positive semantic outcome;
- explicit negative outcome fails Control safe;
- unknown outcome for a persistent transition returns local immediately;
- ordinary cleanup is bounded/best effort;
- if persistent state cannot be proven clean, do not reuse the Session as a
  clean basis for a new Control/Target context;
- helper/backend teardown cleanup is defense in depth, not a substitute for
  normal semantic outcomes; and
- no infinite cleanup retry is allowed.

### Event-class-specific escalation

Not every delivery timeout has identical meaning.

- additive motion/scroll uncertainty may fail the current Control while Session
  reuse can remain possible if the transport/protocol state is still known and
  no persistent state became ambiguous;
- key/button down/up uncertainty creates persistent-state ambiguity and requires
  stronger cleanup/trust handling;
- malformed/protocol-corrupt stream state invalidates Session regardless of
  event class.

Exact recovery classification belongs to #106/#107 tests, but implementations
must not erase this distinction.

## 14. Helper/backend cleanup is a proof obligation

Architecture must not assume “helper/session died, therefore remote held state
is clean.” Each backend needs evidence.

Current evidence is asymmetric:

- `UhidPointerInjector.close()` attempts a zero-button report before destroying
  the virtual device;
- the current `InputManagerPointerInjector.close()` only clears its local
  button mask/state and does not emit a matching synthetic UP/release event.

Therefore #107 must determine the actual Android semantics and either prove
cleanup or implement a bounded explicit release/reset path while the old routing
context remains valid.

The same proof obligation applies to keyboard backends. Existing helper cleanup
is useful but must be tested under shutdown, transport loss, target change,
backend failover, and idempotent repeated cleanup.

If a backend cannot establish a trustworthy cleanup contract, that limitation
must remain explicit and feed Session trust/recovery policy. Do not document
process death as sufficient without evidence.

## 15. Persistent keyboard transitions require an explicit semantic outcome

Current CXI v1 is asymmetric:

- pointer move/button/scroll -> `POINTER_RESULT`;
- `KEY_EVENT` -> helper-side execution with no correlated semantic result;
- helper keyboard backends may reject/drop a transition while keeping Session
  alive and emitting only metadata diagnostics.

That is insufficient for the target invariant that persistent transitions are
ordered and either delivered or fail safe.

The target architecture therefore requires an explicit keyboard-delivery
outcome before the Leap delivery migration is complete.

Preferred compatible design (#141): keep CXI framing/version at v1 and add an
additive HELLO capability plus a correlated key result, conceptually:

```text
HELLO_ACK capability: semantic-key-result
KEY_EVENT(requestId != 0)
  -> KEY_RESULT(requestId, delivered | failed)
```

Exact names/encoding are owned by the dedicated protocol change, not this ADR.
Required semantics are:

- positive means the helper/backend accepted/applied the semantic transition
  according to its backend contract;
- negative means explicit delivery failure and triggers Control fail-safe;
- timeout/stream loss after send is ambiguous persistent state;
- DeliveryWorker updates held-key state only after positive outcome;
- stale result cannot mutate a replacement Control/Session ledger; and
- helper teardown cleanup remains defense in depth.

A different implementation is acceptable only if it proves equivalent outcome
and cleanup guarantees. Fire-and-forget keyboard delivery is **not** accepted as
the final target architecture.

This additive v1 protocol work must update `protocol/protocol.md`, Swift/Kotlin
protocol implementations, fixtures, capability negotiation, tests, and
exact-head physical evidence. It does not require CXI v2.

## 16. Semantic input is platform-neutral before the remote boundary

The semantic domain introduced by #103 must not contain:

- CoreGraphics/AppKit event types;
- macOS virtual-key implementation details beyond the host adapter;
- Android `KEYCODE_*` or `META_*` constants;
- UHID/InputManager types; or
- CXI framing/message identifiers.

Translation is explicit:

```text
macOS event
  -> MacInputTranslator
  -> SemanticInputEvent
  -> InputIngress / DeliveryWorker
  -> CXI v1 remote adapter
  -> helper semantic command
  -> Android backend adapter
```

`CapturedKeyEvent` carrying Android KeyEvent semantics is therefore not a target
host-domain API.

## 17. Application state is projection, not lifecycle ownership

The application layer becomes a composition root plus presentation projection.
It may issue user intents such as:

- connect/disconnect;
- select target;
- enable/disable control;
- emergency return;
- open permission settings; and
- refresh presentation.

It does not directly own transport channels, mutate event-tap internals,
serialize remote input, infer TCC from generic capture failure, or reclassify
one lifecycle's failure as another's merely to reuse an existing path.

`AppModel` is not a compatibility requirement.

## Lifecycle state contracts

The target intentionally avoids one giant application state machine.

### Capability

```text
unknown/checking -> ready
                 -> blocked(reason)
ready            -> blocked(reason)
blocked          -> ready
```

Capability does not own Session.

### Session manager

```text
disconnected -> connecting(candidate)
connecting   -> ready(SessionHandle)
connecting   -> failed/disconnected
ready        -> reconnecting/disconnected
reconnecting -> ready(new SessionHandle)
reconnecting -> failed/disconnected
```

A candidate is private until handshake/capability negotiation succeeds.

Concrete SessionHandle:

```text
open -> closing -> closed
```

### Target

```text
unavailable -> available(snapshot)
available   -> selecting(candidate)
selected(A) -> closing(A) -> selecting(B)
selecting   -> selected(TargetLease)
selecting   -> available/unavailable
any         -> unavailable     // Session invalidated
```

`closing(A)` includes local return + terminal cleanup fence. If that fence cannot
establish a trustworthy persistent state, invalidate Session instead of moving
to B within it.

### Control

```text
disabled -> local
local    -> remote(ControlLease)
remote   -> local
local    -> disabled
remote   -> disabled   // local-return gate first, then disable
```

`returning` may exist as presentation/internal progress only. Host suppression
must already be released; remote cleanup never keeps the user trapped in a
“returning” state.

Edge arming is policy data, not its own lifecycle resource.

### Delivery

One worker per ControlLease:

```text
open -> closing -> closed
```

A worker is never rebound to another Session/Target/Control.

## Failure-domain matrix

| Failure | Control | Session | Target |
| --- | --- | --- | --- |
| missing/revoked host capability | local/blocked | may remain healthy | may remain selected |
| event-tap/capture failure | local/blocked | may remain healthy | may remain selected |
| ordinary boundary return | local | unchanged if remote state clean | unchanged |
| non-droppable queue saturation | local immediately | classify by persistent ambiguity | unchanged unless Session invalidated |
| additive movement timeout | local/fail-safe | may remain reusable if protocol/transport trustworthy | unchanged |
| ambiguous key/button transition | local immediately | invalidate unless state is re-established | invalid with Session if Session closes |
| target disappearance/change | local if active | retain only if cleanup/route state trustworthy | invalidate/reselect |
| transport/helper disconnect | local immediately | invalidate/reconnect | invalidate with Session |
| external-control takeover | local immediately; triggering event passes through | unchanged unless independently failed | unchanged |

A lower-domain failure must not be reclassified as an unrelated lifecycle
failure merely to reuse an old API.

## Target module / dependency direction

Exact SwiftPM target names are finalized by #103, but dependency direction is
fixed:

```text
                         +----------------------+
                         |        App/UI        |
                         | composition/proj.    |
                         +----------+-----------+
                                    |
               +--------------------+--------------------+
               |                                         |
      +--------v---------+                      +---------v----------+
      |     MacHost      |                      |       Remote       |
      | capability/cap.  |                      | session/target/    |
      | suppress/edge    |                      | delivery owners    |
      +--------+---------+                      +----+----------+----+
               |                                     |          |
               +----------------+--------------------+          |
                                |                               |
                       +--------v---------+             +-------v-------+
                       | CrossInputDomain |             |    CXI v1     |
                       | semantic input + |             | wire adapter  |
                       | pure policies    |             +-------+-------+
                       +------------------+                     |
                                                        +-------v-------+
                                                        | ADB transport |
                                                        +---------------+
```

Rules:

- Remote must not depend on MacHost;
- MacHost must not depend on Android/CXI/UHID/InputManager details;
- CrossInputDomain must not depend on either platform;
- CXI framing is not a domain concept;
- diagnostics is metadata-only and cannot carry raw input payloads.

## Concurrency contract

### MainActor

Owns application composition/presentation projection, UI intents, and AppKit
presentation actions. It is not on the capture or remote-input hot path.

### Mac event-tap executor

Dedicated CFRunLoop/queue. Allowed work:

- bounded event classification/translation;
- tiny lock-protected lease/ingress lookup;
- bounded InputIngress admission;
- local suppression/fail-safe mechanics; and
- lightweight control signal emission.

Forbidden:

- transport I/O;
- actor/semaphore waits;
- unbounded allocation/work; and
- payload logging.

### ControlCoordinator

Intended as a Swift actor (or equivalently explicit serial executor if evidence
justifies another model). Owns Control lifecycle and pure HandoffPolicy.

Local return does **not** wait for this actor; the synchronous ControlLease gate
releases host safety first and reconciles actor state afterward.

### SessionManager / RemoteDeviceSession

SessionManager serializes connection/reconnect/replacement policy and publishes
SessionHandles.

Each concrete session owns protocol correlation, disconnect state, and its
stateful RemoteCommandLane.

### DeliveryWorker

One async worker per ControlLease. It drains only that lease's InputIngress and
talks only to that lease's Session/route context.

## Named invariants and enforcement points

### I1 — Local Safety

Mac control returns without waiting for Android or actor scheduling.

**Enforced by:** synchronous ControlLease local-return gate +
HostSuppressionController watchdog/emergency/local release.

### I2 — No Cross-Control Delivery

Work admitted for Control A cannot reach replacement Control B.

**Enforced by:** per-Control closed InputIngress + per-Control DeliveryWorker.

### I3 — No Cross-Session Retargeting

Work holding Session A can never be redirected into Session B.

**Enforced by:** immutable per-connection SessionHandle identity; no mutable
SessionReference.

### I4 — No Cross-Target Retargeting

Ordinary input admitted under target A cannot be delivered after target B is
published current.

**Enforced by:** local-return/ingress close, terminal A cleanup fence,
TargetLease validation, and ordered selection barrier.

### I5 — One Suppression Owner

At most one valid SuppressionLease consumes host input.

**Enforced by:** HostSuppressionController single-owner slot + idempotent local
release.

### I6 — Bounded Capture Work

CGEventTap callback remains bounded/nonblocking.

**Enforced by:** synchronous bounded InputIngress; no remote await on callback
path.

### I7 — Persistent Transitions Are Never Silently Lost

Key/button transitions are delivered in order with an explicit semantic outcome
or Control fails safe.

**Enforced by:** one ordered semantic lane + non-droppable admission + pointer
result / required keyboard outcome contract.

### I8 — Cleanup Never Blocks Local Return

Remote cleanup begins only after local safety release and is bounded.

**Enforced by:** local-return gate ordering + async terminal cleanup.

### I9 — Ambiguous Persistent State Is Not Reused as Clean

Unknown key/button state cannot silently become the starting state for a new
Control/Target context.

**Enforced by:** terminal cleanup proof or Session invalidation.

### I10 — Diagnostics Are Payload-Safe

Raw pointer deltas/coordinates, key codes/typed content, HID reports, clipboard
contents, and equivalent payloads never enter diagnostics.

**Enforced by:** typed metadata-only observations + adversarial tests.

### I11 — Routing Claims Are Honest

Ownership under a selected TargetLease does not imply a backend can explicitly
route every command to that display.

**Enforced by:** typed remote routing scope + physical-evidence-backed backend
claims (#92, ADR-0010, #107).

## Migration map

The mapping is directional; target names are not frozen.

| Current responsibility/type | Target direction |
| --- | --- |
| `AppModel` | composition + presentation projection (#108) |
| `SessionController` | SessionManager connection/reconnect policy |
| `SessionReference` | **delete**; immutable SessionHandle |
| `RemoteSession` | concrete async session + ordered command lane |
| `requestBlocking()` | **delete** |
| `TargetSelectionController` | TargetCoordinator + TargetLease + cleanup/selection fence |
| `ControlHandoffController` | **replace** with ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` internal queue/sequences | pure HandoffPolicy |
| `TransitionSequenceGate` | **delete** |
| monolithic `InputCapture` | split capability/event-tap/translation/edge/suppression ownership |
| `CapturedKeyEvent` Android semantics | **delete from host domain** (#103) |
| `InputSender` | InputIngress + per-Control DeliveryWorker |
| separate pointer/keyboard queues | **delete**; one ordered semantic lane |
| host duplicate held-input bookkeeping | one outcome-based DeliveryWorker ledger |
| fire-and-forget `KEY_EVENT` | **not final**; #141 semantic outcome or equivalent proof |
| current `Protocol` target | retain v1 framing; isolate adapter/translation |
| helper broad `Main.kt` dispatch | audit/split protocol-target-backend ownership (#107) |
| InputManager pointer teardown local-mask reset | prove/replace with trustworthy cleanup (#107) |

## Migration strategy

Broad replacement is authorized; one giant rewrite PR is not.

Rules:

1. every merged slice leaves one coherent runnable architecture;
2. temporary adapters require an owner and explicit deletion point;
3. do not keep dual Control/Session/Target/delivery ownership indefinitely;
4. rewrite tests that encode obsolete structure instead of preserving bad
   architecture to keep them green;
5. preserve CXI v1 framing/compatibility and validated DeX routing unless a
   separately approved additive protocol change/migration supersedes them;
6. preserve accepted #96 behavior exactly unless materially new evidence
   reopens it;
7. reset-sensitive runtime changes require exact-head physical verification and
   ADR-0012 lineage handling.

Issue dependency order remains authoritative. High-level sequence:

1. #102 — approve ownership/concurrency contract;
2. #103 — semantic input domain + module dependency direction;
3. #99 / #104 / #105 — capability, host, Control migration;
4. #106 / #107 / #141 — delivery, helper/backend cleanup, keyboard outcome;
5. #108 — application composition/presentation convergence;
6. #109 — adversarial verification + legacy purge.

Parallel work is allowed when dependencies and ownership migration do not
conflict.

## Alternatives considered

### Preserve current controllers and only narrow them

Rejected. Smaller diff would retain the hardest problem: raw generations,
locks, queues, and callbacks still have to agree on current ownership.

### One global actor

Rejected. It would put unrelated lifecycles behind one executor and weaken the
CGEventTap/local-fail-safe boundary.

### Actors everywhere

Rejected. CGEventTap admission is synchronous by nature; a tiny bounded lock is
more honest and safer there.

### One global generation

Rejected. Session, Target, and Control are intentionally independent lifecycles.
A universal epoch hides ownership mistakes rather than modeling them.

### Separate pointer/keyboard delivery queues

Rejected as target architecture. They make cross-class persistent ordering an
emergent property and complicate held-state cleanup.

### Fire-and-forget keyboard plus helper teardown cleanup

Rejected as final target. Current helper can drop/reject an individual key while
Session stays alive, and teardown cleanup does not prove that normal delivery
succeeded.

### Change CXI v1 to carry target ID on every input immediately

Not selected. It could simplify future routing, but the TargetLease + ordered
barrier design makes current v1 safe without coupling #102 to a larger wire
migration.

### Require CXI v2 for keyboard outcomes

Rejected. A small additive v1 capability/result can satisfy the correctness
contract without coupling the Leap to the broader v2 migration gate.

### Assume helper process exit cleans InputManager pointer state

Rejected without evidence. Current InputManager pointer close only resets local
bookkeeping; #107 must prove or implement remote cleanup semantics.

## Consequences

Positive:

- stale work is isolated primarily by resource ownership;
- old Session work cannot redirect into a replacement;
- target changes have a cleanup + selection barrier;
- local pointer safety is independent of Android and actor scheduling;
- persistent input state becomes outcome-based rather than write-based;
- one ordered lane simplifies state ordering and cleanup;
- platform/routing claims stay semantically honest;
- blocking async-to-sync request bridges disappear;
- dependent issues receive a concrete target rather than “keep old structure.”

Cost:

- substantial internal rebuild;
- many structure-coupled tests must be replaced;
- temporary migration adapters may be needed;
- #141 adds a separately reviewed additive v1 protocol slice;
- #107 must prove/repair backend teardown cleanup;
- repeated exact-head physical verification is required for runtime slices;
- ADR-0012 cycle credit resets when the candidate lineage is invalidated.

## Validation / proof obligations

Before accepting this ADR:

- exact-final-HEAD documentation/repository CI passes;
- independent architecture review challenges the model rather than restating
  it;
- no contradictory current architecture/agent rule remains;
- every lifecycle has one authoritative owner;
- every cross-owner ordering relation is explicit;
- no safety claim relies on actor scheduling or remote cleanup success.

Review must trace at least:

1. normal handoff and return;
2. Control acquisition failure halfway through setup;
3. local return while ControlCoordinator is delayed;
4. target A -> B with ordinary input queued/in-flight;
5. target A -> B with a confirmed held key/button;
6. target disappearance before cleanup can complete;
7. Session replacement with queued/in-flight delivery;
8. host capability revocation with healthy Session;
9. event-tap failure;
10. non-droppable queue saturation;
11. helper-side keyboard rejection while Session stays alive;
12. key/button timeout after send;
13. additive movement timeout;
14. external-control takeover;
15. watchdog/emergency return;
16. helper shutdown/backend cleanup, including InputManager pointer state;
17. stale response after replacement; and
18. diagnostics payload isolation.

This PR is docs-only. No new physical behavior is claimed, so no new physical
test is required for the ADR itself. Each implementation slice must supply its
own exact-head physical evidence where the claim depends on macOS + Samsung DeX
behavior.

## Revisit conditions

Revisit this ADR if any of the following materially changes the ownership model:

- CXI v2 makes target identity explicit per input command;
- a second production transport changes Session ownership;
- Android -> macOS pointer/keyboard input becomes approved scope;
- simultaneous multi-device control becomes approved scope;
- a materially different privileged host-input mechanism replaces the current
  unprivileged CGEventTap/suppression design; or
- new reproducible evidence disproves a safety assumption above.
