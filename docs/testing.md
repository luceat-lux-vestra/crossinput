# Ampersand Testing Guide

> On-device verification protocol. Linked to AGENTS.md hard rule 2 (no verification claim without on-device logs).
>
> ADR-0012 is authoritative for verification levels, release-stability cycle
> credit, and evidence-window reset policy. Architecture Leap #101 / ADR-0016
> may replace the concrete implementation types named by historical procedures
> below; verification follows affected behavior/responsibility, not obsolete
> class names.

## General principles

- Emulator/local test passing ≠ verification complete.
- Claims of "it works" must attach one of:
  1. On-device `dumpsys display` log
  2. ADB `logcat` excerpt (no payloads/content — hard rule 4)
  3. Video/screen capture
  4. A list of commands that reproduce the verification procedure
- Level-1 verification is targeted to the behavior changed. Do **not** impose an
  arbitrary repeated-manual-run count. Repeat a case only when an intermittent
  defect or another stated hypothesis gives the repetition count evidentiary
  value.
- >=100 real physical handoff/return cycles belong only to ADR-0012 Level 3.

## Verification levels

Verification work is classified into three levels. The level determines what
evidence a change requires; the >=100 physical-cycle criterion belongs only
to Level 3 (see [ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md)).

### Level 1 — Issue / PR acceptance

Applies to every individual issue fix and PR. Required:

- Unit/integration tests covering the affected behavior.
- CI green on the exact PR HEAD used for the acceptance decision.
- Targeted real-device verification of device-dependent behavior the change
  touched (reproduction of the original defect, then regression check).
- Human visual confirmation when machine evidence cannot observe the surface
  (e.g. pointer visibility, scroll direction on screen).

A bug-fix PR never requires repetitive manual cycles merely as ritual (and never
100 cycles). The targeted checks are scoped to what the change could plausibly
affect. If a defect is intermittent, record the reason for any chosen repetition
count and what the repetitions are intended to establish.

Docs-only design work that introduces no new runtime/device claim may satisfy
Level 1 without a fresh physical run when its issue/ADR explicitly says so; its
later runtime implementation slices still require their own device-dependent
evidence.

### Level 2 — Feature stabilization

Applies once all blocker/bug issues for a feature area are closed. Required:

- A release-candidate build from the stabilization branch.
- A representative physical smoke test of the whole feature on real hardware.
- Diagnostics readiness: logs must be able to classify every semantic failure
  mode the feature can produce, including entry/return, takeover, emergency or
  watchdog recovery, transport/session failure, bounded admission/coalescing,
  lifecycle-driven work retirement/cancellation, held-input cleanup, and
  remote-state recovery when cleanliness cannot be proved.

Concrete diagnostic event/type names may change during the Architecture Leap;
classification coverage must survive those implementation changes.

### Level 3 — Release stability

Applies to the release candidate as a whole. Required:

- At least 100 real physical completed handoff/return cycles accumulated on
  the same release-candidate lineage — naturally during real use or through
  an approved physical automation harness.
- Sufficient diagnostics to classify each anomaly. Unclassified failures or
  mixed build identities fail closed (no PASS).
- Final stability verdict is made against this record, not against per-PR
  evidence alone.

## Physical handoff cycle definition

One physical cycle is **not** a state-machine transition count. A valid
cycle is:

```text
local -> successful physical remote-control entry -> usable remote session
      -> return/local recovery
```

The target must be a real physical device. Historical evidence below uses the
SM-G977N DeX setup. Synthetic unit/state-machine/event-tap loops — e.g.
`testOneHundredEdgeHandoffCyclesStaySafe` — remain useful deterministic
regression tests but contribute zero physical cycles. See
[ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md) for cycle
counting, evidence windows, reset-sensitive responsibilities, and fail-closed
classification.

## Verification environment (historical/current evidence baseline)

| Item | Value |
|---|---|
| Device | Galaxy S10 5G (SM-G977N, beyondxks) |
| Android | 12, API 31 |
| ADB | 37.0.1, wireless debugging (mDNS TLS) |
| DeX | wired HDMI external display 1920x1080 |

This table describes the established evidence environment; it does not make a
particular model number an architecture requirement. A new device-dependent
claim records the exact hardware/software environment used for that claim.

## DeX input routing verification protocol

1. Pre-check: `adb shell dumpsys display` — DeX active (Desktop display ON, phone display DOZE)
2. After input injection, confirm pointer events via `adb shell getevent -lt` / `logcat`
3. Visual check: whether the pointer appears on the DeX screen (external monitor) and whether input reaches the phone screen
4. Run each targeted verification case sufficiently to establish the issue/claim. Repetition beyond one successful reproduction/regression run requires a stated rationale (for example, an intermittent race); there is no generic "10+ times" Level-1 rule.

### Verification items (R1)

Status: ✅ verified on device (SM-G977N) · ⏳ not yet verified. Full results in [issue #2](https://github.com/luceat-lux-vestra/crossinput/issues/2).

| # | Item | Pass criteria | Status |
|---|---|---|---|
| 1 | Relative mouse | Pointer shown on DeX screen, moves across full resolution | ✅ (movement 1:1, pointer acceleration as on a real mouse) |
| 2 | Absolute mouse | Coordinate-pointer position match | ⏳ |
| 3 | Absolute stylus | hover movement | ⏳ |
| 4 | Composite mouse (wheel) | left/right click, drag, vertical/horizontal scroll | ⏳ (click and focus change verified; drag/scroll pending) |
| 5 | Input persists after app switch | delivered to DeX screen even after focus changes | ✅ (click delivered after focus change, displayId verified) |

## Phase 2: CXI helper verification (issue #6)

Drives the current Android helper over the binary CXI v1 protocol using
`scripts/deploy-helper.sh`. Prereqs: DeX active (same setup as Phase 0),
APK buildable (`scripts/build-android-helper.sh assembleDebug`).

1. Pre-check display state: `adb shell dumpsys display` — the Desktop display must be present (do not assume any display id; AGENTS.md rule 3).
2. `scripts/deploy-helper.sh start` — build + push + launch `app_process` with FIFO stdin.
3. `scripts/deploy-helper.sh hello` — expect HELLO_ACK (type 0x8001) in `dump` output.
4. `scripts/deploy-helper.sh list` — expect DISPLAY_LIST (0x8002) containing the Desktop display.
5. `scripts/deploy-helper.sh select <desktop-id>` — expect DISPLAY_CHANGED (0x8003) echo for that display; current pre-Leap macOS selection publishes only after this response. The Leap retains the confirmation/barrier requirement through TargetLease rather than preserving that controller type.
6. Send semantic `POINTER_MOVE_REL`, `POINTER_BUTTON`, and `POINTER_SCROLL` frames — the helper returns `POINTER_RESULT` with status/accepted movement, without logging payloads. In `auto` mode the backend depends on the target: desktop-flagged sinks (DeX) are served by the system-routed UHID mouse so the visible sprite follows; non-desktop targets use explicit InputManager display targeting. On UHID failure the current dispatcher degrades to InputManager until the next `SELECT_DISPLAY`.
7. The `create-hid.bin` and `hid-report.bin` fixtures remain a separate v1 compatibility check; they are not the normal Ampersand pointer path.
8. `scripts/deploy-helper.sh dump` — inspect captured frames + helper stderr log (metadata only; hard rule 4).
9. `scripts/deploy-helper.sh stop` — SHUTDOWN frame; helper must destroy pointer and keyboard UHID devices and exit cleanly (B-07).

For deterministic pointer backend runs, start the helper with
`POINTER_BACKEND=input-manager scripts/deploy-helper.sh start`; use the
discovered display ID from `dumpsys display` when issuing `select` or `pointer`.
`POINTER_BACKEND=uhid` accepts `SELECT_DISPLAY` by activating system routing
and logs a warning that the target is ignored; it still never claims explicit
display routing in HELLO_ACK capabilities.

Issue #57 acceptance (desktop-sink pointer routing):

- After `select <desktop-id>` in auto mode, the helper log shows
  `backend=uhid ... routing=system` and the DeX pointer sprite follows
  `POINTER_MOVE_REL` (regression check: injected events previously left the
  sprite frozen at the display center).
- Four-direction scroll semantics on device, both backends
  (`POINTER_BACKEND=uhid` and `=input-manager`): CXI +vertical scrolls up,
  -vertical down, +horizontal (left contract) scrolls left, -horizontal
  right. Horizontal was previously inverted on the InputManager path.
- Send a move immediately after `select` (UHID create race): the first
  reports must reach the desktop.
- Mid-session UHID failure: current behavior attempts held-button release before
  the virtual device closes and continues through InputManager. For Leap
  implementation claims, ADR-0016/#107 additionally require proof that cleanup
  or recovery establishes trustworthy remote state; the historical best-effort
  behavior alone is not proof of cleanliness.

### Remote physical-device verification

One-shot driver for the home Mac (`scripts/verify-device-issue57.sh`,
issue #60): runs every automatable item of the #57 acceptance list against the
physically connected SM-G977N + DeX and collects evidence under
`docs/research/evidence/issue-57-device-verification/<timestamp>-<sha>/`.

Prerequisites: ADB device connected (`adb devices` shows exactly one usable
device, or set `ANDROID_SERIAL`), DeX active on the external display,
`python3`, `jq`; optional `scrcpy >= 4.1` for the DeX-display recording.
A JDK 17 is selected automatically when the default JVM is too new for the
helper build.

Invocation (SSH into the home Mac; the caller controls checkout state — the
script never mutates history):

```sh
cd <crossinput-repo>
git fetch --prune origin
git switch fix/57-uhid-desktop-pointer-routing
git pull --ff-only
REV="$(git rev-parse HEAD)"
./scripts/verify-device-issue57.sh "$REV" --with-failover
```

The driver verifies the requested revision equals the checked-out HEAD
(exact-HEAD invariant) and records the tested SHA in the evidence, so this
procedure stays valid as the branch advances. Never `reset --hard` to a
historical SHA to "re-verify" — that reproduces known-broken revisions.

Add `--with-failover` for the deterministic mid-session UHID→InputManager
scenario (needs the test-only `--fail-uhid-report=N` helper hook, which fails
the Nth UHID report write at the real error path; auto-detected in the built
APK — revisions without the hook record that item NOT_RUN instead of failing).
`--skip-video` disables the recording attempt. Exit codes: 0 pass/pending-visual,
1 automated FAIL, 2 usage/environment error, 3 precondition not met (e.g. DeX
inactive).

Automated: dynamic DeX discovery (never hardcodes the display id), AUTO backend
assertion (`backend=uhid routing=system`), immediate first-move-after-select
regression, forced-backend sessions with full pointer smoke (move, left/right/
middle click, four-direction scroll), UHID registration via `dumpsys input` +
time-bounded `getevent` on the Ampersand event node only, kernel-level scroll
sign checks (REL_WHEEL/REL_HWHEEL), deterministic failover injection, clean
shutdown, and a machine-readable summary (`result.md`). Evidence is
metadata-only (no keystrokes, clipboard, or HID payloads) and identifier-
redacted: adb serials appear as `<redacted-adb-serial>`, host home paths and
the username are masked, and only the JVM version/vendor is recorded — a
fail-closed sanitizer aborts the run if any raw identifier would persist.

Still requires human confirmation (marked MANUAL_REQUIRED, never collapsed
into PASS): visible pointer motion/appearance on the DeX screen, idle-fade
reappearance, visible scroll direction (the attached screen-recording assists
review but cursor composition is not machine-verifiable), and the complete
macOS → Android → macOS edge handoff. Handoff-policy logic stays covered by
automated macOS tests; exact test/type names may change under ADR-0016.

PASS/HOLD rules: overall is `FAIL` if any automatable assertion failed;
otherwise `AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING` while any visual item
remains open; PR #59 stays HOLD until those items are physically confirmed
per AGENTS.md rule 2.

### Keyboard compatibility verification (ADR-0007 / current CXI v1)

The following exercises the existing pre-Leap `KEY_EVENT` wire/backend behavior.
It does **not** prove the ADR-0016/#141 correlated semantic-outcome contract;
#141 requires its own exact-head positive, negative, ambiguous, timeout, late,
stale, and physical verification after implementation.

10. `scripts/deploy-helper.sh start` — helper log shows `Ampersand Keyboard` UHID device created; `adb shell "dumpsys input | grep -A2 'Ampersand Keyboard'"` shows `KEYBOARD | ALPHAKEY | EXTERNAL` classes.
11. Send one key down/up pair using the dedicated fixtures, then verify as follows (character input is only asserted after the full down/up pair):
    ```sh
    DOWN_HEX="$(xxd -p protocol/fixtures/key-event-down.bin | tr -d '\n')"
    UP_HEX="$(xxd -p protocol/fixtures/key-event-up.bin | tr -d '\n')"

    scripts/deploy-helper.sh send "$DOWN_HEX"
    scripts/deploy-helper.sh send "$UP_HEX"
    ```
    - Step 1 (`key-event-down.bin`, action 0): current helper reports the key as pressed through its backend.
    - Step 2 (`key-event-up.bin`, action 1): current helper reports the key as released through its backend.
    - After the complete down/up sequence, confirm that exactly one character was entered in the focused DeX field.
    - Confirm that no repeated input continues after the key-up report.
    - Run `scripts/deploy-helper.sh stop` and confirm that no stuck-key state remains after shutdown.
12. macOS app while captured: Cmd+Tab / Spotlight must NOT fire on the Mac (system-shortcut suppression); typing reaches the Android IME and Korean 2-set composes.

Canonical frame bytes live in `protocol/fixtures/*.bin`; `protocol/scripts/check-fixtures.mjs` keeps them in sync with `protocol/protocol.md`.

### Virtual-injection fallback verification (Status: Verified on device)

The InputManager virtual-injection fallback is implemented and was verified on
SM-G977N / Android 12 on 2026-08-10 (issue #33). A test-only backend override
exists (`--keyboard-backend=input-manager`) so the verification run selects the
fallback deterministically:

1. Force the fallback backend via the test-only override; helper log must show the fallback engaged.
2. Select a focused text field on the DeX display.
3. Send a single key down/up pair — exactly one character must appear (no repeat, no stuck key).
4. Repeat with a modifier combination (e.g. Shift+letter).
5. Confirm no repeated input after release, and that shutdown leaves no stuck key state.
6. Repeat the test with only the key-down fixture, omit the key-up fixture, and
   send SHUTDOWN; the helper must synthesize the release and the focused field
   must not repeat after shutdown.
7. Confirm `scripts/deploy-helper.sh stop` reports graceful completion only
   after the actual helper process exits; force cleanup is permitted only after
   that success decision or after a bounded timeout with preserved diagnostics.
8. Attach logcat/screen evidence; confirm the logs contain metadata only (no key codes or payloads; hard rule 4).

Verification result (2026-08-10): the forced-backend marker was present; a
single key down/up pair produced exactly one character in the focused DeX
search field; a modifier combination produced exactly one additional
character; the field was unchanged after a delayed capture; and shutdown left
no helper or stdin-feeder process running. A held-key run sent only DOWN before
SHUTDOWN; the field remained unchanged after shutdown and a delayed capture,
and the stop command returned success after graceful `app_process` exit. The
captured helper log contained backend, display, and protocol metadata only.
API-unavailable, rejected-injection, and `SecurityException` fail-safe
behavior remains covered by the Android unit tests, which passed in the same
build. Screen and ADB-pulled log evidence is preserved in
[`docs/research/evidence/inputmanager-held-key-2026-08-10/`](research/evidence/inputmanager-held-key-2026-08-10/).

This historical/current backend verification proves the behavior it observed;
it does not prove that helper teardown alone is a trustworthy remote-state
cleanliness mechanism for the Leap. #107 owns that proof/reset contract.

Launch the helper with the override (manual). Both spellings are accepted:

```sh
adb shell app_process -cp /data/local/tmp/crossinput-helper.apk / com.crossinput.helper.Main --keyboard-backend=input-manager
```

Or via deploy-helper.sh (environment variable):

```sh
KEYBOARD_BACKEND=input-manager scripts/deploy-helper.sh start
```

Before recording any result, confirm the run is actually on the forced backend —
the helper logs the active backend once at startup:

```text
[Main] keyboard backend mode=input-manager
[KeyboardBackend] keyboard backend selected backend=input-manager mode=forced
```

An unknown value makes the helper exit rather than fall back to `auto`, so a
missing `selected` line means the helper never started, not that the override
was ignored. In `auto` mode the same line reports whichever backend actually
came up (`backend=uhid` or `backend=input-manager`), and it is logged again if
the session switches after a UHID report failure.

Automated coverage (`KeyboardBackendTest.kt`, `KeyboardBackendModeTest.kt`) —
these substitute a fake injector for the hidden API, so they constrain the
selection logic only and are not a substitute for the on-device run:

- AUTO: UHID preferred; falls back on creation failure, report failure, and unmappable key codes
- Forced UHID: never falls back to virtual injection, survives report failure
- Forced InputManager: never creates or uses UHID; down/up pass through once each
- Failure paths: injection API unavailable (logged once), SecurityException contained, rejection logged
- Shutdown: held keys released with an empty report before the device is destroyed
- Logs carry metadata only — no key codes, meta state, or payloads (AGENTS.md rule 4)
- Override parsing: both `--keyboard-backend=<value>` and `--keyboard-backend <value>`; unknown/missing values fail loudly

### Verification items (Phase 2)

Status per item — ✅ verified on device (SM-G977N, 2026-08) · ⏳ not yet verified. Full results in issue [#6](https://github.com/luceat-lux-vestra/crossinput/issues/6); keyboard work in issue [#21](https://github.com/luceat-lux-vestra/crossinput/issues/21); InputManager fallback verification is recorded in [issue #33](https://github.com/luceat-lux-vestra/crossinput/issues/33).

| # | Item | Pass criteria | Status |
|---|---|---|---|
| 1 | HELLO/HELLO_ACK | HELLO_ACK with matching requestId within 2s | ✅ |
| 2 | LIST_DISPLAYS/DISPLAY_LIST | All displays reported, Desktop display present with correct size/density | ✅ |
| 3 | SELECT_DISPLAY | Unknown id → FATAL_ERROR; known id → DISPLAY_CHANGED echo | ✅ |
| 4 | CREATE_HID_DEVICE | HID_CREATED with device id; `/dev/uhid` created (log metadata) | ✅ |
| 5 | Semantic pointer path (explicit target routing) | Pointer visible + relative move/click/scroll on the selected display; helper returns accepted movement | ⏳ helper routing smoke; macOS edge/screen regression pending |
| 5b | InputManager pointer backend (`PointerDispatcher`) | Forced/auto InputManager routes movement/click/scroll to the selected display | ⏳ helper routing smoke; macOS app-path screen evidence pending |
| 6 | UHID keyboard | `Ampersand Keyboard` registered as `KEYBOARD | ALPHAKEY | EXTERNAL`; single key-down/up yields exactly one character | ✅ |
| 7 | macOS shortcut suppression | Cmd+Tab / Spotlight do not fire on the Mac while captured | ✅ |
| 8 | Korean 2-set | Hangul composes in a DeX field via Android IME | ✅ |
| 9 | SHUTDOWN | Clean exit; UHID devices destroyed; stdout flushed | ✅ |
| 10 | InputManager virtual-injection fallback | Fallback engaged (forced), single char + modifier, no repeat, no stuck keys, shutdown clean | ✅ verified on device (SM-G977N, 2026-08-10; issue #33) |

## Historical PR #42 regression matrix

The following matrix records the verification obligations from the pre-Leap
controller/pointer-backend split. It remains regression evidence and a source of
behaviors the Leap must preserve/revalidate, but it does not freeze the old
controller/type layout. New Leap PRs use their own issue-specific matrices plus
ADR-0016/ADR-0012 obligations.

| Area | Required checks | Evidence status |
|---|---|---|
| DeX pointer | selected DeX target, edge handoff, visible pointer, relative move, left/right/middle click, scroll, return to macOS | helper routing recorded; target-screen visibility and fresh app path pending |
| Phone target | phone display selection and pointer routing | pending; requires screen confirmation |
| Keyboard | key down/up, modifiers, no repeat/stuck key, Korean 2-set, Mac shortcut suppression | pending fresh regression |
| Pointer fallback | deterministic forced InputManager movement/click/scroll routing | helper smoke recorded; app/screen pending |
| Failure safety | helper kill, ADB disconnect, emergency hotkey, reconnect, held key/button cleanup, stale callback suppression | pending |
| Target lifecycle | display removal/reappearance, refresh, selected target disappearance, failed selection rollback, stale A/B response | selection/stale-response tests pass; removal/reappearance deferred to issue #17 |
| Edge stability | targeted physical handoff/return checks per change; >=100 physical cycles tracked at release level ([ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md)) | real app 100-cycle event-tap/helper record ✅ (synthetic/regression evidence, zero physical-cycle credit); release-level accumulation pending |

## Edge switching stability (Phase 5)

- Historical state-machine and real macOS event-tap/helper 100-cycle regressions
  remain useful deterministic regression tests. They are synthetic/scripted
  logic loops for evidence-credit purposes: they contribute **zero** physical
  cycles toward the Level-3 gate unless a separately approved physical
  automation harness satisfies ADR-0012's physical-cycle definition.
- Release stability is declared complete only under the Level-3 rule in
  [ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md): >=100 real
  physical handoff/return cycles accumulated on a release-candidate lineage,
  naturally or via approved physical automation — never by asking a user to
  manually bounce the pointer 100 times in one sitting.
- For each failure case, verify the current architecture's ownership/control
  diagnostics and recovery path. Do not require an obsolete class/state-machine
  log name after that implementation has been superseded.

### A/B comparison protocol (origin/main vs fix branch, issue #37 / PR #38)

Goal: prove the left-edge immediate-return defect is reproduced on `origin/main`
and not on the fix branch, under identical conditions. This is a historical
issue-specific procedure, not a generic requirement for future Leap PRs. If both
branches behave identically, the root cause is not yet found — do not claim
otherwise.

1. **Same conditions for both branches**: same Mac, same physical mouse, same
   Android device, same DeX display, same configured edge(s), same TCC grants
   (Accessibility + Input Monitoring; re-grant after every re-sign — the grant
   is per-signature), same installed bundle path, same helper APK.
2. **Clean build per branch** (no shared build cache):
   ```sh
   git worktree add /tmp/amper-ab origin/main
   cd /tmp/amper-ab/apps/macos && swift build -c release
   cp .build/release/Ampersand /Applications/Ampersand.app/Contents/MacOS/Ampersand
   codesign --force --deep --sign - /Applications/Ampersand.app
   killall Ampersand; open /Applications/Ampersand.app
   ```
   Repeat the same steps on the fix branch.
3. **Capture a real trace**: with `launchctl setenv AMPER_EDGE_DIAG 1`, reproduce
   the failing maneuver; collect the first 20–50 pointer-move event metadata
   (entry edge, event order/direction, state, and transition reason). Never put
   raw movement values or input payloads in logs (hard rule 4). If replay is
   needed, keep the raw synthetic trace in a private test fixture only.
4. **Feed the same trace to both**: run the same private trace fixture through
   the unit test on each branch and compare the state transitions. Accept:
   - origin/main: reproduces immediate return (failure)
   - fix branch: stays `remoteActive` while moving into Android; returns only past
     the boundary + hysteresis
   Identical behavior on both branches ⇒ root cause not found; stop and
   investigate before continuing.
5. **Record the transition reason** for every return. Historical diagnostics used
   `edge transition <from> -> <to> reason=<cause>` and required the left-edge
   return to be `reason=boundaryCrossed` rather than watchdog/connection/
   suppression paths. Equivalent semantic evidence is acceptable after those
   internal state/type names are replaced.

### Four-direction trace collection (top/bottom sign validation)

For each edge (left, right, top, bottom) capture metadata-only diag excerpts
covering: (1) movement toward Android, (2) movement inside Android, (3)
pull-back toward macOS, (4) reaching the boundary, (5) crossing the hysteresis
threshold, and (6) the local-return transition with reason. Validate the
direction invariant with private trace fixtures/unit assertions, not by logging
raw deltas: movement toward Android must increase the virtual position and
movement toward macOS must decrease it. The top/bottom directions were inverted
in the historical origin/main defect; replacement HandoffPolicy tests must
preserve the corrected invariant without preserving the old state-machine type.
