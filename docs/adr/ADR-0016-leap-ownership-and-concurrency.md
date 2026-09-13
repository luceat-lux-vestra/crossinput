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

The pre-Leap architecture contains useful local boundaries, but global
correctness still depends on several independent mechanisms agreeing about
ownership at the same instant:

- `SessionReference.generation` plus a mutable pointer to the current connection;
- `ControlHandoffController.controlEpoch`, suppression generations, and
  `TransitionSequenceGate`;
- `TargetSelectionController.selectionToken`;
- a monolithic `InputCapture` that mixes TCC/capture, suppression, edge policy,
  watchdog/emergency handling, held-input bookkeeping, Android key semantics,
  and P0 confinement;
- an `InputSender` with separate pointer/keyboard queues, generation checks,
  held-button state, backpressure, wire translation, and delivery;
- `SessionConnection.requestBlocking()` using a semaphore bridge;
- `AppModel` coordinating unrelated lifecycle owners; and
- CXI v1 helper-global target selection combined with target-implicit input.

Adversarial review also found two concrete remote-state gaps:

1. `KEY_EVENT` is fire-and-forget while pointer transitions have an explicit
   result path, so a helper-side key rejection can be invisible while the
   Session remains alive; and
2. helper/backend teardown does not currently provide symmetric proof of remote
   held-state cleanup, notably for InputManager pointer state.

Architecture Leap #101 explicitly permits broad internal replacement. Diff size
and preservation of pre-Leap class/module shape are not design constraints.
The design preserves validated product behavior, device/protocol facts, safety
invariants, and reproducible evidence — not obsolete coordination mechanisms.

## Decision summary

The target architecture is built around six authoritative lifecycles:

1. Capability
2. Host capture
3. Session
4. Target
5. Control
6. Delivery

Each lifecycle has one owner. Cross-lifecycle coordination uses immutable
handles/leases and explicit barriers rather than a universal generation or
cross-layer epoch choreography.

The critical decisions are:

- immutable per-connection `SessionHandle` identity;
- confirmed Session-scoped `TargetLease` identity;
- one `ControlLease` per remote-ownership period;
- synchronous idempotent local return independent of actor/Android scheduling;
- one bounded synchronous `InputIngress` on the CGEventTap boundary;
- one ordered semantic delivery lane per ControlLease;
- one stateful `RemoteCommandLane` per SessionHandle;
- no blocking semaphore bridge;
- explicit semantic outcomes for persistent key/button transitions;
- non-abandonment of already-issued persistent transition outcomes;
- terminal old-target cleanup before helper-global route mutation;
- helper/backend cleanup as a proof obligation, never an assumption;
- platform-neutral semantic input before the remote adapter boundary; and
- App/UI as composition and projection, not hidden lifecycle ownership.

## 1. Authoritative lifecycles

### Capability

Owns whether macOS has the permissions/capabilities required to observe and
suppress input. Capability loss blocks Control and fails toward local control.
It does not become a Session failure.

### Host capture

Owns the CGEventTap and raw host-event observation lifetime. Capture may exist
while Control remains local. Capture and suppression are separate lifetimes.

### Session

Represents one concrete Android/helper/CXI connection instance. A replacement
connection is a new Session, never a mutation of the old identity.

### Target

Represents one confirmed selected remote routing context inside exactly one
Session.

### Control

Represents one period in which CrossInput is authorized to suppress local input
and deliver semantic input remotely.

### Delivery

Represents one bounded remote-input pipeline scoped to exactly one Control and
its captured Session/Target context.

These lifecycles must not collapse into one application state machine or one
global generation counter.

## 2. Handles and leases

A concrete connection is represented by an immutable **SessionHandle**. Its
identity and connection reference never change:

```text
open -> closing -> closed
```

Once closed, a SessionHandle never points at a replacement connection.
Reconnect/replacement therefore means:

1. invalidate/shut down SessionHandle A;
2. allow outstanding work to retain only A;
3. create SessionHandle B; and
4. publish B separately.

`SessionReference`-style mutable-current indirection is not part of the target
design.

The same identity rule applies to TargetLease and ControlLease. Their captured
owner references are immutable. Validity moves only toward closure/invalidation.
Typed IDs may exist for diagnostics/tests, but correctness does not depend on
comparing unrelated raw counters.

## 3. Target selection and routing honesty

CXI v1 `SELECT_DISPLAY` mutates helper-global route state. Target selection is
therefore a remote-state operation, not merely UI state.

A successful selection creates a **TargetLease** that is:

- scoped to exactly one SessionHandle;
- created only after helper confirmation;
- immutable in identity/target metadata;
- valid only while that Session and selected route remain valid; and
- required by commands whose semantics depend on selected-target routing.

### Selected target does not imply explicit backend routing

Binding a ControlLease to a TargetLease means that Control was acquired under
that selected-target context. It does **not** imply every backend can explicitly
route to that Android display.

The remote boundary must represent routing scope honestly, conceptually:

- `selectedTarget(TargetLease)` — command semantics depend on the selected
  target; or
- `sessionRouted(SessionHandle)` — backend/system policy routes at Session or
  system scope and cannot honestly promise a display ID.

This distinction is required because system-routed UHID cannot be described as
explicitly targeting an arbitrary Android display, and phone-vs-DeX keyboard
routing remains a physical-evidence question (#92).

## 4. ControlLease and fail-closed acquisition

Entering remote control creates one **ControlLease**:

```text
open -> closed
```

It binds:

- exact SessionHandle;
- exact TargetLease;
- one SuppressionLease;
- one synchronous InputIngress; and
- one asynchronous DeliveryWorker.

No callback may infer remote authority from a global boolean or a mutable
"current session" pointer. It must possess the current lease-bound ingress.
Late callbacks holding an old ingress see only closed/rejected admission.

Acquisition is fail-closed:

1. verify capability readiness and capture availability;
2. snapshot exact SessionHandle + TargetLease;
3. create InputIngress + DeliveryWorker bound to those resources;
4. prepare ControlLease + synchronous local-return gate;
5. atomically install SuppressionLease + exact ingress in the host suppression
   boundary; and
6. only then publish Control as remote-owned.

If any step fails, close/cancel partial resources and remain local.
Host suppression must never consume input without already having a valid bounded
ingress and synchronous local-return path.

## 5. Synchronous local-return gate

Actor scheduling is **not** part of the pointer-safety proof.

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

1. atomically mark ControlLease closing/closed;
2. close InputIngress immediately;
3. synchronously release/clear HostSuppressionController's active
   SuppressionLease and current-ingress slot so following host events pass
   locally; and
4. schedule, without waiting, ControlCoordinator reconciliation,
   DeliveryWorker quiescence/cancellation, remote cleanup, diagnostics, and any
   Session trust decision.

Steps 1-3 are the local safety boundary. They contain no transport write, actor
`await`, main-thread dispatch, helper response, or remote cleanup.

Lock ordering must be explicit. No arbitrary callback may execute while the tiny
safety-state lock is held. Deinitialization is defense in depth, not the primary
release mechanism.

### Capture race at closure

A callback that obtained the old suppression/ingress view before the gate closed
must still fail local deterministically:

- a closed ingress rejects the admission;
- the stale callback cannot reopen or replace the ingress;
- if a **non-droppable** event has not been admitted remotely, the suppression
  boundary must not newly consume that triggering event merely because it raced
  closure; it returns local and lets that host event pass where CGEventTap
  semantics permit; and
- additive motion/scroll may still be intentionally shed according to the
  bounded backpressure policy while Control is valid.

This prevents a rejected local key/button transition from being swallowed while
its matching later transition is delivered locally.

### External-control takeover

When another controller's triggering event causes takeover, local return must
not synthesize a pointer restore/park mutation that changes that event. The
triggering event passes through unchanged after suppression ownership is
released.

## 6. Host responsibility split and #96

The pre-Leap `InputCapture` responsibilities separate conceptually into:

- **InputCapabilityController** — permission/capability status and recovery;
- **MacEventTap** — tap lifecycle and raw observation;
- **MacInputTranslator** — macOS event -> semantic input;
- **EdgeDetector** — edge/hysteresis facts; and
- **HostSuppressionController** — event consumption, accepted P0 confinement,
  watchdog/emergency release, external takeover, and SuppressionLease ownership.

Exact type names are not frozen, but these responsibilities must not collapse
back into one implicit owner.

Only HostSuppressionController may consume local host input or perform accepted
P0 confinement.

The #96 decision remains authoritative:

- retain P0-style confinement;
- keep the native Mac cursor visible;
- accept/document the cursor-presentation limitation;
- no private SkyLight/CGS production dependency;
- no synthetic click/focus stealing;
- no pointer-jump workaround;
- no custom cursor solely to mask #96; and
- no equivalent cursor-API permutation experiments without materially new
  evidence.

## 7. HandoffPolicy is pure

Replace queue/callback-sequenced handoff orchestration with a pure
**HandoffPolicy**.

Inputs are facts such as enabled state, edge entry, entry edge,
requested/accepted movement acknowledgement, and return reason. Outputs are
acquire/remain/return decisions.

HandoffPolicy owns no transport, event tap, lock, task, queue, diagnostics, or
callback sequencing. ControlCoordinator serializes policy application.

Validated #45/#37 behavior remains unless deliberately superseded:

- return-direction movement credits requested intent when Android clamps
  accepted movement at a boundary;
- inward movement credits confirmed accepted movement;
- first post-entry movement cannot instantly return; and
- return hysteresis prevents edge wobble.

## 8. InputIngress and backpressure

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

If a non-droppable transition cannot be admitted, invoke local return rather
than silently losing remote persistent state.

## 9. DeliveryWorker and persistent outcome ownership

Each ControlLease owns one **DeliveryWorker**. It is never rebound to a new
Session, Target, or Control.

Responsibilities:

- drain exactly that ControlLease's InputIngress;
- serialize semantic input according to the ordered-lane contract;
- translate semantic input at the CXI v1 remote boundary;
- await semantic outcomes where required;
- return movement acknowledgement facts to handoff policy;
- maintain the host-side ledger of **confirmed** remote held inputs;
- classify applied/not-applied/ambiguous outcomes; and
- coordinate terminal cleanup after local return without blocking local safety.

`requestBlocking()` and semaphore-based async-to-sync bridges are removed.

### Commit point and non-abandonment rule

Cancellation is not allowed to erase knowledge about an already-issued
persistent state transition.

A persistent key/button transition has three phases:

1. **queued, not issued** — it may be cancelled safely before wire execution;
2. **issued / may have crossed the wire** — its correlation and semantic outcome
   become owned by the old Session/closing delivery context until it resolves or
   reaches a bounded ambiguity timeout; and
3. **resolved** — outcome is applied, proven-not-applied, or ambiguous.

Once phase 2 begins:

- ordinary Control closure stops new input but does not abandon result
  accounting;
- Task cancellation cannot silently discard the correlation;
- a late positive result updates only the **old closing context's** ledger;
- a late result can never mutate a replacement Control/Session ledger;
- target cleanup/selection barriers must account for every earlier issued
  persistent transition; and
- if an issued transition cannot be resolved, the old Session is untrustworthy
  for a new Target/Control context.

This rule closes the race where a `DOWN` is applied after local return but its
result is ignored, causing terminal cleanup to miss the matching `UP`.

### Semantic outcome classes

Remote result APIs must distinguish semantic certainty, not merely transport
completion:

- **applied** — backend contract confirms the transition took effect;
- **notApplied** — backend contract proves the transition did not take effect;
- **ambiguous** — the implementation cannot prove either state.

Timeout/stream loss after send is ambiguous. An explicit helper/backend failure
may be `notApplied` **only** when the backend contract proves that meaning;
otherwise it is ambiguous. A generic `failed` result must not be interpreted as
`notApplied` by default.

Held-state ledger updates occur only from `applied` outcomes. `notApplied`
leaves the ledger unchanged but still fails the active Control as appropriate.
`ambiguous` fails local immediately and feeds cleanup/Session trust policy.

## 10. RemoteCommandLane and ordering

Swift actor isolation alone is insufficient because actor methods may reenter
across `await` points.

Each SessionHandle owns an explicit **RemoteCommandLane** for stateful operations
whose relative order affects correctness:

- target selection;
- target-dependent pointer input;
- keyboard input under its honest routing scope;
- persistent held-input cleanup; and
- shutdown/reset operations that alter backend state.

### Baseline contract

The baseline executes one stateful command through semantic completion before
starting the next. This matches the current pointer request/response shape and
keeps target/cleanup barriers simple.

The architectural requirement is **total stateful ordering + explicit barriers**,
not "serial forever." Future bounded pipelining requires proof that:

- write order is deterministic;
- persistent outcome/commit order cannot reorder;
- target selection drains earlier target-dependent work;
- shutdown/reset acts as a barrier;
- stale TargetLease work is rejected before wire execution; and
- cancellation cannot permit an earlier command to semantically commit across a
  later barrier unnoticed.

Selected-target-dependent commands validate TargetLease at admission and again
immediately before wire execution.

Already-issued old-target work is ordered before terminal cleanup/selection.
Late ordinary old-target work after closure is rejected and never written.

## 11. Target change requires terminal cleanup before route mutation

The safe A -> B sequence is:

1. invoke Control A local-return gate;
2. close ordinary A ingress;
3. cancel/shear off queued **ordinary** A work that has not reached its wire
   commit point;
4. let every already-issued persistent transition ahead of the barrier reach a
   semantic outcome, updating only the closing A ledger;
5. if any such transition remains ambiguous, do not treat A as clean —
   invalidate/reconnect Session instead of selecting B on it;
6. while TargetLease A and route A are still valid, execute one terminal cleanup
   fence for the now-known confirmed held persistent state;
7. wait only under a bounded remote-cleanup policy for that fence;
8. if cleanup is confirmed, or there is provably nothing persistent to clean,
   invalidate TargetLease A;
9. enqueue ordered `SELECT_DISPLAY(B)` on the same RemoteCommandLane;
10. publish TargetLease B only after helper confirmation; and
11. only then permit Control B.

If route disappearance, cleanup timeout, backend ambiguity, or stream loss
prevents a trustworthy old-target state, do not reuse the Session as clean for
B. Invalidate it and re-establish remote state.

TargetLease A remains valid long enough for its own privileged terminal cleanup,
but ordinary A user input is already closed. Cleanup privilege admits no new
user input.

Additive motion/scroll may be discarded without Session replacement when no
persistent state becomes ambiguous.

## 12. Persistent state and keyboard outcome gap

Persistent state includes at least keys and pointer buttons.

Unknown outcome after a state-changing command must remain unknown. The system
must not invent a clean state from transport success, task cancellation, or
process death.

Rules:

- local return is immediate;
- cleanup is bounded;
- known held state is released under its old routing context where possible;
- unresolved persistent state prevents Session reuse as a clean basis for a new
  Control/Target; and
- no infinite cleanup retry is allowed.

Current CXI v1 keyboard delivery is insufficient because `KEY_EVENT` is
fire-and-forget. #141 must add an additive v1 capability/result contract or an
equivalent mechanism with the semantic certainty described above.

A minimal compatible protocol may still use a correlated key result, but a
single `failed` status is adequate only if its specification states whether it
means proven `notApplied` or `ambiguous`. Backend failure must never be promoted
to `notApplied` without evidence.

Host held-key state changes only from `applied` outcomes. Timeout, stream loss,
or backend-uncertain failure after send is ambiguous persistent state.

## 13. Helper/backend cleanup is a proof obligation

Architecture must not assume "helper/session died, therefore remote held state
is clean."

Current evidence is asymmetric:

- `UhidPointerInjector.close()` attempts a zero-button report before destroying
  the virtual device; while
- current `InputManagerPointerInjector.close()` clears local button bookkeeping
  but does not itself inject a matching release.

#107 must prove actual Android semantics or implement bounded explicit
release/reset while the old route is valid. The same obligation applies to
keyboard backend cleanup, backend failover, stream loss, target change, helper
shutdown, and idempotent repeated cleanup.

If trustworthy cleanup cannot be established, that limitation remains explicit
and feeds Session trust/recovery policy.

## 14. Platform-neutral semantic input

The semantic domain introduced by #103 must not contain:

- CoreGraphics/AppKit event types;
- macOS virtual-key implementation details beyond the host adapter;
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

## 15. Application state is projection

The application layer becomes a composition root plus presentation projection.
It may issue intents such as connect/disconnect, select target, enable/disable
control, emergency return, permission settings, and presentation refresh.

It does not own transport channels, event-tap internals, remote serialization,
or lifecycle reclassification. `AppModel` is not a compatibility requirement.

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
connecting   -> ready(SessionHandle)
connecting   -> failed/disconnected
ready        -> reconnecting/disconnected
reconnecting -> ready(new SessionHandle)
reconnecting -> failed/disconnected
```

A candidate stays private until handshake/capability negotiation succeeds.
Concrete SessionHandle is `open -> closing -> closed`.

### Target

```text
unavailable -> available(snapshot)
available   -> selecting(candidate)
selected(A) -> closing(A) -> selecting(B)
selecting   -> selected(TargetLease)
selecting   -> available/unavailable
any         -> unavailable     // Session invalidated
```

`closing(A)` includes issued-persistent reconciliation plus terminal cleanup.
If a trustworthy state cannot be established, Session is invalidated instead of
moving to B inside it.

### Control

```text
disabled -> local
local    -> remote(ControlLease)
remote   -> local
local    -> disabled
remote   -> disabled   // local-return gate first
```

A presentation/internal `returning` state may exist, but host suppression is
already released. Remote cleanup never traps the user in that state.

### Delivery

One worker/context per ControlLease:

```text
open -> closing -> closed
```

The ordinary ingress closes immediately on local return. A closing remote
context may remain only long enough to resolve already-issued persistent
outcomes and terminal cleanup; it is never rebound to new ordinary input.

## Failure-domain matrix

| Failure | Immediate Control action | Session/Target consequence |
| --- | --- | --- |
| missing/revoked capability | local/blocked | healthy Session/Target may remain |
| event-tap/capture failure | local/blocked | healthy Session/Target may remain |
| ordinary boundary return | local | Session/Target unchanged if remote state is clean |
| non-droppable admission saturation | local immediately | classify any earlier issued persistent state; current rejected event was not remotely admitted |
| additive motion/scroll timeout | local if required | Session may remain reusable if protocol/transport remains trustworthy |
| explicit proven-not-applied key/button result | local/fail-safe | Session may remain reusable after cleanup of prior confirmed held state |
| ambiguous key/button result | local immediately | cleanup; invalidate Session if certainty cannot be re-established |
| target disappearance/change | local immediately | reuse Session only after trustworthy old-target reconciliation/cleanup |
| transport/helper disconnect | local immediately | invalidate Session + Target; reconnect policy owns replacement |
| external-control takeover | local immediately; triggering event passes through | Session/Target unchanged unless independently failed |

Lower-domain failures must not be reclassified as unrelated lifecycle failures
merely to reuse an old API.

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
for transport/helper completion.

### Mac event-tap executor

Dedicated CFRunLoop/queue. Allowed work is bounded translation/classification,
tiny lock-protected ingress lookup/admission, local suppression, and local
fail-safe release.

Forbidden:

- transport I/O;
- actor waits;
- semaphore waits;
- unbounded allocation/work;
- main-thread round trips required for safety; and
- payload logging.

### ControlCoordinator

Intended as a Swift actor or equivalent explicit serial executor. Owns Control
lifecycle state and pure HandoffPolicy serialization. Local safety never waits
for it.

### SessionManager / concrete Session

SessionManager serializes connection/reconnect/replacement policy. Each concrete
Session owns protocol correlation, disconnect state, and RemoteCommandLane.

### DeliveryWorker

One async worker per ControlLease drains only that ingress and talks only to that
captured Session/routing context.

### Blocking rule

No target production path intentionally blocks an OS thread on remote progress.
Remote work may perform **bounded async awaits** for protocol outcomes/timeouts
inside Session/Delivery tasks. Local-return and capture paths do not await them.

### Cancellation rule

Cancellation means different things before and after a remote commit point:

- queued ordinary work not issued may be dropped/cancelled according to event
  class;
- closing InputIngress prevents new work;
- already-issued persistent transitions keep their old correlation/outcome
  ownership until resolved or classified ambiguous;
- terminal cleanup is a privileged closing operation, not ordinary input; and
- Session invalidation cancels remaining remote activity only after the system
  has conservatively classified unresolved persistent state as untrustworthy.

This distinction is mandatory; generic Task cancellation is not an ownership
model.

## Named invariants and enforcement points

### I1 — Local Safety
Mac control returns without Android, actor, or main-thread scheduling.

**Enforced by:** synchronous ControlLease local-return gate +
HostSuppressionController watchdog/emergency release.

### I2 — No Cross-Control Delivery
Work admitted for Control A cannot reach Control B.

**Enforced by:** per-Control permanently closed InputIngress + per-Control
DeliveryWorker/closing context.

### I3 — No Cross-Session Retargeting
Work holding Session A can never be redirected into Session B.

**Enforced by:** immutable SessionHandle identity; no mutable SessionReference.

### I4 — No Cross-Target Retargeting
Old-target ordinary input cannot become new-target input.

**Enforced by:** ingress closure, issued-persistent reconciliation, terminal A
cleanup, TargetLease validation, and ordered SELECT_DISPLAY barrier.

### I5 — One Suppression Owner
At most one valid SuppressionLease consumes host input.

**Enforced by:** HostSuppressionController single-owner slot + idempotent release.

### I6 — Bounded Capture Work
CGEventTap remains bounded/nonblocking.

**Enforced by:** synchronous bounded InputIngress; no remote/main/actor wait.

### I7 — Persistent Transitions Are Never Silently Lost
Key/button transitions are ordered and semantically classified.

**Enforced by:** one ordered lane, non-droppable admission, explicit semantic
outcomes, and non-abandonment after wire commit.

### I8 — Cleanup Never Blocks Local Return
Remote cleanup begins only after local safety release and remains bounded.

**Enforced by:** local-return ordering + async closing context.

### I9 — Ambiguous Persistent State Is Not Reused as Clean
Unknown key/button state cannot seed a new Control/Target context.

**Enforced by:** reconciliation/cleanup proof or Session invalidation.

### I10 — Diagnostics Are Payload-Safe
Raw pointer/key/HID/clipboard payloads never enter diagnostics.

**Enforced by:** typed metadata-only observations + payload tripwire tests.

### I11 — Routing Claims Are Honest
Target ownership does not imply explicit backend display routing.

**Enforced by:** typed routing scope + physical-evidence-backed backend claims.

## Deterministic proof/test strategy

Implementation slices must turn the invariants into deterministic tests. Physical
verification remains separately required when a claim depends on macOS/Samsung
behavior.

| Invariant | Deterministic proof strategy |
| --- | --- |
| I1 | race watchdog/emergency/failure callers; delay ControlCoordinator indefinitely; assert ingress closes and suppression releases exactly once |
| I2 | retain stale ingress/worker from Control A, acquire B, then attempt late A admission/delivery; assert B is unreachable |
| I3 | queue work on Session A, replace with B, then complete/cancel A responses; assert no command/result reaches B state |
| I4 | model A -> B with queued additive work, issued persistent transition, late result, cleanup, and selection; assert SELECT_DISPLAY(B) cannot pass unresolved A persistent state |
| I5 | concurrent acquire/release attempts; assert only one active SuppressionLease and idempotent first-winner release |
| I6 | source-level prohibition tests plus bounded-ingress stress/benchmark; no semaphore/remote await on event callback path |
| I7 | queue saturation, positive/notApplied/ambiguous results, late positive result after local return, and result reordering attempts; assert ledger/order rules |
| I8 | make cleanup/helper never respond; assert local return completes before cleanup timeout and cleanup terminates boundedly |
| I9 | timeout after persistent send and cleanup uncertainty; assert Session cannot become basis for new Target/Control |
| I10 | inject sentinel pointer/key/HID/clipboard payloads into error paths; assert diagnostics contain metadata only |
| I11 | compile/unit-test routing-scope APIs so session-routed backends cannot claim arbitrary TargetLease routing; physical evidence gates device claims |

Additionally, issue-level adversarial tests must cover capability loss without
Session failure, event-tap failure, external takeover, target disappearance,
helper shutdown, InputManager cleanup, stale responses, and additive-only
timeouts.

## Migration map

| Current responsibility/type | Target direction |
| --- | --- |
| `AppModel` | composition + presentation projection (#108) |
| `SessionController` | SessionManager connection/reconnect policy |
| `SessionReference` | **delete**; immutable SessionHandle |
| `RemoteSession` | concrete async session + ordered RemoteCommandLane |
| `requestBlocking()` | **delete** |
| `TargetSelectionController` | Target owner + TargetLease + reconciliation/cleanup/selection fence |
| `ControlHandoffController` | replace with ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` queue/sequences | pure HandoffPolicy |
| `TransitionSequenceGate` | **delete** |
| monolithic `InputCapture` | split capability/event-tap/translation/edge/suppression ownership |
| host `CapturedKeyEvent` Android semantics | remove from host domain (#103) |
| `InputSender` | InputIngress + per-Control DeliveryWorker/closing context |
| separate pointer/keyboard queues | **delete**; one ordered semantic lane |
| duplicate held-input bookkeeping | one outcome-based delivery ledger |
| fire-and-forget `KEY_EVENT` | **not final**; #141 semantic outcome contract |
| current protocol target | retain v1 framing; isolate adapter/translation |
| helper broad dispatch | audit/split protocol-target-backend ownership (#107) |
| InputManager pointer teardown mask reset | prove/replace with trustworthy cleanup (#107) |

## Migration strategy

Broad replacement is authorized; one giant rewrite PR is not.

1. every merged slice leaves one coherent runnable architecture;
2. temporary adapters have an owner and deletion point;
3. do not keep dual Control/Session/Target/delivery ownership indefinitely;
4. replace tests that encode obsolete structure rather than preserve bad
   architecture to keep them green;
5. preserve CXI v1 framing and validated DeX routing unless separately approved
   protocol work supersedes them;
6. preserve #96 exactly unless materially new evidence reopens it; and
7. reset-sensitive runtime changes require exact-head physical verification and
   ADR-0012 lineage handling.

Issue dependency sequence:

1. #102 — ownership/concurrency contract;
2. #103 — semantic input domain + module direction;
3. #99 / #104 / #105 — capability, host, Control migration;
4. #106 / #107 / #141 — delivery, helper/backend cleanup, keyboard outcome;
5. #108 — app composition/presentation convergence;
6. #109 — adversarial verification + legacy purge.

## Alternatives considered

### Preserve current controllers and only narrow them
Rejected. Smaller diff keeps raw generations/queues/callbacks as shared
correctness machinery.

### One global actor
Rejected. It combines independent lifecycles and weakens the capture/local
fail-safe boundary.

### Actors everywhere
Rejected. CGEventTap admission is synchronous; a tiny bounded lock is more
honest there.

### One global generation
Rejected. Session, Target, and Control are intentionally independent resources.

### Separate pointer/keyboard delivery queues
Rejected. They make cross-class persistent ordering emergent rather than owned.

### Fire-and-forget keyboard plus helper teardown
Rejected. A live Session may still lose/reject an individual key transition.

### Require CXI v2
Rejected. A small additive v1 outcome extension can satisfy the Leap contract.

### Treat generic `failed` as proven not-applied
Rejected. A backend/transport failure may occur after partial or uncertain
application. Semantic certainty must be explicit.

### Assume helper process exit cleans InputManager pointer state
Rejected without evidence. #107 must prove or implement cleanup.

## Consequences

Positive:

- stale work is isolated primarily by resource ownership;
- old Session work cannot redirect into a replacement;
- local pointer safety is independent of Android and actor scheduling;
- target changes reconcile issued persistent state before cleanup/selection;
- persistent input state is outcome-based rather than write-based;
- one ordered lane simplifies state ordering and cleanup;
- routing claims remain honest;
- blocking async-to-sync bridges disappear; and
- follow-up issues receive concrete proof obligations.

Cost:

- substantial internal rebuild;
- structure-coupled tests must be replaced;
- temporary migration adapters may be needed;
- #141 adds additive v1 protocol work;
- #107 must prove/repair backend teardown cleanup;
- runtime slices require repeated exact-head physical verification; and
- ADR-0012 cycle credit resets when candidate lineage is invalidated.

## Validation / proof obligations

Before accepting this ADR:

- exact-final-HEAD repository/documentation CI passes;
- exact-final-HEAD architecture review challenges the model rather than merely
  restating it;
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
5. target A -> B with an issued or confirmed held key/button;
6. target disappearance before reconciliation/cleanup completes;
7. Session replacement with queued/in-flight delivery;
8. capability revocation with healthy Session;
9. event-tap failure;
10. non-droppable InputIngress saturation;
11. helper-side key rejection while Session remains alive;
12. key/button timeout after send;
13. late positive persistent result after Control closes;
14. additive movement timeout;
15. external-control takeover;
16. watchdog/emergency return;
17. helper/backend cleanup including InputManager pointer state;
18. stale response after replacement; and
19. diagnostics payload isolation.

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
