# Issue #96 — affected-display recovery surface matrix

Status: INVESTIGATION ONLY

## Objective

Distinguish whether a keyboard-driven target-application activation path can recover the BROKEN native directional-cursor state without a target-display mouse-down, or whether a real mouse-down on the affected target display is required.

This protocol adds no cursor API, input injection, event monitor, focus workaround, or production behavior. It is a human-observed decision tree over the existing standalone reproducer / issue-96 instrumentation.

## Current verified observations

- The known cross-display trigger can transition native directional cursor presentation from HEALTHY to BROKEN.
- Cross-display movement alone is normally insufficient; a real activation/click on the other display is the high-signal trigger.
- A real click/activation on an app/window on the affected target display can recover HEALTHY presentation.
- A real click in the affected target display's menu-bar region can recover HEALTHY presentation.
- Hovering the menu bar does not recover presentation.
- Finder desktop/background click recovery is currently UNVERIFIED.
- PR #127 does not fix #96. An earlier claim that PR #127 also broke real-click recovery was withdrawn after a repeat from a known HEALTHY start state; affected-target-display real-click recovery still works under that build.

## Primary one-BROKEN-state decision tree

Do not run a four-surface matrix by repeatedly destroying and recreating the cursor state. The primary question can normally be answered from one known-BROKEN state.

### Preconditions

1. Start from a visually confirmed HEALTHY native directional cursor on the affected target display.
2. Use an existing known reproduction path. Do not add or change cursor APIs for this test.
3. Trigger the known failure:
   - move to another display;
   - real-click/activate an app or window there;
   - return the pointer to the target display without clicking the target display.
4. Hover the native directional-cursor probe and visually confirm BROKEN.
5. If the cursor is not definitely BROKEN, stop. Do not classify the recovery path from a contaminated start state.

### Test 1 — keyboard activation with zero target-display mouse-down

With the pointer already back on the affected target display, switch to the target-display repro/test application using keyboard-only application switching (for example Command-Tab). Do **not** click the affected target display.

Then hover the native directional-cursor probe and record the visual result.

- `HEALTHY` => classify `KEYBOARD_ACTIVATION_PATH_SUFFICIENT` and stop.
- `BROKEN` => the keyboard activation path was insufficient to recover presentation; continue to Test 2 without recreating the BROKEN state.

The important invariant is zero target-display mouse-down between the BROKEN observation and this result. A HEALTHY result proves that a target-display mouse-down is not necessary, but does not by itself distinguish application activation from another side effect of the keyboard-switching path.

### Test 2 — mouse-down in an already-active target window

This test runs only if Test 1 remained BROKEN. The target application is now already active from Test 1.

Perform exactly one real click inside the already-active target application window, preferably in a neutral/background region that does not close, resize, drag, or invoke a command. Then hover the native directional-cursor probe again.

- `HEALTHY` => classify `REAL_MOUSEDOWN_REQUIRED_AFTER_ACTIVATION` and stop.
- `BROKEN` => the previously observed generic app/window-click recovery is not reproduced in this controlled ordering; continue only to the secondary discrimination below.

This ordering deliberately separates the keyboard-driven activation path from the real mouse-down because both activation and mouse-down normally occur together during an ordinary click on an inactive window.

## Secondary discrimination — only if Test 2 stays BROKEN

Do not run these if either primary test already recovered the cursor.

### Finder desktop/background click

Perform exactly one real click on Finder desktop/background on the affected target display and re-check the native directional cursor.

- `HEALTHY` => a normal app window is not required; a broader affected-display real click / Finder activation boundary is sufficient.
- `BROKEN` => continue to the known menu-bar control.

This case is currently UNVERIFIED and should not be assumed to recover.

### Menu-bar control

Perform exactly one real click in the affected target display's menu-bar region and re-check the native directional cursor.

- `HEALTHY` => recovery is narrower than a generic display click in this run and may involve system-UI/display cursor invalidation.
- `BROKEN` => stop and mark the run contaminated/inconsistent with the previously verified recovery behavior. Do not infer a new mechanism from that run without first re-establishing a known HEALTHY start.

## Result record

Record only the tests actually reached:

```text
START_CURSOR=HEALTHY
BROKEN_AFTER_CROSS_DISPLAY_ACTIVATION=YES
AFTER_KEYBOARD_ONLY_TARGET_APP_ACTIVATION=HEALTHY | BROKEN | NOT_RUN
AFTER_ALREADY_ACTIVE_TARGET_WINDOW_CLICK=HEALTHY | BROKEN | NOT_RUN
AFTER_TARGET_DESKTOP_CLICK=HEALTHY | BROKEN | NOT_RUN
AFTER_TARGET_MENUBAR_CLICK=HEALTHY | BROKEN | NOT_RUN
```

Stop after the first recovery-producing action. Once HEALTHY is restored, later actions no longer test the same BROKEN state.

## Interpretation

| Observation | Strongest supported conclusion |
| --- | --- |
| Keyboard-only target-app switching recovers | A target-display real mouse-down is not necessary. The keyboard activation path, or another side effect of that path, is sufficient. |
| Keyboard switching stays BROKEN; click in the now-active target window recovers | The keyboard activation path is insufficient; a real target-display mouse-down (or processing tied to that mouse-down) is required in this ordering. |
| Active-window click stays BROKEN; Finder desktop click recovers | Recovery is not a generic app-window mouse-down; Finder/display activation or desktop handling is involved. |
| Desktop stays BROKEN; menu-bar click recovers | The recovery boundary is narrower and may involve system UI / menu-bar cursor invalidation. |
| Known menu-bar control also stays BROKEN | Run is inconsistent/contaminated; re-establish a known HEALTHY baseline before drawing conclusions. |

These are classification boundaries, not root-cause proof. In particular, a recovery-producing action may indirectly invalidate state owned by WindowServer, AppKit, SystemUIServer, Finder, or another subsystem.

## Safety / scope

- Real user actions only; no synthetic clicks.
- No pointer relocation as a recovery operation.
- No cursor hide/show, custom cursor, CGAssociate experiment, or private SPI.
- No production code changes.
- No Android/helper/protocol changes.
- Preserve the fixed `investigate/issue-96-minimal-repro` evidence branch at exact `c1c8b4a776f9314a712dfa36d1958341d2421573`.
- Do not run the ADR-0012 long-cycle release test from this investigation.
