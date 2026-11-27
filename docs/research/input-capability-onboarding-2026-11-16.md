# macOS Input Capability / Onboarding Review — 2026-11-16

Issue: #99  
Architecture: ADR-0017 / HostInputRuntime capability boundary

## Question

How should Ampersand decide whether Accessibility and/or Input Monitoring are
required without hard-coding an unnecessary dual-permission gate, and where
should that decision live?

## Platform findings

### Accessibility

Apple documents `AXIsProcessTrusted()` as the silent trust check for the current
process.

`AXIsProcessTrustedWithOptions` may use
`kAXTrustedCheckOptionPrompt = true` to inform an untrusted user, but Apple
explicitly documents that prompting is asynchronous and does not alter the
function's immediate return value.

References:

- https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions

Decision:

- silent preflight belongs to `InputCapabilityController`;
- prompting occurs only from an explicit user action;
- capture start itself must not prompt or infer Accessibility state.

### Input Monitoring / listen-event access

Core Graphics exposes:

- `CGPreflightListenEventAccess()`;
- `CGRequestListenEventAccess()`.

Apple's user guidance describes Input Monitoring as the Privacy & Security
permission controlling whether an app may monitor keyboard, mouse, or trackpad
input.

References:

- https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess
- https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess
- https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac

Decision:

A false listen-event preflight is **not by itself** a reason to block Ampersand
when the current modifying event tap actually works.

The current runtime decision is:

1. Accessibility missing -> block capture as missing Accessibility.
2. Accessibility present -> attempt the real event-tap mechanism.
3. Capture succeeds -> separate Input Monitoring is not required for this
   process/runtime, even if its independent preflight is false.
4. Capture fails:
   - listen-event preflight false -> learn that separate Input Monitoring is
     required for this process/runtime;
   - listen-event preflight true -> classify a non-permission capture mechanism
     failure.
5. Once separate Input Monitoring has been proven required, keep that learned
   requirement for the process lifetime so later revocation is fail-safe.

This is capability-driven and avoids treating OS/version behavior as a static
permission matrix.

## Product references

### Karabiner-Elements

Current Karabiner-Elements documentation says Accessibility may also provide the
permission needed for physical input capture, and that separate Input Monitoring
is normally unnecessary in newer releases/configurations when Accessibility
already covers it.

References:

- https://karabiner-elements.pqrs.org/docs/manual/misc/required-macos-settings/
- https://karabiner-elements.pqrs.org/docs/getting-started/installation/
- https://karabiner-elements.pqrs.org/docs/releasenotes/

Adopted pattern:

- ask only for the capability the current runtime actually proves it needs;
- keep permission recovery explicit and user-visible.

Rejected pattern:

- do not copy Karabiner's privileged daemon/system-extension architecture;
  Ampersand's product and ownership model are different.

### Logitech Options+

Logitech keeps permission state/recovery documented and discoverable rather than
treating permission setup as a one-time hidden onboarding step. Its permission
matrix is broader than Ampersand's and varies by macOS version.

Reference:

- https://support.logi.com/hc/en-001/articles/1500005514962-Logi-Options-permissions-on-macOS

Adopted pattern:

- permission status remains visible after onboarding;
- explicit recovery actions remain available;
- returning from System Settings refreshes state.

Rejected pattern:

- do not require every permission Logitech needs;
- do not require restart/reopen unless Ampersand's actual mechanism proves it is
  necessary.

## Ampersand ownership decision

`InputCapabilityController` owns:

- silent Accessibility preflight;
- silent listen-event/Input Monitoring preflight;
- explicit user-request actions;
- the published capability snapshot;
- the learned `inputMonitoringRequired` fact;
- runtime capability polling outside event callbacks;
- classification of a failed capture attempt into:
  - missing Accessibility;
  - missing Input Monitoring;
  - capture mechanism unavailable.

`InputCapture` owns only the event-tap mechanism. It does not request TCC,
prompt the user, or classify permission state.

`AppModel` projects capability state for the current UI only. It does not own
the learned Input Monitoring requirement.

This is an intermediate ADR-0017 migration boundary. #104 may later split
`InputCapture` further into HostInputRuntime components without changing this
capability ownership.
