# Issue #96 affected-window cursor lifecycle instrumentation

## Status and provenance

This is a diagnostic-only, opt-in AppKit lifecycle instrument. It does not
implement a production cursor fix. It is intended for independent review
before any further physical testing.

Investigation base commit:

```text
e9b6ea474fffa1b0393f58f6ce3bbac74056686f
```

Baseline immediately before this resize-experiment change:

```text
bdeb3af3363d397d3d0965b6628e2f43a93af146
```

Prior reviewed invalidation probe lineage:

```text
f25dfe59588e0175d93b3f328d8f3649544c1c21
```

The branch also retains the follow-up panel-coordinate correction required for
non-primary displays. The final implementation HEAD is reported with the
review handoff because this document cannot self-reference the commit that
contains its own final SHA.

The previously completed arbitrary-window primitive probes were physically
reported as BROKEN for `cursor-rect`, `redraw`, `tracking-area`,
`window-update`, and `activation-control`, with all commands invoked through
the off-target Unix-domain control channel. This instrumentation does not
extend or reinterpret that negative probe matrix.

The owned diagnostic panel itself has since been physically confirmed to
reproduce BROKEN: native resize cursors remain visually stale as the ordinary
arrow after the cross-display activation transition. While BROKEN, the panel
remains visible on the configured display and continues to receive
`mouseEntered`, `mouseExited`, and `mouseMoved` callbacks. This is lifecycle
observation evidence, not an inferred cursor state or a root-cause conclusion.

The activation-only recovery trial was then performed on exact HEAD
`3ce56e1fd8b533df73bf64b323b1f4c1974e6457`. The recorded sequence included
`marker-broken-confirmed app_active=false key=false main=false`,
`marker-recovery-action app_active=false key=false main=false`, and
`application-did-become-active app_active=true key=false main=false`. The
operator visually checked the affected horizontal/vertical native cursor while
the application was active, and it remained BROKEN. Application activation
alone was therefore physically negative and insufficient to recover the BROKEN
native cursor presentation state. A later resign-active notification or late marker does not
invalidate the observation made during the explicitly confirmed active
interval.

The realized non-key -> key physical trial was also physically negative. Its trace
contained two realized non-key -> key transitions, so it was not a perfectly
isolated single-request trace. Even with that caveat, the affected panel was
observed in the realized key state while the native cursor remained BROKEN;
being key was insufficient. This resize experiment does not repeat, combine,
or reinterpret that trial.

The `26892febac34da24a817e37f7d951fb49b20c283` draft was not physically
tested. Independent review found that its borderless/nonactivating diagnostic
panel was not explicitly key-capable, so `window.makeKey()` could fail to
realize the requested transition. The corrected diagnostic design below adds
only explicit key eligibility to the Issue #96 panel before any physical trial.

## Opt-in and target selection

The harness remains disabled unless the app is launched with:

```sh
APP=/path/to/Ampersand.app
env CROSSINPUT_DIAG_TARGET_DISPLAY_INVALIDATION=1 \
  "$APP/Contents/MacOS/Ampersand"
```

An optional local socket path may be supplied with:

```sh
export CROSSINPUT_ISSUE96_PROBE_SOCKET=/tmp/crossinput-issue96.sock
```

The app creates the harness only after `AppModel.refreshHostDisplays()` and
resolves the configured target from `AppModel.hostDisplays`. A display is
configured when its existing edge option is non-nil. Exactly one configured
display is required:

* zero configured displays fails closed with `no-configured-target`;
* multiple configured displays fail closed with
  `multiple-configured-targets`;
* exactly one configured display is passed by identity to the harness.

The harness does not hardcode a display ID, inspect the current pointer, read
`AppSettings`, or reach into `InputCapture` to select a target.

The diagnostic window is a CrossInput-owned `Issue96ProbePanel`, a
non-activating floating `NSPanel` with a minimal custom `NSView`. The diagnostic
subclass explicitly overrides `canBecomeKey` to return `true`, solely so the
dedicated `recovery-window-key` trial can request an actual key transition. Its
frame is normalized to the selected screen's local coordinate space before
construction, so a non-primary screen origin is not applied twice. It is
ordered and its tracking state is stabilized before the experiment; that setup
is not a probe command.

Key eligibility does not change baseline state: the window is not key or main
by default, does not accept first mouse, and does not intentionally activate
the application. No menu or clickable probe control is presented on the target
display.

## Diagnostic cursor regions

The view draws three obvious symbolic regions plus an ordinary background:

* `resize-horizontal` — public `NSCursor.resizeLeftRight` cursor rect;
* `resize-vertical` — public `NSCursor.resizeUpDown` cursor rect;
* `resize-diagonal` — symbolic lifecycle region only;
* `background` — ordinary arrow region.

The macOS SDK used for this build does not expose a built-in diagonal resize
`NSCursor`. The diagonal tile therefore does not invent a custom cursor; it is
retained as a symbolic region for callback classification. Only the built-in
horizontal and vertical native resize cursors are registered.

The view uses two separate owned tracking areas. The mouse lifecycle area uses
`.activeAlways`, `.mouseEnteredAndExited`, and `.mouseMoved`. The cursor-update
area uses `.activeInActiveApp` and `.cursorUpdate`. AppKit documents that
`.activeAlways` combined with `.cursorUpdate` suppresses `cursorUpdate(with:)`,
so that invalid combination is deliberately not constructed. Consequently,
`cursor-update` observation is meaningful only while the application is
active. Therefore, the absence of `cursor-update` while the app is inactive is
expected and is not causal evidence; application activation state is recorded
alongside the trace rather than inferred from cursor callbacks.

## Lifecycle callbacks instrumented

The view records these callbacks:

* `resetCursorRects()` -> `reset-cursor-rects`;
* `cursorUpdate(with:)` -> `cursor-update`;
* `updateTrackingAreas()` -> `update-tracking-areas`;
* `mouseEntered(with:)` -> `mouse-entered`;
* `mouseExited(with:)` -> `mouse-exited`;
* `mouseMoved(with:)` -> `mouse-moved`;
* `viewDidMoveToWindow()` -> `view-did-move-to-window`;
* `viewDidMoveToSuperview()` -> `view-did-move-to-superview`;
* `layout()` -> `view-layout`;
* `draw(_:)` -> `view-draw`.

The harness observes these application/window notifications for the owned
window:

* `NSApplication.didBecomeActiveNotification`;
* `NSApplication.didResignActiveNotification`;
* `NSWindow.didBecomeKeyNotification`;
* `NSWindow.didResignKeyNotification`;
* `NSWindow.didBecomeMainNotification`;
* `NSWindow.didResignMainNotification`;
* `NSWindow.didChangeOcclusionStateNotification`;
* `NSWindow.didMiniaturizeNotification`;
* `NSWindow.didDeminiaturizeNotification`;
* `NSWindow.didChangeScreenNotification`;
* `NSWindow.didMoveNotification`;
* `NSWindow.didResizeNotification`;
* `NSWindow.willCloseNotification`.

AppKit does not expose the old order-on-screen names used by some other APIs
in this SDK. Visibility and occlusion are captured on every trace record, and
the public occlusion/miniaturize/window lifecycle notifications above are the
available order/visibility evidence.

## Trace schema and bounds

Each record is a stable metadata line with this shape:

```text
TRACE sequence=42 monotonic_ns=... event=cursor-update region=resize-horizontal target_display_id=... window_display_id=... app_active=false is_key_window=false is_main_window=false visible=true occlusion_state=1 occluded=false
```

Fields are:

* monotonically increasing sequence number;
* monotonic timestamp from `DispatchTime`;
* stable lifecycle or trial-marker event kind;
* symbolic region, or `none`;
* configured target display ID;
* current public window display ID, or `none`;
* application active state;
* window key/main state;
* window visibility and public occlusion-state raw value.

The in-memory trace is a deterministic circular ring with capacity 1,000
records, avoiding an array front-shift on every high-frequency callback.
`clear-trace` clears retained records but does not reset the monotonic sequence.
`dump-trace` is capped at 64 KiB and reports whether output was truncated. When
truncated, it retains the newest contiguous suffix and emits that suffix in
chronological order, preserving the latest trial marker and nearby callbacks.
No raw coordinates, event payloads, keys, clipboard data, HID reports, or
screen content are retained or emitted.

## Off-target control commands

The existing local Unix-domain endpoint remains the only control channel. It is
mode `0600`, not TCP/network exposed, accepts one bounded UTF-8 command per
connection, and has the existing 512-byte input and two-second socket-read
limits. The fixed command set is:

```text
status
redraw
cursor-rect
tracking-area
window-update
activation-control
recovery-app-activate
recovery-window-key
recovery-window-resize
mark-baseline-healthy
mark-broken-confirmed
mark-recovery-action
mark-recovered
mark-still-broken
clear-trace
dump-trace
```

The socket writer handles short writes, retries `EINTR`, and sets
`SO_NOSIGPIPE` for accepted clients. A disconnected client can therefore
discard its response without terminating the process; no partial write is
reported as a complete response internally.

Use the repository script from SSH or another off-target shell:

```sh
./scripts/issue96/target-display-probe.sh clear-trace
./scripts/issue96/target-display-probe.sh mark-baseline-healthy
./scripts/issue96/target-display-probe.sh dump-trace
```

Marker commands append exactly one symbolic marker record. `clear-trace` only
clears the ring. `dump-trace` only serializes retained records. `status` only
reads state. None of these commands call an AppKit mutation primitive, order
the window, activate the application, change key/main state, redraw, rebuild
tracking areas, invalidate cursor rects, or move the pointer. The dispatcher
tests assert that all trace/control commands dispatch zero primitive calls.

The five earlier primitive commands remain separately identifiable and retain
their original one-family dispatcher mapping. Their presence does not imply
that the new lifecycle controls execute them. `recovery-app-activate` is a
separate affected-window recovery experiment because the owned panel itself is
the observed BROKEN surface; it is not a rewrite of the historical
`activation-control` probe.

Their exact mappings remain:

| Command | AppKit primitive |
| --- | --- |
| `redraw` | `view.needsDisplay = true`; `view.displayIfNeeded()` |
| `cursor-rect` | `window.invalidateCursorRects(for: view)` |
| `tracking-area` | remove/add both owned tracking areas |
| `window-update` | `window.orderFront(nil)` |
| `activation-control` | `NSApplication.activate`; `window.makeKeyAndOrderFront` |
| `recovery-app-activate` | `NSApplication.activate(ignoringOtherApps: true)` only, after fail-closed checks |
| `recovery-window-key` | `window.makeKey()` only, after fail-closed checks |
| `recovery-window-resize` | `window.setFrame(_:display: false, animate: false)` once, after fail-closed checks |

`recovery-app-activate` requires the panel to exist on the configured target
display and the application to be inactive. If the app is already active it
returns `application-already-active` without calling the activation API. On a
valid inactive state it performs exactly one public AppKit operation:
`NSApplication.shared.activate(ignoringOtherApps: true)`. It does not call
`makeKey`, `makeMain`, any ordering method, redraw, cursor-rect invalidation,
tracking-area rebuild, cursor setter, synthetic input, or pointer movement.
AppKit notifications that naturally follow activation remain observable in
the existing trace. The command does not add any automatic trial marker and
does not claim cursor recovery.

`recovery-window-key` is a separate affected-window recovery experiment. It
requires, in order, that the diagnostic window still exists, remains on the
configured target display, the application is already active, and the
diagnostic window is currently non-key. Failure returns an explicit reason:
`diagnostic-window-unavailable`,
`diagnostic-window-not-on-target-display`, `application-not-active`, or
`diagnostic-window-already-key`. It never activates the application, orders the
window, makes it main, redraws, resizes, invalidates cursor rectangles,
rebuilds tracking areas, changes content, moves the window or pointer, sends
synthetic input, sets a cursor, hides/shows the window, or uses private APIs.

On valid preconditions it invokes only the public AppKit operation
`window.makeKey()`. `api_success=true` means only that this request was issued
after the fail-closed preconditions; it does not prove that the nonactivating
panel became key and does not claim cursor recovery. The physical trial is
valid only when lifecycle evidence shows `window-did-become-key` and/or later
state with `is_key_window=true`. If `makeKey()` is invoked but the panel
remains `key=false`, the result is `INVALID / TRANSITION NOT REALIZED`, not
`STILL BROKEN`. AppKit callbacks that naturally follow `makeKey()` are
retained as evidence.

The panel's `canBecomeKey == true` capability is not itself a key transition.
Only `recovery-window-key` requests `window.makeKey()`, and API invocation is
still not transition proof. Physical evidence must confirm
`window-did-become-key` and/or `key=true`; human visual HEALTHY/BROKEN judgment
of the cursor remains authoritative.

`recovery-window-resize` is the next and only new recovery experiment in this
change. It requires, in order, that the diagnostic window still exists, remains
on the configured target display, has an available valid current frame, that
the current frame is within its public minimum/maximum size limits, that the
requested frame is valid and within those limits, and that the requested frame
changes the size. Failure returns one of:
`diagnostic-window-unavailable`, `diagnostic-window-not-on-target-display`,
`diagnostic-window-frame-unavailable`, `diagnostic-window-frame-invalid`,
`diagnostic-window-frame-not-resizable`, `requested-resize-frame-invalid`,
`requested-resize-frame-not-resizable`, or `resize-would-not-change-size`.
Every failure is returned as `ERROR` and makes zero resize mutation calls.

On valid preconditions it invokes exactly one public AppKit frame operation:

```swift
window.setFrame(requestedFrame, display: false, animate: false)
```

`requestedFrame` preserves the current frame origin, preserves the current
height, and increases the current width by exactly 16 points. The call is not
animated, and the original frame is not restored by the command. No
application-active, key-window, main-window, visibility, ordering, redraw,
cursor-rect, tracking-area, cursor-set, pointer, or event-posting operation is
part of this path. The frame API is programmatic; the panel's existing
nonactivating diagnostic configuration is not changed to make it user
resizable.

`api_success=true` means only that this one request was issued after the
fail-closed checks. It does not prove that AppKit realized the new size or that
the cursor recovered. Resize records include bounded before/after panel-size
metadata. A later physical trial must also retain naturally emitted
`window-did-resize` and/or resulting frame-size evidence. The command does not
manually invoke resize, layout, draw, cursor, tracking, ordering, or any other
lifecycle mechanism.

## Physical protocol for the later controlled resize trial

No physical result is claimed by this implementation or its automated tests.
This commit only makes `recovery-window-resize` testable. After independent
strict review of the final implementation HEAD, the trial must start from a
FRESH controlled BROKEN state:

```text
1. Fresh launch of the exact reviewed SHA.
2. Confirm the diagnostic panel is initially HEALTHY.
3. Reproduce BROKEN using the known cross-display real-application activation trigger.
4. Visually reconfirm the diagnostic horizontal/vertical resize cursor is BROKEN.
5. Perform any required experiment setup BEFORE the recovery marker.
6. Reconfirm the cursor is still BROKEN after setup.
7. clear-trace / establish a clean evidence window as appropriate.
8. mark-broken-confirmed.
9. mark-recovery-action.
10. Execute exactly one recovery-window-resize.
11. Observe the same cursor visually.
12. Record exactly one of mark-recovered or mark-still-broken.
13. status.
14. dump-trace.
```

The off-target operator should have the control shell ready before step 7, so
no target-display interaction is needed after the recovery marker. Do not
click, keypress, use menus, display terminal output, take screenshots, or
record the target display before its result is observed. Any target-display
interaction not required by the known BROKEN reproduction or explicitly
selected resize request makes the trial `INVALID / CONTAMINATED`; repeat from
a fresh state.

Do not execute activation recovery, key recovery, `redraw`, cursor
invalidation, tracking rebuild, ordering, or synthetic-input operations during
the same physical recovery trial. The historical activation-only and key
trials are separate evidence and are not repeated or combined here.

The trace must be compared as observed event sequences. If one requested
`setFrame` call naturally emits multiple `window-did-resize` callbacks, retain
and report every callback honestly; do not hide or normalize the sequence. A
resize API response alone is not proof that the lifecycle transition occurred.
The physical trial requires `window-did-resize` and/or resulting frame-size
evidence plus human visual HEALTHY/BROKEN observation. If neither is observed,
record `INVALID / TRANSITION NOT REALIZED`, not `STILL BROKEN`. The code must
not infer HEALTHY or BROKEN and must not infer causality from a missing event.

Resize has NOT yet been physically tested. No automated test claims cursor
recovery; human cursor observation remains authoritative. Preserve the
resulting app-active, key, main, target/panel display, visibility, and
occlusion state in the normal diagnostic records, including any natural state
changes caused by the resize.

## P0 structural cursor-mutation serialization experiment

This branch also contains a bounded production experiment for a structural
hypothesis: multiple execution contexts may previously have written Quartz
cursor position concurrently, and a suppression-generation check could be
separated from its warp by a TOCTOU window. `CursorMutationExecutor` makes the
event-tap CFRunLoop the single writer for every production
`CGWarpMouseCursorPosition` call. Hold and restore requests carry their
ownership generation; stale queued requests are rejected, and non-tap restore
coordination is synchronous with a bounded timeout. A timeout releases local
suppression and skips the restore; it never falls back to a caller-thread warp.

This is a structural hypothesis experiment, not a confirmed root cause and
not a production workaround claim. The AppKit recovery probing is paused.
The next physical test uses the existing controlled diagnostic panel and the
known cross-display activation trigger. Physical result is required before
claiming Issue #96 fixed. No physical experiment is claimed by this change.

## Interpretation

If the owned diagnostic window reproduces BROKEN, compare HEALTHY, BROKEN, and
successful-recovery traces for cursor, tracking, activation, window, and view
callback ordering. In particular, check whether mouse movement occurs without
cursor update, cursor reset, or tracking entry callbacks.

If it never reproduces BROKEN, record that negative result. The next target is
a controlled observation of a known affected real application/window rather
than additional cursor APIs or synthetic events.

## Production boundary

This change does not modify CGEventTap source/location/options, event posting,
pointer delta forwarding, suppression timeout/fail-safe policy, handoff,
Android code, CXI protocol, target routing, or Issue #97 generation/watchdog/
fail-safe behavior. It changes only the ownership and serialization boundary
around existing production pointer warps. It uses no private CGS/WindowServer
SPI, SystemUIServer/Dock restart, root, synthetic click, periodic reset,
background recovery loop, focus-stealing production workaround, or pointer
trap.
