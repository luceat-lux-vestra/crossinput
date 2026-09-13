# CrossInput Architecture

> Status: **Architecture Leap target model proposed by ADR-0016, 2026-09-13.**
>
> [Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> is the authority for sequencing. [ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md)
> is the normative ownership/concurrency decision for #102. This document is the
> implementation-facing overview. Pre-Leap classes, modules, queues, generation
> counters, and diff size are not architectural constraints.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary product use case while the built-in phone display remains a
supported secondary target on the same connected Android device.

## Architecture authority

Preserve:

- validated user-visible behavior;
- device/protocol facts;
- safety invariants;
- reproducible physical evidence; and
- intentional product scope.

Do not preserve an abstraction merely because it already exists or because
rewriting it increases the diff. #101 / ADR-0016 explicitly authorize broad
internal redesign when that produces clearer ownership, safer lifecycle
semantics, safer concurrency, or better testability.

Large changes are still decomposed into coherent, independently reviewable PRs.
Rewrite freedom is not permission to combine unrelated product, protocol, or
transport migrations.

The Leap hierarchy remains:

```text
#101 Architecture Leap
├── #114 architecture — target ownership, concurrency, semantic boundaries
├── #115 host         — macOS capability/capture/suppression/control ownership
├── #116 remote       — delivery/Android helper/protocol/backend boundaries
├── #117 app          — composition and presentation ownership
└── #118 quality      — adversarial verification/physical acceptance/legacy purge
```

## Product topology that remains valid

```text
macOS host
  -> pointer/keyboard capture
  -> local/remote control handoff
  -> platform-neutral semantic input
  -> CXI v1 remote adapter
  -> ADB / app_process transport
  -> Android helper
  -> backend/system routing
```

This topology is a product/device fact. It does not require preserving current
controller classes, mutable references, queue layout, or source target names.

## Non-negotiable invariants

1. **Local safety** — macOS pointer/keyboard control can never be permanently
   trapped, and local restoration never waits for Android, an actor, or the main
   thread.
2. **No cross-Control delivery** — stale work from an invalidated Control owner
   cannot reach a replacement Control owner.
3. **No cross-Session retargeting** — work captured for an old Session cannot be
   redirected to a replacement connection.
4. **No cross-Target retargeting** — work captured for target A cannot become
   ordinary input for target B after route mutation.
5. **Held-state safety** — confirmed remote held keys/buttons are cleaned while
   their old routing context is still valid, or the remote Session is treated as
   untrustworthy and replaced.
6. **One suppression owner** — at most one valid host SuppressionLease may
   consume local input.
7. **Bounded capture path** — CGEventTap/event hot paths remain bounded and
   nonblocking.
8. **Persistent transitions are ordered and acknowledged** — key/button state
   transitions are never silently lost, reordered, or assumed applied without a
   semantic outcome contract.
9. **Platform boundaries** — CoreGraphics/AppKit/TCC do not leak into remote
   domain semantics; Android/CXI/UHID/InputManager details do not leak into the
   host/domain API.
10. **Routing honesty** — a selected TargetLease is lifecycle context, not proof
    that every backend explicitly routes to that target.
11. **Payload-safe diagnostics** — raw typed contents, HID reports, raw key
    payloads, pointer coordinates/deltas, and clipboard contents never enter
    normal diagnostics.

## Authoritative lifecycles

The architecture is organized around six separate lifecycles. They must not be
collapsed into one global state machine or one universal generation counter.

### Capability

Owns whether macOS has the capabilities required to observe/suppress input.
Capability failure blocks Control acquisition and returns/stays local. It does
**not** tear down a healthy Android Session solely because local TCC capability
is unavailable.

### Host capture

Owns the CGEventTap lifecycle and raw macOS event observation. Capture lifetime
is distinct from suppression lifetime.

The host side is separated conceptually into:

- `InputCapabilityController`;
- `MacEventTap`;
- `MacInputTranslator`;
- `EdgeDetector`; and
- `HostSuppressionController`.

Exact names may change, but those responsibilities must not collapse back into
one monolithic input object.

### Session

A concrete Android/helper/CXI connection is represented by one immutable
**SessionHandle**. Its identity and connection reference never change.

```text
open -> closing -> closed
```

A Session manager may replace the current SessionHandle, but old work continues
to reference only the old handle. The target architecture therefore removes the
mutable `SessionReference` pattern in which stale work can resolve through a
newer connection.

Session owns:

- ADB/helper launch through the transport adapter;
- CXI handshake/capabilities;
- request correlation and timeout classification;
- disconnect/shutdown;
- the stateful RemoteCommandLane; and
- connection/reconnect identity.

### Target

Target discovery/selection is a lifecycle separate from Session. A successful
selection creates one immutable **TargetLease** scoped to exactly one
SessionHandle.

CXI v1 `SELECT_DISPLAY` mutates helper-global routing state. Target selection is
therefore an ordered remote-state barrier, not merely presentation state.

A TargetLease is published only after helper confirmation.

### Control

One **ControlLease** represents one remote-ownership period. Its identity and
captured context are immutable; operational lifetime is one-way:

```text
open -> closed
```

It binds:

- the exact SessionHandle;
- the exact TargetLease;
- one host SuppressionLease;
- one synchronous InputIngress; and
- one asynchronous DeliveryWorker.

Late callbacks carrying an old ingress can observe only closed/rejected
admission. They cannot become valid for a replacement ControlLease.

### Delivery

One DeliveryWorker exists per ControlLease. It is never rebound to another
Session, Target, or Control.

Delivery owns:

- one ordered semantic input lane;
- class-aware coalescing/backpressure;
- semantic-to-CXI v1 translation at the remote boundary;
- async remote execution;
- movement acknowledgement needed by handoff policy;
- the authoritative host-side ledger of **confirmed** remote held inputs;
- terminal cleanup coordination; and
- explicit/cancelled/ambiguous outcome classification.

### Application / presentation

The application root composes owners and projects their states into UI.
Presentation may issue intents such as connect/disconnect, select target,
enable/disable control, emergency return, or open permission settings.

Presentation does not implicitly own Session, Target, Control, capture, TCC, or
delivery lifetimes. `AppModel` is not a compatibility requirement.

## Runtime data path

### Local state

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator / EdgeDetector
  -> local macOS event path
```

While local, events pass through. Edge detection may request Control acquisition.

### Remote state

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

The event-tap callback never waits for remote acknowledgement.

## Control acquisition is fail-closed

Acquisition order is part of the safety contract:

1. verify capability readiness and capture availability;
2. snapshot the exact SessionHandle + TargetLease context;
3. create InputIngress and DeliveryWorker bound to those exact handles;
4. prepare the ControlLease and synchronous local-return gate;
5. atomically install the SuppressionLease + exact ingress into the host
   suppression boundary; and
6. only after installation succeeds, publish Control as remote-owned.

If any step fails, close/cancel partial resources and remain local.

The host suppression boundary must never consume local input unless it already
has both a valid bounded ingress and a synchronous local-return path.

## Synchronous local-return gate

Actor scheduling is **not** part of the pointer-safety proof.

Every open ControlLease exposes one idempotent, thread-safe local-return gate.
It may be triggered by:

- normal boundary return;
- watchdog timeout;
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

```text
mark ControlLease closing/closed
  -> close InputIngress
  -> synchronously clear/release HostSuppressionController's active
     SuppressionLease and current-ingress slot
  -> subsequent host events pass locally
  -> schedule async reconciliation/cancellation/remote cleanup/diagnostics
```

No transport write, actor `await`, main-thread dispatch, helper response, or
remote cleanup is allowed inside this critical local-return path.

Implementations must define lock ordering so the gate cannot deadlock with the
CGEventTap callback or HostSuppressionController. Arbitrary callbacks must not
run while the small safety-state lock is held.

Deinitialization is defense in depth, never the primary safety mechanism.

### External-control takeover

When another controller's triggering event causes takeover, local return must
not synthesize a cursor restore/park mutation that changes that triggering
event. After suppression ownership is released, the triggering event passes
through unchanged.

## Host suppression and #96

`HostSuppressionController` is the only owner allowed to consume host input or
perform the accepted P0 cursor-confinement mutations.

The accepted #96 disposition remains authoritative:

- retain P0-style host confinement;
- keep the native Mac cursor visible;
- accept the documented native cursor-presentation limitation;
- do not introduce private SkyLight/CGS production dependencies;
- do not use synthetic click/focus stealing;
- do not use pointer-jump or custom-cursor workarounds merely to mask #96; and
- do not repeat equivalent cursor-API experiments without materially new
  evidence.

## Handoff policy

The target architecture replaces internally queued/callback-sequenced handoff
state with a pure **HandoffPolicy**.

It receives facts and returns decisions; it owns no executor, task, queue,
transport, event tap, diagnostics, or callback sequencing.

Inputs include:

- enabled/disabled;
- edge entered;
- entry edge;
- requested/accepted remote movement acknowledgement; and
- explicit normal/failure return reason.

Outputs include acquire, remain, and return decisions.

ControlCoordinator serializes policy application.

Validated #45/#37 behavior remains unless separately superseded:

- return-direction movement credits requested intent when Android clamps
  accepted movement at a display boundary;
- inward movement credits confirmed accepted movement;
- first post-entry movement cannot instantly trigger a return; and
- return hysteresis prevents accidental edge wobble.

## InputIngress and backpressure

CGEventTap callbacks cannot `await`. Each open ControlLease therefore exposes
one small lock-protected **InputIngress**.

InputIngress:

- performs O(1) or otherwise strictly bounded synchronous admission;
- performs no transport I/O;
- performs no remote await/semaphore wait;
- returns an immediate admission result; and
- becomes permanently closed when its ControlLease ends.

One ordered semantic lane covers pointer and keyboard input. The old split
pointer/keyboard queue model is not part of the target design.

Default policy:

| Event class | Coalesce | Shed | Ordering requirement |
| --- | --- | --- | --- |
| relative motion | adjacent only | allowed under bounded overload | additive |
| scroll | adjacent only | allowed when additive semantics are preserved | additive |
| pointer button down/up | never | never silently | strict |
| key down/up | never | never silently | strict |
| key repeat | no shedding by default | only if later proven safe | strict by default |
| cleanup/release | no lossy treatment | never silently | terminal/strong |

If a non-droppable transition cannot be admitted, invoke the local-return gate.
Do not silently lose persistent remote state.

## RemoteCommandLane

Swift actor isolation alone is insufficient because actor methods can reenter
across `await` points.

Each SessionHandle therefore owns an explicit **RemoteCommandLane** for
helper-global/stateful operations whose relative order affects correctness,
including:

- target selection;
- selected-target-dependent pointer input;
- keyboard input under its honest routing scope;
- persistent held-input cleanup; and
- shutdown/reset operations that alter backend state.

### Baseline execution contract

The baseline implementation executes one stateful command through completion
before starting the next. This intentionally matches the current pointer
request/response model.

The architectural requirement is **total stateful ordering + explicit barriers**,
not “serial forever.” Future bounded pipelining is allowed only after measurement
and proof that:

- command write order remains deterministic;
- persistent transition outcome/commit order cannot reorder;
- target selection drains all earlier target-dependent work before route
  mutation;
- shutdown/reset acts as a barrier;
- stale/invalid TargetLease work is rejected before wire execution; and
- cancellation cannot let earlier work semantically commit across a later
  barrier unnoticed.

Read-only requests may use a separate path only when they cannot race
helper-global routing/input state.

## Target change: terminal cleanup before route mutation

A target change must not let old-target persistent state leak across
`SELECT_DISPLAY`.

The safe Target A -> B sequence is:

```text
invoke Control A local-return gate
  -> ordinary A ingress is closed
  -> queued ordinary A delivery is cancelled/sheared off
  -> while TargetLease A and route A are still valid:
       execute one terminal cleanup fence for confirmed held persistent state
  -> bounded wait for that terminal cleanup only
  -> if cleanup is confirmed, or there is provably nothing to clean:
       invalidate TargetLease A
       enqueue ordered SELECT_DISPLAY(B) on the same RemoteCommandLane
       wait for helper confirmation
       publish TargetLease B
       permit new Control B
  -> otherwise:
       do not reuse the Session as clean for B
       invalidate/reconnect the Session and re-establish remote state
```

The old TargetLease is invalidated before **new ordinary A input** can be
admitted, but not so early that its privileged terminal cleanup becomes
impossible. Terminal cleanup admits no new user input.

This conservative escalation is required for persistent key/button state.
Additive motion/scroll samples may be discarded without requiring Session
replacement because they do not represent held remote state.

## Routing honesty

A ControlLease may be bound to a selected TargetLease as product/lifecycle
context, but that binding is not a claim that every backend explicitly targets
that display.

The remote boundary must represent routing scope honestly, conceptually:

- `selectedTarget(TargetLease)` — command semantics depend on the confirmed
  selected target; or
- `sessionRouted(SessionHandle)` — backend/system routing occurs at Session or
  system scope and cannot honestly promise explicit selected-display routing.

This matters because:

- system-routed UHID must not be described as explicitly targeting an arbitrary
  Android display ID; and
- phone-versus-DeX keyboard routing with both displays present remains a
  physical-evidence question (#92).

## Persistent input outcomes and cleanup

A host held-state ledger is authoritative only for transitions with confirmed
semantic outcomes.

Pointer request/response already has an explicit result path. Current keyboard
`KEY_EVENT` delivery is fire-and-forget, so helper-side rejection can currently
be invisible while the Session remains alive. #141 closes that architecture gap
with an additive CXI v1 capability/result contract rather than forcing CXI v2.

The required direction is:

- persistent key transitions receive correlated semantic outcomes;
- the host ledger changes only after a positive semantic outcome;
- timeout/stream loss after a possibly applied persistent transition is treated
  as ambiguous remote state; and
- ambiguous persistent state fails Control local immediately and escalates to
  cleanup and/or Session invalidation when trust cannot be restored.

Helper/backend cleanup is defense in depth, not an assumption. #107 must prove
cleanup semantics for each pointer backend, including InputManager. If a backend
cannot reliably release held state on reset/shutdown, the limitation must remain
explicit in Session recovery policy rather than being hidden by local bookkeeping.

No infinite cleanup retries are permitted.

## Session replacement

Session identity is structural rather than generation-based:

```text
SessionHandle A -- shutdown/invalidate --> dead forever
SessionHandle B -- newly created --------> independent resource
```

A DeliveryWorker created for A has no path that can suddenly resolve to B.
Typed IDs may exist for diagnostics/tests, but they are not a substitute for
resource ownership.

## Platform-neutral semantic input

#103 finalizes concrete SwiftPM target names, but dependency direction is fixed:

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

Rules:

- `CrossInputDomain` contains semantic input and pure policies only;
- `MacHost` depends on domain, never on Android/CXI/backend types;
- `Remote` depends on domain and remote adapters, never on MacHost;
- CoreGraphics/AppKit/TCC types do not cross the semantic domain boundary;
- Android KEYCODE/META constants are not produced by host capture;
- UHID/InputManager are remote/backend implementation details; and
- CXI framing is not a domain concept.

The intended pipeline is:

```text
Mac event
  -> MacInputTranslator
  -> SemanticInputEvent
  -> InputIngress / DeliveryWorker
  -> CXI v1 adapter
  -> helper semantic command
  -> Android backend
```

## Concurrency model

### MainActor

Application composition, view-state projection, UI intents, and AppKit/System
Settings presentation actions.

### Mac event-tap executor

Dedicated CFRunLoop/queue. Allowed work is bounded translation/classification,
small lock-protected lease lookup, bounded InputIngress admission, and bounded
local suppression/fail-safe mechanics.

Forbidden work includes transport I/O, semaphore waits, actor waits, main-thread
round trips for safety, unbounded work, and payload logging.

### ControlCoordinator

Intended as a Swift actor. It owns Control lifecycle state and HandoffPolicy
serialization.

Local safety does not depend on this actor being scheduled. The synchronous
local-return gate closes ingress and releases host suppression first, then
notifies the actor asynchronously.

### Session manager / concrete remote session

Connection/reconnect/replacement is serialized by the Session owner. Each
concrete SessionHandle owns its own protocol session and RemoteCommandLane.

### DeliveryWorker

One asynchronous worker per ControlLease. It drains only that lease's ingress
and talks only to that lease's captured SessionHandle/routing context.

## Failure-domain matrix

| Failure | Immediate Control action | Session/Target consequence |
| --- | --- | --- |
| missing/revoked host capability | local/blocked | healthy Session/Target may remain |
| event-tap/capture failure | local/blocked | healthy Session/Target may remain |
| ordinary Control return | local | Session/Target unchanged |
| additive motion/scroll timeout | local for current Control when required | Session may remain reusable if transport/protocol state is trustworthy |
| key/button outcome ambiguous | local immediately | cleanup; invalidate Session if persistent state cannot be proven clean |
| target change/disappearance | local immediately | reuse Session only after trustworthy old-target cleanup; otherwise reconnect |
| transport/helper disconnect | local immediately | invalidate Session and Target; reconnect policy owns replacement |
| external-control takeover | local immediately; no restore/park mutation on triggering event | Session/Target unchanged unless independently failed |

A lower-domain failure must not be reclassified as an unrelated lifecycle
failure merely to reuse an existing error path.

## Current device-routing facts

### Pointer

For a Samsung DeX desktop sink, current AUTO policy prefers a system-routed UHID
mouse because physical evidence showed explicit InputManager injection could
deliver events while the visible DeX pointer sprite stayed stationary.

For non-desktop targets such as the built-in phone display, current production
behavior uses explicit-display InputManager routing.

A system-routed UHID device must never be described as explicitly targeting an
arbitrary Android display ID.

### Keyboard

Current keyboard delivery uses UHID with an InputManager virtual-injection
fallback. Phone-versus-DeX routing with both displays present remains an
explicit physical-evidence question (#92). Code shape is not proof of routing
behavior.

Separately, #141 is required to give persistent keyboard transitions an explicit
CXI v1 semantic result path.

## Protocol and transport

CXI and transport remain separate.

CXI v1 remains the compatibility wire during the Leap. Additive v1 capabilities
and result messages required for safety, such as #141 keyboard semantic results,
are permitted. CXI v2 (#93) remains a future migration gate, not a side effect of
architecture cleanup.

ADB/`app_process` remains the current/default production transport. An alternate
local transport (#94) requires its own product/security/evidence gate.

A target ID on every future input message could simplify routing semantics, but
ADR-0016 does not require that migration. TargetLease, honest routing scope, and
RemoteCommandLane barriers define the CXI v1 safety boundary.

## Migration map

| Pre-Leap structure | Direction |
| --- | --- |
| `SessionReference` | delete; immutable SessionHandle |
| `SessionController` | Session manager/reconnect policy |
| `RemoteSession` | concrete async protocol session + ordered stateful lane |
| `requestBlocking()` | delete |
| `TargetSelectionController` | Target owner/coordinator + TargetLease |
| `ControlHandoffController` | replace with ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` queue/sequence machinery | pure HandoffPolicy |
| `TransitionSequenceGate` | delete |
| monolithic `InputCapture` | split host capability/capture/translation/edge/suppression responsibilities |
| host `CapturedKeyEvent` Android semantics | replace with platform-neutral semantic key model |
| `InputSender` | InputIngress + per-Control DeliveryWorker |
| separate pointer/keyboard queues | one ordered semantic lane |
| duplicated held-input ownership | delivery ledger + helper/backend cleanup defense in depth |
| `AppModel` infrastructure ownership | composition + presentation projection only |

This map is a direction for deleting the old coordination model rather than
wrapping it indefinitely. Exact type names remain implementation details of the
follow-up slices.

## Verification authority

Automated tests/CI establish deterministic code/protocol/repository properties.
They do **not** substitute for physical-device evidence when the claim depends on
macOS + Samsung DeX behavior.

Issue #68 remains the canonical ADR-0012 Level-3 release-stability tracker. Its
current post-rewrite lineage is **0 / 100 accepted physical handoff/return
cycles** and therefore incomplete. Leap task acceptance evidence and CI do not
credit that counter.

The docs-only #102 architecture decision does not create a new runtime claim and
therefore does not itself require new physical acceptance evidence. Follow-up
implementation PRs require exact-final-HEAD review plus targeted physical
verification for materially affected runtime behavior.

Any HEAD change after a merge-gate PASS invalidates that PASS.

### Required adversarial architecture traces for #102

Before #102 is mergeable, exact-final-HEAD review must be able to trace at least:

1. normal handoff/return;
2. Control acquisition failing halfway;
3. actor-delayed reconciliation after synchronous local return;
4. target A -> B with queued/in-flight ordinary input;
5. target A -> B with a confirmed held key/button;
6. target disappearance before cleanup completes;
7. Session replacement with queued/in-flight input;
8. capability revocation;
9. event-tap failure;
10. non-droppable InputIngress saturation;
11. helper key rejection while Session remains alive;
12. key/button timeout after send;
13. additive motion timeout;
14. external-control takeover;
15. watchdog/emergency return;
16. helper/backend cleanup, including InputManager pointer state;
17. stale response after replacement; and
18. diagnostics payload isolation.

UNKNOWN / UNVERIFIED / INSUFFICIENT EVIDENCE is a merge-gate failure, not a
reason to assume the design is safe.

## Explicit product non-goals

Unless separately approved:

- Android -> macOS pointer or keyboard input;
- Android as a macOS pointing device;
- simultaneous control of multiple Android devices;
- cloud relay/account/server infrastructure;
- root or Knox bypass;
- speculative transport/plugin frameworks; and
- CXI v2 implementation merely to make the Leap cleaner.

## Historical architecture records

Existing ADRs and research notes remain historical evidence. ADR-0016
supersedes the internal architecture-preservation/lifecycle/concurrency portions
of ADR-0009, but not its retained product/device observations.

See [roadmap](roadmap.md), [product definition](product.md), the [ADR index](adr/),
[ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md), and
[CXI v2 design](../protocol/v2-design.md).
