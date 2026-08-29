# Issue #97 Return-to-macOS Input Ownership Investigation

Status: `AUTOMATED_PASS_PHYSICAL_REQUIRED`

This record is scoped to the return-path ownership defect in issue #97. It
does not investigate native directional cursor presentation (#96) or
permissions/onboarding (#99).

## Classification

Classification: **B — ownership is local, but stale routing survives at the
capture boundary.**

The existing lifecycle already restores the state machine to `localActive` and
releases `InputCapture` suppression on a normal return. The defect was a race
inside an already-running macOS event-tap callback:

1. The callback observed suppression as active in generation A.
2. A return released suppression and a later handoff started generation B.
3. The callback read the mutable current generation only when emitting its
   event, so an event that began in A could be labelled B.
4. `ControlHandoffController` correctly accepted B-labelled events, and
   `InputSender` correctly delivered them for the current session. The stale
   event therefore bypassed the existing controller/sender generation guards.

This is not inferred from cursor position. A deterministic test on the
pre-fix behavior paused the callback between suppression admission and event
emission, completed return and re-entry, and observed the old event relabelled
from generation `1` to generation `2`.

## Root cause and fix

`InputCapture` now snapshots `isSuppressing` and `suppressionGeneration`
together under `stateLock` at event entry. Pointer and keyboard emissions use
that captured generation. The pointer edge-hold operation also verifies that
the captured generation is still active before warping, so a callback cannot
re-hold the pointer after local ownership has been restored.

The existing `ControlHandoffController` admission guard remains the lifecycle
owner for forwarding. An event from an older suppression generation is
rejected, while the existing control epoch and `InputSender` pointer/session
generation barriers continue to reject stale completions and queued work.
No delay, cursor-visibility bookkeeping, Android routing change, or session
restart was added.

## Invariants checked

- normal return reaches `localActive`;
- suppression is false after local ownership is established;
- new mouse and keyboard events pass through to macOS and are not queued for
  the remote session;
- an event already in the old capture epoch cannot be forwarded after
  return/re-entry;
- stale pointer completions remain cancelled and cannot mutate the new handoff
  position;
- held-key and held-button cleanup remains owned by the existing fail-safe
  lifecycle paths;
- repeated handoff/return cycles do not accumulate generation leakage;
- emergency return, watchdog, remote-unavailable, Disable Edge Switch, and
  Disconnect paths remain covered by the existing tests.

## Automated evidence

The focused regression coverage includes:

- direct `InputCapture` generation retention across return and re-entry;
- controller-integrated stale pointer capture rejection;
- controller-integrated stale keyboard capture rejection;
- five deterministic handoff/return cycles asserting local pass-through and
  zero remote requests after each return;
- the pre-existing stale in-flight completion, stale re-entry, held-input,
  emergency, watchdog, remote-unavailable, Disable, and Disconnect tests.

The pre-fix mutation of `InputCapture` back to reading the current generation
at emit time fails the direct generation-retention test with observed
generation `2` instead of expected generation `1`. The snapshot implementation
passes it.

## Physical verification procedure

Physical acceptance remains required on the Mac plus Samsung DeX setup. The
procedure must use the exact candidate commit and must retain the diagnostics
and screen evidence; visible cursor position alone is not an ownership result.

1. In a clean checkout, record:

   ```sh
   git rev-parse HEAD
   git status --porcelain
   ./scripts/package-macos.sh release
   shasum -a 256 dist/Ampersand.app/Contents/MacOS/Ampersand
   ```

   The recorded `git rev-parse HEAD` is the candidate SHA. Do not use an
   anticipated merge SHA. Re-signing or rebuilding a dirty tree is not a
   candidate evidence build.

2. Launch the exact `dist/Ampersand.app`, connect to the real SM-G977N DeX
   setup, and preserve a sanitized copy of:

   ```sh
   adb shell dumpsys display
   tail -F "$HOME/Library/Logs/Ampersand/diag.log"
   ```

   The diagnostics must contain metadata only. Do not record key contents,
   typed text, clipboard data, or raw pointer/HID payloads.

3. Before entry, record the candidate identity marker and the current control
   state as local. Cross the configured host edge and verify the diagnostics
   show `localActive -> edgeArmed -> remoteActive`, followed by a suppression
   start with its generation. Confirm the DeX session is usable using the
   existing device-side helper/session evidence.

4. Pull the pointer back across the same edge until the normal return occurs.
   The evidence must show `remoteActive -> returning -> localActive` and a
   matching suppression release. Record the suppression generation and the
   exact return reason. `selectedTarget` may still be DeX; that selection is
   not ownership evidence.

5. After the apparent return, generate a **new** mouse movement away from the
   configured edge while a macOS application is the visible local target.
   Confirm the movement is visible on macOS and that the helper/device log has
   no new pointer delivery for it. Then generate a **new** keyboard event in a
   local macOS text target and confirm it reaches macOS; do not place the
   typed content in logs or evidence.

6. Repeat the same check after several handoff/return cycles. Also exercise
   emergency return and an intentional Disable Edge Switch. For Disconnect,
   confirm local ownership before the helper is torn down and confirm a later
   explicit Connect starts a new session normally.

7. Classify each attempt:

   - **A:** state remains `remoteActive` or suppression remains true after the
     apparent return;
   - **B:** state is local and suppression is false, but a new event reaches
     DeX;
   - **C:** state and suppression disagree, or a stale event/cleanup callback
     mutates the current epoch;
   - **D:** state is local, suppression is false, and new input remains on
     macOS while only the selected DeX target persists.

Do not report physical PASS until the user has performed this procedure and
provided the state/suppression/generation evidence plus the mouse and keyboard
routing result. This issue requires targeted Level-1 physical verification;
it does not start or claim the ADR-0012 100-cycle release window.

## ADR-0012 impact

`RESET REQUIRED`. This changes production `InputCapture` handoff semantics and
therefore invalidates prior physical-cycle lineage for release-stability
accounting. The new eligible window begins only at the resulting production
commit after independent review/merge. No existing or synthetic cycles are
credited here, and no 100-cycle window is started by this issue.

