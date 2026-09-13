# CrossInput Architecture

> Status: **Architecture Leap target model proposed by ADR-0016, 2026-09-13.**
>
> [Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> is the authority for sequencing. [ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md)
> defines the target ownership/concurrency model for #102. Pre-Leap classes,
> modules, queues, and generation counters are not architectural commitments.

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
internal redesign when it produces clearer ownership and safer lifecycle or
concurrency semantics.

Large internal changes are still decomposed into coherent, independently
reviewable PRs. Rewrite freedom is not permission to combine unrelated product,
protocol, or transport migrations.

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
  -> selected Android target
     -> desktop sink: system-routed UHID preferred
     -> other target: explicit-display InputManager
```

This topology is a product/device fact. It does not require preserving the
current controller classes, mutable references, queue layout, or source target
names.

## Non-negotiable invariants

1. **Local safety** — macOS pointer/keyboard control can never be permanently
   trapped and local restoration never waits for Android.
2. **No cross-Control delivery** — stale work from an invalidated Control owner
   cannot reach a replacement Control owner.
3. **No cross-Session retargeting** — work captured for an old Session cannot be
   redirected to a replacement connection.
4. **No cross-Target retargeting** — work captured for target A cannot be
   delivered after target B becomes current.
5. **Held-state safety** — remote held keys/buttons are cleaned up or the
   remote state/session is invalidated safely.
6. **One suppression owner** — at most one valid host SuppressionLease may
   consume local input.
7. **Bounded capture path** — CGEventTap/event hot paths remain bounded and
   nonblocking.
8. **Persistent transitions are ordered** — key/button state transitions are
   delivered in order or the Control fails safe; they are never silently lost.
9. **Platform boundaries** — CoreGraphics/AppKit/TCC do not leak into remote
   domain semantics; Android/CXI/UHID/InputManager details do not leak into the
   host/domain API.
10. **Payload-safe diagnostics** — raw input payloads, key codes/typed contents,
    HID reports, pointer coordinates/deltas, and clipboard contents never enter
    normal diagnostics.

## Target ownership model

The architecture is defined by lifecycle owners rather than by the current file
layout.

### Capability owner

Owns macOS Accessibility/Input Monitoring capability state and recovery.
Capability failure blocks Control acquisition and fails toward local control.
It does **not** tear down a healthy Android Session solely because local TCC
capability is unavailable.

### Host capture owner

Owns the CGEventTap lifecycle and raw macOS event observation. Capture lifetime
is distinct from suppression lifetime.

The host side is split conceptually into:

- `InputCapabilityController`;
- `MacEventTap`;
- `MacInputTranslator`;
- `EdgeDetector`; and
- `HostSuppressionController`.

Exact names may change, but those responsibilities must not collapse back into
one monolithic input object.

### Session owner

A concrete connection is represented by one immutable **SessionHandle**. It is
bound to one helper/CXI connection and never points at a replacement connection.

A Session manager may replace the current SessionHandle, but old work continues
to hold only the old handle. The target architecture therefore removes the need
for a mutable `SessionReference` that can be redirected to a newer session.

Session owns:

- ADB/helper launch through the transport adapter;
- CXI handshake/capabilities;
- request correlation and timeout classification;
- disconnect/shutdown;
- the stateful remote command lane; and
- connection/reconnect identity.

### Target owner

Target discovery/selection is a lifecycle separate from Session. Selection
produces one immutable **TargetLease** scoped to exactly one SessionHandle.

CXI v1 `SELECT_DISPLAY` mutates helper-global routing state. Therefore a target
change is an ordering barrier, not a presentation-only state change.

A TargetLease is published only after the helper confirms the selection.
Delivery requires the exact current TargetLease.

### Control owner

Control owns whether CrossInput is currently allowed to transfer local input to
the selected remote target.

Entering remote ownership creates one **ControlLease** binding:

- SessionHandle;
- TargetLease;
- host SuppressionLease;
- synchronous InputIngress; and
- asynchronous DeliveryWorker.

Ending Control closes that lease permanently. Late callbacks carrying the old
lease cannot become valid for a replacement Control.

### Delivery owner

One DeliveryWorker exists per ControlLease. It is never rebound to a new Session
or Target.

Delivery owns:

- one ordered semantic input lane;
- class-aware coalescing/backpressure;
- semantic-to-CXI v1 translation at the remote boundary;
- async request/response execution;
- movement acknowledgement needed by handoff policy;
- the authoritative host-side ledger of acknowledged remote-held keys/buttons;
- bounded cleanup; and
- stale/ambiguous delivery classification.

### Application / presentation

The application root composes owners and projects their states into UI.
Presentation may issue intents such as connect/disconnect, select target,
enable/disable control, emergency return, or open permission settings.

Presentation does not become an implicit owner of Session, Target, Control,
capture, TCC, or delivery lifetimes.

`AppModel` is not a compatibility requirement.

## Runtime data path

### Local state

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator / EdgeDetector
  -> local macOS event path
```

While local, events pass through. Edge detection may send a lightweight acquire
request to ControlCoordinator.

### Remote state

```text
CGEventTap
  -> MacEventTap
  -> MacInputTranslator
  -> current ControlLease.InputIngress
  -> DeliveryWorker
  -> TargetLease-validated RemoteCommandLane
  -> CXI v1 adapter
  -> Android helper
  -> selected backend
```

The CGEventTap callback never waits for remote acknowledgement.

## Host suppression and fail-safe

`HostSuppressionController` is the only owner allowed to consume host input or
perform the accepted P0 cursor-confinement mutations.

It owns an explicit **SuppressionLease** with idempotent release.

Suppression release is local and can be triggered by:

- normal return/boundary crossing;
- watchdog timeout;
- emergency shortcut;
- permission/capture loss;
- Session failure/replacement;
- Target invalidation/change;
- remote delivery failure;
- external-control takeover;
- user disable/disconnect; or
- teardown.

The required ordering is:

```text
restore local host control
  -> close ControlLease ingress
  -> cancel remote work
  -> bounded best-effort held-input cleanup
  -> invalidate Session if remote state remains ambiguous
```

No Android response is required for the first step.

The accepted #96 disposition is part of this host contract:

- retain P0-style host confinement;
- keep the native Mac cursor visible;
- accept the documented native cursor-presentation limitation;
- do not introduce private SkyLight/CGS, synthetic-click, focus-stealing,
  custom-cursor, pointer-jump, or equivalent workaround permutations without
  materially new evidence.

## Handoff policy

The target architecture replaces internally queued/callback-sequenced handoff
state with a pure **HandoffPolicy**.

It receives facts and returns decisions; it owns no executor.

Inputs include:

- control enabled/disabled;
- edge entered;
- entry edge;
- requested/accepted remote movement acknowledgement;
- explicit return/failure reason.

Outputs include:

- acquire remote ownership; and
- return local ownership.

ControlCoordinator serializes policy application.

Validated #45/#37 behavior remains unless separately superseded:

- return-direction movement credits requested intent when Android clamps
  accepted movement at a display boundary;
- inward movement credits confirmed accepted movement;
- first post-entry movement cannot instantly trigger a return; and
- return hysteresis prevents edge wobble from causing accidental handoff.

## InputIngress and backpressure

The event-tap callback cannot `await`. Therefore each ControlLease exposes one
small lock-protected **InputIngress**.

InputIngress:

- performs bounded synchronous admission;
- never performs transport I/O;
- never blocks on remote completion;
- is permanently closed when its ControlLease ends; and
- returns an immediate admission result.

One ordered semantic lane covers pointer and keyboard events. The old split
pointer/keyboard queue model is not part of the target design.

Default policy:

| Event class | Coalesce | Shed | Ordering requirement |
| --- | --- | --- | --- |
| relative motion | adjacent only | allowed under bounded overload | additive |
| scroll | adjacent only | allowed when additive semantics are preserved | additive |
| pointer button down/up | never | never silently | strict |
| key down/up | never | never silently | strict |
| key repeat | no shedding by default | only if later proven safe | strict by default |
| cleanup/release | no lossy treatment | never silently | stronger than ordinary input |

If a non-droppable transition cannot be admitted, Control returns local rather
than silently losing persistent remote state.

## Remote command ordering

Swift actor isolation alone does not make a remote state machine non-reentrant
across `await` points.

Each SessionHandle therefore owns an explicit non-reentrant
**RemoteCommandLane** for helper-global/stateful operations. The lane executes
one command through completion before starting the next.

At minimum this lane orders:

- `SELECT_DISPLAY`;
- pointer input;
- keyboard input;
- held-input cleanup whose order matters; and
- shutdown/reset operations that alter backend state.

Read-only requests may use a separate path only when they cannot race
helper-global routing/input state.

### Target-change barrier

Target A -> B follows:

```text
Control A -> local restore
          -> close A ingress
          -> cancel/quiesce A delivery
          -> invalidate TargetLease A
          -> ordered SELECT_DISPLAY(B)
          -> helper confirms B
          -> publish TargetLease B
          -> new Control may acquire B
```

This is required because current CXI v1 input messages do not carry a target ID
on every event.

## Session replacement

The old architecture uses a mutable session reference plus generation checks.
The target architecture instead uses per-connection identity by construction.

```text
SessionHandle A -- shutdown/invalidate --> dead forever
SessionHandle B -- newly created --------> independent resource
```

A DeliveryWorker created for A has no path that can suddenly resolve to B.
Typed IDs may exist for diagnostics/tests, but they are not a substitute for
resource ownership.

## Remote held-state and ambiguous failures

DeliveryWorker updates its held-input ledger only from confirmed semantic state
transitions.

A timeout after sending a key/button transition can still be ambiguous: the
helper may have applied it even if the response was not observed.

The system therefore treats ambiguity as a trust boundary:

- restore local control immediately;
- perform bounded cleanup when state is sufficiently known;
- require the helper/backend to clean owned held state on session/helper
  shutdown where possible (audited in #107); and
- invalidate the current Session instead of reusing it as healthy when
  persistent remote state cannot be proven trustworthy.

No infinite cleanup retries are permitted.

## Target module direction

Exact SwiftPM target names are finalized by #103, but dependency direction is
fixed:

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
- CXI framing is not a domain concept;
- Android key/meta constants are not emitted from host capture; and
- CoreGraphics/AppKit types are not exposed through the semantic input API.

## Concurrency model

### MainActor

Application composition, view-state projection, UI intents, and AppKit/System
Settings presentation actions.

### Mac event-tap executor

Dedicated CFRunLoop/queue. Allowed work is bounded translation/classification,
small lock-protected lease lookup, bounded InputIngress admission, and local
suppression/fail-safe mechanics.

Forbidden work includes transport I/O, blocking semaphore waits, actor waits,
unbounded allocation/work, and payload logging.

### ControlCoordinator

Intended as a Swift actor. It owns Control lifecycle state and HandoffPolicy.

Local safety does not depend on actor scheduling: HostSuppressionController can
release synchronously and notify the actor afterward.

### Session manager / concrete remote session

Connection/reconnect/replacement is serialized by the Session owner. Each
concrete SessionHandle owns its own protocol session and explicit stateful
RemoteCommandLane.

### DeliveryWorker

One asynchronous worker per ControlLease. It drains only that lease's ingress
and only talks to that lease's SessionHandle/TargetLease.

## Failure-domain matrix

| Failure | Control | Session | Target |
| --- | --- | --- | --- |
| missing/revoked host capability | local/blocked | may remain healthy | may remain selected |
| event-tap/capture failure | local/blocked | may remain healthy | may remain selected |
| ordinary Control return | local | unchanged | unchanged |
| delivery state becomes ambiguous | local | invalidate when trust cannot be restored | invalid with Session if Session ends |
| target disappears/changes | local if using it | may remain healthy | invalidate/reselect |
| transport/helper disconnect | local immediately | invalidate/reconnect policy | invalidate with Session |
| external-control takeover | local immediately, no restore/park side effect on triggering event | unchanged unless separately failed | unchanged |

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

## Protocol and transport

CXI and transport remain separate.

CXI v1 remains the compatibility wire during the Leap. CXI v2 (#93) is a future
migration gate, not a side effect of refactoring.

ADB/`app_process` remains the current/default production transport. An alternate
local transport (#94) requires its own product/security/evidence gate.

A target ID on every future input message could simplify routing semantics, but
ADR-0016 deliberately does not require that protocol migration. TargetLease +
RemoteCommandLane provide the v1 safety boundary.

## Migration map

| Pre-Leap structure | Direction |
| --- | --- |
| `SessionReference` | delete; immutable SessionHandle |
| `SessionController` | Session manager/reconnect policy |
| `RemoteSession` | concrete async protocol session + ordered stateful lane |
| `requestBlocking()` | delete |
| `TargetSelectionController` | TargetCoordinator + TargetLease |
| `ControlHandoffController` | replace with ControlCoordinator + ControlLease |
| `EdgeSwitchStateMachine` queue/sequence machinery | pure HandoffPolicy |
| `TransitionSequenceGate` | delete |
| monolithic `InputCapture` | split host capability/capture/translation/edge/suppression responsibilities |
| host `CapturedKeyEvent` Android semantics | replace with platform-neutral semantic key model |
| `InputSender` | InputIngress + per-Control DeliveryWorker |
| separate pointer/keyboard queues | one ordered semantic lane |
| duplicated held-input ownership | consolidate in delivery; helper cleanup as defense in depth |
| `AppModel` infrastructure ownership | composition + presentation projection only |

This map is not a requirement to use these exact target names. It is a direction
for deleting the old coordination model rather than wrapping it indefinitely.

## Verification authority

Automated tests/CI establish deterministic code/protocol/repository properties.
They do **not** substitute for physical-device evidence when the claim depends on
macOS + Samsung DeX behavior.

Issue #68 remains the canonical ADR-0012 Level-3 release-stability tracker. Its
current post-rewrite lineage is **0 / 100 accepted physical handoff/return
cycles** and therefore incomplete. Leap task acceptance evidence and CI do not
credit that counter.

Implementation PRs must include exact-final-HEAD review and targeted physical
verification for materially affected runtime behavior. Any HEAD change after a
merge-gate PASS invalidates that PASS.

## Explicit product non-goals

Unless separately approved:

- Android → macOS pointer or keyboard input;
- Android as a macOS pointing device;
- simultaneous control of multiple Android devices;
- cloud relay/account/server infrastructure;
- root or Knox bypass;
- speculative transport/plugin frameworks; and
- CXI v2 implementation merely to make the Leap cleaner.

## Historical architecture records

Existing ADRs and research notes remain historical evidence. ADR-0016
supersedes the internal architecture-preservation/concurrency portions of
ADR-0009, but not its retained product/device observations.

See [roadmap](roadmap.md), [product definition](product.md), the [ADR index](adr/),
[ADR-0016](adr/ADR-0016-leap-ownership-and-concurrency.md), and
[CXI v2 design](../protocol/v2-design.md).
