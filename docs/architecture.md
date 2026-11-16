# CrossInput Architecture

> Status: **Architecture Leap midpoint rebaseline candidate from ADR-0017 / #284.**
>
> [ADR-0017](adr/ADR-0017-architecture-leap-midpoint-rebaseline.md) is the
> current candidate target ownership/concurrency model. ADR-0016 is retained as
> historical Architecture Leap rationale and is no longer normative.
>
> Runtime implementation is still in progress under [Epic #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> and Tracks #114–#118. Until ADR-0017 is accepted on merged `main`, do not
> treat current class/module shape or ADR-0016-specific lease names as compatibility requirements.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary use case while the built-in Android display remains a supported
secondary target on the same connected device.

## Architecture authority

Preserve:

- validated 0.1.3 product behavior;
- accepted macOS/CoreHID physical evidence;
- Samsung DeX routing evidence;
- CXI v1 compatibility unless separately approved;
- local-return safety;
- stale-work rejection;
- persistent-input correctness;
- bounded capture/event hot paths; and
- payload-safe diagnostics.

Do not preserve a class, queue, generation counter, callback graph or test merely
because the current implementation contains it.

## Target topology

```text
                           App / UI
                              |
                      ControlCoordinator
                       /               \
              HostInputRuntime      RemoteEndpoint
                    |                    |
              semantic input      RemoteControlChannel
                    \                    /
                     \                  /
                         ControlSession
                              |
                         DeliveryPump
                              |
                    ordered remote commands
                              |
                         CXI v1 adapter
                              |
                      ADB / app_process
                              |
                        Android helper
                              |
                  backend / system routing
```

The durable ownership boundaries are:

1. **HostInputRuntime** — macOS capability, capture, edge observation, host
   suppression/ownership, CoreHID pointer ownership and cursor presentation.
2. **RemoteEndpoint** — one Android device, its endpoint trust, concrete CXI
   connection, remote route revision, reconnect policy and remote command
   serialization.
3. **ControlCoordinator** — creates and closes one transient
   **ControlSession** connecting those two owners.

## RemoteEndpoint is above one Session

Remote persistent-state cleanliness belongs to the Android endpoint, not to one
ADB/CXI connection.

```text
RemoteEndpoint(device)
  trust = clean | uncertain(reason)
  connection = concrete CXI connection?
  route = RemoteRoute(target, revision, routing scope)
```

A connection may die and be replaced while Android still has ambiguous held
key/button state. Therefore:

- a new helper process is not proof of cleanliness;
- HELLO success is not proof of cleanliness;
- an ADB reconnect is not proof of cleanliness; and
- a new concrete connection does not reset endpoint trust.

When trust is `uncertain`, discovery/recovery may run, but a new remote
ControlSession may not activate until an evidence-backed reset/cleanup contract
proves neutral state.

## Remote route ownership

CXI v1 `SELECT_DISPLAY` mutates helper-global route state. Route selection is
therefore an ordered RemoteEndpoint barrier.

A route is represented conceptually by:

```text
RemoteRoute
  target identity
  revision
  routing scope/capability
```

A ControlSession captures one route revision immutably. Old work never looks up
"the current target" and can therefore never become new-route work.

System-routed UHID remains honest: selecting a DeX target does not make an
arbitrary UHID report explicitly display-addressed.

## One ControlSession per remote-ownership period

A ControlSession has one lifecycle:

```text
preparing -> active -> returning -> closed
     \-------------------------> closed
```

It owns only resources for that period:

- host control/suppression handle;
- synchronous bounded host admission;
- immutable RemoteControlChannel;
- delivery pump;
- boundary-watch handle where required; and
- close result.

The architecture does not require the former public graph of
SessionHandle/TargetLease/ControlLease/SuppressionLease/remote-close-fence
objects. Small local handles are allowed where they clarify one component, but
they must not recreate distributed ownership.

## Immutable RemoteControlChannel

RemoteEndpoint prepares the channel before host suppression is committed.

The channel binds:

- endpoint identity;
- concrete connection identity;
- route identity + revision;
- routing scope/capability; and
- control-period identity.

It is never rebound. Reconnect or route mutation creates a different future
channel.

This replaces correctness based on a mutable `SessionReference` plus generation
checks.

## HostInputRuntime

The current monolithic `InputCapture` is not a target shape. The host boundary
separates these responsibilities:

- capability monitor;
- event-tap lifecycle;
- keyboard translator;
- edge detector;
- CoreHID built-in-pointer owner;
- cursor presenter; and
- small host safety/admission state.

Exact type names may change.

### Preserved CoreHID mechanism

The current production built-in-trackpad mechanism remains a validated
implementation constraint unless stronger evidence supersedes it:

- exact-device matching;
- disposable CoreHID ownership child process;
- prepare/commit acquisition;
- parent-lifetime stdin lease;
- bounded containment for a wedged child;
- independent non-seizing witness; and
- physical release only after ownership-process exit plus independent
  `deviceUnseized` evidence.

Cursor presentation remains isolated from physical pointer ownership. It may not
be used as proof that CoreHID ownership was released.

## Pure handoff policy

Handoff policy becomes a pure reducer:

```text
HandoffState + HandoffFact -> HandoffDecision
```

It owns no queue, lock, Task, callback sequencing, transport, diagnostics or
generation counter.

The coordinator serializes ordinary high-level decisions. The emergency/local
return safety path can pre-empt that orchestration and never waits for actor
scheduling.

The current queue-backed `EdgeSwitchStateMachine` and
`TransitionSequenceGate` are migration debt.

## Local-return safety plane

Local safety is synchronous and bounded.

```text
return trigger
  -> mark active ControlSession returning
  -> close ordinary admission
  -> release host suppression / pointer ownership
  -> subsequent host input is local
  -> reconcile remote close asynchronously
```

No Android request, helper response, actor wait or remote cleanup completion is
required to restore local input.

A replacement remote ControlSession remains blocked while the old remote close
is unresolved.

## Delivery model

Remote delivery uses one owned ordering domain rather than independent pointer
and keyboard queues whose relative order is reconstructed with cross-queue
barriers.

### Streaming/additive commands

The validated DeX movement path remains low latency:

```text
POINTER_MOVE_REL requestId=0
POINTER_MOVE_REL requestId=0
POINTER_MOVE_REL requestId=0
...
```

Writes stay ordered but do not wait for one response RTT per movement sample.

Other additive events may use streaming/coalescing only when their semantic
contract allows it.

### Stateful/barrier commands

Persistent or routing-changing commands are barriers, including:

- pointer button transitions;
- key transitions;
- route selection;
- cleanup/reset;
- shutdown; and
- any command whose result affects persistent remote state.

A later stateful command cannot cross a required barrier before the earlier
command has the required commit classification.

"One ordered lane" means **one ordering owner**, not **one response per event**.

## Persistent delivery outcomes

Persistent key/button results use the strongest certainty a backend actually
proves:

- **committed** — crossed the reviewed backend commit point;
- **rejected** — proven not to have crossed that commit point;
- **unknown** — may have crossed; retrying it as new work is unsafe.

These terms intentionally do not claim arbitrary application/UI consumption.

Timeout or stream loss after issue is `unknown` unless backend-specific evidence
proves otherwise.

Generic "failed" is not automatically `rejected`.

## One remote persistent-state ledger

Host capture owns what the Mac physically observed.

Remote delivery owns what Android is known to have committed:

```text
committed keys
committed pointer buttons
outstanding issued persistent transitions
```

Cleanup is derived from this single remote ledger.

The current split where `InputCapture` tracks held keys and `InputSender`
tracks remote buttons is not the target model.

## Backend fallback rule

A persistent transition may be retried on another backend only after the first
backend proves `rejected` before its commit point.

`unknown` must never be retried through another backend, connection or
ControlSession as if nothing happened.

This applies to UHID/InputManager fallback.

Backend adapters compute prospective persistent state first and commit their
local ledger only after their reviewed backend commit point succeeds.

## InputManager persistent state

Current InputManager paths use asynchronous injection. That acceptance is not
treated as sufficient persistent-state commit proof.

For persistent key/button transitions, the remote implementation must either:

1. use a stronger bounded result mode with reviewed commit semantics;
2. provide another backend-specific acknowledgement/proof; or
3. classify the outcome `unknown` and move RemoteEndpoint trust to
   `uncertain`.

High-rate non-persistent movement may retain asynchronous behavior where safe.

## Android helper responsibility split

The target Android structure is responsibility-based:

```text
ProtocolDispatcher
        |
     InputEngine
     /   |    \
 route pointer keyboard
 state backend  backend
        |
 persistent outcome / cleanup contract

DisplayCatalog
BoundaryOracle
HID/InputManager adapters
```

Exact class names are not normative.

Rules:

- protocol parsing does not own backend state;
- route state has one owner;
- backend policy does not exaggerate routing guarantees;
- persistent backend outcomes are typed, not ambiguous booleans;
- hidden API usage stays isolated behind adapters;
- helper teardown is defense in depth, not endpoint-cleanliness proof.

## Concurrency model

Use one mechanism per responsibility:

- App/UI projection: `MainActor`;
- endpoint/control orchestration: structured concurrency / Swift actor where
  appropriate;
- remote I/O: async/await;
- event-tap/CoreHID hot paths: bounded synchronous primitives only;
- narrow cross-thread safety cells: explicit mutex/lock invariant, no arbitrary
  callbacks while held;
- OS/FFI wrappers: `@unchecked Sendable` only where genuinely required.

Production remote paths must remove the `DispatchSemaphore` request bridge.

## Non-negotiable invariants

1. **Immediate local safety** — local host control never waits for Android.
2. **One active ControlSession** — only one period owns host suppression/admission.
3. **Immutable remote context** — old work cannot retarget to a replacement
   connection or route revision.
4. **No dirty reacquisition** — unresolved close or uncertain endpoint blocks a
   new remote period.
5. **No silent persistent duplication** — unknown persistent work is never
   retried as clean.
6. **One remote persistent ledger** — remote committed state has one owner.
7. **Bounded host hot path** — no remote I/O/actor wait on capture callbacks.
8. **Streaming performance preserved** — DeX movement does not acquire one RTT
   per physical sample.
9. **Route mutation is a barrier** — old-route work cannot become new-route work.
10. **Endpoint trust outlives connections** — reconnect/helper restart does not
    reset uncertainty.
11. **Routing claims are honest** — system-routed UHID is not arbitrary explicit
    display routing.
12. **Diagnostics are payload-safe**.

## Migration map

| Current type/responsibility | Target |
| --- | --- |
| `SessionReference` | delete |
| `SessionController` | RemoteEndpoint connection/reconnect ownership |
| `TargetSelectionController` | endpoint-owned RemoteRoute + revision/barrier |
| `ControlHandoffController` | ControlCoordinator + ControlSession + host components |
| queue-backed `EdgeSwitchStateMachine` | pure handoff reducer |
| `TransitionSequenceGate` | delete |
| monolithic `InputCapture` | HostInputRuntime components |
| `InputSender` | one delivery pump / ordered remote command domain |
| pointer + keyboard queues | delete as separate ordering owners |
| `requestBlocking()` | delete |
| host held-key + sender held-button remote truth | one remote persistent ledger |
| fire-and-forget `KEY_EVENT` | persistent commit outcome contract |
| Session cleanliness fence | RemoteEndpoint trust |
| backend boolean fallback | committed/rejected/unknown policy |

## Implementation sequence

Architecture issue dependencies remain the execution authority, but ADR-0016
specific abstractions are no longer mandatory once ADR-0017 is accepted.

1. #284 / #114 — accept the rebaseline and reconcile task text.
2. #99 — complete capability/onboarding under HostInputRuntime.
3. #104 + #222 — rebuild host boundaries and edge-entry behavior while preserving
   validated CoreHID mechanics.
4. #105 — implement ControlCoordinator/ControlSession and remove epoch/sequence
   choreography.
5. #106 — implement RemoteEndpoint, endpoint trust, immutable remote channel and
   one async delivery ordering domain.
6. #107 — backend commit/cleanup semantics; reconcile or replace PR #238.
7. #141 — minimum additive CXI v1 keyboard outcome contract required by
   committed/rejected/unknown.
8. #108 — reduce AppModel after lower owners exist.
9. #109 — adversarial verification and legacy deletion.
10. #68 — independent ADR-0012 release-stability qualification.

## Evidence boundary

Architecture refactoring does not preserve device evidence automatically.

Runtime changes that affect input ownership, routing, suppression, boundary
return, persistent cleanup or backend semantics require the targeted exact-head
physical evidence owned by their execution issue. ADR-0012/#68 remains the
independent release-stability gate.

See:

- [ADR-0017](adr/ADR-0017-architecture-leap-midpoint-rebaseline.md)
- [ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md)
- [Testing](testing.md)
- [CXI v1 protocol](../protocol/protocol.md)
