# Issue #96 standalone cursor-presentation reproducer

## Purpose

This tool isolates Issue #96 from CrossInput production code, Android, ADB,
Samsung DeX, session state, and the handoff state machine.

It answers one question at a time:

> Does the stale native resize/directional-cursor presentation reproduce with
> pure AppKit, or does it appear only after a specific CoreGraphics capture /
> warp primitive is introduced?

This is a diagnostic executable only. It is not a workaround and must not be
packaged into the Ampersand application.

Investigation base:

```text
646dd6f408242317a5b447eaa7ae398c38a5e089
```

Branch:

```text
investigate/issue-96-minimal-repro
```

## Safety invariants

The reproducer intentionally keeps the dangerous search space bounded:

- no synthetic mouse clicks at any stage;
- no app/window activation injection as a recovery mechanism;
- no cursor hide/show calls;
- no private CGS / SkyLight / WindowServer SPI;
- no `CGAssociateMouseAndMouseCursorPosition` experiments;
- no Android, ADB, helper, protocol, Session, Control, or Target code;
- Stage A and B never mutate pointer position;
- Stage C-G suppression is lease-bounded and defaults to 1.5 seconds;
- `--lease-ms` is fail-closed to the range 250-5000 ms;
- Stage C-G auto-release at lease expiry;
- Shift-Command-X releases an active lease immediately;
- the active event tap passes all events through outside a lease;
- no raw coordinates, key codes, HID reports, clipboard data, or input payloads
  are logged.

D-G intentionally exercise pointer warp behavior. A visible pointer relocation
in those stages is an expected diagnostic side effect, not product behavior.
Do not use D-G for ordinary desktop use.

## Build

From the repository worktree:

```sh
cd apps/macos
swift build --product cursor-presentation-repro
```

Run the built binary directly so the executable path remains stable while
performing a stage:

```sh
.build/debug/cursor-presentation-repro --stage A
```

The diagnostic log is written to:

```text
~/Library/Logs/Ampersand/cursor-presentation-repro.log
```

and mirrored to stdout.

## Stage matrix

Each stage includes the preceding conceptual behavior and adds one new
primitive.

| Stage | Added behavior | Pointer mutation |
|---|---|---|
| A | Pure AppKit window, native `resizeLeftRight` / `resizeUpDown` cursor rects, tracking and activation telemetry | none |
| B | Passive `CGEventTapOptions.listenOnly` mouse tap | none |
| C | Active event tap; during a bounded lease consume mouse-move / drag events | no warp |
| D | C + one `CGWarpMouseCursorPosition` to the selected display edge at lease start | one start warp |
| E | D + repeat the edge hold warp for each consumed movement during the lease | repeated hold warp |
| F | E + explicit restore warp to the same edge when the lease ends | hold + restore |
| G | F + one synthetic `.mouseMoved` after restore | hold + restore + synthetic move |

The stage ordering is diagnostic, not architectural. A failure boundary at a
stage is evidence that the newly introduced primitive or its interaction with
prior stages matters; it is not automatically proof of a single root cause.

## Probe window

The standalone process creates one ordinary resizable AppKit window with two
large probe regions:

- horizontal probe: `NSCursor.resizeLeftRight`;
- vertical probe: `NSCursor.resizeUpDown`.

`resetCursorRects()` installs the built-in native cursor rects. Separate
tracking areas record:

- `mouseEntered` / `mouseExited` / rate-limited `mouseMoved` using
  `.activeAlways`;
- `cursorUpdate(with:)` using `.activeInActiveApp`.

The tracking areas are deliberately separate. AppKit documents that combining
`.cursorUpdate` with `.activeAlways` does not produce cursor-update callbacks,
so absence of `cursor-update` while the application is inactive is expected
and must not be treated as causal evidence.

Lifecycle telemetry also records metadata-only changes for:

- app active / inactive;
- window key / non-key;
- window main / non-main;
- window screen changes;
- window move / resize;
- frontmost application bundle identifier;
- pointer display transitions observed by the event tap in stages B-G.

No pointer coordinates are logged.

## Stage commands

A — pure AppKit:

```sh
.build/debug/cursor-presentation-repro --stage A
```

B — passive event tap:

```sh
.build/debug/cursor-presentation-repro --stage B
```

C — bounded movement consumption:

```sh
.build/debug/cursor-presentation-repro --stage C --lease-ms 1500
```

D-G — choose the edge that matches the physical experiment. Example for the
right edge:

```sh
.build/debug/cursor-presentation-repro --stage D --edge right --lease-ms 1500
.build/debug/cursor-presentation-repro --stage E --edge right --lease-ms 1500
.build/debug/cursor-presentation-repro --stage F --edge right --lease-ms 1500
.build/debug/cursor-presentation-repro --stage G --edge right --lease-ms 1500
```

For stages that install a CoreGraphics event tap, macOS privacy permissions may
be required for the terminal/executable. The tool fails closed if the tap
cannot be created and emits `event-tap-unavailable`; do not treat such a run as
a stage result.

## Physical protocol

Run stages in order and stop at the first reproducible boundary.

### Per-stage setup

1. Start exactly one stage in a fresh process.
2. Move the reproducer window to the display that will be the target display.
3. Hover both probe regions and record the visual cursor state.
4. If the cursor is already BROKEN at process start, either:
   - record the run as `STARTED_BROKEN` and do not infer that this stage caused
     the failure; or
   - use the already-documented **manual real menu-bar click** once to establish
     an observable HEALTHY baseline, then record that recovery explicitly.
5. For stages C-G, press **Run bounded stage action** once and wait for
   `lease-ended ... reason=timeout` before continuing. Do not interact with the
   other display while the lease is active.
6. Move the real pointer to another display.
7. Click/activate a real application or window on that other display.
8. Return to the target display **without clicking the target display**.
9. Hover both native resize probe regions and classify the result.
10. Quit the process before starting the next stage.

### Stop conditions

- If Stage A reproduces BROKEN reliably, **stop**. CrossInput capture/warp is
  not required for the failure; B-G add no root-cause value until the pure
  AppKit result is understood.
- If A is healthy and B first reproduces, isolate passive event-tap presence.
- If B is healthy and C first reproduces, isolate active event-tap / movement
  suppression.
- Continue similarly only while every prior stage remains physically healthy.
- A stage that starts BROKEN and cannot be restored to a known baseline is
  `INCONCLUSIVE`, never FAIL/PASS evidence for the stage boundary.

## Evidence capture

Before each run:

```sh
LOG="$HOME/Library/Logs/Ampersand/cursor-presentation-repro.log"
: > "$LOG"
```

After the run:

```sh
cat "$LOG"
```

Useful compact view:

```sh
grep -E \
'event=session-start|event=event-tap-installed|event=lease-|event=warp-|event=synthetic-move|event=app-did-|event=window-did-|event=cursor-update|event=mouse-entered|event=mouse-exited|event=pointer-display-changed' \
"$LOG"
```

Physical classification must be supplied separately because the tool does not
infer the rendered cursor image:

```text
stage=A
start=HEALTHY|BROKEN|RECOVERED_MANUALLY
post_cross_display=HEALTHY|BROKEN
notes=<optional visible behavior>
```

## Interpretation matrix

### A reproduces

Strong evidence that CrossInput-specific event capture, Android delivery, and
pointer-hold logic are unnecessary. Next step is to reduce the standalone
AppKit window further and prepare an Apple Feedback reproducer.

### A healthy, B reproduces

Passive event-tap presence becomes the first boundary. Verify with a narrower
mouse-event mask and tap placement before touching production code.

### B healthy, C reproduces

Active tap / suppression semantics become the first boundary. Split active
pass-through from event consumption in a follow-up micro-stage before drawing a
production conclusion.

### C healthy, D reproduces

A one-off Quartz warp becomes the first strong boundary. Investigate whether
CrossInput can avoid or relocate that mutation rather than adding cursor
recovery APIs.

### D healthy, E reproduces

Repeated edge-hold warping becomes the first strong boundary. This would
justify architectural work on how remote ownership keeps the local pointer
stationary.

### E healthy, F reproduces

The release/restore warp becomes the first boundary. Focus on local-return
ownership and restore semantics.

### F healthy, G reproduces

The post-restore synthetic `.mouseMoved` becomes the first boundary. This is a
narrow production-search space and should be verified against the already
negative synthetic-move history before any code change.

### A-G all healthy

The minimal harness has removed something material from production. Compare the
remaining differences systematically; do not restart cursor API combinatorics.
Candidates include production timing, multi-event suppression duration,
state-machine sequencing, or another interaction not represented by the
harness.

## Non-goals

This reproducer does not:

- recover the cursor automatically;
- synthesize clicks;
- decide that macOS is at fault from one run;
- change production cursor behavior;
- replace the Issue #96 existing controlled-panel evidence;
- authorize a production workaround or PR.

## Verification gate

Before physical use:

1. exact branch HEAD must be recorded;
2. `swift build --product cursor-presentation-repro` must succeed on macOS;
3. `swift test --quiet --disable-sandbox` must remain green;
4. static review must confirm production source files are unchanged except the
   SwiftPM declaration adding the standalone target;
5. physical stage results must be recorded against the exact executable HEAD.

Until those conditions are met, verdict is:

```text
NOT PASS FOR PHYSICAL EXPERIMENT
```
