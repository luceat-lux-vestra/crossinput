# Issue #96 — SystemUIServer recovery investigation

Status: READY_FOR_REVIEW

This document describes an investigation-only harness. It does not change
CrossInput production behavior, install a cursor or input workaround, or
classify a rendered cursor automatically.

## 1. Objective

Measure externally observable macOS state across the confirmed transition:

```text
BROKEN native directional cursor
  -> human-issued `killall SystemUIServer`
  -> HEALTHY native directional cursor
```

The investigation asks whether a repeatable public state change accompanies
SystemUIServer recreation: HID/pointing-device topology, event-system or
service registration, WindowServer-facing observations, cursor/tracking logs,
display topology, workspace/application activation, accessibility state, or
SystemUIServer service state. A recurring transition may narrow the root-cause
boundary and suggest a later public-API experiment; it is not itself a fix.

The rendered native cursor remains human-observed because public cursor APIs do
not reliably expose the WindowServer-composited cursor shape.

## 2. Confirmed recovery observation

Issue #96 currently records repeated real macOS + Samsung DeX observations in
which the native directional cursor becomes an ordinary-arrow BROKEN state and
`killall SystemUIServer` restores HEALTHY presentation. The restart is a
timing/reset anchor only. **SystemUIServer restart recovering the cursor does
not prove that SystemUIServer owns the defective state.** The reset may
indirectly recreate or invalidate state owned by WindowServer, HID
infrastructure, AppKit, a system-UI connection, or another subsystem.

Earlier cursor-control and event-tap variants are not repeated by this task.
The physical cursor state is recorded by the operator's `healthy`, `broken`,
and `recovered` markers; the harness never tries to recognize the cursor image.

## 3. Harness architecture

The bounded harness lives under `scripts/issue96/`:

| Component | Responsibility | Mutation policy |
|---|---|---|
| `capture.sh` | Start/stop three bounded observers and create a run directory | No UI or input action |
| `mark.sh` | Append one high-resolution human state marker | Timestamp/process metadata only |
| `snapshot.sh` | Capture one labeled read-only state snapshot | No cursor, focus, or input change |
| `lifecycle_monitor.py` | Poll `SystemUIServer` PID at 0.5 Hz | Process observation only |
| `unified_capture.py` | Run a restricted `log stream` predicate and scrub selected records | No raw reports or input payloads written |
| `workspace_observer.swift` | Observe selected public `NSWorkspace` notifications | No event monitor or focus change |
| `state_snapshot.swift` | Read public CoreGraphics display, NSWorkspace, and accessibility state | No cursor API call |
| `crossinput_identity.swift` | Resolve the running Ampersand bundle/process identity once at capture start | One-shot metadata lookup only |
| `analyze.py` | Normalize, group, rank, and compare evidence | Offline transformation only |

Each run contains `run.json`, `crossinput-build-identity.json`,
`markers.jsonl`, `raw/`, a run-scoped `bin/`, and labeled snapshot directories.
The default evidence root is outside the repository:
`~/Library/Logs/CrossInput/issue96`. Set `ISSUE96_RUNS_DIR` consistently for
all commands if another local evidence root is preferred.

`capture.sh start` compiles the three Swift helpers into that run's `bin/`
directory before any HEALTHY marker can be recorded. It records helper hashes,
the harness checkout SHA, and the actual running CrossInput executable's
SHA-256 in `run.json`; the compiled helpers are never installed globally. They
remain alongside the preserved run evidence for manual archival/cleanup after
analysis, and no helper process is left after `capture.sh stop`.

The selected unified log is retained as `raw/unified.jsonl`, but it is not a
byte-for-byte dump of the system log. Only allowlisted metadata fields and a
payload-scrubbed state message are written. This preserves raw selected
evidence for analysis while honoring the repository rule that input payloads
must never be logged.

The unified stream has a one-hour default ceiling (`ISSUE96_MAX_CAPTURE_SECONDS`)
so a forgotten capture cannot run without bound. A run that reaches that
ceiling is marked incomplete; increase the ceiling only deliberately for a
longer bounded observation.

## 4. Commands

Run from this investigation worktree:

```sh
./scripts/issue96/capture.sh start run-001
./scripts/issue96/mark.sh healthy
./scripts/issue96/snapshot.sh healthy

# use CrossInput normally until the human observes the native cursor failure
./scripts/issue96/mark.sh broken
./scripts/issue96/snapshot.sh broken

# Human action, issued explicitly in another terminal:
killall SystemUIServer

# Wait for the lifecycle observer to record old PID exit and new PID launch.
# Visually confirm that the native directional cursor is HEALTHY.
./scripts/issue96/mark.sh recovered
./scripts/issue96/snapshot.sh recovered

./scripts/issue96/capture.sh stop
./scripts/issue96/analyze.py "$HOME/Library/Logs/CrossInput/issue96/run-001"
```

The first `healthy` snapshot is intentional: it makes the comparison
three-state (`HEALTHY`, `BROKEN`, `RECOVERED`) rather than relying on a marker
alone. The restart command is never run by the harness.

For repeated runs, use a new ID and reset only through the explicitly observed
manual command when needed:

```sh
./scripts/issue96/capture.sh start run-002
# ... same procedure ...
./scripts/issue96/analyze.py \
  "$HOME/Library/Logs/CrossInput/issue96/run-001" \
  "$HOME/Library/Logs/CrossInput/issue96/run-002" \
  --output "$HOME/Library/Logs/CrossInput/issue96/issue96-comparison.md"
```

`capture.sh start` fails unless exactly one running Ampersand application can
be resolved through public `NSWorkspace` metadata. It records bundle ID,
short version, bundle/executable paths, process ID, and the SHA-256 of the
running executable. The executable SHA-256 is the authoritative same-binary
key. Candidate/source SHA and build-identifier fields are retained only when
explicitly exposed as bundle metadata; otherwise they are `unknown`. The
helper never scans arbitrary executable bytes for a candidate SHA and never
replaces an unavailable source SHA with the harness SHA.

`capture.sh stop` validates the stored command lines before sending TERM and
uses a five-second bounded cleanup. A validated capture process is KILLed only
after that timeout, and the stop log plus `run.json.shutdown` record the forced
cleanup. A run is complete only when `state` is `stopped`, shutdown was
requested and clean, and `forced_kill` is false. A stale active-run marker is
not silently overwritten.

## 5. Captured evidence sources

### Unified logging

`unified_capture.py` starts an unprivileged `log stream --style json
--level info` with a predicate limited to `SystemUIServer`, `WindowServer`,
`hidd`, `Dock`, `loginwindow`, `Finder`, and `Ampersand`. Within those
processes it selects state-oriented terms such as cursor, tracking, display,
event system, client, service, registration, activation, and menu.

Records containing key codes, keyboard/keystroke terms, clipboard terms, HID
reports/descriptors, deltas, coordinates, scroll payloads, buttons, Unicode,
or generic payload terms are omitted before disk. `raw/unified-capture-errors.log`
records only bounded error categories, not discarded source text.

The raw selected log and its stderr/error sidecar remain separate from the
semantic report. Empty or malformed selected logs make analysis
`INCOMPLETE`.

### Process lifecycle

`lifecycle_monitor.py` records the initial SystemUIServer PID, each observed
exit, and each new PID at 0.5-second intervals. It records only timestamp,
PID timing anchor, parent PID, and executable command. The analyzer accepts
only one transition satisfying all of these bindings:

```text
BROKEN marker PID == observed old-PID exit
BROKEN timestamp <= exit <= RECOVERED timestamp
exit < new-PID launch <= RECOVERED timestamp
RECOVERED marker PID == observed new-PID launch
old PID != new PID
```

Unrelated pre-BROKEN restarts, marker PID mismatches, missing marker PIDs,
same-only marker PIDs, and multiple candidate pairs are `INCOMPLETE`. PIDs are
not treated as root-cause evidence; they delimit and authenticate the restart
interval.

The analyzer also uses the public workspace notification stream to check
CrossInput continuity. A termination of the initial CrossInput PID/bundle, or
a relaunch of the same bundle with a different PID, between HEALTHY and
RECOVERED contaminates the experiment and makes the run `INCOMPLETE`.

### IORegistry/HID

`snapshot.sh` captures. Every command writes a manifest entry with `status`
and an evidence state of `present` or `not_available`. A successful command
that produces zero bytes is a failed contract, not a valid empty observation.
For a public source that exposes no matching object, the command writes an
explicit JSON sentinel such as `{"evidence":"not_available","reason":"..."}`.
Malformed sentinels, empty required files, missing files, and manifest/file
disagreement fail analysis closed.

The sources are:

- an opt-in `hidutil list` (never `hidutil dump`); by default its file records
  an explicit `not_available` sentinel to avoid creating an extra event-system
  client;
- allowlisted `ioreg` properties from `IOHIDDevice`, `IOHIDEventSystem`, and
  `IOHIDEventSystemClient`, and `IOHIDEventService`.

If a specific run needs the additional `hidutil` view, enable it explicitly
for every snapshot in that run:

```sh
ISSUE96_INCLUDE_HIDUTIL=1 ./scripts/issue96/snapshot.sh broken
```

On the preparation Mac, this command caused a short-lived
`IOHIDEventSystemConnection` create/remove pair in the captured unified log.
That observed observer effect is why the default path uses the IOKit registry
allowlist and why an opt-in run must record the setting in its notes.

The allowlist is limited to product/vendor identity, transport, location,
usage page/usage, built-in/virtual flags, and registry entry identity. Report
descriptors, raw reports, deltas, button state, and key data are not written.
This is sufficient to compare physical-mouse versus Karabiner virtual-device
topology when the platform exposes it. The harness does not modify Karabiner
configuration and does not assume Karabiner is causal.

### Display/workspace/accessibility

`state_snapshot.swift` uses public APIs to record active display IDs, online and
built-in flags, global bounds, pixel dimensions, main-display status, the
frontmost application's PID/bundle/name and active flag, and
`AXIsProcessTrusted()`. It does not enumerate window titles or document data.

`workspace_observer.swift` records selected public `NSWorkspace` notifications:
application activate/deactivate/launch/terminate and active-space changes,
with only application identity metadata. It installs no mouse/keyboard
monitor.

If present, the snapshot also retains a bounded filter of the existing
CrossInput `~/Library/Logs/Ampersand/diag.log` metadata lines. This is an
observation of existing telemetry; `InputCapture.swift` is unchanged and the
harness does not require a new production diagnostic flag.

`NSCursor.current` and `NSCursor.currentSystem` are not used as a rendered
cursor classifier. Any existing CrossInput cursor telemetry remains supporting
metadata only.

### SystemUIServer service state

The snapshot reads a small allowlisted subset of
`launchctl print gui/<uid>/com.apple.SystemUIServer`: state, PID, program/path,
active-count, last-exit, and service-name lines. It does not inspect or alter
service configuration.

## 6. Known limitations

- The harness cannot observe the WindowServer-composited cursor shape. Human
  confirmation is mandatory for all three state labels.
- Unified logging is restricted and may contain no relevant record even when
  the visual transition occurred. That is reported as `INCOMPLETE`, not as
  evidence that no state changed.
- IOKit registry tools expose services/devices, not every event-system client
  or private WindowServer state. A stable physical/virtual topology does not
  exclude private client state changes.
- PIDs, launch timing, and process recreation are correlation anchors only.
- The executable SHA-256 proves that two captures observed the same executable
  bytes; it does not identify the source commit or prove that the process was
  built from a particular checkout.
- `NSWorkspace` notifications are observer-process notifications and are not a
  complete dump of AppKit cursor tracking or private system UI registration.
- CrossInput continuity validation is limited to termination/relaunch events
  exposed to the public `NSWorkspace` notification center. Missing or delayed
  notifications cannot prove continuous execution.
- A successful public API call, an `NSCursor` fingerprint, or a snapshot delta
  cannot establish what was actually rendered on screen.
- The commands require a real macOS host with the listed tools and an
  unprivileged user context. No root or sudo step is part of the procedure.
- Physical runs must begin from a known HEALTHY state. A run begun after an
  unknown prior state cannot support a candidate-prevention conclusion.

## 7. Perturbation controls

The harness deliberately does not:

- poll mouse position or install a high-frequency mouse observer;
- create one task per input event;
- screen-record, screenshot, or use ScreenCaptureKit/QuickTime;
- synthesize clicks/moves, open menus, steal focus, or restart
  SystemUIServer automatically;
- hide/show or reset the cursor, warp the pointer, associate/disassociate the
  mouse, alter event-tap behavior, or seize a HID device;
- use private CGS/WindowServer SPI;
- read or write key codes, clipboard content, mouse movement payloads, raw HID
  reports, or typed data;
- modify Karabiner configuration or CrossInput production code.

The only recurring observer is the 0.5 Hz SystemUIServer PID poll. The
workspace observer receives public notifications; it does not monitor input.
Snapshots are explicitly human-triggered and bounded.

## 8. Physical execution procedure

1. Check out this exact investigation branch on the target Mac. Start the
   actual Ampersand/CrossInput build that will be tested before capture; start
   fails closed if its running bundle identity cannot be resolved. Verify
   `harness_source_sha` and `crossinput_build_identity` in `run.json` after
   `capture.sh start`.
2. Confirm the normal CrossInput + Samsung DeX setup and that the directional
   cursor is visually HEALTHY.
3. Start capture, mark HEALTHY, and take the healthy snapshot.
4. Use CrossInput normally. Do not perform recovery clicks, restarts, or
   native screen capture while waiting for the first failure.
5. When the human sees the ordinary-arrow BROKEN state, mark BROKEN and take
   the bounded broken snapshot without changing the state.
6. In a separate terminal, issue exactly `killall SystemUIServer`. Do not run
   that command through the harness.
7. Wait for lifecycle evidence of old PID exit/new PID launch. Confirm the
   native directional cursor is visually HEALTHY, then mark RECOVERED and take
   the recovered snapshot.
8. Stop capture and run the analyzer. Preserve the entire run directory,
   including raw selected logs, error sidecars, shutdown metadata, build
   identity, and helper hashes.
9. Repeat with `run-002` and `run-003` when the physical setup permits. Do not
   combine different application builds or unknown starting states in one
   run.

The operator may add a separate written observation, such as the cursor
direction and whether the transition was immediate, but must not add cursor
pixels or screen recordings through this harness.

## 9. Analysis methodology

`analyze.py` fails closed on missing/malformed run metadata, duplicate or
misordered markers, missing labeled snapshots, failed required snapshot
commands, empty or malformed evidence, malformed JSONL, empty selected unified
logs, missing required snapshot files, an unclean/unrecorded capture stop, an
unresolved or hashless CrossInput identity, CrossInput process termination or
relaunch during the experiment, or an unobserved marker-bound SystemUIServer
exit/new-PID launch pair. It does not treat the harness checkout SHA as the
CrossInput build identity.

For each snapshot it:

1. removes timestamps, PIDs, UUIDs, process timing, transient client/
   connection/session identifiers, and other explicitly volatile fields;
2. flattens JSON in sorted-key order and treats arrays as unordered records;
3. normalizes safe text lines and removes bare `ps` PID columns;
4. groups stable records into HID/pointing, cursor/tracking, WindowServer,
   SystemUIServer, display, workspace/activation, accessibility, or other;
5. reports semantic additions/removals for `HEALTHY -> BROKEN` and
   `BROKEN -> RECOVERED` rather than a raw text diff;
6. reports bounded non-noise unified-log observations in the marker/restart
   window.

The per-run report uses `MEDIUM` for a relevant log message close to the
restart and `LOW` for a relevant message outside that interval. PID/process
launch noise is `NOISE`. A multi-run exact normalized intersection is the only
finding promoted to `HIGH`; even then it is a recurring candidate boundary,
not ownership or root-cause proof.

The comparison command computes only when every run is `COMPLETE`, all harness
worktrees are known clean, the evidence modes match (including the opt-in
`hidutil` flag), and the resolved CrossInput identities match on bundle ID,
version/build, paths, and executable SHA-256. Unknown or different app
identities cannot receive a `HIGH` recurring finding. A missing executable
SHA-256 is unresolved for repeated-run purposes. A different harness SHA is
rejected. The structured comparison status is also the CLI exit status:
`COMPLETE` returns 0 and `INCOMPLETE` returns 3.

The optional source SHA and build-identifier fields remain visible in the
report as secondary metadata; they are not substituted for, or allowed to
override, the executable SHA-256 same-binary key.

The comparison command computes:

```text
meaningful_delta(run-001)
  ∩ meaningful_delta(run-002)
  ∩ meaningful_delta(run-003)
```

Run IDs must be distinct. A report with incomplete input remains
`INCOMPLETE`; it never presents a partial comparison as complete.

## 10. Interpretation rules

### Outcome A — public observable recovery transition

If the same public notification or stable service/client transition appears
close to recovery in at least two or three complete runs, report it as a
recurring candidate and propose one minimal follow-up public-API experiment.
Do not implement that action in this investigation branch.

### Outcome B — HID/event-system recreation correlation

If physical/virtual HID topology or exposed event-service registration changes
consistently across recovery, report that as a boundary toward HID/event
routing/cursor presentation interaction. Do not infer private ownership and do
not jump to IOHID seize or privileged integration.

### Outcome C — only opaque/private state is implicated

If public logs, registry snapshots, workspace observations, and service state
show no stable meaningful delta beyond process restart, report exactly:

```text
No supported externally observable state transition explains recovery.
```

This strengthens the case that the reset is inside private SystemUIServer,
WindowServer, or another opaque subsystem. It does not justify private SPI.
The next architectural discussion may consider avoiding reliance on the
unreliable native presentation state, including device-level capture
feasibility, as a separate approved investigation.

Across all outcomes, SystemUIServer restart recovering the cursor does not
prove that SystemUIServer owns the defective state.

## 11. Result template

Copy this into the issue after each physical run, filling only from preserved
evidence and direct human observation:

```text
Run: run-___
Branch: ___
Harness source SHA: ___
CrossInput build identity: ___
CrossInput executable SHA-256: ___
Host macOS/build: ___
Device/setup: ___

Human cursor observation:
- HEALTHY: ___
- BROKEN: ___
- RECOVERED after explicit SystemUIServer restart: ___

Lifecycle anchor:
- BROKEN marker PID: ___
- old SystemUIServer PID / exit time: ___
- RECOVERED marker PID: ___
- new SystemUIServer PID / launch time: ___
- restart binding: VALID / INCOMPLETE

Capture shutdown:
- state: stopped / ___
- clean: true / false
- forced_kill: false / true

CrossInput continuity:
- initial PID / bundle: ___
- continuity: VALID / INCOMPLETE

Evidence contract:
- required sources: present / not_available / INCOMPLETE
- evidence mode (`hidutil`): ___

Semantic deltas:
- HEALTHY -> BROKEN: ___
- BROKEN -> RECOVERED: ___

Recurring candidate across runs: HIGH / MEDIUM / LOW / NONE
Evidence paths retained: ___
Analyzer status: COMPLETE / INCOMPLETE
Interpretation: observation only; no root-cause claim unless repeated evidence supports it.
```

## 12. Prohibited conclusions

Do not conclude any of the following from this harness alone:

- that SystemUIServer owns the defective cursor state;
- that a changed PID, process launch, log line, notification, or registry ID is
  causal merely because it follows `killall`;
- that `NSCursor.current` or `NSCursor.currentSystem` identifies the cursor
  rendered by WindowServer;
- that stable HID topology proves no HID/event-system/client state changed;
- that a public notification is a safe recovery API;
- that a private CGS/WindowServer or IOHID-seize mechanism is justified;
- that local tests, a successful command, or a report without human visual
  evidence proves cursor recovery;
- that this investigation changed or fixed CrossInput input behavior.

No production workaround, production PR, cursor reset, input-routing change,
or ADR-0012 release-stability claim belongs in this task.
