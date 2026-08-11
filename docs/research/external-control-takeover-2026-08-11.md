# External-Control Takeover Hotfix

Date: 2026-08-11
Issue: #43
Branch: `fix/43-external-control-takeover`

## Scope

This hotfix extends the existing `InputCapture` event tap and
`EdgeSwitchStateMachine` release path. It does not import the architecture
rebaseline from PR #42 and does not change the Android helper or CXI protocol.

## Implemented contract

While suppression is active, a source must have a valid non-system PID, must
not be CrossInput's own PID, and must match an exact configured bundle or
executable identity before it can request `externalControl` takeover. The
takeover is synchronous at the event-tap boundary:

1. suppression and the watchdog are released;
2. the cursor is shown;
3. held Android keys are flushed through the existing cleanup callback;
4. held pointer buttons are reset through the existing pointer transport;
5. the normal edge-return warp is skipped and a short edge re-arm cooldown is set;
6. the existing suppression-generation callback drives the state machine back
   to `macActive`; and
7. the original triggering CGEvent is returned to macOS.

The current `main` forwarding path is synchronous and has no queued pointer or
keyboard input, so no new queue or cancellation architecture was added.

## Source characterization status

The exact installed RustDesk application bundle identifier available during
implementation is `com.carriez.rustdesk`. This is a provider identity input,
not proof of the CGEvent source used by a live remote session.

The opt-in diagnostic probe is implemented and rate-limited. It records only:

| Field | Recorded |
|---|---|
| CGEvent type | Yes |
| event-source Unix PID | Yes |
| resolved bundle identifier | Yes |
| resolved executable/process identity | Yes |
| key code, text, clipboard, coordinates, HID payload | Never |

The live RustDesk source matrix is **NOT VERIFIED** until a GUI-capable agent
connects from another device and captures the metadata for physical local,
RustDesk, CrossInput synthetic, and other observed system/local events.

## Automated validation

The macOS test suite covers exact identity classification, physical-source
rejection, self-generated-source rejection, unknown-source rejection, mouse /
click / keyboard first-event pass-through, synchronous suppression release,
held-key cleanup, pointer-state reset, external-control phase policy, and the
no-warp release policy.

Automated tests do not prove that a real RustDesk event reaches the event tap
with the configured identity, nor do they prove cursor or DeX-screen behavior.
Those checks remain **NOT VERIFIED**.

## Physical verification handoff

Before testing, build and launch the exact hotfix HEAD with Accessibility and
Input Monitoring permissions. Set `CROSSINPUT_DIAG_EVENT_SOURCE=1` before
launching and preserve metadata-only logs. With Android selected and
CrossInput in `dexActive` / remote-owned state, perform the following from a
real RustDesk client:

- first remote mouse move;
- first remote click without a preceding move when possible;
- first remote keyboard event;
- a held Android key/button followed by takeover;
- continued RustDesk use after takeover;
- normal physical Mac-to-Android handoff and return regression.

For every case, record the exact source metadata, whether the first event
changed the macOS target, cursor visibility, whether a pointer warp occurred,
the CrossInput state, Android-side delivery, and held-input cleanup. Any item
without direct macOS/RustDesk/DeX observation is **NOT VERIFIED**.
