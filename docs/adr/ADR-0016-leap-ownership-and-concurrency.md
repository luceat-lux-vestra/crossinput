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

The pre-Leap architecture contains several good local boundaries, but the system
as a whole still relies on cross-layer coordination by mutable shared references,
raw counters, queues, locks, callback ordering, and manual stale-work checks.
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
  pointer/keyboard messages implicitly depend on that state.

This structure is not being retained merely to reduce diff size. The Architecture
Leap explicitly permits replacement or deletion of existing classes/modules when
that is the safer and more coherent route.

The design must preserve validated behavior and safety evidence, not pre-Leap
class boundaries.

## Decision

### 1. Architecture is organized around owned lifecycles, not existing classes

The authoritative lifecycles are:

1. **Capability** — whether the macOS host has the capabilities required to
   capture/control input.
2. **Host capture** — the event-tap and host-side observation mechanism.
3. **Session** — one concrete Android/helper/CXI connection instance.
4. **Target** — one selected remote routing target scoped to one Session.
5. **Control** — one period in which CrossInput is authorized to transition
   between local and remote ownership.
6. **Delivery** — one remote-input pipeline scoped to one concrete Control,
   Session, and Target.

These lifecycles are coordinated, but they are not collapsed into one global
state machine or one universal generation counter.

### 2. Replacement is modeled by immutable handles, not mutable current pointers

A concrete Session is represented by an immutable **SessionHandle** bound to one
connection instance. Once created, that handle never starts pointing at a newer
connection.

`SessionReference`-style mutable indirection is not part of the target design.
When reconnect/replacement occurs:

1. the old SessionHandle is invalidated/shut down;
2. outstanding work that captured it can only reach that old session;
3. a new SessionHandle is created and published separately.

The same principle applies to Target and Control. Identity may use typed IDs for
diagnostics/testing, but correctness must not depend on comparing unrelated raw
`UInt64` counters across layers.

### 3. Target selection produces a Session-scoped TargetLease

CXI v1 `SELECT_DISPLAY` changes helper-global routing state. Therefore Target
selection is not merely presentation state.

A successful selection returns an immutable **TargetLease** that is:

- bound to exactly one SessionHandle;
- created only after the helper confirms the selected target;
- invalidated before a replacement target becomes routable; and
- required by every target-dependent input delivery operation.

The Session boundary rejects delivery carrying an old TargetLease.

Target change is an ordering barrier:

1. restore local host control / end the current ControlLease;
2. stop admitting new input for the old target;
3. cancel or quiesce old delivery work according to the delivery contract;
4. invalidate the old TargetLease;
5. execute `SELECT_DISPLAY` on the ordered remote command lane;
6. publish the new TargetLease only after confirmation;
7. allow a new ControlLease to be acquired.

This prevents old input from being silently redirected to a newly selected
helper-global target.

### 4. One ControlLease is the authority for remote ownership

Entering remote control creates one immutable **ControlLease**. It binds:

- the current SessionHandle;
- the current TargetLease;
- one host SuppressionLease;
- one synchronous InputIngress; and
- one remote DeliveryWorker.

No input callback may infer remote authority from global booleans or a mutable
"current session" reference. It must possess the current lease-bound ingress.

Ending control closes that ingress and releases the host SuppressionLease.
Late callbacks holding the old ingress can only fail admission; they cannot
become valid for a replacement ControlLease.

### 5. Local restoration is independent and always wins

Host safety is a local invariant, not a remote RPC outcome.

On normal return, watchdog expiry, emergency shortcut, permission/capture loss,
remote failure, target invalidation, session replacement, external-control
takeover, disable, or teardown:

1. **restore local macOS control first**;
2. close/invalidate the ControlLease ingress;
3. cancel pending remote work;
4. attempt bounded best-effort remote held-input cleanup;
5. invalidate the remote Session when its state is ambiguous and cannot be made
   trustworthy.

Remote cleanup success is never a prerequisite for local restoration.

The accepted #96 P0 host-confinement behavior remains the production cursor
policy during this Leap. The Leap does not reopen equivalent cursor-API
permutation experiments.

### 6. Host suppression is an explicit local resource

The macOS host side is decomposed into responsibilities rather than one
`InputCapture` owner:

- **InputCapabilityController** — Accessibility/Input Monitoring capability
  state and recovery; does not own Session.
- **MacEventTap** — CGEventTap lifecycle and raw event observation.
- **MacInputTranslator** — CoreGraphics/AppKit event representation to
  platform-neutral semantic input.
- **EdgeDetector** — local edge/hysteresis detection needed to request control
  acquisition.
- **HostSuppressionController** — event consumption, P0 cursor confinement,
  watchdog, emergency release, external-control takeover, and SuppressionLease
  ownership.

Only the host-suppression boundary may consume local events or mutate host cursor
position. Its watchdog/fail-safe must be able to release locally without
awaiting an actor, transport, Android helper, or main-thread callback.

### 7. Handoff policy is pure; lifecycle orchestration owns execution

The target replacement for the current internally queued
`EdgeSwitchStateMachine` is a pure **HandoffPolicy** value/model:

- input: current policy state, entry edge, requested/accepted movement facts,
  and explicit return/failure commands;
- output: deterministic decisions such as acquire remote ownership or return
  local ownership;
- no transport, event tap, locks, tasks, queues, diagnostics, or callback
  sequencing inside the policy.

`ControlCoordinator` owns serialization and applies policy decisions. Therefore
there is no need for transition sequence numbers solely to defend callbacks from
another internal state-machine queue.

The #45 requested-vs-accepted movement rule and first-movement/hysteresis safety
behavior remain product/safety facts unless deliberately superseded with new
physical evidence.

### 8. Capture hot path uses a synchronous bounded ingress

CGEventTap callbacks cannot `await` an actor and must remain bounded and
nonblocking.

Therefore the architecture intentionally uses one small synchronous boundary:
**InputIngress**.

InputIngress is a lock-protected bounded mailbox scoped to one ControlLease. It:

- accepts platform-neutral semantic events in O(1) or bounded work;
- coalesces only event classes whose semantics permit it;
- never performs transport I/O;
- never blocks waiting for remote completion;
- returns an immediate admission result; and
- becomes permanently closed when its ControlLease ends.

Using a small lock here is intentional. Replacing it with an actor would force
an async hop from the event callback and would not improve ownership semantics.

### 9. Remote input uses one ordered semantic lane per ControlLease

The current split pointer/keyboard queues are not part of the target design.
A single ControlLease owns one ordered semantic input lane so cross-class
ordering such as modifier/button/key transitions cannot be reordered merely
because they used different queues.

Default backpressure semantics are:

- relative pointer motion: adjacent samples may coalesce; overload may shed
  samples because they do not represent persistent remote state;
- scroll: adjacent samples may coalesce; bounded shedding is permitted when it
  preserves the documented additive semantics;
- pointer button transitions: never silently drop or reorder;
- key down/up transitions: never silently drop or reorder;
- key repeat: ordered by default; any future shedding/coalescing requires an
  explicit semantic proof and tests;
- cleanup/release transitions: stronger ordering than ordinary lossy samples.

If the bounded mailbox cannot admit a non-droppable state transition, the safe
response is to end the ControlLease and return local, not to silently lose the
transition.

### 10. DeliveryWorker is asynchronous; blocking bridges are removed

Each ControlLease owns one **DeliveryWorker** that drains InputIngress and talks
to the exact SessionHandle/TargetLease captured by that lease.

The worker:

- serializes semantic input delivery;
- performs semantic-to-CXI v1 translation at the remote adapter boundary;
- awaits responses asynchronously;
- publishes delivery acknowledgements/failures back to ControlCoordinator;
- owns the authoritative host-side ledger of remotely acknowledged held
  keys/buttons for that ControlLease; and
- stops when the lease is closed, the Session is invalid, or the TargetLease is
  no longer current.

`SessionConnection.requestBlocking()` and semaphore-based async-to-sync request
bridges are removed. No capture callback waits for a remote acknowledgement.

### 11. Stateful remote commands use an explicit non-reentrant command lane

Swift actor isolation alone is not sufficient to establish target/input ordering
because actor methods are reentrant across `await` points.

Each concrete SessionHandle therefore owns an explicit ordered
**RemoteCommandLane** for stateful operations whose relative order affects
helper behavior, including at minimum:

- target selection;
- pointer/keyboard input delivery;
- held-input cleanup that must be ordered against those events; and
- shutdown/reset operations that alter backend state.

The lane executes one stateful command at a time through completion. A newer
Target selection cannot overtake an in-flight input command, and old input
cannot be admitted against a newly published TargetLease.

Read-only/discovery operations may use a separate safe request path only when
there is no helper-global ordering dependency.

### 12. Ambiguous remote state invalidates trust

A timeout or transport failure after sending a state-changing input can leave
remote held state ambiguous: the helper may have applied the event even though
the host did not observe an acknowledgement.

The architecture does not pretend such state is known.

- Confirmed held state is tracked by DeliveryWorker.
- Cleanup is bounded and best effort.
- The Android helper must also clean backend-owned held state on session/helper
  shutdown where the backend permits it (defense in depth; audited in #107).
- If a non-idempotent state-changing delivery becomes ambiguous and the current
  protocol/backend cannot prove recovery, the current Session is invalidated
  rather than reused as if its input state were trustworthy.

No infinite cleanup retry is allowed.

### 13. Session, Target, Control, and Capability remain separate failure domains

A capability/capture failure:

- restores/stays local;
- blocks Control acquisition;
- does **not** tear down a healthy Session solely because local TCC capability
  is missing.

A Target failure:

- invalidates that TargetLease;
- returns local if it was in use;
- does not automatically redefine the underlying Session as transport-failed.

A Session failure:

- invalidates all TargetLeases and ControlLeases scoped to it;
- restores local control immediately;
- may enter reconnect policy owned by SessionManager.

A Control failure:

- restores local control;
- ends only that ControlLease unless the underlying failure also proves the
  Session or Target untrustworthy.

### 14. Application state is projection, not lifecycle ownership

The application layer becomes a composition root plus presentation projection.
It may issue intents such as connect, disconnect, select target, enable control,
disable control, open permission settings, and emergency return.

It does not directly:

- own transport channels;
- mutate event-tap state;
- perform TCC inference;
- serialize remote input;
- hold mutable session references used by delivery; or
- reinterpret lower-level failures as another lifecycle's failure.

`AppModel` is not a compatibility requirement and may be replaced.

### 15. Semantic input is platform-neutral before the remote boundary

The semantic domain introduced by #103 must not contain:

- CoreGraphics/AppKit event types;
- macOS virtual-key implementation details beyond the host adapter;
- Android `KEYCODE_*` or `META_*` constants;
- UHID/InputManager types;
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

CXI v1 remains wire-compatible unless a separate protocol change is explicitly
approved.

## Target module / dependency direction

Exact target names may be adjusted during #103, but the dependency direction is
fixed by this ADR:

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

`Remote` must not depend on `MacHost`. `MacHost` must not depend on Android/CXI
wire or backend details. `CrossInputDomain` must not depend on either platform.

Diagnostics is a side boundary available to adapters/owners but may carry only
metadata-safe facts, never raw input payloads.

## Concurrency contract

### MainActor

Owns:

- application composition/presentation projection;
- UI intents;
- AppKit/System Settings presentation actions; and
- capability UI interaction where the platform API requires it.

It is not on the capture or remote-input hot path.

### Mac event-tap executor

A dedicated CFRunLoop/queue owns CGEventTap callback execution. The callback may:

- classify/translate one host event;
- inspect a small lock-protected current suppression/ingress snapshot;
- perform bounded InputIngress admission;
- perform local fail-safe/suppression mechanics; and
- emit a lightweight control signal.

It may not perform transport I/O, actor waits, semaphore waits, unbounded work,
or payload logging.

### ControlCoordinator

A Swift actor (or an equivalently single, explicitly documented serial executor
if implementation evidence justifies it) owns Control lifecycle state and the
pure HandoffPolicy.

The intended implementation is an actor. Local host release does not depend on
actor scheduling: HostSuppressionController can release synchronously and then
notify the actor of the resulting transition.

### SessionManager / RemoteDeviceSession

SessionManager serializes connection/reconnect/replacement policy and publishes
immutable SessionHandles.

A concrete remote session owns protocol correlation, disconnect, and one
RemoteCommandLane. The stateful lane is explicitly non-reentrant across remote
request awaits.

### DeliveryWorker

One asynchronous worker exists per ControlLease. It drains that lease's bounded
InputIngress. No worker is rebound to a replacement Session or Target.

## Named invariants and enforcement points

### I1 — Local Safety

**Property:** macOS input can always return locally without waiting for Android.

**Enforced by:** HostSuppressionController watchdog/emergency/local release.

### I2 — No Cross-Lease Delivery

**Property:** work admitted for one ControlLease cannot reach a replacement
ControlLease.

**Enforced by:** per-lease InputIngress closure + per-lease DeliveryWorker.

### I3 — No Cross-Session Retargeting

**Property:** work holding an old SessionHandle cannot be redirected to a new
session.

**Enforced by:** immutable per-connection SessionHandle; no mutable
SessionReference.

### I4 — No Cross-Target Retargeting

**Property:** input admitted for target A cannot be delivered after target B is
published as current.

**Enforced by:** TargetLease validation + ordered target-selection/input command
lane + target-change control barrier.

### I5 — One Suppression Owner

**Property:** at most one valid SuppressionLease may consume host input.

**Enforced by:** HostSuppressionController single-owner lease slot and idempotent
release.

### I6 — Bounded Capture Work

**Property:** event-tap callback cost stays bounded/nonblocking.

**Enforced by:** synchronous bounded InputIngress and no remote awaits on the
callback path.

### I7 — Persistent Transitions Are Never Silently Lost

**Property:** key/button state transitions are delivered in order or control
fails safe.

**Enforced by:** unified ordered input lane + non-droppable admission policy.

### I8 — Cleanup Never Blocks Local Return

**Property:** remote cleanup is best effort after local restoration.

**Enforced by:** return ordering and bounded asynchronous cleanup.

### I9 — Ambiguous Remote State Is Not Reused as Healthy

**Property:** an uncertain state-changing remote delivery cannot silently become
part of a supposedly clean replacement control session.

**Enforced by:** session invalidation when cleanup/state certainty cannot be
re-established.

### I10 — Diagnostics Are Payload-Safe

**Property:** raw pointer deltas/coordinates, key codes/typed content, HID
reports, clipboard contents, and equivalent payloads never enter diagnostics.

**Enforced by:** typed metadata-only observation APIs and adversarial tests.

## Migration map

The following mapping is directional, not a requirement to preserve names:

| Current responsibility/type | Target responsibility | Planned owner |
| --- | --- | --- |
| `AppModel` | composition + view-state projection | #108 |
| `SessionController` | connection/reconnect policy | SessionManager |
| `SessionReference` | **delete** mutable-current indirection | immutable SessionHandle |
| `RemoteSession` | per-connection CXI session + ordered command lane | RemoteDeviceSession |
| `requestBlocking()` | **delete** | async RemoteCommandLane |
| `TargetSelectionController` | target discovery/selection lifecycle | TargetCoordinator + TargetLease |
| `ControlHandoffController` | **replace** orchestration/epoch choreography | ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` internal queue/sequences | **replace** with pure policy | HandoffPolicy |
| `TransitionSequenceGate` | **delete** | actor/lease ownership |
| monolithic `InputCapture` | capability, event tap, translation, edge, suppression | MacHost boundaries |
| `CapturedKeyEvent` Android semantics | **delete from host API** | semantic key type in #103 |
| `InputSender` | bounded ingress + per-lease async delivery | InputIngress + DeliveryWorker |
| separate pointer/keyboard delivery queues | **delete** | one ordered semantic lane |
| host-side duplicate held-input state | consolidate | DeliveryWorker ledger; helper defense-in-depth |
| current `Protocol` target | keep v1 wire, isolate translation | CXI v1 adapter |
| helper `Main.kt` broad dispatch | separate protocol/target/backend ownership where justified | #107 |

## Migration strategy

This ADR authorizes broad replacement but does **not** authorize one giant rewrite
PR.

Rules:

1. every merged slice leaves one coherent runnable architecture;
2. temporary adapters require a named owner and deletion issue/step;
3. no long-lived dual Control, Session, Target, or delivery owner may remain;
4. structural compatibility with old tests is not a reason to preserve obsolete
   architecture; rewrite tests that encode implementation shape rather than
   required behavior;
5. preserve CXI v1 wire compatibility and validated DeX routing unless a
   separate approved change supersedes them;
6. #96 cursor behavior is carried forward exactly until materially new evidence
   justifies reopening it;
7. reset-sensitive runtime changes receive exact-head physical verification and
   restart/apply ADR-0012 lineage accounting as required.

Suggested implementation order remains governed by the native issue dependency
graph:

1. #102 — approve this ownership/concurrency contract;
2. #103 — semantic input domain + module dependency direction;
3. #99 / #104 / #105 — capability, host, and Control migration;
4. #106 / #107 — delivery and Android/helper migration as dependencies permit;
5. #108 — application composition/presentation convergence;
6. #109 — adversarial verification + legacy purge.

Parallel work is allowed where dependencies do not overlap ownership being
migrated.

## Alternatives considered

### Preserve the current controllers and only narrow their responsibilities

Rejected. It reduces diff size but retains the hardest correctness property:
multiple raw generations, locks, queues, and callbacks must still agree on which
lifecycle is current.

### One global actor for the entire application

Rejected. It makes ownership superficially simple but puts the event-tap hot
path and local fail-safe behind async scheduling and creates unnecessary
serialization between unrelated lifecycles.

### Actors everywhere, including capture admission

Rejected. CGEventTap requires synchronous bounded handling. A small
lock-protected ingress is the correct boundary for this workload.

### One global generation counter shared by Session/Target/Control

Rejected. Those lifecycles are intentionally independent. A universal epoch
hides ownership errors rather than modeling them.

### Keep separate pointer and keyboard queues

Rejected as the target design. Separate queues make cross-class ordering an
emergent property and complicate held-input cleanup. One semantic lane with
class-aware coalescing is easier to reason about.

### Change CXI v1 to put the target ID in every input message immediately

Not selected by this ADR. That could remove some helper-global route coupling,
but it is a protocol migration with its own compatibility/evidence cost. The
TargetLease + ordered command-lane design makes the current v1 contract safe
without smuggling a wire migration into the architecture Leap. A future
protocol change may revisit this separately.

## Consequences

Positive:

- stale work is isolated primarily by resource ownership rather than repeated
  counter comparisons;
- replacement sessions cannot receive old work through a mutable shared
  reference;
- target routing changes become explicit barriers;
- local host safety remains independent of remote scheduling;
- one ordered semantic input lane simplifies backpressure and held-state
  reasoning;
- async request execution no longer requires semaphore bridges;
- platform details move behind explicit adapters;
- dependent issues receive a concrete architecture contract instead of a
  mandate to preserve existing types.

Negative / cost:

- this is a substantial internal rebuild, not a cosmetic refactor;
- many existing tests will need replacement because they encode old class/
  generation structure;
- the migration requires temporary adapters at some boundaries;
- exact-head physical verification is required repeatedly for materially
  affected runtime behavior;
- ADR-0012 stability credit will reset when reset-sensitive production slices
  change the candidate lineage.

## Validation

Before this ADR is accepted:

- documentation validation and repository-prescribed CI must pass on exact HEAD;
- independent review must verify every lifecycle has one owner and every
  cross-owner ordering relation is explicit;
- review must specifically challenge Target selection vs in-flight input,
  actor reentrancy, local fail-safe independence, session replacement, held
  state after timeout, and bounded capture behavior;
- `docs/architecture.md`, `AGENTS.md`, and ADR-0009 must not contradict this
  contract.

No physical-device test is required for this docs-only design PR. Physical
claims remain those already established by existing evidence; implementation
slices require their own exact-head device verification.

## Revisit conditions

Revisit this ADR when one of the following materially changes the ownership
model:

- CXI v2 makes target identity explicit per input command;
- a second production transport changes Session ownership requirements;
- Android → macOS pointer/keyboard input becomes an approved product direction;
- simultaneous multi-device control becomes approved scope;
- a materially different privileged host-input mechanism replaces the current
  unprivileged CGEventTap/suppression architecture; or
- new reproducible evidence disproves a safety assumption encoded here.
