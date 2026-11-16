# ADR-0017: Architecture Leap Midpoint Rebaseline

> Status: **proposed**
> Date: 2026-11-16
> Issue: #284
> Parent Track: #114
> Epic: #101
> Supersedes: ADR-0016 as the target ownership/concurrency architecture

## Context

Ampersand 0.1.3 is usable enough to serve as a field-use behavioral baseline, but
the Architecture Leap is still in progress. The midpoint review was intentionally
performed against current production code and physical/device evidence rather
than assuming ADR-0016 was correct because it had already been written.

The review found that ADR-0016 made several useful corrections to the pre-Leap
prototype but still over-modeled some lifecycles and placed one important safety
property on the wrong owner.

Current production safety is implemented by a large amount of cross-object
coordination:

- `SessionReference.generation`;
- target-selection tokens;
- control epochs;
- capture/suppression generations;
- CoreHID ownership generations;
- boundary tokens;
- edge-transition sequence numbers and `TransitionSequenceGate`;
- separate pointer and keyboard queues;
- lock-protected cleanup state; and
- a blocking async-to-sync request bridge.

Those mechanisms are evidence of real races that must remain prevented, but they
are not the architecture to preserve.

The largest ownership error in ADR-0016 is remote cleanliness. A CXI/ADB
connection may be replaced while Android persistent input state remains
ambiguous. Therefore a new connection identity cannot own or reset the truth of
whether the Android endpoint is safe for another control period. The trust state
belongs above individual connections.

The midpoint review also found that:

- target selection is primarily mutable remote route state, not necessarily a
  peer top-level lifecycle owner;
- the ADR-0016 graph of SessionHandle, TargetLease, ControlLease,
  SuppressionLease, InputIngress, DeliveryWorker and remote-close fence can be
  simplified without weakening the invariants;
- the current DeX/UHID low-latency movement path intentionally writes
  `requestId = 0` movement without one response RTT per sample and must not be
  accidentally serialized by a new command-lane abstraction;
- persistent delivery certainty must be named after the strongest boundary the
  backend can actually prove, not after an assumed end-to-end application
  effect;
- InputManager ASYNC acceptance is not sufficient evidence for persistent
  key/button cleanliness; and
- retry/fallback after a persistent transition whose commit outcome is unknown
  can duplicate state.

ADR-0016 remains valuable historical reasoning, especially its local-safety,
stale-work, immutable-context, bounded-capture and cleanup principles. This ADR
replaces its target ownership model.

## Decision

### 1. Preserve behavior and evidence, not the current object graph

The following are compatibility requirements unless separately superseded by
reviewed evidence:

- macOS local return never waits for Android;
- the emergency return path remains independent of remote progress;
- the production CoreHID built-in-trackpad owner remains isolated in a
  disposable process with exact-device binding, prepare/commit acquisition and
  independent physical-release evidence;
- the remote cursor presentation helper remains isolated from physical pointer
  ownership;
- Samsung DeX desktop pointer delivery remains system-routed UHID where the
  validated AUTO policy selects it;
- non-desktop explicit-display pointer delivery retains the InputManager path;
- DeX normal return remains based on the Android compositor-authority contract;
- high-rate DeX movement retains its one-way low-latency
  `POINTER_MOVE_REL(requestId = 0)` behavior;
- CXI v1 remains the protocol baseline; and
- no raw input payload is added to diagnostics.

Current classes, queues, generation counters and callback topology are not
compatibility requirements.

### 2. Use three durable ownership boundaries

The target runtime has three durable owners.

#### HostInputRuntime

Owns the macOS input environment:

- capability/readiness observation;
- event-tap lifecycle;
- semantic keyboard translation;
- edge observation/detection;
- CoreHID pointer acquisition/release;
- cursor presentation; and
- the small synchronous host-safety gate used by the active control period.

These remain separate components internally. `HostInputRuntime` is the
composition/ownership boundary, not a new monolith.

#### RemoteEndpoint

Represents the currently controlled Android device, independent of one concrete
ADB/CXI connection.

It owns:

- endpoint identity;
- endpoint trust: `clean` or `uncertain(reason)`;
- the current concrete CXI connection, if any;
- remote route state and a monotonically changing route revision;
- connection/reconnect/replacement policy;
- remote command serialization;
- closing-control exclusion; and
- evidence-backed recovery/reset that may move endpoint trust from
  `uncertain` back to `clean`.

A fresh ADB transport, helper process, HELLO_ACK, or CXI connection does not
change `uncertain` to `clean` by itself.

#### ControlCoordinator

Owns orchestration between the host and remote endpoint. It consumes facts,
creates one transient `ControlSession`, projects high-level state and initiates
return/recovery. It does not own transport details, event taps, backend details
or UI state.

High-level orchestration should use Swift structured concurrency/actor isolation
where appropriate. Host safety does not depend on actor scheduling.

### 3. Model one remote-control period as ControlSession

One `ControlSession` represents one Mac-to-Android ownership period.

Conceptually:

```text
preparing -> active -> returning -> closed
     \-------------------------> closed
```

A ControlSession owns exactly the resources for that period:

- one host control/suppression handle;
- one synchronous bounded host admission gate;
- one immutable `RemoteControlChannel`;
- one delivery pump;
- one boundary-watch handle when required; and
- one close result.

The public architecture does not require a graph of independently coordinated
SessionHandle/TargetLease/ControlLease/SuppressionLease/fence objects. Internal
components may use small handles when they clarify a local responsibility, but
they must not recreate distributed lifecycle ownership.

### 4. Bind remote work to an immutable RemoteControlChannel

Before host suppression becomes active, `RemoteEndpoint` prepares an immutable
remote channel containing at least:

- concrete connection identity;
- selected route identity;
- route revision;
- routing capability/scope;
- endpoint identity; and
- control-period identity.

The channel is never rebound.

Old work therefore cannot look up "the current session" or "the current target"
and redirect into replacement state. Reconnect or route change creates a new
future channel; it cannot mutate an existing one into new ownership.

`SessionReference`-style mutable indirection is not part of the target
architecture.

### 5. Treat target selection as ordered RemoteEndpoint route state

CXI v1 `SELECT_DISPLAY` mutates helper-global routing state and therefore
remains a strong remote ordering barrier.

The endpoint owns:

```text
RemoteRoute
  target identity
  route revision
  routing scope/capability
```

A route mutation is allowed only after the previous control period has returned
local and its remote channel has reached a clean close, or after the endpoint
has been moved to `uncertain` and control is blocked.

A new control channel captures one route revision immutably. Work for an older
revision cannot become work for the new route.

System-routed UHID remains honest: selecting a DeX target does not make an
arbitrary UHID report explicitly display-addressed.

### 6. Make handoff policy pure

The target handoff policy is a pure reducer/policy:

```text
HandoffState + HandoffFact -> HandoffDecision
```

It owns no:

- DispatchQueue;
- lock;
- callback sequencing;
- transition generation;
- Task;
- transport;
- diagnostics;
- event tap; or
- remote cleanup.

The coordinator serializes ordinary high-level decisions.

The synchronous emergency/local-return safety gate is separate from the reducer
and may pre-empt coordinator progress.

The current `EdgeSwitchStateMachine` queue/callback model and
`TransitionSequenceGate` are migration debt.

### 7. Separate the safety plane from the orchestration plane

Local return has one non-negotiable synchronous boundary.

The first valid return trigger performs bounded local work:

```text
mark ControlSession returning
  -> close ordinary host admission
  -> withdraw/release host suppression and pointer ownership
  -> following host input is local
  -> schedule asynchronous remote close/reconciliation
```

No remote request, actor wait, main-thread round trip, helper response or cleanup
completion is required to restore local input.

If physical CoreHID release cannot be proved, the host pointer owner retains its
fail-closed release responsibility according to the already validated CoreHID
mechanism. That mechanism is not weakened by this ADR.

An immediate new remote acquisition is blocked while the previous
ControlSession remote close is unresolved.

### 8. Use one ordered remote write domain with explicit barrier classes

The target delivery architecture has one remote command ordering domain per
concrete endpoint connection/channel context. It does not use independent
pointer and keyboard queues whose relative ordering must be reconstructed with
cross-queue `sync` calls.

Commands are classified by semantics.

#### Streaming/additive

Examples:

- compositor-authoritative DeX relative movement;
- other additive events only when their semantics permit it.

Streaming commands preserve write order but do not require one semantic response
before the next write.

The existing DeX `requestId = 0` movement path is explicitly preserved.

#### Barrier/stateful

Examples:

- pointer button transitions;
- key transitions;
- route selection;
- terminal cleanup/reset;
- shutdown; and
- any command whose outcome changes persistent remote state or routing.

A barrier cannot be crossed by later stateful work until its required commit
classification is known. A route/close barrier also retires earlier issued work
far enough that replacement-context work cannot be reordered before it.

"One ordered lane" therefore means one owned ordering domain, not "one response
RTT for every event."

### 9. Define persistent outcomes as committed, rejected or unknown

For persistent key/button transitions, use only certainty the backend contract
can actually prove.

- `committed` — the command crossed the reviewed backend commit point. This is
  not a claim that an arbitrary application/UI consumed it.
- `rejected` — the backend can prove the command did not cross its commit
  point.
- `unknown` — the transition may have crossed the commit point; retrying it as
  new work is unsafe.

Timeout/stream loss after an issued transition is `unknown` unless a stronger
backend-specific proof exists.

Generic "failed" is not automatically `rejected`.

The remote held-state ledger changes only for `committed` transitions. Cleanup
failure or an `unknown` outcome moves endpoint trust to `uncertain` unless
an evidence-backed reset proves neutral state.

### 10. Persistent InputManager injection needs a stronger commit contract

Current InputManager paths use asynchronous injection. That acceptance is not
used as proof that a persistent key/button transition has reached the required
commit boundary.

For persistent transitions, #107/#141 implementation must do one of:

1. use a stronger bounded InputManager result mode whose semantics are reviewed
   as an adequate commit point;
2. add another backend-specific acknowledgement/proof; or
3. return `unknown` and fail the endpoint toward `uncertain`.

Non-persistent high-rate movement may continue using asynchronous semantics when
safe for latency and ordering.

### 11. Fallback/retry is allowed only before the persistent commit boundary

A backend may retry/fallback a persistent transition only when the first backend
proves `rejected` before commit.

`unknown` must never be retried through another backend as if nothing happened.

This rule applies to UHID-to-InputManager fallback as well as transport/backend
replacement.

Backend implementations must compute prospective persistent state first and
commit their local ledger only when the reviewed backend commit point succeeds.
A write failure cannot blindly clear held-state knowledge and then retry the same
transition through another backend.

### 12. Give remote committed-state accounting one owner

Host capture owns observed physical host input and local suppression/admission
decisions.

It does not own truth about what Android has committed.

The delivery/remote-channel side owns the persistent remote ledger:

```text
committed keys
committed pointer buttons
outstanding issued persistent transitions
```

Terminal cleanup is derived from that ledger.

The current split where `InputCapture` tracks held semantic keys while
`InputSender` separately tracks accepted buttons is migration debt.

### 13. Endpoint trust survives connection replacement

`RemoteEndpoint` trust is:

```text
clean
uncertain(reason)
```

A normal clean control close keeps `clean`.

Any unresolved persistent transition, untrustworthy terminal cleanup, or
backend-specific state whose neutrality cannot be proved produces
`uncertain`.

While uncertain:

- macOS remains fully local;
- connection/discovery/recovery work may run;
- no new ControlSession may activate; and
- a route/connection replacement is not treated as proof of cleanliness.

Recovery may return to `clean` only through an explicit mechanism whose
backend/platform contract proves neutral state. If none exists, remote control
remains blocked until an operator-visible reset/reconnect action with sufficient
evidence is performed.

This intentionally prioritizes correctness over automatic recovery convenience.

### 14. Concurrency model

Use one concurrency mechanism for each responsibility.

- App/UI presentation: `MainActor`.
- High-level endpoint/control orchestration: Swift actors or equivalent
  structured async ownership.
- Remote I/O: async/await; no intentional thread blocking on remote progress.
- CGEvent/CoreHID/event-tap hot paths: small bounded synchronous primitives only.
- Cross-thread safety primitives: narrow lock/mutex-backed cells with explicit
  invariants; no arbitrary callbacks while holding the safety lock.
- OS/FFI wrappers may require `@unchecked Sendable`, but it is not a default
  escape hatch for orchestration objects.

Production remote paths must remove `DispatchSemaphore` blocking bridges.

### 15. Android helper boundaries

The Android helper target structure is responsibility-based rather than
symmetrical with macOS:

```text
ProtocolDispatcher
        |
    InputEngine
    /    |     \
 route pointer keyboard
 state backend  backend
        |
 persistent outcome / cleanup contract

DisplayCatalog
BoundaryOracle
HID/InputManager adapters
```

Exact class names are not normative.

Required rules:

- protocol parsing/validation does not own backend state;
- route state has one owner;
- backend policy does not claim stronger routing than the backend provides;
- backend APIs return semantic delivery/cleanup outcomes rather than ambiguous
  booleans where persistent correctness depends on the result;
- hidden APIs remain isolated behind reviewed adapters;
- helper teardown is defense in depth, not remote-cleanliness proof by itself.

## Named invariants

### R1 — Immediate Local Safety

Local host control restoration does not wait for remote progress.

### R2 — One Active ControlSession

At most one active remote control period owns host suppression/admission.

### R3 — Immutable Remote Context

Work admitted to one ControlSession cannot retarget to a replacement connection
or route revision.

### R4 — No Dirty Reacquisition

A new ControlSession cannot activate while the prior remote close is unresolved
or the RemoteEndpoint is uncertain.

### R5 — Persistent Transitions Are Never Silently Duplicated

A persistent transition with unknown commit outcome is not retried through a new
backend/connection/control period.

### R6 — One Remote Persistent Ledger

Committed key/button state and outstanding persistent transitions have one
remote-delivery owner.

### R7 — Bounded Host Hot Path

Event-tap/CoreHID admission performs bounded local work and never waits for
remote I/O or actor progress.

### R8 — Streaming Performance Is Preserved

The proven DeX movement path does not acquire one network/helper RTT per physical
movement sample.

### R9 — Route Mutation Is a Barrier

Old-route work cannot become new-route work, including across same-display
selection epochs when the protocol/backend intentionally creates a new route
revision.

### R10 — Endpoint Trust Outlives Connections

Replacing ADB/helper/CXI connection identity never converts uncertain persistent
remote state into clean state by itself.

### R11 — Routing Claims Are Honest

System-routed UHID is never described as explicit arbitrary-display routing.

### R12 — Diagnostics Are Payload-Safe

Raw pointer/key/HID/clipboard payloads do not enter normal diagnostics.

## Migration map

| Current responsibility/type | Target direction |
| --- | --- |
| `AppModel` orchestration | presentation/composition projection only (#108) |
| `SessionReference` | delete; no mutable current-connection redirection |
| `SessionController` | `RemoteEndpoint` connection/reconnect ownership |
| `TargetSelectionController` | endpoint-owned `RemoteRoute` + revision/barrier |
| `ControlHandoffController` | `ControlCoordinator` + `ControlSession` + host components |
| `EdgeSwitchStateMachine` queue/callback ownership | pure handoff reducer/policy |
| `TransitionSequenceGate` | delete |
| monolithic `InputCapture` | HostInputRuntime components (#104) |
| `InputSender` | one delivery pump / ordered remote command domain (#106) |
| pointer + keyboard delivery queues | delete as separate ordering owners |
| `requestBlocking()` / semaphore bridge | delete |
| host `keysDown` + sender `heldButtons` remote truth | one remote persistent ledger |
| fire-and-forget `KEY_EVENT` | persistent commit outcome contract (#141) |
| InputManager ASYNC persistent acceptance | stronger commit proof or `unknown` |
| boolean backend failure/fallback | typed committed/rejected/unknown policy |
| Session recovery cleanliness | endpoint trust + evidence-backed recovery |
| PR #238 old cleanup slice | re-evaluate/rebase or supersede under endpoint-trust/backend-outcome contract |

## Implementation sequencing

Existing issue numbers remain useful responsibility boundaries, but their old
ADR-0016 wording is not normative after this ADR is accepted.

1. **#284 / #114** — accept this rebaseline and reconcile downstream task text.
2. **#99** — finish capability/onboarding behavior against HostInputRuntime;
   capability failure remains independent of remote endpoint health.
3. **#104 + #222** — split host capture/edge/suppression/pointer ownership and
   fix edge-entry behavior without changing the validated CoreHID physical
   ownership mechanism.
4. **#105** — implement ControlCoordinator/ControlSession and remove epoch/
   sequence choreography from control ownership.
5. **#106** — implement RemoteEndpoint, immutable remote control channel,
   endpoint trust and one async ordered delivery domain; remove blocking bridges
   and split queue ownership.
6. **#107** — implement backend commit/cleanup contracts and reconcile or replace
   PR #238 under the new endpoint-trust model.
7. **#141** — add the minimum additive CXI v1 persistent keyboard outcome needed
   by the committed/rejected/unknown contract.
8. **#108** — reduce AppModel after lower owners exist.
9. **#109** — adversarial verification, structural dependency checks, resource
   checks and deletion of superseded architecture.
10. **#68** remains the independent ADR-0012 release-stability physical gate.

Tasks may be split into smaller PR-sized issues where one step would otherwise
mix multiple independently reviewable runtime changes.

## Alternatives considered

### Keep ADR-0016 unchanged and only finish implementation

Rejected. The midpoint review identified an ownership error: persistent remote
cleanliness can outlive a Session. Continuing would encode the wrong owner more
deeply.

### One global actor/state machine

Rejected. Host return is a synchronous safety boundary, and endpoint persistent
trust outlives individual control/connection lifetimes. One actor would blur
those concerns.

### Preserve SessionHandle/TargetLease/ControlLease as mandatory public concepts

Rejected. Immutable context and one-way validity are required; these particular
abstractions are not. A RemoteEndpoint + immutable RemoteControlChannel +
ControlSession expresses the same safety properties with fewer distributed
lifecycles.

### Treat a new helper/connection as clean

Rejected. Connection identity is not proof that Android persistent state is
neutral.

### Treat backend write/ASYNC acceptance as end-to-end applied

Rejected. The architecture should name only the boundary actually proven and
handle uncertainty explicitly.

### Retry every failed persistent command on another backend

Rejected. Failure after an unknown commit point can duplicate DOWN/UP state.

### Serialize every input event through semantic response completion

Rejected. It would unnecessarily put the proven high-rate DeX movement path
behind response RTT and change a validated product property.

### One giant rewrite

Rejected. Broad replacement is authorized, but each merged slice must remain
coherent and independently reviewable.

## Consequences

Positive:

- remote cleanliness has the correct lifetime owner;
- stale work is prevented primarily by immutable context, not universal
  generations;
- the top-level lifecycle model is smaller;
- local safety remains independent of remote scheduling;
- persistent retry/fallback policy becomes explicit;
- remote state accounting has one owner;
- DeX movement latency is protected by architecture rather than incidental code;
- route mutation remains a clear ordering barrier; and
- the blocking bridge/split-queue architecture has a defined deletion path.

Cost:

- several existing issue descriptions and tests need rebaselining;
- portions of ADR-0016 implementation work may be replaced rather than
  incrementally completed;
- #107/#141 need stronger backend/protocol semantics;
- endpoint trust/recovery needs explicit product-facing behavior when recovery
  cannot prove clean state; and
- reset-sensitive runtime changes will invalidate relevant physical evidence
  lineage under ADR-0012.

## Validation / proof obligations

Before changing this ADR to accepted:

- repository documentation contains no contradictory normative ADR-0016 claims;
- current 0.1.3 field behavior and accepted #96/CoreHID evidence are explicitly
  preserved;
- each named invariant has at least one deterministic test strategy mapped in
  the implementation tasks;
- the design traces normal handoff/return, emergency return, host capability
  loss, CoreHID acquisition/release failure, connection replacement, route
  change, persistent transition rejection, persistent transition unknown,
  backend fallback, target disappearance, late response and endpoint recovery;
- the design proves that a stale control channel cannot retarget;
- the design proves that `unknown` persistent work cannot be retried as clean;
- the design preserves low-latency DeX movement;
- no protocol version bump is implied; and
- the exact docs-only PR passes repository documentation/evidence validation.

Runtime completion additionally requires exact-head deterministic and physical
evidence according to each implementation issue and ADR-0012.

## Revisit conditions

Revisit this ADR if:

- CXI v2 replaces helper-global route state with explicit per-command target
  identity;
- more than one Android endpoint may be controlled simultaneously;
- a new transport changes endpoint identity/trust semantics;
- Android provides a stronger stable persistent-state reset/application proof
  that materially simplifies endpoint trust;
- macOS replaces the CoreHID/event-tap ownership mechanism; or
- physical evidence disproves a preserved 0.1.3 behavior or safety assumption.
