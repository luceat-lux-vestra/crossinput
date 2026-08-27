# Issue #70: Directional Cursor Marker Investigation

Date: 2026-08-27

## Findings

Issue #70 reports that remote ownership no longer gives the user a reliable
macOS-side entry cue. The follow-up observation is more specific: a hollow
inward-facing marker was seen at the right edge of host display `5`, while the
stored host configuration was `{1 = left}` and the diagnostic line recorded
`remote edge for host display 5 = none`. The defect is therefore a
presentation-to-display binding problem, not an Android pointer-visibility
problem tracked by #46.

The reachable repository history does not retain a separate overlay/marker
implementation. Earlier macOS app code has a menu-bar `cursorarrow.motionlines`
symbol and the capture layer hides the macOS cursor during suppression; neither
is a host-edge marker. The current application already exposes the needed
read-only inputs: `ControlState`, `EdgeSwitchStateMachine.entryEdge`, the
session projection, and the per-host-display edge catalog.

## Design

`CursorMarkerPresentationState.derive` is pure:

```text
ControlState + SessionState + entryEdge + host-display edge catalog
    -> hidden | visible(displayID, edge)
    -> click-through marker window at that display's edge
```

The marker is visible for `ready + arming(edge)` and `ready + remote`. Local,
returning, failed, disconnected, and reconnecting states derive `hidden`. The
display is selected by the unique configured host display whose edge equals the
authoritative active edge. The renderer resolves that display ID through
`NSScreen.screens` and never falls back to `NSScreen.main` or the current
pointer display. Duplicate same-edge assignments are ambiguous in the current
state model and fail closed rather than showing a wrong marker.

The marker points inward, matching the earlier cue: left edge `>`, right edge
`<`, top edge down, and bottom edge up. Its borderless `NSPanel` ignores mouse
events, cannot become key/main, and is reconciled as one owned window. State
updates close stale windows before showing a replacement; teardown is safe to
repeat. Screen-parameter changes refresh the presentation catalog and window
placement. Process termination releases the AppKit-owned marker windows with
the application.

## Lifecycle coverage

| Lifecycle | Marker result |
|---|---|
| local | hidden |
| arming + ready | one marker on configured host display and edge |
| remote + ready | one marker on configured host display and edge |
| returning / emergency return | hidden |
| remote unavailable / failure | hidden through session or control projection |
| reconnecting | hidden; a later fresh remote entry may render again |
| display reconfiguration | stale window closed or repositioned by display ID |
| teardown | all windows closed; repeated teardown is harmless |

## Verification

Automated coverage is in
`apps/macos/Tests/AppTests/CursorMarkerTests.swift`. It covers the state and
edge mapping, configured display selection, all four edges, duplicate-edge
fail-closed behavior, failure/reconnect/emergency removal, repeated cycles,
geometry, and idempotent teardown.

The current ADR-0012 Level-3 tracker remains at 21 accepted physical cycles
of 100, with window start
`dd9b1327d5b858d1a23a568b876ba46c15815eef` and main
`621e181dde427f8b6d097c93e612a91654a4575d`. Issue #70's physical visual
acceptance on SM-G977N + DeX remains pending until a human confirms the
configured host-display marker and its removal on the required return/failure
paths.

## ADR-0012 classification

**NO RESET.** This change is confined to App presentation state derivation,
AppKit marker rendering, AppModel presentation wiring, tests, and docs. It
does not alter any ADR-0012 reset-scope production semantics or CXI protocol
messages.
