# Issue #146 — CoreHID built-in trackpad ownership research

Status: **H1 physical split result / production feasibility FAIL until cursor-health cause is isolated**

This note supersedes the external-mouse premise of closed PR #147. The required pointing device is the MacBook built-in trackpad.

## Problem boundary

The current production host path consumes `CGEvent` pointer events and repeatedly calls `CGWarpMouseCursorPosition()` while remote ownership is active. Issue #96 standalone evidence proves that repeated edge-hold warping is sufficient to produce the BROKEN native cursor state. Previous hide/show, `CGAssociateMouseAndMouseCursorPosition(false)`, synthetic-event, focus, AppKit invalidation, and private cursor-presentation candidates did not establish a HEALTHY return baseline.

The desired boundary remains below cursor presentation:

```text
built-in trackpad
    |
    v
physical HID ownership lease
    +---- remote-owned ----> pointer input ----> DeX
    |
    X---- macOS local pointer pipeline

lease release
    |
    +---- macOS owns the native pointer pipeline again
```

No per-move cursor warp, cursor visibility lifecycle, cursor association lifecycle, or synthetic recovery action belongs in this architecture.

## Primary API evidence

Apple's current public CoreHID API exposes `HIDDeviceClient.seizeDevice()`. Apple documents the operation as making the caller the device's only active client for notifications/interactions until that client is deinitialized.

Apple's `hidutil` discovery documentation shows `Apple Internal Keyboard / Trackpad` as multiple HID components. In particular, a built-in `AppleHIDTransportHIDDevice` appears with Generic Desktop usage page `1`, usage `2` (Mouse), separately from the keyboard component at usage `6`.

Apple DTS described the intended seizure architecture in March 2026 as routing HID activity to the process instead of the system, with a virtual HID device only if replacement local events are required. Ampersand does not need replacement local pointer events while remote ownership is active.

The same DTS discussion about the built-in MacBook trackpad states that a third-party DriverKit extension cannot use the non-public `com.apple.developer.driverkit.builtin` entitlement required at minimum to match the built-in interface. DriverKit therefore remains an unattractive shipping path for this hardware.

Primary references:

- https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
- https://developer.apple.com/documentation/corehid/discoveringhiddevicesfromterminal
- https://developer.apple.com/documentation/corehid/communicatingwithhiddevices
- https://developer.apple.com/forums/thread/820066
- https://developer.apple.com/forums/thread/818441

## Capture-layer disposition

| Layer | Built-in trackpad visibility | Consume before local pointer processing | Pointer data | Supportability | Issue #146 disposition |
| --- | --- | --- | --- | --- | --- |
| AppKit / NSEvent | translated events only | no reliable physical-device ownership | translated | public | rejected as ownership boundary |
| CGEventTap HID | translated HID event stream | can consume events, but existing confinement mutates global cursor state | relative deltas available | public + Accessibility | keep for edge detection / keyboard only |
| IOHIDManager / IOHIDDevice | device-level | `kIOHIDOptionsTypeSeizeDevice` exists | device-dependent | public legacy IOKit | secondary only |
| CoreHID `HIDDeviceClient` | device-level, built-in matching works physically | **YES physically proven** | reports + X/Y activity physically proven; relative semantics still require proof | public | **capture/isolation PASS; cursor-health FAIL** |
| IOHIDEventSystemClient | event-system level | filtering/suppression contract not established | yes | private SPI | not a production candidate |
| HIDDriverKit DEXT | driver/provider level | could own matched hardware | raw reports | built-in entitlement unavailable to third parties | reject as shippable built-in-trackpad path |
| Private MultitouchSupport / private HID filters | lower/private path | potentially | raw touch | unsupported private API | contingency research only |

## Physical H1 result — exact HEAD 9eed72e

Exact tested HEAD:

`9eed72ea3b267a48adb392521facf734244ec679`

Observed probe output:

```text
PROBE_DEVICE_MATCH product=Apple_Internal_Keyboard_Trackpad built_in=true usage=generic_desktop_mouse transport=Optional(CoreHID.HIDDeviceTransport.spi) location_id_present=true descriptor_length=78 xy_element_count=2
PROBE_SEIZE_OK
PROBE_OBSERVATION input_reports=389 xy_element_notifications=778 device_removed=false externally_seized=false
```

Human physical observations on MacBook built-in trackpad:

| Gate | Result |
| --- | --- |
| D0 expected built-in Generic Desktop Mouse selected | PASS |
| D1 descriptor/X/Y surface present | PASS |
| S1 ordinary-user CoreHID seizure | PASS |
| S2 host pointer remains stationary during physical trackpad movement | **PASS** |
| S3 CoreHID receives physical movement activity during seizure | **PASS** |
| R1 local pointer control returns immediately after client lifetime ends | **PASS** |
| R2 native directional/resize cursor remains HEALTHY | **FAIL — BROKEN** |

This materially changes the root-cause boundary.

### What this proves

CoreHID seizure is a real, public, pre-local-pointer ownership boundary for the MacBook built-in trackpad. It can simultaneously:

- prevent physical trackpad movement from moving the macOS pointer;
- expose the movement to the process;
- release local pointer control immediately when the client lifetime ends.

Therefore the old statement that Ampersand must move the macOS pointer and repeatedly warp it back is false.

### What this disproves

Repeated `CGWarpMouseCursorPosition()` remains a proven sufficient trigger for BROKEN from the standalone Stage E matrix, but it is **not a necessary condition**.

This CoreHID probe never invoked:

- `CGWarpMouseCursorPosition()`;
- `CGAssociateMouseAndMouseCursorPosition()`;
- cursor hide/show;
- synthetic pointer input;
- production `InputCapture`;
- DeX delivery.

Yet post-release native cursor presentation was BROKEN.

Therefore production integration of CoreHID is blocked until the seizure/release cursor side effect is isolated.

## Phase H1.1 — isolate seizure vs monitoring

The probe now requires an explicit mode and fails closed if no mode is supplied:

```text
--mode monitor-only
--mode seize-only
--mode seize-monitor
```

Every physical trial has a mandatory precondition:

> Before starting the process, native macOS directional/resize cursor presentation must be visibly HEALTHY.

A manual recovery action may be used **before** a trial only to establish that precondition. No recovery action may occur after the trial starts until the HEALTHY/BROKEN result has been recorded.

### Trial A — monitor-only control

```bash
.build/release/trackpad-seize-probe --mode monitor-only
```

Purpose:

- construct and validate the same CoreHID client;
- monitor reports/X/Y activity;
- do **not** seize the device.

Expected behavior:

- macOS pointer continues moving normally;
- notifications are non-zero;
- post-trial native cursor remains HEALTHY.

Interpretation:

- BROKEN here means CoreHID monitoring/client activity itself is enough to perturb cursor presentation;
- HEALTHY here removes monitoring-only as the trigger.

### Trial B — seize-only

```bash
.build/release/trackpad-seize-probe --mode seize-only
```

Purpose:

- construct/validate the same client;
- seize the built-in mouse component;
- do **not** create a notification monitor after seizure;
- hold the seizure for five seconds, then end client lifetime.

During the five-second lease, move the built-in trackpad.

Expected behavior:

- host pointer remains stationary;
- local pointer resumes immediately after process exit;
- native directional/resize cursor remains HEALTHY.

Interpretation:

- BROKEN after this trial means the **exclusive ownership transition itself** is sufficient to break native cursor presentation;
- HEALTHY here, combined with the already-BROKEN seize+monitor result, points at the seized-monitoring/data path as the trigger.

### Trial C — seize-monitor reference

```bash
.build/release/trackpad-seize-probe --mode seize-monitor
```

This reproduces the original H1 shape and is not needed again unless A/B produce an ambiguous result.

## Decision table after H1.1

| Monitor-only | Seize-only | Seize+monitor | Interpretation |
| --- | --- | --- | --- |
| HEALTHY | BROKEN | BROKEN | exclusive ownership transition itself is sufficient; CoreHID seize architecture fails #96 unless Apple provides a clean ownership-return primitive |
| HEALTHY | HEALTHY | BROKEN | monitor-after-seize path is the trigger; investigate CoreHID monitoring contract/lifetime |
| BROKEN | HEALTHY | BROKEN | ordinary CoreHID monitoring/client interaction is the trigger |
| BROKEN | BROKEN | BROKEN | CoreHID client path broadly perturbs cursor presentation; reject as #96 architecture |
| HEALTHY | HEALTHY | HEALTHY | original BROKEN result had an uncontrolled precondition/contamination; repeat exact-head controlled trial |

UNKNOWN or an unverified pre-trial cursor state does not satisfy any row.

## Relative-delta semantics

The presence of X/Y elements is **not** proof that CoreHID exposes relative deltas. CoreHID's public `HIDElement` surface does not expose an `isRelative` property analogous to legacy `IOHIDElementIsRelative`.

If and only if cursor-health architecture becomes viable, the next bounded proof must establish report-descriptor relative semantics or an equivalent safe decoding contract before any production translator emits `SemanticPointerEvent.move`.

## Production architecture remains blocked

Do not integrate CoreHID into `HostSuppressionController` yet.

If a future candidate preserves HEALTHY cursor state, the target ownership model remains:

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
    +--> release(): synchronous ownership release proof

HostSuppressionController
    |
    +--> owns pointer lease + keyboard suppression for one Control generation
```

Control must never become remote until pointer ownership is confirmed. The known-broken warp backend must not be used as a silent fallback for a HEALTHY-qualified session.

## Current proof status

- public built-in-trackpad discovery: **PASS**
- ordinary-user CoreHID seizure: **PASS**
- host pointer isolation during seizure: **PASS**
- process receives physical movement activity: **PASS**
- immediate local pointer return: **PASS**
- native cursor HEALTHY after seize+monitor release: **FAIL**
- relative-delta semantics: UNVERIFIED
- production CoreHID backend: **BLOCKED**
- #146: **FAIL / blocker remains open**


## H1.1 physical result — CoreHID monitor path also breaks cursor

Physical trials were rerun from a visibly HEALTHY native directional/resize cursor state before each process start.

| Mode | Host pointer during trial | Local pointer return | Post-trial native cursor |
| --- | --- | --- | --- |
| `monitor-only` | moved normally | n/a | **BROKEN** |
| `seize-only` | stationary | immediate | **BROKEN** |

This rules out seizure as a necessary trigger and rules out the seizure+monitor combination as the sole trigger. A CoreHID notification-monitoring path without exclusive ownership is already sufficient to reproduce BROKEN on the tested machine/OS.

The H1 production architecture is therefore rejected unless a smaller CoreHID operation boundary can be found that preserves HEALTHY cursor presentation.

## H1.2 minimal-trigger isolation

The probe now exposes cumulative boundaries, each of which must begin from a visibly HEALTHY native directional/resize cursor:

1. `discovery-only` — `HIDDeviceManager.monitorNotifications` until the built-in mouse component is discovered; no `HIDDeviceClient`.
2. `client-only` — discovery plus `HIDDeviceClient(deviceReference:)`; no property reads.
3. `identity-only` — client construction plus only `primaryUsage`, `isBuiltIn`, and `product` reads.
4. `metadata-only` — identity reads plus transport, location, descriptor, and elements.
5. `monitor-only` — metadata plus device notification monitoring.
6. `seize-only` — metadata plus seizure, without device notification monitoring.

The purpose is not to rescue the existing CoreHID implementation by cursor-reset workarounds. The purpose is to identify the first public CoreHID operation that perturbs native cursor presentation and decide whether any lower-level supported capture path can avoid that boundary.

Strict decision rule:

- if `discovery-only` is BROKEN, the CoreHID manager discovery/notification path itself is disqualified for #96;
- if discovery is HEALTHY but `client-only` is BROKEN, `HIDDeviceClient` construction is the first implicated boundary;
- if client construction is HEALTHY but later cumulative modes break, the first failing mode names the smallest currently known trigger surface;
- UNKNOWN or a trial that did not begin HEALTHY is FAIL / insufficient evidence.

No production backend work proceeds until this classification is complete.
