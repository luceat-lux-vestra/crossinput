# Issue #96 target-display AppKit invalidation probe

Status: diagnostic-only harness, ready for independent code review. No
physical cursor result is claimed by this document.

## Purpose and opt-in boundary

This harness tests five public AppKit primitive families independently after a
human has established the deterministic `HEALTHY -> BROKEN` cursor transition.
It does not implement recovery in production and does not modify
`InputCapture`, event-source/posting behavior, pointer warping, suppression,
handoff state, the Android helper, or the CXI protocol.

The harness is disabled by default. Enable it before launching Ampersand with:

```sh
export CROSSINPUT_DIAG_TARGET_DISPLAY_INVALIDATION=1
open /path/to/Ampersand.app
```

The process creates one small CrossInput-owned `NSPanel` and custom `NSView`
before the experiment. The panel is a non-activating floating panel, does not
accept first mouse, does not intentionally become key or main, and is placed
on the one host display whose existing CrossInput edge configuration is set.
`AppModel` resolves that display from its `hostDisplays` projection and passes
only the selected display identity into the harness; the harness never reads
`AppSettings` or `InputCapture`.
It is ordered once during setup so the surface is stabilized before the
operator induces `BROKEN`; setup is not a probe command. The view owns a
native `resizeLeftRight` cursor rect and one tracking area. It does not log
pointer coordinates or accept input payloads.

The harness requires exactly one configured host display. Zero configured
displays and multiple configured displays fail closed. It does not inspect the
current pointer location and does not choose a display ID from pointer state.

## Off-target control channel

When enabled and successfully initialized, the app listens only on a local
Unix-domain socket at:

```text
~/Library/Application Support/Ampersand/Diagnostics/issue-96-target-display.sock
```

Set `CROSSINPUT_ISSUE96_PROBE_SOCKET` to the same explicit path in both the
app launch environment and the control shell when an alternate path is
needed. The socket is mode `0600`, has a backlog of four, accepts one bounded
UTF-8 command per connection, and is not a TCP/listening network endpoint.

From SSH or another off-target shell, run:

```sh
./scripts/issue96/target-display-probe.sh status
./scripts/issue96/target-display-probe.sh redraw
```

The script sends one command and prints only the bounded metadata response.
It does not click, type, move, warp, capture, record, or present anything on
the target display. The operator must not use target-display UI to invoke a
probe.

## Exact command mapping

Each command enters one dispatcher case and calls only the listed operation.
The command handler takes window/app state snapshots before and after the
operation; those getters are observation metadata and do not intentionally
change UI state.

| Command | AppKit primitive(s) | Intentional activation/focus/order |
|---|---|---|
| `redraw` | `view.needsDisplay = true`; `view.displayIfNeeded()` | No activation, key/main change, or order call |
| `cursor-rect` | `window.invalidateCursorRects(for: diagnosticView)` | No redraw, tracking rebuild, activation, key/main change, or order call |
| `tracking-area` | owned `view.removeTrackingArea(area)`; `view.addTrackingArea(newArea)` | No explicit redraw, cursor-rect invalidation, activation, key/main change, or order call |
| `window-update` | `window.orderFront(nil)` | Non-activating order/update candidate; no explicit key/main or app activation |
| `activation-control` | `NSApplication.shared.activate(ignoringOtherApps: true)`; `window.makeKeyAndOrderFront(nil)` | Intentional positive control; activation and key/main/order transition are expected |
| `status` | no AppKit primitive | Metadata only; no probe execution |

AppKit may perform internal bookkeeping as part of a public operation. In
particular, `orderFront(nil)` may cause AppKit-managed window/tracking work;
the harness does not add another explicit operation and records only the
observable before/after state. This is an experimental limitation, not a
claim that the API is internally side-effect-free.

## Logged metadata

Every probe execution logs a monotonic sequence and `DispatchTime` timestamp,
probe kind, configured target display ID, panel display ID, application active
state before/after, key-window state before/after, main-window state
before/after, exact operation description, and API success/failure. Startup
fail-closed reasons are logged for missing/ambiguous/unavailable target
selection or an unavailable control endpoint. Cursor `HEALTHY`/`BROKEN` state
is not inferred or logged; it remains human observed.

No raw pointer coordinates/deltas, key values, clipboard contents, HID
reports, screenshots, screen recordings, or input payloads are collected.

## Controlled physical procedure

After independent strict review of the exact implementation HEAD, test each
probe separately from a fresh state:

```text
HEALTHY
  -> activate/click UI on another display
  -> move back to the configured target and confirm BROKEN
  -> invoke exactly one command through SSH/off-target control
  -> move/observe on the target and record HEALTHY or still BROKEN
```

Do not click, keypress, use menus, display terminal output, screenshot, or
screen-record on the target before observing the result. Any such action makes
that trial `INVALID / CONTAMINATED`; repeat it from a fresh `HEALTHY` state.

Automated tests prove dispatch isolation, command parsing, target selection,
non-activating configuration, disabled gating, and metadata shape only. They
cannot prove rendered cursor recovery.

The activation positive control intentionally changes application/window
context. Start a fresh harness process and re-establish `HEALTHY` before
testing another primitive family; do not use a prior activation-control result
as the starting state for a later trial.
