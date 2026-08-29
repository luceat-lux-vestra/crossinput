# macOS Native Cursor Mechanism Investigation

Status: **IN PROGRESS — physical observation required**  
Issue: [#96](https://github.com/luceat-lux-vestra/crossinput/issues/96)  
Branch: `investigate/macos-native-cursor`  
Investigation candidate: `8c71ea543fbfd18831c7930b9b0049ceafde5ddc`

This is an investigation record, not a production change proposal. The
candidate must not be merged. No conclusion about the native directional
cursor mechanism is established until the exact A/B artifacts below have been
observed on the physical Mac + DeX setup.

## Scope and provenance

The investigation starts from the current `main` commit:

`a20dd712c9aa1f9c165ec4d470470b70ba8a9667`

The candidate restores the pre-#87 explicit host-cursor lifecycle only for
comparison. It does not restore the #72 AppKit overlay, add a custom cursor,
change the Android helper, change the protocol, or change handoff/session
semantics.

### Exact A/B artifacts

| Build | Source commit | Package identity | Build identifier | Artifact |
|---|---|---|---|---|
| A | `a20dd712c9aa1f9c165ec4d470470b70ba8a9667` | `a20dd712c9aa1f9c165ec4d470470b70ba8a9667` | `20260829T154140Z` | `dist/investigation/Ampersand-A-a20dd712.app` |
| B | `8c71ea543fbfd18831c7930b9b0049ceafde5ddc` | `8c71ea543fbfd18831c7930b9b0049ceafde5ddc` | `20260829T154201Z` | `dist/investigation/Ampersand-B-8c71ea5.app` |

Both artifacts were ad-hoc signed and passed:

```text
codesign --verify --deep --strict --verbose=2 <artifact>
valid on disk
satisfies its Designated Requirement
```

The candidate's only production behavior restoration is:

- `suppress()` sets the suppression state and increments the generation, then
  invokes `CGDisplayHideCursor` once under the existing state lock.
- The first release of an active suppression invokes
  `CGDisplayShowCursor` once under the existing state lock.
- Duplicate suppression/release calls remain idempotent.
- Existing pointer warp/restore calls remain in place. B only records their
  result when the investigation flag is enabled; it does not change their
  target or routing.

The candidate adds investigation-only metadata logging for suppression,
handoff state, session state, cursor API results, cursor identity signatures,
pointer warp targets, display context, and release reasons. It never logs raw
mouse events, key codes, clipboard data, or HID payloads.

## Current lifecycle map

The relevant current and candidate lifecycle is:

```text
edge entry
  -> ControlHandoffController: local -> arming -> remote
  -> InputCapture.suppress()
       state lock: isSuppressing = true; generation += 1
       B only: CGDisplayHideCursor(main-display argument)
       start watchdog
  -> forward pointer/keyboard events while suppressed
  -> one release reason
       state lock: isSuppressing = false; cancel watchdog
       B only: CGDisplayShowCursor(main-display argument)
       flush stuck keys
       external-control: reset pointer state, cooldown, no warp
       other releases: restore crossing edge / fallback center and arm exit
  -> ControlHandoffController: returning -> local
```

The release reasons covered by the candidate tests and diagnostics are
`normalReturn`, `watchdogTimeout`, `emergencyHotkey`, `remoteUnavailable`,
`captureStopped`, and `externalControl`. The external-control path retains the
no-normal-edge-warp distinction.

`CGWarpMouseCursorPosition` is a separate pointer-geometry operation. It is
intentionally retained for center/hold/restore behavior, including the
external-control no-warp path. This investigation does not infer that cursor
visibility and pointer geometry have the same owner.

## Physical environment preflight

The following was observed before the physical A/B run; per-run foreground and
cursor observations remain to be recorded.

| Item | Observed value |
|---|---|
| Host macOS | 26.6.2, build 25G83 |
| Host hardware | Apple M1 Max |
| Host displays | U3260CE 3840x2160 UI, built-in Liquid Retina XDR, DELL U2312HM portrait 1080x1920 UI, 1920x1200 UI display, DELL U2312HM 1920x1080 UI |
| Android device | SM-G977N (`beyondxks`) |
| Android | 12, API 31 |
| Helper | `com.crossinput.helper`, versionName 0.1.0, versionCode 1 |
| ADB | wireless mDNS/TLS; repository guide records 37.0.1 |
| DeX Desktop | display ID 2, virtual 1920x1080, ON |
| Android HDMI Screen | display ID 7, 1920x1080, external; current dump includes base OFF and override ON state lines |
| Configured handoff edge | to be recorded with the run |
| Frontmost application / Ampersand activation | to be recorded separately for A and B |

The Android display IDs are discovered from the device; the test does not
assume that display ID 2 is universal.

## Physical A/B observation matrix

The following matrix is intentionally unfilled. `PENDING_HUMAN_OBSERVATION`
is not a pass or a failure and cannot be replaced by unit tests, ADB
screencap, or code inference.

| Lifecycle point | A — no explicit hide/show | B — restored hide/show | Evidence / notes |
|---|---|---|---|
| Local | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | ordinary Mac cursor before entry |
| Edge approach | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | edge coordinate and pre/post-entry timing |
| Arming | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | native directional presentation and direction |
| Remote ownership | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | visible/hidden/stale/fixed-at-edge; forwarding |
| Normal return | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | arrow restoration and pointer geometry |
| Emergency return | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | usable Mac control; stuck state check |
| Watchdog recovery | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | deliberate timeout; subsequent handoff |
| `remoteUnavailable` | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | recovery and re-entry |
| Reconnect / re-entry | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | no visibility state carried across session |
| External-control takeover | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | triggering event reaches macOS; no normal edge warp |
| Configured non-main display | PENDING_HUMAN_OBSERVATION | PENDING_HUMAN_OBSERVATION | same edge/restore semantics on that display |

For each row, the observer must check pointer trap, hidden/stuck host cursor,
duplicate cursor artifact, stuck key/button, forwarding correctness, restore
geometry, and the external-control no-warp distinction where applicable.

## Diagnostic collection

Run one artifact at a time with all other Ampersand instances stopped. B's
cursor investigation diagnostics are enabled only for that process:

```bash
launchctl setenv CROSSINPUT_DIAG_CURSOR_VISIBILITY 1
open -n "$PWD/dist/investigation/Ampersand-B-8c71ea5.app"
launchctl unsetenv CROSSINPUT_DIAG_CURSOR_VISIBILITY
tail -f "$HOME/Library/Logs/Ampersand/diag.log"
```

The log lines to retain for an observation are the candidate identity marker,
handoff/session state lines, suppression generation/release reason,
`cursor hide/show call` and `return` lines, cursor identity lines, and pointer
warp/restore metadata. The existing log may contain other candidate windows;
do not attribute lines to A or B without the identity marker.

## Native cursor identification status

Current classification: **UNKNOWN**.

The B candidate records both `NSCursor.current` and
`NSCursor.currentSystem` on the main queue using image size, hotspot, TIFF byte
count, and an FNV-1a signature. This is identification metadata, not a cursor
implementation. A physical observer must correlate the signature with the
visible cursor at local, edge, arming, remote, and return points. No claim is
made yet that the observed directional cursor is CrossInput-owned, AppKit-owned,
or WindowServer-generated.

## API findings before physical confirmation

These are documented API facts and implementation observations, not a root
cause conclusion.

| Mechanism | API class | Background/non-active behavior | Investigation assessment |
|---|---|---|---|
| Hide cursor | public CoreGraphics `CGDisplayHideCursor` | Apple documents a foreground-app expectation and reference-counted hiding | useful as an A/B factor; not yet a production recommendation |
| Show cursor | public CoreGraphics `CGDisplayShowCursor` | decrements the hide count and restores visibility at zero | must be balanced; does not identify a directional owner |
| Warp pointer | public CoreGraphics `CGWarpMouseCursorPosition` | moves the cursor without generating an event | separate geometry subsystem; intentionally preserved |
| Associate mouse/cursor | public CoreGraphics `CGAssociateMouseAndMouseCursorPosition` | documented for foreground applications; changes mouse/cursor coupling | candidate factor for a later isolated experiment; not changed here |
| Inspect current system cursor | public AppKit `NSCursor.currentSystem` | reports the system cursor regardless of which application set it | diagnostic identification only; no production cursor setting |
| Set a system cursor | public AppKit `NSCursor.resizeLeft/right/up/down`, `push/pop/set`, cursor rectangles | depends on AppKit/window activation and cursor-rect ownership | requires a separate background/non-active experiment; not implemented here |
| WindowServer background cursor property | private CGS/SPI pattern used by Deskflow | outside public API contract; compatibility and distribution risk | evidence for mechanism comparison only; not adopted |

Primary references:

- [CGDisplayHideCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayhidecursor%28_%3A%29?changes=_1)
- [CGDisplayShowCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayshowcursor%28_%3A%29)
- [CGWarpMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition%28_%3A%29?changes=_4)
- [CGAssociateMouseAndMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition%28_%3A%29?language=objc)
- [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
- [NSCursor](https://developer.apple.com/documentation/appkit/nscursor)
- [NSCursor.currentSystem](https://developer.apple.com/documentation/appkit/nscursor/currentsystem)
- [Deskflow OSXScreen.mm](https://github.com/deskflow/deskflow/blob/master/src/lib/platform/OSXScreen.mm) — comparison evidence only; its background cursor handling includes private WindowServer SPI and is not copied.

The Deskflow comparison is significant because its macOS implementation uses
more than hide/show: it combines cursor visibility calls with mouse/cursor
association changes and a private background-cursor property. This does not
prove that CrossInput needs those mechanisms; it only prevents treating
hide/show as a complete explanation before the physical and factor-isolation
experiments are done.

## Factor-isolation plan

If B alone reproduces the directional cursor, the result is initially
`STRONG EVIDENCE` that hide/show is an incidental trigger, not proof that it is
the correct production mechanism. The next isolated candidates are:

1. hide without show, with a strictly bounded diagnostic process only;
2. show timing and post-show cursor re-evaluation;
3. warp with neither visibility call and with the existing suppression path;
4. event suppression while holding pointer geometry constant;
5. frontmost/active application and AppKit cursor-rectangle ownership;
6. display-edge position and non-main display selection;
7. mouse/cursor association, only as a separately measured public-API
   experiment.

No factor-isolation result is a production change. The #72 overlay and custom
cursor alternatives remain excluded from this investigation.

## Provisional production options

| Option | Public/private | Background operation | Lifecycle complexity / risk | Recommendation now |
|---|---|---|---|---|
| Keep explicit hide/show | public CoreGraphics | documented foreground limitation; behavior is reference-counted | simple balance, but may be an incidental trigger and can hide a safety regression | no decision before A/B |
| Explicit public `NSCursor` system cursor | public AppKit | requires testing active/background and cursor-rect ownership | may fight the frontmost application and is not yet shown to work for this handoff | no decision before activation experiment |
| Use mouse/cursor association | public CoreGraphics | documented foreground-oriented behavior | changes event/cursor coupling; can affect pointer semantics | do not change without factor evidence |
| Use private WindowServer SPI | private | can address background cursor behavior in some KVM implementations | distribution, compatibility, and maintenance risk | not recommended for this investigation |
| Do not own cursor presentation; preserve geometry/forwarding only | public existing path | depends on native behavior outside CrossInput | lowest ownership complexity, but only acceptable if physical A/B confirms usable behavior | candidate recommendation only after evidence |

## Current conclusion

Root-cause confidence: **UNKNOWN**.  
Physical A/B conclusion: **HOLD — required human observation is not recorded**.

No production implementation is recommended yet. After the exact A/B run, the
result must be classified as one of:

- **Case A:** directional behavior is independent of hide/show;
- **Case B:** hide/show is an undocumented incidental trigger;
- **Case C:** a public `NSCursor` mechanism is stable, including background
  conditions;
- **Case D:** public APIs do not satisfy the requirement;
- **Case E:** another application’s cursor rect or display-edge behavior owns
  the presentation.

Until that classification is supported by direct physical observation and
metadata logs, this branch remains diagnostic-only and must not be merged.

## Local verification

The candidate passed the macOS test suite before packaging:

```text
swift test --quiet --disable-sandbox
146 XCTest tests passed
30 Swift Testing tests passed
```

The final physical verdict remains independent of these local results.
