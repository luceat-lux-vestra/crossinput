# Issue #47 Disable/Disconnect Verification Record

Status: `AUTOMATED_PENDING_PHYSICAL`

This record is scoped to the macOS lifecycle controls in issue #47. It does
not claim device completion and does not change the Level-3 release-stability
requirement.

## Lifecycle contract

- **Disable Edge Switch** returns pointer/control ownership to macOS, releases
  active suppression and held remote input, and leaves the Android
  helper/session, transport, and selected display target alive.
- **Enable Edge Switch** resumes acquisition on that same ready session.
- **Disconnect** disables Control before tearing down the helper/session. Its
  session generation is invalidated, so stale callbacks cannot restore state,
  and the intentional path does not schedule automatic reconnect.
- A later explicit Connect uses the existing endpoint discovery, handshake,
  display refresh, and target-selection policy. The current policy enables
  Edge Switch after a valid target is confirmed.

## Provenance and stability classification

| Field | Value |
|---|---|
| Issue | #47 |
| Base SHA | `a20dd712c9aa1f9c165ec4d470470b70ba8a9667` (live `main` observed before implementation) |
| Candidate SHA | Record the exact PR HEAD SHA at physical-verification time |
| ADR-0012 classification | `RESET REQUIRED` |
| Existing Level-3 credit | `0 / 100`; no credit carried forward |
| New Level-3 window | Starts at the resulting future squash-merged production commit |

The base SHA above is retained as the implementation baseline. The candidate
SHA must be recorded from the actual PR HEAD; a local branch or an anticipated
merge SHA is not evidence. This lifecycle change touches session/control
production behavior, so it resets the eligible stability window under
ADR-0012.

## Focused physical procedure

Run this procedure on the real Samsung DeX setup after building the exact
candidate SHA. Record only metadata and sanitized diagnostics; never record
key codes, typed content, clipboard contents, or raw input/HID payloads.

1. Record the exact candidate SHA, macOS version, Android device/model,
   Android version, One UI version, DeX setup, and the relevant sanitized
   diagnostics directory.
2. Connect normally and confirm the helper/session is ready and the display
   list contains the intended target. Use `adb shell dumpsys display` and the
   existing helper/app diagnostics as appropriate.
3. Cross the configured edge into remote ownership, then select **Disable Edge
   Switch**. Confirm macOS control returns immediately, the Android session
   remains alive, and another edge crossing does not reacquire Android.
4. Select **Enable Edge Switch**. Confirm edge switching works again without an
   unnecessary helper/session restart.
5. Enter remote ownership and select **Disconnect**. Confirm local control is
   immediately safe, the helper/session is torn down, and no automatic
   reconnect is caused by this intentional action.
6. Select **Connect** again. Confirm endpoint/session/helper recovery, display
   list refresh, valid target reselection, and the documented enabled edge
   state.
7. Repeat Disable and Disconnect while a key and a pointer button are held.
   Confirm both are released and no stuck input remains on Android.
8. Confirm the existing emergency-return shortcut still restores local control.
9. Cause an unexpected helper/session loss and confirm the existing
   `remoteUnavailable` recovery behavior remains unchanged.

## Evidence boundary

Unit tests and macOS builds establish lifecycle and fail-safe behavior but do
not substitute for the device procedure above. This issue requires targeted
Level-1 physical verification only; it does not require 100 manual cycles.
