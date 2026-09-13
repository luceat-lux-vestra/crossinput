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

The pre-Leap implementation contains useful local boundaries, but global
correctness still depends on several unrelated mechanisms agreeing about current
ownership:

- mutable `SessionReference` + raw connection generation;
- `ControlHandoffController.controlEpoch`, suppression generations, and
  `TransitionSequenceGate`;
- `TargetSelectionController.selectionToken`;
- monolithic `InputCapture` ownership of TCC/capture, suppression, edge policy,
  watchdog/emergency handling, held-input bookkeeping, Android key semantics,
  and P0 confinement;
- separate pointer/keyboard `InputSender` queues with generation checks,
  backpressure, held-state bookkeeping, wire translation, and delivery;
- `SessionConnection.requestBlocking()` using Task + semaphore bridging;
- `AppModel` coordinating lifecycles it should only compose/project; and
- CXI v1 helper-global target selection combined with target-implicit input.

Adversarial review of current code also exposed two concrete remote-state gaps:

1. pointer transitions have an explicit result path, but `KEY_EVENT` is
   fire-and-forget, so helper/backend keyboard rejection can be invisible while
   the Session remains alive; and
2. helper/backend teardown does not currently provide symmetric proof of held
   state cleanup, notably for InputManager pointer state.

Architecture Leap #101 explicitly permits broad internal replacement. Diff size,
pre-Leap type names, and tests that encode obsolete structure are not design
constraints. Preserve validated behavior, device/protocol facts, safety
invariants, and reproducible evidence — not accidental coordination machinery.

## Decision summary

The target architecture has six authoritative lifecycles:

1. Capability
2. Host capture
3. Session
4. Target
5. Control
6. Delivery

Each lifecycle has one owner. Cross-owner coordination uses immutable
handles/leases, explicit semantic outcomes, and explicit barriers rather than a
universal generation counter or cross-layer epoch choreography.

The critical decisions are:

- immutable per-connection `SessionHandle` identity;
- confirmed Session-scoped `TargetLease` identity;
- one `ControlLease` per remote-ownership period;
- synchronous idempotent local return independent of actor/Android scheduling;
- one bounded synchronous `InputIngress` on the CGEventTap boundary;
- suppression decisions coupled to ingress admission results;
- one ordered semantic delivery lane per ControlLease;
- one stateful `RemoteCommandLane` per SessionHandle;
- no blocking semaphore bridge;
- explicit semantic outcomes for persistent key/button transitions;
- non-abandonment of already-issued persistent transitions;
- a **remote-close fence** that blocks new Control acquisition until the old
  Control's remote state is clean;
- terminal old-target cleanup before helper-global route mutation;
- a **Session recovery cleanliness fence** before a dirty replacement Session
  may become control-capable;
- helper/backend cleanup as a proof obligation, never an assumption;
- platform-neutral semantic input before the remote adapter boundary; and
- App/UI as composition and projection, not hidden lifecycle ownership.

## 1. Authoritative lifecycles

### Capability

Owns whether macOS has the permissions/capabilities required to observe and
suppress input. Capability loss blocks Control and fails toward local control.
It does not automatically become a Session failure.

### Host capture

Owns CGEventTap lifecycle and raw host-event observation. Capture may exist while
Control remains local. Capture and suppression are separate lifetimes.

### Session

Represents one concrete Android/helper/CXI connection instance. A replacement
connection is a new Session, never a mutation of the old identity.

Session identity and remote-state cleanliness are distinct. A fresh connection
proves new ownership identity; it does **not** prove persistent state left by a
previous helper/backend has disappeared.

### Target

Represents one confirmed selected remote routing context inside exactly one
Session.

### Control

Represents one period in which CrossInput is authorized to suppress local input
and admit semantic input for remote delivery.

### Delivery

Represents one bounded remote-input pipeline scoped to exactly one Control and
its captured Session/Target context. Its closing work may outlive local
suppression, but it cannot admit new ordinary input.

These lifecycles must not collapse into one global application state machine or
one global generation. Remote cleanliness and remote-close readiness are
**gating conditions** on these lifecycles, not extra mutable owners.

## 2. Immutable handles and leases

A concrete connection is represented by an immutable **SessionHandle**:

```text
open -> closing -> closed
```

Its identity and connection reference never change. Once closed, it never points
at a replacement connection.

Reconnect/replacement therefore means:

1. invalidate/shut down SessionHandle A;
2. outstanding work may retain only A;
3. create candidate SessionHandle B; and
4. publish B as control-capable only after handshake/capability requirements and
   any required remote-state recovery fence succeed.

`SessionReference`-style mutable-current indirection is not part of the target
design.

`TargetLease` and `ControlLease` follow the same identity rule: captured owner
references and identity are immutable; validity moves only toward
closure/invalidation. Typed IDs may exist for diagnostics/tests, but correctness
must not depend on comparing unrelated raw counters.

## 3. Target selection is remote state

CXI v1 `SELECT_DISPLAY` mutates helper-global routing state. A selected target is
therefore not merely presentation state.

A successful selection creates a **TargetLease** that is:

- scoped to exactly one SessionHandle;
- created only after helper confirmation;
- immutable in identity/target metadata;
- valid only while that Session and selected route remain valid; and
- checked by every command whose semantics depend on selected-target routing.

### Routing ownership is not the same as routing claim

Binding a ControlLease to a selected TargetLease means that Control was acquired
under that selected-target context. It does **not** permit the implementation to
claim every backend explicitly routes to that display.

The remote boundary must represent routing scope honestly, conceptually:

- `selectedTarget(TargetLease)` — command semantics depend on the confirmed
  selected target; or
- `sessionRouted(SessionHandle)` — backend/system policy routes at Session/system
  scope and cannot honestly promise an arbitrary display ID.

This matters because system-routed UHID cannot be described as explicit-display
routing, and phone-vs-DeX keyboard routing remains a physical-evidence question
(#92).

## 4. One ControlLease owns one remote-ownership period

Entering remote control creates one **ControlLease**:

```text
open -> closed
```

It binds:

- exact SessionHandle;
- exact TargetLease;
- one host SuppressionLease;
- one synchronous InputIngress; and
- one asynchronous DeliveryWorker/closing context.

No input callback may infer remote authority from a global boolean or mutable
"current session" reference. It must possess the current lease-bound ingress.
Late callbacks holding an old ingress can only observe closed/rejected admission;
they can never become valid for a replacement ControlLease.

### Fail-closed acquisition

Acquisition order is part of the safety contract:

1. verify host capability and capture readiness;
2. snapshot exact SessionHandle + TargetLease;
3. verify the Session/Target context is control-capable — no dirty Session
   recovery requirement and no predecessor remote-close fence pending;
4. create InputIngress + DeliveryWorker bound to those exact resources;
5. prepare ControlLease + synchronous local-return handle;
6. atomically install the SuppressionLease + exact ingress into the host
   suppression boundary; and
7. only then publish Control as remote-owned.

If any step fails, synchronously release any installed suppression/ingress and
close/cancel partial resources. Remain local.

No fallible remote operation belongs after host suppression installation. Any
presentation/actor projection that follows installation is not the authority for
host safety; the prepared local-return handle is already valid.

The host suppression boundary must never consume local input without already
having a bounded ingress and synchronous local-return path.

## 5. Synchronous local-return gate

Actor scheduling is **not** part of pointer safety.

Every open ControlLease exposes one idempotent thread-safe local-return gate.
Triggers include:

- normal boundary return;
- watchdog;
- emergency shortcut;
- event-tap/capture loss;
- capability loss;
- delivery failure;
- Session invalidation/replacement;
- Target invalidation/change;
- external-control takeover;
- user disable/disconnect; and
- teardown.

The first caller wins. The bounded local sequence is:

1. atomically mark ControlLease closed for ordinary remote authority;
2. close InputIngress immediately;
3. synchronously release/clear HostSuppressionController's active
   SuppressionLease and current-ingress slot; and
4. schedule — without waiting — ControlCoordinator reconciliation,
   DeliveryWorker remote-close work, diagnostics, and Session trust decisions.

Steps 1-3 are the local safety boundary. They contain no transport write, actor
`await`, main-thread dispatch, helper response, or remote cleanup.

Lock ordering must be explicit. No arbitrary callback may execute while the tiny
safety-state lock is held. Deinitialization is defense in depth, not the primary
release mechanism.

### Capture race at closure

A callback that obtained the old suppression/ingress view before closure still
fails local deterministically:

- a closed ingress rejects admission;
- the stale callback cannot reopen or replace ingress;
- rejected non-droppable input is not newly consumed because it raced closure;
- where CGEventTap semantics permit, the triggering event passes through
  unchanged; and
- additive motion/scroll may still be intentionally shed only under the valid
  bounded-overload policy.

### External-control takeover

When another controller's triggering event causes takeover, local return must
not synthesize a pointer restore/park that alters that event. After suppression
release, the triggering event passes through unchanged.

## 6. Local return and remote close are intentionally different

Local safety completes at the synchronous local-return gate. Remote state may
still need reconciliation afterward.

Every closing Control therefore owns a bounded **remote-close fence**. The fence
covers, in order:

1. all persistent transitions already issued before ingress closure;
2. semantic outcome reconciliation for those transitions;
3. the final confirmed-held ledger for the closing Control; and
4. terminal cleanup/release of that known persistent state under the old
   routing/backend context.

While this fence is pending:

- host control is already local;
- no ordinary input may enter the old Control;
- **no replacement ControlLease may be acquired on that Session/Target context**;
- late semantic results update only the old closing context;
- a clean fence completion releases remote-control eligibility; and
- an ambiguous/failed-to-prove-clean fence moves the Session into recovery
  rather than allowing immediate re-entry.

This prevents normal return followed by immediate edge re-entry from overlapping
old cleanup with a new DeliveryWorker. It is also the primitive used by target
change and disconnect/recovery.

The user never waits synchronously for this fence. If it takes time, CrossInput
remains local until remote control is safe again.

## 7. Host responsibilities are split

The pre-Leap `InputCapture` responsibilities separate conceptually into:

- **InputCapabilityController** — permission/capability status and recovery;
- **MacEventTap** — event-tap lifecycle and raw event observation;
- **MacInputTranslator** — macOS event -> semantic input;
- **EdgeDetector** — edge/hysteresis facts; and
- **HostSuppressionController** — event consumption, accepted P0 confinement,
  watchdog/emergency release, external-control takeover, and SuppressionLease
  ownership.

Exact names may change, but these responsibilities must not collapse back into
one implicit owner.

Only HostSuppressionController may consume local host input or perform accepted
P0 cursor-confinement mutations.

The accepted #96 disposition remains authoritative:

- retain P0 confinement;
- keep the native Mac cursor visible;
- accept/document the cursor-presentation limitation;
- no private SkyLight/CGS production dependency;
- no synthetic click/focus stealing;
- no pointer-jump workaround;
- no custom cursor solely to mask #96; and
- no equivalent cursor-API permutation experiments without materially new
  evidence.

## 8. HandoffPolicy is pure

Replace internally queued/callback-sequenced handoff orchestration with a pure
**HandoffPolicy**.

Inputs are facts such as:

- enabled/disabled;
- edge entered / entry edge;
- requested/accepted remote movement acknowledgement; and
- explicit normal/failure return reason.

Outputs are acquire/remain/return decisions.

HandoffPolicy owns no transport, event tap, task, queue, lock, diagnostics, or
callback sequencing. ControlCoordinator serializes policy application.

Validated #45/#37 behavior remains unless deliberately superseded:

- return-direction movement credits requested intent when Android clamps
  accepted movement at a display boundary;
- inward movement credits confirmed accepted movement;
- first post-entry movement cannot instantly trigger return; and
- hysteresis prevents accidental edge wobble.

A policy decision to acquire remote control is still subject to the capability,
Session/Target readiness, and predecessor remote-close gates described here.

## 9. InputIngress and suppression admission

CGEventTap callbacks cannot `await`. Each open ControlLease owns one small
lock-protected **InputIngress** that:

- performs O(1) or otherwise strictly bounded synchronous admission;
- performs no transport I/O;
- performs no remote await/semaphore wait;
- returns an immediate admission result; and
- becomes permanently closed when Control ends.

One ordered semantic lane covers pointer and keyboard input.

| Event class | Coalesce | Shed | Required ordering |
| --- | --- | --- | --- |
| relative motion | adjacent only | yes under bounded overload | additive |
| scroll | adjacent only | yes when additive semantics are preserved | additive |
| pointer button down/up | never | never silently | strict |
| key down/up | never | never silently | strict |
| key repeat | no shedding by default | only with later proof | strict by default |
| cleanup/release | no lossy treatment | never silently | terminal/strong |

### Admission result controls suppression

For a host event intended for remote delivery, the event may be consumed only
after InputIngress returns an admission result that permits consumption, or when
the event is intentionally handled by the accepted P0 host-confinement
mechanism.

- successful admission may consume the corresponding host event;
- intentionally shed additive motion/scroll may be consumed only under the
  explicit bounded-overload policy while Control remains valid; and
- rejected **non-droppable** key/button/repeat input is not consumed. It invokes
  synchronous local return and the triggering host event passes through
  unchanged where CGEventTap semantics permit.

A full/closing ingress cannot silently turn a non-droppable event into host-side
loss.

## 10. DeliveryWorker owns persistent outcome accounting

Each ControlLease owns one **DeliveryWorker**. It is never rebound to another
Session, Target, or Control.

Responsibilities:

- drain exactly that ControlLease's InputIngress;
- serialize the ordered semantic lane;
- translate semantic input at the CXI v1 remote adapter boundary;
- await semantic outcomes where required;
- provide movement acknowledgement facts to HandoffPolicy;
- maintain the host-side ledger of **confirmed** remote held inputs;
- classify applied/not-applied/ambiguous outcomes; and
- own the closing remote-close fence after local return.

`requestBlocking()` and semaphore-based async-to-sync bridges are removed.

### Persistent commit point and non-abandonment

A persistent key/button transition has three phases:

1. **queued, not issued** — safe to cancel before wire execution;
2. **issued / may have crossed the wire** — the old Session/closing delivery
   context owns its correlation until semantic resolution or bounded ambiguity
   timeout; and
3. **resolved** — outcome is `applied`, proven `notApplied`, or `ambiguous`.

Once phase 2 begins:

- ordinary Control closure does not abandon outcome accounting;
- generic Task cancellation cannot silently discard correlation;
- a late positive result updates only the old closing context's ledger;
- no late result may mutate a replacement Control/Session ledger;
- the remote-close fence must account for every earlier issued persistent
  transition; and
- unresolved ambiguity makes the Session untrustworthy for remote re-entry.

This closes the race where a `DOWN` is applied after local return but its result
is ignored and cleanup therefore misses the matching `UP`.

### Semantic outcome classes

Result APIs classify semantic certainty, not transport completion:

- **applied** — backend contract confirms the transition took effect;
- **notApplied** — backend contract proves it did not take effect;
- **ambiguous** — neither state can be proved.

Timeout/stream loss after send is ambiguous. A helper/backend failure is
`notApplied` only when its contract proves no application; generic `failed` is
not interpreted as `notApplied` by default.

Held-state ledger changes only from `applied` outcomes. A failed/`notApplied`
release leaves a previously confirmed held item in the ledger for terminal
cleanup. `ambiguous` immediately fails Control local and drives Session recovery
if cleanliness cannot be re-established.

## 11. RemoteCommandLane owns stateful wire ordering

Swift actor isolation alone is insufficient because actor methods can reenter
across `await`.

Each SessionHandle owns an explicit **RemoteCommandLane** for stateful operations
whose relative order affects correctness:

- target selection;
- target-dependent pointer input;
- keyboard input under its honest routing scope;
- persistent cleanup/reset; and
- shutdown operations that alter backend state.

### Baseline execution contract

The baseline executes one stateful command through semantic completion before
starting the next. This intentionally matches the current pointer
request/response model and keeps barriers understandable.

The architectural requirement is **total stateful ordering + explicit
barriers**, not "serial forever." Future bounded pipelining requires measured
need plus proof that:

- write order stays deterministic;
- persistent outcome/commit order cannot reorder;
- target selection drains earlier target-dependent work;
- cleanup/reset/shutdown act as barriers;
- stale TargetLease work is rejected before wire execution; and
- cancellation cannot allow an earlier command to semantically commit across a
  later barrier unnoticed.

Selected-target-dependent commands validate TargetLease at admission and again
immediately before wire execution.

Read-only/discovery requests may use a separate path only when they cannot race
helper-global route/input state.

## 12. Target A -> B uses the remote-close fence

A target change must not let old-target persistent state leak across
`SELECT_DISPLAY`.

Safe sequence:

1. invoke Control A synchronous local return;
2. close ordinary A ingress;
3. cancel queued ordinary A work not yet issued;
4. through Control A's remote-close fence, resolve every already-issued
   persistent transition;
5. if any issued transition becomes ambiguous, invalidate A's Session and enter
   Session recovery instead of selecting B on it;
6. while TargetLease A and route A remain valid, perform terminal cleanup for
   the now-known confirmed held state;
7. wait only under a bounded **async** cleanup policy for the remote-close fence;
8. if clean, invalidate TargetLease A;
9. enqueue ordered `SELECT_DISPLAY(B)` on the same RemoteCommandLane;
10. publish TargetLease B only after helper confirmation; and
11. only then permit Control B.

If route disappearance, cleanup timeout, backend ambiguity, or stream loss
prevents a trustworthy old-target state, do not reuse that Session as clean.
Enter the Session recovery fence.

TargetLease A remains valid long enough for privileged terminal cleanup, but no
new ordinary A input is admitted. Additive motion/scroll may be discarded when
no persistent state becomes ambiguous.

## 13. Session recovery requires remote-state cleanliness proof

Invalidating SessionHandle A prevents stale ownership from reaching replacement
SessionHandle B. It does **not** prove Android persistent state created by A has
been cleared.

When A is invalidated because persistent state is ambiguous, SessionManager
enters a recovery-required condition. A transport/helper candidate may be used
for bounded recovery, discovery, or reset work, but it is not published as a
**control-capable ready Session**, and no usable TargetLease/ControlLease may be
created for input until a recovery fence proves a trustworthy neutral remote
state.

A recovery fence may be satisfied only by evidence-backed semantics such as:

- confirmed terminal cleanup under the old routing/backend context;
- an explicit helper/backend reset whose contract proves held state neutral;
- teardown/recreation of a backend identity for which platform evidence proves
  destruction clears relevant held state; or
- another separately reviewed mechanism with equivalent proof.

Merely reconnecting ADB, launching a new helper, obtaining HELLO_ACK, or creating
a fresh SessionHandle is **not** proof of cleanliness.

If no available recovery mechanism can prove neutral state, CrossInput remains
local/blocked for remote Control rather than assuming a new Session is clean.
Local host control has already returned and never waits for recovery.

#107 owns backend-specific cleanup/reset proof and implementation.

## 14. Persistent keyboard outcome gap / #141

Current CXI v1 keyboard `KEY_EVENT` delivery is fire-and-forget and is not the
final architecture.

#141 must add the smallest compatible additive v1 outcome contract (or an
equivalent mechanism) with the semantic certainty defined here.

Required properties:

- correlated result for every new-path persistent key transition;
- `applied`, proven `notApplied`, and `ambiguous` semantics directly or through
  an unambiguous equivalent mapping;
- capability negotiation so a new client does not silently use an old helper;
- outcome accounting survives ordinary Control closure once a transition may
  have crossed the wire;
- stale results cannot mutate replacement Control/Session state; and
- no blocking semaphore bridge.

A two-state `delivered/failed` encoding is sufficient only if the protocol proves
what `failed` means. Backend uncertainty must never be mislabeled as
`notApplied`.

## 15. Helper/backend cleanup is a proof obligation / #107

Architecture must not assume "helper/session died, therefore remote held state
is clean."

Current evidence is asymmetric:

- `UhidPointerInjector.close()` attempts a zero-button report before virtual
  device destruction; while
- current `InputManagerPointerInjector.close()` clears local button bookkeeping
  but does not itself inject a matching release.

#107 must prove actual Android semantics or implement bounded explicit
release/reset. The obligation also covers keyboard backends, backend failover,
stream loss, target change, helper shutdown, Session recovery, and idempotent
repeated cleanup.

If trustworthy cleanup cannot be established, that limitation remains explicit
and keeps remote Control blocked rather than being hidden by local bookkeeping.

## 16. Platform-neutral semantic input

The semantic domain introduced by #103 must not contain:

- CoreGraphics/AppKit event types;
- macOS implementation details beyond the host adapter;
- Android `KEYCODE_*` / `META_*` constants;
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

`CapturedKeyEvent` carrying Android KeyEvent semantics is not a target host-domain
API.

## 17. Application state is composition/projection

The application layer becomes a composition root plus presentation projection.
It may issue intents such as connect/disconnect, target selection,
enable/disable control, emergency return, permission settings, and UI refresh.

It does not own transport channels, event-tap internals, remote serialization,
remote-close fences, or lifecycle reclassification. `AppModel` is not a
compatibility requirement.

## Lifecycle state contracts

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
connecting   -> ready(clean SessionHandle)
connecting   -> failed/disconnected
ready        -> reconnecting/disconnected
ready        -> recoveryRequired(reason)
reconnecting -> ready(clean new SessionHandle)       // only if no dirty predecessor
reconnecting -> failed/disconnected
recoveryRequired -> recovering(candidate/reset)
recovering   -> ready(clean SessionHandle)            // recovery fence proved neutral
recovering   -> recoveryRequired/failed/disconnected
```

A candidate stays private until handshake/capability negotiation and any required
cleanliness fence succeed.

### Target

```text
unavailable -> available(snapshot)
available   -> selecting(candidate)
selected(A) -> closing(A) -> selecting(B)
selecting   -> selected(TargetLease)
selecting   -> available/unavailable
any         -> unavailable     // Session invalidated
```

`closing(A)` includes predecessor Control remote-close completion and target
terminal cleanup. Failure to prove clean enters Session recovery instead of
moving to B inside a dirty Session.

### Control

Host ownership returns immediately:

```text
disabled -> local
local    -> remote(ControlLease)
remote   -> local
local    -> disabled
remote   -> disabled   // synchronous local return first
```

Remote eligibility is separately fenced:

```text
controlEligible
  -> remote(ControlLease)
  -> remoteClosePending(old Control)
  -> controlEligible                  // clean close
  -> sessionRecoveryRequired          // ambiguous close
```

`remoteClosePending` never traps host control. It only blocks new remote
acquisition.

### Delivery

One worker/closing context per ControlLease:

```text
open -> closing(remote-close fence) -> closed
```

Ordinary ingress closes immediately on local return. The closing context exists
only to resolve already-issued persistent outcomes and terminal cleanup. It is
never rebound to new input.

## Failure-domain matrix

| Failure | Immediate host action | Remote consequence |
| --- | --- | --- |
| missing/revoked capability | local/blocked | healthy Session/Target may remain; close fence still resolves prior persistent state |
| event-tap/capture failure | local/blocked | healthy Session/Target may remain only after prior Control close proves clean |
| ordinary boundary return | local immediately | new Control blocked until remote-close fence proves clean |
| non-droppable admission saturation | local; triggering event not consumed | close fence classifies prior issued persistent state |
| additive motion/scroll timeout | local if required | Session may remain reusable if lane/protocol remains trustworthy and close proves clean |
| proven-not-applied key/button | local/fail-safe | ledger unchanged for that transition; close prior confirmed holds; reuse only if clean |
| ambiguous key/button | local immediately | Session recovery if close cannot prove neutral state |
| target change/disappearance | local immediately | target switch only after clean old close; otherwise Session recovery |
| helper/transport disconnect | local immediately | invalidate Session/Target; recovery fence if persistent state may be dirty |
| external-control takeover | local; triggering event unchanged | close fence still resolves prior remote state |

Lower-domain failures must not be reclassified as unrelated lifecycle failures
merely to reuse an existing API.

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

- Remote does not depend on MacHost;
- MacHost does not depend on Android/CXI/UHID/InputManager details;
- CrossInputDomain depends on neither platform;
- CXI framing is not a domain concept; and
- diagnostics is metadata-only and cannot carry raw input payloads.

## Concurrency, blocking, and cancellation contract

### MainActor

Owns composition/presentation projection, UI intents, and AppKit presentation.
It is not on the capture or remote-input hot path and never synchronously waits
for remote progress.

### Mac event-tap executor

Dedicated CFRunLoop/queue. Allowed work is bounded translation/classification,
tiny lock-protected lease/ingress lookup, bounded admission, local suppression,
and local fail-safe release.

Forbidden:

- transport I/O;
- actor waits;
- semaphore waits;
- main-thread round trips required for safety;
- unbounded allocation/work; and
- payload logging.

### ControlCoordinator

Intended as a Swift actor or equivalent explicit serial executor. Owns Control
lifecycle, remote-control eligibility, predecessor remote-close gating, and pure
HandoffPolicy serialization.

Local host return never waits for this actor.

### SessionManager / concrete Session

SessionManager serializes connect/reconnect/replacement/recovery and publishes
only clean control-capable Sessions. Each concrete Session owns protocol
correlation, disconnect state, and RemoteCommandLane.

### DeliveryWorker

One async worker/closing context per ControlLease. It drains only that ingress,
talks only to the captured Session/routing context, and owns that Control's
remote-close fence.

### Blocking rule

No target production path intentionally blocks an OS thread on remote progress.
Remote tasks may perform **bounded async awaits** for semantic outcomes and
cleanup/reset timeouts. Capture/local-return never await them.

### Cancellation rule

Cancellation semantics depend on the remote commit point:

- queued ordinary work not issued may be dropped/cancelled according to event
  class;
- ingress closure prevents new work;
- already-issued persistent transitions retain old correlation/outcome ownership
  until resolved or classified ambiguous;
- terminal cleanup is privileged closing work;
- a pending remote-close fence blocks replacement Control acquisition; and
- Session invalidation/replacement cannot convert unresolved persistent state
  into a clean new Session without the recovery fence.

Generic Task cancellation is not an ownership model.

## Named invariants and enforcement points

### I1 — Local Safety
Mac control returns without Android, actor, or main-thread scheduling.

**Enforced by:** synchronous ControlLease local-return gate +
HostSuppressionController watchdog/emergency release.

### I2 — No Cross-Control Delivery
Work admitted for Control A cannot reach Control B.

**Enforced by:** permanently closed per-Control InputIngress + per-Control
DeliveryWorker/closing context.

### I3 — No Cross-Session Retargeting
Work holding Session A cannot redirect into Session B.

**Enforced by:** immutable SessionHandle identity; no mutable SessionReference.

### I4 — No Cross-Target Retargeting
Old-target ordinary input cannot become new-target input.

**Enforced by:** ingress closure, old remote-close fence, TargetLease validation,
terminal cleanup, and ordered selection barrier.

### I5 — One Suppression Owner
At most one valid SuppressionLease consumes host input.

**Enforced by:** HostSuppressionController single-owner slot + idempotent release.

### I6 — Bounded Capture Work
CGEventTap remains bounded/nonblocking.

**Enforced by:** synchronous bounded InputIngress; no remote/main/actor wait.

### I7 — Persistent Transitions Are Never Silently Lost
Key/button transitions are ordered and semantically classified.

**Enforced by:** one ordered lane, non-droppable admission, admission-bound
suppression, explicit semantic outcomes, and non-abandonment after wire commit.

### I8 — Cleanup Never Blocks Local Return
Remote close/cleanup begins only after local safety release and remains bounded.

**Enforced by:** synchronous local-return ordering + async remote-close fence.

### I9 — Ambiguous Persistent State Is Not Reused as Clean
Unknown key/button state cannot seed a new Target/Control context, even through a
fresh helper/transport/SessionHandle.

**Enforced by:** reconciliation/cleanup proof + Session recovery cleanliness
fence.

### I10 — Diagnostics Are Payload-Safe
Raw pointer/key/HID/clipboard payloads never enter diagnostics.

**Enforced by:** typed metadata-only observations + payload tripwire tests.

### I11 — Routing Claims Are Honest
Selected Target ownership does not imply explicit backend display routing.

**Enforced by:** typed routing scope + physical-evidence-backed backend claims.

### I12 — Control Reacquisition Cannot Cross a Dirty Close
A replacement Control cannot start while the predecessor Control still has
issued persistent outcomes or terminal cleanup pending.

**Enforced by:** ControlCoordinator remote-control eligibility + per-Control
remote-close fence. Clean completion re-enables acquisition; ambiguity enters
Session recovery.

## Deterministic proof/test strategy

Implementation slices must convert the invariants into deterministic tests.
Physical verification remains separately required where a claim depends on
macOS/Samsung behavior.

| Invariant | Deterministic proof strategy |
| --- | --- |
| I1 | race watchdog/emergency/failure callers; delay ControlCoordinator indefinitely; assert ingress closes and suppression releases exactly once |
| I2 | retain stale ingress/worker from Control A, acquire B only after A close, then attempt late A admission/delivery; assert B is unreachable |
| I3 | queue work on Session A, replace with B, then complete/cancel A responses; assert no command/result reaches B state |
| I4 | model A -> B with queued additive work, issued persistent work, late result, close fence, cleanup, and selection; assert selection cannot pass unresolved A state |
| I5 | concurrent acquire/release attempts; assert exactly one active SuppressionLease and first-winner release |
| I6 | source-level prohibition checks + bounded-ingress stress/benchmark; no semaphore/remote await on event callback path |
| I7 | queue saturation must return rejected non-droppable input locally; exercise applied/notApplied/ambiguous outcomes, late positive results, and reordering attempts |
| I8 | make cleanup/helper never respond; assert host return completes before cleanup timeout and remote-close terminates to recovery boundedly |
| I9 | make Session A persistent state ambiguous, connect candidate B, withhold reset/cleanup proof; assert B cannot publish a usable TargetLease or acquire Control |
| I10 | inject sentinel pointer/key/HID/clipboard payloads into error paths; assert diagnostics contain metadata only |
| I11 | type/unit tests prevent session-routed backends from claiming arbitrary TargetLease routing; physical evidence gates device claims |
| I12 | return local while persistent result/cleanup is pending, immediately request reacquisition, and assert no new Control/ingress exists until clean close; ambiguity must enter Session recovery |

Issue-level adversarial tests must additionally cover capability loss without
Session failure, event-tap failure, external takeover, target disappearance,
helper shutdown, InputManager cleanup, stale responses, and additive-only
timeouts.

## Migration map

| Current responsibility/type | Target direction |
| --- | --- |
| `AppModel` | composition + presentation projection (#108) |
| `SessionController` | SessionManager connect/reconnect/recovery policy |
| `SessionReference` | **delete**; immutable SessionHandle |
| `RemoteSession` | concrete async session + ordered RemoteCommandLane |
| `requestBlocking()` | **delete** |
| `TargetSelectionController` | Target owner + TargetLease + close/cleanup/select barriers |
| `ControlHandoffController` | replace with ControlCoordinator + ControlLease + remote-close eligibility |
| `EdgeSwitchStateMachine` internal queue/sequences | pure HandoffPolicy |
| `TransitionSequenceGate` | **delete** |
| monolithic `InputCapture` | split capability/event-tap/translation/edge/suppression ownership |
| host `CapturedKeyEvent` Android semantics | remove from host domain (#103) |
| `InputSender` | InputIngress + per-Control DeliveryWorker/closing context |
| separate pointer/keyboard queues | **delete**; one ordered semantic lane |
| duplicate held-input bookkeeping | one outcome-based delivery ledger |
| fire-and-forget `KEY_EVENT` | **not final**; #141 semantic outcome contract |
| current protocol target | retain v1 framing; isolate adapter/translation |
| helper broad dispatch | audit/split protocol-target-backend ownership (#107) |
| InputManager pointer teardown mask reset | prove/replace with trustworthy cleanup/reset (#107) |

## Migration strategy

Broad replacement is authorized; one giant rewrite PR is not.

1. every merged slice leaves one coherent runnable architecture;
2. temporary adapters require an owner and deletion point;
3. do not keep dual Control/Session/Target/delivery ownership indefinitely;
4. replace tests that encode obsolete structure instead of preserving bad
   architecture merely to keep them green;
5. preserve CXI v1 framing and validated DeX routing unless separately approved
   protocol work supersedes them;
6. preserve accepted #96 behavior unless materially new evidence reopens it; and
7. reset-sensitive runtime changes require exact-head physical verification and
   ADR-0012 lineage handling.

Issue dependency sequence:

1. #102 — ownership/concurrency contract;
2. #103 — semantic input domain + module direction;
3. #99 / #104 / #105 — capability, host, Control migration;
4. #106 / #107 / #141 — delivery, helper/backend cleanup, keyboard outcome;
5. #108 — application composition/presentation convergence;
6. #109 — adversarial verification + legacy purge.

## Alternatives considered

### Preserve current controllers and narrow them only
Rejected. Smaller diff retains the hardest problem: generations, locks, queues,
and callbacks still have to agree on current ownership.

### One global actor
Rejected. It combines unrelated lifecycles and weakens the CGEventTap/local
fail-safe boundary.

### Actors everywhere
Rejected. CGEventTap admission is synchronous by nature; a small bounded lock is
more honest there.

### One global generation
Rejected. Session, Target, and Control are intentionally independent resources.

### Separate pointer/keyboard delivery queues
Rejected. They make cross-class persistent ordering emergent rather than owned.

### Allow immediate re-entry after local return
Rejected. Local suppression may be safely released before remote state is clean;
that must not authorize a new DeliveryWorker to overlap predecessor outcome/
cleanup work.

### Fire-and-forget keyboard plus helper teardown
Rejected. A live Session may still reject/drop an individual key transition.

### Treat generic `failed` as proven not-applied
Rejected. Backend/transport failure may occur after partial or uncertain
application. Semantic certainty must be explicit.

### Require CXI v2 now
Rejected. An additive v1 result extension can satisfy the correctness contract
without coupling #102 to the broader v2 migration.

### Assume a fresh Session is clean
Rejected. New connection identity prevents stale ownership retargeting but does
not prove old held state disappeared.

### Assume helper process exit cleans InputManager state
Rejected without evidence. #107 must prove or implement cleanup/reset.

## Consequences

Positive:

- stale work is isolated primarily by resource ownership;
- old Session work cannot redirect into a replacement;
- local pointer safety is independent of Android and actor scheduling;
- suppression admission cannot silently swallow rejected non-droppable input;
- normal return cannot race immediate re-entry across dirty remote state;
- target changes reconcile old persistent state before route mutation;
- dirty Session replacement cannot bypass unresolved held state;
- persistent state becomes outcome-based rather than write-based;
- one ordered lane simplifies state ordering and cleanup;
- routing claims remain honest;
- blocking async-to-sync bridges disappear; and
- follow-up issues receive concrete proof obligations.

Cost:

- substantial internal rebuild;
- structure-coupled tests must be replaced;
- temporary migration adapters may be needed;
- remote re-entry can be briefly unavailable while bounded close/cleanup resolves;
- #141 adds additive CXI v1 protocol work;
- #107 must prove/repair backend cleanup and recovery semantics;
- runtime slices require repeated exact-head physical verification; and
- ADR-0012 cycle credit resets when candidate lineage is invalidated.

## Validation / proof obligations

Before accepting this ADR:

- exact-final-HEAD repository/documentation CI passes;
- exact-final-HEAD independent/adversarial architecture review challenges the
  model rather than merely restating it;
- no contradictory current architecture/agent rule remains;
- every major mutable lifecycle has one authoritative owner;
- blocking/cancellation semantics are explicit;
- every cross-owner ordering relation is explicit;
- named invariants have enforcement points and deterministic proof strategy; and
- no safety claim relies on actor scheduling or unproved remote cleanup.

Review must trace at least:

1. normal handoff and return;
2. Control acquisition failure halfway through setup;
3. local return while ControlCoordinator is delayed;
4. target A -> B with ordinary input queued/in-flight;
5. target A -> B with issued/confirmed held key/button;
6. target disappearance before reconciliation/cleanup completes;
7. Session replacement with queued/in-flight delivery, including dirty-state
   recovery before replacement becomes control-capable;
8. capability revocation with healthy Session;
9. event-tap failure;
10. non-droppable InputIngress saturation + triggering-event pass-through;
11. helper-side keyboard rejection while Session stays alive;
12. key/button timeout after send;
13. late positive persistent result after Control closes;
14. immediate remote re-entry attempt while predecessor close fence is pending;
15. additive movement timeout;
16. external-control takeover;
17. watchdog/emergency return;
18. helper/backend cleanup including InputManager pointer state;
19. stale response after replacement; and
20. diagnostics payload isolation.

This PR is docs-only. It creates no new runtime claim, so new physical testing is
not required for the ADR itself. Each implementation slice supplies exact-head
physical evidence where the claim depends on macOS + Samsung DeX behavior.

## Revisit conditions

Revisit this ADR if any of the following materially changes the ownership model:

- CXI v2 makes target identity explicit per input command;
- a second production transport changes Session ownership;
- Android -> macOS pointer/keyboard becomes approved scope;
- simultaneous multi-device control becomes approved scope;
- a materially different privileged host-input mechanism replaces the current
  CGEventTap/suppression design; or
- new reproducible evidence disproves a safety assumption above.
