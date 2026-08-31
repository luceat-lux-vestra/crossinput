# Issue #96 affected-window cursor lifecycle instrumentation

## Status and provenance

This is a diagnostic-only, opt-in AppKit lifecycle instrument. It does not
implement a production cursor fix. It is intended for independent review
before any further physical testing.

Investigation base commit:

```text
e9b6ea474fffa1b0393f58f6ce3bbac74056686f
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

The diagnostic window is a CrossInput-owned non-activating floating `NSPanel`
with a minimal custom `NSView`. Its frame is normalized to the selected
screen's local coordinate space before construction, so a non-primary screen
origin is not applied twice. It is ordered and its tracking state is
stabilized before the experiment; that setup is not a probe command.

The window is not key or main by default, does not accept first mouse, and
does not intentionally activate the application. No menu or clickable probe
control is presented on the target display.

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

The in-memory trace is a deterministic FIFO ring with capacity 1,000 records.
`clear-trace` clears retained records but does not reset the monotonic sequence.
`dump-trace` is capped at 64 KiB and reports whether output was truncated.
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
mark-baseline-healthy
mark-broken-confirmed
mark-recovery-action
mark-recovered
mark-still-broken
clear-trace
dump-trace
```

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
that the new lifecycle controls execute them.

Their exact mappings remain:

| Command | AppKit primitive |
| --- | --- |
| `redraw` | `view.needsDisplay = true`; `view.displayIfNeeded()` |
| `cursor-rect` | `window.invalidateCursorRects(for: view)` |
| `tracking-area` | owned tracking-area remove/add |
| `window-update` | `window.orderFront(nil)` |
| `activation-control` | `NSApplication.activate`; `window.makeKeyAndOrderFront` |

## Physical protocol for a later controlled trial

No physical result is claimed by this implementation or its automated tests.
After independent strict review of the final implementation HEAD, each trial
must start fresh:

```text
HEALTHY
  -> off-target clear-trace
  -> off-target mark-baseline-healthy
  -> observe the native cursor in a diagnostic region
  -> move to another display
  -> activate/click a normal window on that other display
  -> return to the target display and observe the same region
  -> if BROKEN, off-target mark-broken-confirmed and dump-trace
  -> perform one explicitly selected natural recovery transition
  -> observe the same region
  -> off-target mark-recovered or mark-still-broken
  -> off-target dump-trace
```

Do not click, keypress, use menus, display terminal output, take screenshots,
or record the target display before its result is observed. A target-display
interaction not explicitly selected as the recovery transition makes the
trial `INVALID / CONTAMINATED`; repeat from a fresh state. Do not stack
recovery transitions. The activation positive control from the old harness is
not a recovery transition for this instrumentation and remains separate.

The recovery transitions to characterize later are independent trials only:

1. application inactive -> active;
2. diagnostic window non-key -> key;
3. diagnostic window occluded -> exposed;
4. natural content redraw;
5. window resize;
6. pointer leaves a native cursor region -> re-enters;
7. pointer leaves the window -> re-enters;
8. application content update without activation.

The trace must be compared as observed event sequences. The code must not
infer `HEALTHY` or `BROKEN` and must not infer causality from a missing event.

## Interpretation

If the owned diagnostic window reproduces BROKEN, compare HEALTHY, BROKEN, and
successful-recovery traces for cursor, tracking, activation, window, and view
callback ordering. In particular, check whether mouse movement occurs without
cursor update, cursor reset, or tracking entry callbacks.

If it never reproduces BROKEN, record that negative result. The next target is
a controlled observation of a known affected real application/window rather
than additional cursor APIs or synthetic events.

## Production boundary

This change does not modify `InputCapture`, CGEventTap source/location/options,
event posting, pointer warping, suppression, handoff, Android code, CXI
protocol, target routing, or Issue #97 generation/watchdog/fail-safe behavior.
It uses no private CGS/WindowServer SPI, SystemUIServer/Dock restart, root,
synthetic click, periodic reset, background recovery loop, focus-stealing
production workaround, or pointer trap.
