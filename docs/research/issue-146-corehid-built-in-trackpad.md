# Issue #146 — CoreHID built-in trackpad ownership research

Status: **H1 probe only / production feasibility UNVERIFIED**

This note supersedes the external-mouse premise of closed PR #147. The required pointing device is the MacBook built-in trackpad.

## Problem boundary

The current production host path consumes `CGEvent` pointer events and repeatedly calls `CGWarpMouseCursorPosition()` while remote ownership is active. Issue #96 standalone evidence proves that repeated edge-hold warping is sufficient to produce the BROKEN native cursor state. Previous hide/show, `CGAssociateMouseAndMouseCursorPosition(false)`, synthetic-event, focus, AppKit invalidation, and private cursor-presentation candidates did not establish a HEALTHY return baseline.

The desired boundary is therefore below cursor presentation:

```text
built-in trackpad
    |
    v
physical HID ownership lease
    +---- remote-owned ----> relative semantic pointer input ----> DeX
    |
    X---- macOS local pointer pipeline

lease release
    |
    +---- macOS owns the untouched native pointer pipeline again
```

No per-move cursor warp, cursor visibility lifecycle, cursor association lifecycle, or synthetic recovery action belongs in this architecture.

## New primary evidence

Apple's current public CoreHID API exposes `HIDDeviceClient.seizeDevice()`. Apple documents the operation as making the caller the device's only active client for notifications/interactions until that client is deinitialized.

Apple's `hidutil` discovery documentation shows `Apple Internal Keyboard / Trackpad` as multiple HID components. In particular, a built-in `AppleHIDTransportHIDDevice` appears with Generic Desktop usage page `1`, usage `2` (Mouse), separately from the keyboard component at usage `6`.

More importantly, an Apple DTS CoreOS/Hardware engineer described the intended architecture in March 2026 as:

1. use CoreHID to seize a HID device, routing HID activity to the process instead of the system;
2. optionally emit replacement local events through a virtual HID device when local reinjection is desired.

Ampersand does **not** need step 2 while remote ownership is active. The captured relative movement should go to DeX, not back into macOS.

The same DTS discussion about the built-in MacBook trackpad states that a third-party DriverKit extension cannot use the non-public `com.apple.developer.driverkit.builtin` entitlement required at minimum to match the built-in interface. DTS distinguishes DriverKit filtering from device seizure and explicitly points back toward seizure as the potentially shippable direction.

Primary references:

- https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
- https://developer.apple.com/documentation/corehid/discoveringhiddevicesfromterminal
- https://developer.apple.com/documentation/corehid/communicatingwithhiddevices
- https://developer.apple.com/forums/thread/820066
- https://developer.apple.com/forums/thread/818441

## Capture-layer disposition

| Layer | Built-in trackpad visibility | Consume before local pointer processing | Relative data | Supportability | Issue #146 disposition |
| --- | --- | --- | --- | --- | --- |
| AppKit / NSEvent | translated events only | no reliable physical-device ownership | yes, translated | public | rejected as ownership boundary |
| CGEventTap HID | translated HID event stream | can consume events, but existing confinement still mutates global cursor state | yes | public + Accessibility | keep for edge detection / keyboard only; do not use for pointer confinement |
| IOHIDManager / IOHIDDevice | device-level | `kIOHIDOptionsTypeSeizeDevice` exists | device-dependent | public legacy IOKit | secondary only; Apple trackpad event delivery has conflicting field evidence |
| CoreHID `HIDDeviceClient` | device-level, built-in matching supported | **seizure is explicitly the candidate contract** | elements and reports | public | **H1 / probe now** |
| IOHIDEventSystemClient | event-system level | filtering/suppression contract not established | yes | private SPI | not a production candidate |
| HIDDriverKit DEXT | driver/provider level | could own matched hardware, but built-in matching requires at least a non-public entitlement | raw reports | public framework, unavailable built-in entitlement | reject as shippable built-in-trackpad path |
| Private MultitouchSupport / private HID filters | lower/private path | potentially | raw touch | unsupported private API | contingency research only after public H1 failure |

DriverKit is therefore **not** the next implementation target. A system extension would add deployment and entitlement cost without first proving that it can bind to the required built-in hardware; current Apple DTS evidence says the minimum built-in entitlement is non-public.

## H1 bounded probe

Branch: `research/issue-146-corehid-built-in-trackpad`

Executable: `trackpad-seize-probe`

The probe intentionally does not touch production `InputCapture` or `Control` code. It:

- matches only a built-in Generic Desktop Mouse whose product is `Apple Internal Keyboard / Trackpad`;
- validates the identity again after constructing `HIDDeviceClient`;
- inspects whether Generic Desktop X/Y elements exist;
- calls `seizeDevice()` before creating any monitor stream, matching Apple's no-outstanding-call requirement;
- observes for five seconds;
- counts report and X/Y element notifications without logging coordinates, deltas, report bytes, buttons, keys, or any other input payload;
- terminates the client lifetime to release the seizure;
- calls no Quartz cursor mutation/presentation API.

### H1 physical proof matrix

The probe is only useful if all rows can be classified on the same exact build:

| Gate | Required observation | Failure meaning |
| --- | --- | --- |
| D0 discovery | exactly the expected built-in mouse component is selected | capability unsupported/ambiguous; fail closed |
| D1 relative surface | X/Y elements exist, or a later descriptor-backed decoder is proven | no usable relative source yet |
| S1 seize | `PROBE_SEIZE_OK` as an ordinary product user | public seizure unavailable in required deployment context |
| S2 isolation | physical built-in trackpad movement does **not** move the macOS pointer during the five-second lease | seizure does not provide the required host ownership boundary |
| S3 capture | the same physical movement produces non-zero report and/or relative-element notification counts | seizure suppresses host but does not expose usable movement if zero |
| R1 release | process exit immediately restores ordinary trackpad control without click/focus/reset action | lease release is not fail-safe enough |
| R2 cursor health | native directional/resize cursor remains HEALTHY immediately after release | H1 does not solve #96 if BROKEN |

`S1` alone is not PASS. `S1 + S2 + S3 + R1 + R2` is the minimum evidence to proceed to a real Host Capture backend.

Screenshots/screen recording are not the cursor-health oracle because prior #96 evidence indicates they may perturb presentation. Human visual observation plus metadata-only probe output is the initial physical oracle.

## If H1 passes

The Architecture Leap target should become:

```text
MacEventTap (listening)
    |
    +--> EdgeDetector
    +--> keyboard capture/suppression while remote

CoreHIDBuiltInPointerBackend
    |
    +--> Capability: discover and validate built-in mouse component
    +--> acquire(): create generation-owned HIDDeviceClient, seize synchronously
    +--> remote lease: translate relative HID X/Y/button/scroll into InputDomain
    +--> release(): synchronously end monitor/client lifetime

HostSuppressionController
    |
    +--> owns the CoreHID pointer lease + keyboard suppression as one Control epoch
```

Control must not become remote until the pointer seizure is confirmed. Return must invalidate the Control generation first, synchronously stop delivery admission, cancel the HID monitor, end the seizure lease, release keyboard suppression, and only then publish local ownership. No queued/stale generation may own a client or mutate host cursor state after return.

The known-broken P0 warp backend must not be a silent fallback for a HEALTHY-qualified session. If CoreHID capability discovery or seizure fails, acquisition fails closed to local ownership.

A production backend also needs separate proof for built-in trackpad click and scroll semantics, device removal, sleep/wake, hot-plug of additional pointing devices, watchdog/emergency release, permission changes, and concurrent Control/Session/Target replacement. The five-second H1 probe does not claim those properties.

## If H1 fails

Classify the failure before choosing another architecture:

- discovery/X-Y absent but seizure works: inspect the report descriptor and CoreHID raw-report availability without logging payloads; determine whether a descriptor-backed relative decoder is possible;
- seizure denied for ordinary user: test whether the denial is permission/entitlement/policy versus built-in-device exclusivity, with exact `HIDDeviceError` metadata;
- seizure succeeds but macOS pointer still moves: CoreHID seizure is not the required pre-pointer suppression boundary on this hardware/OS; do not integrate it;
- host is isolated but no movement data reaches CoreHID: legacy/private multitouch routing becomes the next research question;
- release causes BROKEN: reject H1 for #96 even if capture/isolation works.

Only after that classification should legacy IOHID or private MultitouchSupport be considered. DriverKit is not a default escalation because current Apple evidence blocks third-party matching of the built-in interface for a shippable product.

## Current proof status

As of this research commit:

- architecture evidence: strong enough to justify H1 probe;
- compilation against repository CI SDK: pending;
- ordinary-user built-in-trackpad seizure: UNVERIFIED;
- host pointer isolation: UNVERIFIED;
- relative notification delivery: UNVERIFIED;
- release cursor HEALTHY: UNVERIFIED;
- #146: **FAIL / blocker remains open**.
