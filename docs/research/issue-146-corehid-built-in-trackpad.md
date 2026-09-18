# Issue #146 — CoreHID built-in trackpad ownership research

Status: **physical ownership/capture/cursor-health PASS; relative semantics UNVERIFIED**

This note supersedes the external-mouse premise of closed PR #147. The required pointing device is the MacBook built-in trackpad.

## Proven physical facts

The CoreHID probe has physically established all ownership and native-cursor-health gates on the built-in trackpad.

Original capture evidence on exact tested HEAD `9eed72ea3b267a48adb392521facf734244ec679`:

```text
PROBE_DEVICE_MATCH product=Apple_Internal_Keyboard_Trackpad built_in=true usage=generic_desktop_mouse transport=Optional(CoreHID.HIDDeviceTransport.spi) location_id_present=true descriptor_length=78 xy_element_count=2
PROBE_SEIZE_OK
PROBE_OBSERVATION input_reports=389 xy_element_notifications=778 device_removed=false externally_seized=false
```

Corrected cursor-health retest used the same active/key resizable Terminal window as the oracle.

| Gate | Result |
| --- | --- |
| built-in Generic Desktop Mouse discovery | PASS |
| descriptor/X/Y surface present | PASS |
| ordinary-user CoreHID seizure | PASS |
| physical trackpad movement does not move the macOS host pointer while seized | PASS |
| the same physical movement produces CoreHID input/X-Y activity | PASS |
| local pointer control returns immediately after client lifetime ends | PASS |
| `seize-monitor` native directional/resize cursor after return | **HEALTHY / PASS** |
| `monitor-only` live and post-exit native directional/resize cursor | **HEALTHY / PASS** |
| `seize-only` native directional/resize cursor after return | **HEALTHY / PASS** |

The earlier BROKEN observations were invalid false negatives caused by using an inactive window as the resize-cursor oracle. They must not be used in root-cause analysis.

The older standalone Stage E evidence remains independently valid: repeated edge-hold `CGWarpMouseCursorPosition()` is a sufficient trigger for BROKEN.

## Architectural consequence

Public CoreHID now satisfies the required built-in-trackpad ownership boundary:

```text
built-in trackpad
    |
    v
CoreHID HIDDeviceClient
    |
    +-- LOCAL: ordinary macOS ownership
    |
    +-- REMOTE:
           seizeDevice()
           |
           +--> macOS host pointer receives no movement
           +--> process receives HID activity
           |
           release by ending client lifetime
           |
           +--> local pointer immediately resumes
           +--> native cursor remains HEALTHY
```

No per-move cursor warp, cursor hide/show, cursor association lifecycle, synthetic recovery event, focus steal, or menu-bar recovery belongs in this candidate architecture.

## Current proof obligation — descriptor-backed relative X/Y semantics

The observed X/Y activity is not by itself enough to emit `SemanticPointerEvent.move`.

Apple exposes the physical device's HID-spec-compliant raw report descriptor through `HIDDeviceClient.descriptor`. HID 1.11 defines the Input item flags so that bit 2 distinguishes Absolute from Relative data. The probe therefore must prove that the matched Generic Desktop X and Y fields are unambiguously declared as **Data, Variable, Relative** in the report descriptor.

The current branch adds a dedicated pure parser and adversarial tests.

New probe mode:

```bash
.build/release/trackpad-seize-probe --mode descriptor-semantics
```

Required PASS output:

```text
PROBE_DESCRIPTOR_SEMANTICS ... strict_relative_xy=true
PROBE_DESCRIPTOR_RELATIVE_XY_OK
PROBE_END boundary=descriptor_semantics result=PASS
```

Strict proof requires:

- exactly one Data/Variable X declaration;
- exactly one Data/Variable Y declaration;
- both declarations have the Relative flag;
- X and Y belong to the same report ID;
- malformed or ambiguous descriptors fail closed.

The parser tests include:

- canonical relative HID mouse descriptor;
- absolute X/Y rejection;
- Usage Minimum/Maximum range handling;
- local-usage reset after a Main item;
- mixed relative/absolute rejection;
- different report-ID rejection;
- extended Usage decoding;
- truncated descriptor rejection;
- unmatched global Pop rejection.

## Candidate production architecture after semantics PASS

```text
MacEventTap (listen-only)
    |
    +--> EdgeDetector
    +--> keyboard suppression while remote

CoreHIDBuiltInPointerBackend
    |
    +--> Capability
    |      discover/revalidate exact built-in Generic Desktop Mouse
    |
    +--> acquire(controlGeneration)
    |      create generation-owned HIDDeviceClient
    |      seizeDevice()
    |      only then acknowledge remote pointer ownership
    |
    +--> remote lease
    |      descriptor-proven relative X/Y
    |      -> InputDomain SemanticPointerEvent
    |
    +--> release(controlGeneration)
           stop delivery admission
           cancel monitor
           end generation-owned client lifetime
           verify no stale generation retains ownership

HostSuppressionController
    |
    +--> owns CoreHID pointer lease + keyboard suppression as one Control epoch
```

The known-broken repeated-warp backend must not be a silent fallback. If CoreHID discovery or seizure cannot establish the required capability, remote acquisition fails closed to local ownership.

## Remaining production proof after relative semantics

Relative X/Y is necessary but not sufficient for merge. Production work still needs proof for:

- element-value decoding and sign handling;
- click/button semantics;
- scroll semantics;
- device removal while remote;
- sleep/wake;
- additional pointing-device hot-plug and leakage policy;
- synchronous release / stale-generation exclusion;
- watchdog or emergency-release behavior;
- permission/capability changes;
- repeated Mac -> DeX -> Mac cycles on the exact production backend;
- physical HEALTHY native cursor after those production cycles.

## Current proof status

- public built-in-trackpad discovery: **PASS**
- ordinary-user CoreHID seizure: **PASS**
- host pointer isolation during seizure: **PASS**
- process receives physical movement activity: **PASS**
- immediate local pointer return: **PASS**
- native cursor HEALTHY with valid active/key-window oracle: **PASS**
- descriptor-backed relative X/Y semantics: **UNVERIFIED**
- production CoreHID backend: **BLOCKED pending semantics + integration proof**
- #146: **open**
