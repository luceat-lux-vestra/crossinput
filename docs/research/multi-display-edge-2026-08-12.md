# Issue #45 Multi-Display Edge Regression

Date: 2026-08-12
Branch: `fix/45-target-display-edge`
Base: `f708d304586c703597ee81454a5807b1844fdebc` (`origin/main`)

## Root cause

`InputCapture.updatePosition` retained the last `NSScreen` and frame when a
pointer event location was not contained by any current screen. `detectEdge`
then evaluated that stale frame and its display-specific Android edge. A gap,
offset layout, or out-of-frame event could therefore reuse a configured edge
from a different display.

### 2026-08-13 reopened finding

The original fix still resolved `CGEvent.location` against `NSScreen.frame`.
Those values use different global coordinate systems: Quartz event locations
and `CGDisplayBounds` use a global display coordinate space whose origin is the
upper-left of the main display. AppKit `NSScreen.frame` uses a different global
coordinate convention, so mixing the two can misidentify a display or invert
vertical edge meaning. The original implementation therefore worked by
coincidence on the primary display but could not resolve the configured
Built-in Retina display in the five-display physical layout.

The 2026-08-12 physical record below is superseded for the configured-edge
success claim by the direct 2026-08-13 reproduction. The non-target stale-state
coverage remains valid. The runtime fix now resolves the display and all
handoff/return geometry with CoreGraphics APIs, matching the event coordinate
space.

## Implementation

- Resolve the display from each pointer event location and clear the current
  event display before every resolution attempt.
- Evaluate only the configured edge belonging to that resolved display.
- Treat gap and out-of-frame locations as unresolved and fail safe, allowing
  ordinary macOS pointer behavior.
- Keep the resolver value-based and deterministic so multi-display geometry is
  covered without depending on the host's current monitor arrangement.
- Preserve the existing per-display edge settings and the external-control
  takeover hotfix from `main`.
- Resolve `CGEvent.location` with `CGGetDisplaysWithPoint` and use
  `CGDisplayBounds` for edge detection, suppression holding, and return warps.

The Quartz convention is authoritative for this path:

```text
CGEvent.location / CGGetDisplaysWithPoint / CGDisplayBounds:
origin = upper-left of main display
top = minY
bottom = maxY
left = minX
right = maxX
```

`NSScreen.frame` must not be mixed into this event and warp geometry. It may
still be used by the host-display menu for presentation, but not for pointer
edge resolution or pointer holding/restoration.

## Automated verification

The macOS suite passed on this branch:

```text
swift test --quiet
79 XCTest cases passed
30 Swift Testing cases passed
```

The deterministic regression fixture covers:

- side-by-side target and non-target display edges;
- vertically offset display gaps and out-of-frame coordinates;
- transition from a configured display to a non-target display;
- transition back to a configured display; and
- single-display edge behavior.
- Quartz top/bottom semantics on a primary-like frame and the non-primary
  Built-in Retina geometry;
- shared pure pointer hold/restore coordinates for all four edges.

Repository-wide validation is recorded below as it is run.

Additional repository gates passed:

```text
swift build: PASS
./scripts/build-android-helper.sh test: PASS
node protocol/scripts/check-fixtures.mjs: PASS (15 fixtures)
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n: PASS
Android metadata-only logging guard: PASS
git diff --check: PASS
```

## Physical verification

Date: 2026-08-12
Runtime code verified: `a07e0714710b6d767bf2c22e6d1b665e960e8b33`
Observation: user-confirmed on the real macOS multi-display setup.

The host had five active displays. Display ID `1` (Built-in Retina) was the
configured Android edge display with the left edge selected; display IDs
`2`, `3`, `4`, and `5` had no Android edge configured.

Results:

- PASS — non-target display edges remained ordinary macOS navigation and did
  not hand off to Android;
- PASS — the configured display's left edge handed off to Android and returned
  to macOS normally;
- PASS — movement between displays worked in both directions;
- PASS — offset/gap boundary movement did not hand off or trap the pointer;
- PASS — repeated movement at non-target edges did not hide, hold, or later
  hand off the pointer.

The diagnostic log also recorded capture activation, dynamic target selection,
edge entry, and `boundaryCrossed` return transitions. Those metadata logs do
not replace the user's direct screen and pointer observation; both evidence
types are retained here.

## Reopened physical verification

Date: 2026-08-13
Device: SM-G977N, Android 12 / API 31
Host layout: five active macOS displays

The packaged app from this branch connected over the paired wireless ADB
transport, listed three Android displays, and dynamically selected the Desktop
display at runtime (display ID 2 in this run). `dumpsys display` recorded the
Desktop as a 1920 x 1080 virtual display in state ON; this numeric ID is
observational and is not assumed by the app.

The configured host display was the non-primary Built-in Retina display
(CoreGraphics display ID 1) with its left edge selected. Its geometry in the
physical layout demonstrated the coordinate mismatch directly:

```text
NSScreen frame:       x=909, y=-1586, width=2454, height=1586
CGDisplayBounds:      x=909, y=2160,  width=2454, height=1586
```

Before the fix, the user directly confirmed that the pointer did not hand off
at that edge. After resolving the event against `CGDisplayBounds`, the user
directly confirmed that the same edge handed off successfully. Metadata-only
diagnostics recorded `localActive -> edgeArmed -> remoteActive`, balanced
cursor hide/show, and `boundaryCrossed` return transitions.

The Android pointer sprite was not visible during this successful routing
test. That observation remains tracked by issue #46 and is not claimed as
fixed by this coordinate-space correction.

The 2026-08-13 physical smoke test covered the configured Built-in Retina
left edge and Android-to-macOS return. Top/bottom physical edge smoke tests
were not performed in that run; they remain an automated geometry regression,
not a physical PASS claim.

## Cursor visibility follow-up

The same physical run exposed a separate macOS cursor fail-safe defect: the
diagnostic line `cursor shown (balanced)` did not guarantee that the cursor was
visible after emergency return when handoff began on a non-primary display.
The rebaseline had reduced the public CoreGraphics calls to
`CGMainDisplayID()` only, although cursor hide/show is display-scoped. The
follow-up keeps the current resolved display and the main display symmetric,
with a unique display list when they are the same. This does not claim to fix
the Android/DeX pointer sprite or its idle behavior; those remain issue #46.
The cursor-display fix was covered by deterministic tests and a release build,
but its post-emergency-return visibility was not re-verified physically after
the latest code change because the app was intentionally left stopped.
