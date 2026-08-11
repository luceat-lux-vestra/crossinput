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

## Automated verification

The macOS suite passed on this branch:

```text
swift test --quiet
101 XCTest cases passed
28 Swift Testing cases passed
```

The deterministic regression fixture covers:

- side-by-side target and non-target display edges;
- vertically offset display gaps and out-of-frame coordinates;
- transition from a configured display to a non-target display;
- transition back to a configured display; and
- single-display edge behavior.

Repository-wide validation is recorded below as it is run.

Additional repository gates passed:

```text
swift build: PASS
./scripts/build-android-helper.sh test: PASS
node protocol/scripts/check-fixtures.mjs: PASS (14 fixtures)
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
