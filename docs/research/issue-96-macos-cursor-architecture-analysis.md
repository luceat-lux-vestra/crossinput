# Issue #96 macOS cursor architecture analysis

## Status

This document records the architecture-analysis pivot for Issue #96 after the controlled AppKit recovery experiments. It is a research artifact, not a production-fix claim.

At the time of this analysis, the investigation branch was based on:

```text
a489057e529839e49647c293dde2e3bc45aabae2
```

The key conclusion is:

> Further one-by-one AppKit recovery probing is paused. The next bounded implementation should serialize Quartz cursor-position mutations onto the event-tap CFRunLoop and extend generation safety to queued cursor mutations. Root cause is not yet confirmed.

## 1. Confirmed physical evidence

The authoritative physical trigger for the native cursor-presentation failure is display-local and deterministic:

1. Native directional/resize cursors are HEALTHY on the configured CrossInput target display.
2. Moving the pointer to another display and back, by itself, does not trigger the failure.
3. Activating or clicking real application/window UI on another display and then returning to the target display reproducibly leaves the affected native directional/resize cursor visually stuck as the ordinary arrow (`BROKEN`).
4. While BROKEN, mouse tracking on the controlled diagnostic AppKit view remains live.
5. Meaningful UI activation/redraw on the affected target display has sometimes restored HEALTHY; equivalent activity on another display does not.
6. `killall SystemUIServer` performed over SSH while leaving the affected target display untouched did not recover the cursor. Earlier apparent SystemUIServer recovery was contaminated by local target-display terminal interaction/output.

The controlled diagnostic panel itself reproduces BROKEN, so the failure is not dependent on an arbitrary third-party application surface.

### Controlled negative recovery experiments

The following affected-window experiments have been physically negative:

- application inactive -> active: BROKEN remains;
- non-key -> key: the transition was realized and BROKEN remains;
- one real window resize: the resize was realized and BROKEN remains.

The resize trial naturally produced window/view lifecycle work including:

```text
window-did-resize
view-layout
update-tracking-areas
reset-cursor-rects
view-draw
```

while the native cursor remained BROKEN.

These results substantially lower the hypothesis that merely refreshing ordinary AppKit window/view/cursor-rect lifecycle state is sufficient to repair the failure.

## 2. Investigation pivot

Do not continue by adding a sequence of recovery commands such as occlusion/expose, miniaturize/deminiaturize, content invalidation, additional redraws, additional activation variants, or similar AppKit lifecycle primitives.

The existing controlled panel is now primarily a regression oracle for the known cross-display activation trigger.

The investigation moves from:

```text
one recovery primitive -> physical trial -> next recovery primitive
```

to:

```text
compare mature macOS input-sharing architectures
-> identify structural ownership/order differences
-> implement one coherent bounded change
-> run the known deterministic physical trigger
```

## 3. Comparative implementation analysis

The comparison covered current CrossInput behavior and the macOS input backends/history of Deskflow, Input Leap, and Lan Mouse.

The purpose is semantic comparison, not API-name matching.

### 3.1 CrossInput

CrossInput creates a HID/head-insert active event tap and runs it on a dedicated `CFRunLoop` hosted by `tapQueue`.

Suppressed pointer moves are consumed and forwarded as raw deltas. `holdPointerAtEdge(generation:)` runs from the capture callback and calls `CGWarpMouseCursorPosition` to keep the local pointer visually at the configured edge.

However cursor-position mutation ownership is not confined to that event-tap run loop.

`release()` may be reached from lifecycle paths including the controller/MainActor, the watchdog queue, emergency control paths, and capture shutdown. Non-external-control release invokes `restorePointerAtEdge()`, which directly performs a cursor warp on the caller's execution context.

CrossInput therefore has multiple potential Quartz cursor-mutation writers even though event capture itself has a dedicated native run loop.

CrossInput also currently treats `event.location` as the authoritative current pointer position for display resolution and local edge detection.

### 3.2 Deskflow

Deskflow's current macOS backend uses a HID/head-insert active event tap with a dedicated native event-tap run loop.

A particularly relevant 2026 macOS fix changed cursor warps so that, while the event-tap loop is active, warp requests originating elsewhere are marshalled onto that Quartz event-tap run loop before `CGWarpMouseCursorPosition` executes.

The associated Deskflow PR describes a race between cursor movement initiated from the normal Deskflow event loop and cursor movement initiated by the Quartz event-tap thread. The fix intentionally creates one native-loop execution context for the warp.

Deskflow also changed its off-screen capture model in July 2026: instead of continuously center-warping the local cursor, it dissociates the hardware mouse from the cursor while off-screen, forwards raw deltas, consumes off-screen mouse movement, and reassociates on return.

That latter design must not be copied blindly into CrossInput: CrossInput already physically tested a suppression-lifetime disassociation/no-per-move-warp variant (Candidate E), and the native cursor problem still reproduced. Disassociation lifetime alone is therefore already negative evidence for Issue #96.

Deskflow's current source also contains private CGS behavior for cursor background handling. That code is informative only and is outside CrossInput's production boundary; private CGS/WindowServer SPI must not be introduced.

### 3.3 Input Leap

Input Leap is useful as the legacy Synergy-lineage comparison.

Its macOS backend still contains the older off-screen center-warp model: while remote, the cursor is repeatedly warped back toward the center and movement is derived from position change. Its `warpCursor()` directly invokes `CGWarpMouseCursorPosition` without the recent Deskflow event-tap-run-loop marshalling behavior.

This is important because it prevents the false conclusion that all mature Synergy-derived implementations use the same current architecture. Deskflow's recent macOS changes are deliberate divergence from older lineage behavior after real macOS cursor/input problems.

### 3.4 Lan Mouse

Lan Mouse provides an independent implementation lineage.

Its current macOS capture backend uses a session event tap on a dedicated native thread/run loop. While captured it can drop local events and reset/warp the cursor from the capture callback path.

Lan Mouse therefore shows that neither of the following is, by itself, a sufficient explanation for Issue #96:

- HID event tap versus session event tap;
- repeated cursor warp versus no repeated warp.

Lan Mouse still uses a repeated cursor reset/warp model successfully, while Deskflow's current model does not. This is consistent with CrossInput's physical evidence that repeated warp is not a necessary trigger.

The more relevant common design property is that low-level capture decisions and cursor mutation have clear execution-context ownership.

## 4. Architecture delta matrix

| Area | CrossInput | Deskflow current | Input Leap | Lan Mouse | Relevance to #96 |
| --- | --- | --- | --- | --- | --- |
| Event tap | HID/head/default | HID/head/default | HID/head/default | Session/head/default | Tap location alone is low priority |
| Native capture loop | dedicated tap CFRunLoop | dedicated event-tap CFRunLoop | current/legacy CFRunLoop ownership | dedicated native thread/CFRunLoop | established viable patterns |
| Remote move | consume + raw delta | consume + raw delta | legacy position diff | consume + deltas | CrossInput already modern here |
| Remote pointer hold | edge per-move warp | disassociate/freeze | center per-move warp | repeated capture-position reset | repeated warp is not sufficient explanation |
| Cursor warp execution context | multiple callers can directly warp | marshalled to event-tap CFRunLoop | direct caller | capture callback path | **highest-value structural delta** |
| Local pointer position authority | `event.location` | live cursor query on local path | live cursor query | event location/delta | secondary candidate only |
| Private CGS | no | yes for cursor background handling | legacy lineage | no | forbidden for CrossInput |

## 5. Concrete CrossInput race found during the comparison

`holdPointerAtEdge(generation:)` currently performs a generation check under `stateLock` and then releases the lock before the actual `CGWarpMouseCursorPosition` call.

Conceptually:

```text
tap callback
  generation guard PASS
  lock released

other thread
  release generation N
  isSuppressing = false
  restore pointer

old tap callback resumes
  old hold warp executes
```

The existing generation check prevents a stale hold only when release has already completed before the check. It does not make the check and subsequent cursor mutation one serialized ownership operation.

Therefore a stale hold can theoretically become the last cursor-position writer after local ownership has already been restored.

A second ordering hazard exists if a generation-N restore is queued/delayed, generation N+1 begins, and the old restore is later allowed to execute.

This is a real cursor-mutation ordering/ownership defect independent of whether it proves to be the direct cause of Issue #96.

The defect is structurally similar to the class of warp race that Deskflow's 2026 macOS fix addressed.

## 6. Root-cause classification

Do not overstate the evidence.

### High-confidence findings

- The controlled affected AppKit view can remain BROKEN while ordinary mouse tracking remains live.
- Activation, key transition, and real resize/layout/tracking/cursor-rect/draw lifecycle are insufficient recovery actions.
- CrossInput has mixed execution-context ownership for Quartz cursor warps.
- The current generation guard does not make generation validation + cursor mutation atomic/serialized.

### Strong inference

The actionable CrossInput-side hypothesis is now:

> Quartz cursor-mutation ordering/ownership, interacting with macOS multi-display activation/focus transitions, can leave or expose stale native cursor-presentation state.

The actual visually BROKEN state appears to be at or below the native cursor-presentation/WindowServer boundary rather than explained by ordinary AppKit tracking-area delivery alone.

### Not yet proven

The following claim is **not** established:

> The mixed-thread warp race is definitively the root cause of Issue #96.

Only a clean implementation plus physical regression result can strengthen or reject that causal claim.

## 7. P0 implementation direction

The next bounded implementation should establish this invariant:

> All production `CGWarpMouseCursorPosition` mutations are executed by one designated owner tied to the event-tap CFRunLoop.

The implementation should preserve the current capture strategy and avoid unrelated behavioral changes.

Keep unchanged in P0:

- HID event tap;
- current edge-switch semantics;
- Android transport and ADB/app_process path;
- pointer-delta forwarding semantics;
- timeout and emergency fail-safe behavior;
- external-control takeover behavior;
- display configuration semantics;
- current `event.location` policy;
- Issue #97 generation/stale-callback guarantees;
- current return-edge behavior except where required to serialize the cursor mutation itself.

A small dedicated cursor-mutation executor/owner is acceptable, but it must not become a general scheduler abstraction.

### Required P0 safety properties

1. A non-owner caller requests a cursor mutation; it does not directly call the platform warp.
2. The actual platform warp executes on the designated event-tap run loop.
3. Already-owner execution may run inline.
4. Cursor-mutation commands carry enough generation/ownership context to reject stale work at execution time.
5. A generation-N hold cannot execute after generation-N local ownership restoration.
6. A generation-N restore cannot mutate the cursor after generation N+1 has taken ownership.
7. Coordination must be bounded; no deadlock or infinite wait.
8. Failure to coordinate must never fall back to a warp from an arbitrary caller thread.
9. Fail-safe priority remains: release suppression/local ownership first; exact pointer continuity is secondary.

## 8. Required deterministic tests for P0

At minimum, tests should force these orderings rather than relying on timing luck.

### Stale hold after release

```text
generation 1 active
hold admitted
pause before platform mutation
release generation 1
resume old hold
```

Expected: the old hold is not permitted to become a post-release cursor mutation.

### Old restore after a new generation

```text
generation 1 restore pending
generation 2 begins
old restore gets execution opportunity
```

Expected: generation-1 restore is rejected as stale.

### Single writer

Request cursor mutations from non-tap execution contexts and verify that the platform mutation is executed only by the designated cursor/event-tap owner.

### Ordinary active hold

An active current-generation suppressed move retains the existing edge-hold behavior.

### Fail-safe coordination failure

If cursor-mutation coordination cannot complete within its bound:

- suppression/local ownership is released;
- local input is not trapped;
- no caller-thread fallback warp occurs;
- no deadlock occurs;
- metadata-only diagnostics may record the failure.

Tests should verify ordered mutation behavior, not just helper invocation counts.

## 9. Physical verification after P0

Do not add another recovery command to the diagnostic panel.

After an independently reviewed exact P0 HEAD receives `PASS FOR PHYSICAL EXPERIMENT`, use the existing controlled panel as a regression oracle:

```text
fresh exact reviewed build
-> confirm target resize cursor HEALTHY
-> move to another display
-> activate/click a real application/window there
-> return to target display
-> visually judge native resize/directional cursor HEALTHY or BROKEN
```

Interpretation:

- HEALTHY: strong causal evidence for the cursor-mutation ownership/order change; proceed to repeated real CrossInput handoff/fail-safe regression testing before any production-merge claim.
- BROKEN: keep any independently valid correctness hardening, but do not claim Issue #96 fixed; move to P1 only then.

## 10. P1 only if P0 remains BROKEN

The next bounded comparison axis is pointer-position authority.

CrossInput currently uses `event.location` directly. Deskflow deliberately re-queries the live cursor position on its local on-screen path because queued event position may be stale by the time it is processed.

If P0 is physically negative, evaluate using an authoritative live cursor snapshot at carefully selected ownership/display boundaries such as local edge detection, suppression entry, display transition, or local restore.

Do not automatically mix this into P0. Lan Mouse's viable use of event location/delta means live-query semantics are a secondary robustness hypothesis, not yet sufficient root-cause evidence.

## 11. Candidates not to rediscover

Do not restart these as standalone Issue #96 directions without genuinely contradictory new evidence:

- redraw/cursor-rect/tracking-area/window-update recovery;
- application activation or key-window recovery;
- another ordinary resize/layout/draw recovery probe;
- occlusion/expose as the next one-by-one recovery probe;
- hide/show as a standalone cure;
- one-off `CGAssociateMouseAndMouseCursorPosition(true)` recovery;
- suppression-lifetime disassociation as a standalone preventive cure;
- synthetic return move/source variants as a standalone cure;
- event-tap location swapping as the leading hypothesis;
- SystemUIServer reset as a production workaround;
- private CGS/WindowServer SPI.

## 12. Investigation boundary

The controlled AppKit lifecycle characterization has done enough work to reject the "just refresh the affected view/window" direction.

Issue #96 now proceeds as an input/cursor ownership architecture investigation.

The next claim boundary is strict:

> No root-cause or production-fix claim until an exact reviewed implementation HEAD passes the known physical trigger and subsequent real CrossInput handoff/fail-safe regression testing.
