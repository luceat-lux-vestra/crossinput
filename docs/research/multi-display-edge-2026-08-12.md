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

NOT VERIFIED — the CLI cannot observe the actual macOS multi-display pointer
or GUI behavior. The following require a GUI-capable agent or user observation:

- non-target display left/right/upper/lower edges do not hand off;
- configured target display edge hands off normally;
- cross-display movement in both directions remains ordinary navigation;
- gaps and vertically offset boundaries do not trap the pointer or hand off;
- no repeated movement eventually triggers Android from a non-target edge.
