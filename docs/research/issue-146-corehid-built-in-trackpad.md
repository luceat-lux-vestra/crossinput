# Issue #146 — CoreHID built-in trackpad ownership research

Status: **physical ownership/capture PASS; native cursor health UNVERIFIED**

This note supersedes the external-mouse premise of closed PR #147. The required pointing device is the MacBook built-in trackpad.

## Proven physical facts

On exact tested HEAD `9eed72ea3b267a48adb392521facf734244ec679`:

```text
PROBE_DEVICE_MATCH product=Apple_Internal_Keyboard_Trackpad built_in=true usage=generic_desktop_mouse transport=Optional(CoreHID.HIDDeviceTransport.spi) location_id_present=true descriptor_length=78 xy_element_count=2
PROBE_SEIZE_OK
PROBE_OBSERVATION input_reports=389 xy_element_notifications=778 device_removed=false externally_seized=false
```

The following observations remain valid:

| Gate | Result |
| --- | --- |
| built-in Generic Desktop Mouse discovery | PASS |
| descriptor/X/Y surface present | PASS |
| ordinary-user CoreHID seizure | PASS |
| physical built-in trackpad movement does not move macOS host pointer while seized | PASS |
| same movement produces CoreHID input/X-Y activity | PASS |
| local pointer control returns immediately after client lifetime ends | PASS |

These results prove that public CoreHID provides a real pre-local-pointer ownership boundary for the built-in trackpad.

## Cursor-health evidence invalidation

The previous HEALTHY/BROKEN cursor judgments were made against an **inactive window**.

That is not a valid oracle for native directional/resize cursor presentation. Inactive-window cursor behavior cannot be treated as equivalent to an active/key resizable window.

Therefore all previous cursor-health conclusions are invalidated and return to **UNVERIFIED**:

- original H1 post-release `BROKEN`;
- H1.1 `monitor-only` post-run `BROKEN`;
- H1.1 `seize-only` post-run `BROKEN`;
- all downstream claims that CoreHID monitoring, seizure, deinit, or teardown is sufficient to break native cursor presentation;
- the claim that repeated Quartz warp is not a necessary condition, insofar as that claim depended on the invalid CoreHID BROKEN observations.

The older standalone Stage E result still independently proves that repeated edge-hold `CGWarpMouseCursorPosition()` is a sufficient trigger for BROKEN. Nothing here changes that evidence.

## Correct physical oracle

Every corrected trial must use the same known **active/key resizable window**.

Recommended oracle:

1. keep the Terminal window launching the probe as the active/key window;
2. before starting each trial, verify that its left/right/bottom resize edge shows the expected directional resize cursor;
3. do not click another window, Cmd-Tab, open a menu, take a screenshot/recording, reconnect, or perform any recovery action during the trial;
4. after the process exits, keep the same Terminal window active and immediately verify the same resize edge again.

A trial where the oracle window was inactive, not key, ambiguous, or changed during the trial is **INSUFFICIENT EVIDENCE**.

## Corrected retest order

Use one exact current HEAD and rerun the original logical cases in this order:

### 1. seize-monitor

```bash
.build/release/trackpad-seize-probe --mode seize-monitor
```

Purpose: reproduce the original H1 lifecycle under a valid active/key cursor oracle.

Required observations:

- during seizure: built-in-trackpad movement does not move host cursor;
- CoreHID activity is non-zero;
- after process exit: local pointer control returns immediately;
- same active/key Terminal resize cursor is HEALTHY or BROKEN.

### 2. monitor-only

```bash
.build/release/trackpad-seize-probe --mode monitor-only
```

Purpose: determine whether non-exclusive CoreHID monitoring preserves native cursor health.

Required observations:

- host pointer moves normally;
- X/Y activity is non-zero;
- same active/key Terminal resize cursor is HEALTHY or BROKEN after the trial.

### 3. seize-only

```bash
.build/release/trackpad-seize-probe --mode seize-only
```

Purpose: determine whether exclusive ownership transition without notification monitoring preserves native cursor health.

Required observations:

- host pointer is stationary during the five-second lease;
- local pointer returns immediately after process exit;
- same active/key Terminal resize cursor is HEALTHY or BROKEN.

Only after these three corrected trials are classified may the smaller H1.2 cumulative modes be used.

## H1.2 minimal-trigger modes

Current probe also supports:

- `discovery-only`
- `client-only`
- `identity-only`
- `metadata-only`

These modes exist only to isolate a smaller trigger **if a valid active/key-window retest first reproduces BROKEN**.

Do not use H1.2 results to infer anything from the invalid inactive-window trials.

## Architecture status

CoreHID production integration remains blocked, but it is **not rejected**.

If corrected cursor-health trials are all HEALTHY, the candidate architecture becomes viable again:

```text
MacEventTap (listening)
    |
    +--> EdgeDetector
    +--> keyboard capture/suppression

CoreHIDBuiltInPointerBackend
    |
    +--> Capability: discover exact built-in mouse component
    +--> acquire(): generation-owned HIDDeviceClient + confirmed seizure
    +--> remote lease: descriptor-proven pointer decoding
    +--> release(): synchronously end monitor/client lifetime

HostSuppressionController
    |
    +--> owns pointer lease + keyboard suppression for one Control generation
```

Control must not become remote until pointer seizure is confirmed. The known-broken repeated-warp backend must not be a silent fallback for a HEALTHY-qualified session.

Relative-delta semantics remain a separate proof obligation after cursor health passes.

## Current proof status

- public built-in-trackpad discovery: **PASS**
- ordinary-user CoreHID seizure: **PASS**
- host pointer isolation during seizure: **PASS**
- process receives physical movement activity: **PASS**
- immediate local pointer return: **PASS**
- native cursor HEALTHY after corrected active/key-window trial: **UNVERIFIED**
- relative-delta semantics: **UNVERIFIED**
- production CoreHID backend: **BLOCKED**
- #146: **UNVERIFIED / blocker remains open**
