# CrossInput Product Definition

## Definition

CrossInput is a **DeX-first, Android-capable macOS input bridge**.

Its primary purpose is to let a Mac's pointer and keyboard control a Samsung DeX desktop through safe screen-edge handoff, so a Galaxy device can remain useful as a desktop even when it is no longer convenient to use as a handheld phone.

The user-facing macOS application is named Ampersand. Samsung DeX is the primary product use case, while the existing selectable Android-display model remains part of the product because the built-in phone display is already a useful supported target.

## Current supported topology

```text
macOS host
    → one connected Android device
        → one selected Android display target
            ├─ Samsung DeX desktop (primary)
            ├─ built-in phone display (supported)
            └─ other discovered displays (best-effort unless verified)
```

Only one Android device is controlled at a time. Multiple displays on that single device are part of target selection; simultaneous control of multiple Android devices is not.

## Current input and handoff

Input direction is one-way: **macOS → Android**.

- Pointer: movement, buttons, drag, vertical scroll, and horizontal scroll.
- Keyboard: key down/up, modifiers, repeat, shortcut suppression while remote, and Android IME composition including the implemented Korean input path.
- Handoff: a configured edge on each macOS display transfers pointer ownership between macOS and the selected Android target.
- Transport: CXI v1 over the current ADB/app_process byte stream.
- Android pointer routing: desktop sink candidates such as Samsung DeX prefer system-routed UHID so Android's InputReader path moves the visible desktop cursor; non-desktop targets use InputManager explicit-display routing. The Android helper owns this policy.

The selected Android display directly controls pointer routing. The current keyboard backend is not explicitly bound to the selected display ID, so phone-versus-DeX keyboard routing remains a device-verification item rather than an assumed guarantee.

## Clipboard and data sharing

Clipboard is intentionally separate from input direction.

- **Near term:** bidirectional UTF-8 text clipboard synchronization.
- **Backlog:** bidirectional image clipboard synchronization.
- **Backlog:** file clipboard / file transfer.

Text synchronization must prevent echo loops and must not log clipboard contents. Image and file support remain separate work items because they add binary payload, size, streaming/storage, cancellation, and validation concerns.

## Current behavior and safety

The bridge returns control to macOS on normal boundary return, emergency release, capture shutdown, timeout, helper failure, and unexpected disconnect. Remote failure must never permanently trap the local pointer or keyboard.

When a session is ready, **Disable Edge Switch** stops remote-control
acquisition and returns ownership to macOS without stopping the Android helper,
transport, or selected display target. **Enable Edge Switch** can resume the
existing session. **Disconnect** is different: it intentionally releases local
control, cleans up held input, and tears down the current Android session. A
later explicit Connect/reconnect uses the existing endpoint discovery,
handshake, display refresh, and target-selection flow; the current product
policy enables Edge Switch after a successful reconnect.

## Explicit non-goals

The following are not part of the current product direction unless a new product decision explicitly supersedes this document:

- Android → macOS pointer input.
- Android → macOS keyboard input.
- Using the Android phone itself as a pointing device for macOS.
- Simultaneous control of multiple Android devices.
- Cloud relay, accounts, server infrastructure, or arbitrary remote-desktop functionality.
- Root or Knox-bypass requirements.

Windows/Linux hosts and broader target families are not current commitments. They may be evaluated later, but must not drive current abstractions without a concrete requirement.

## Future extension points

### Alternate transports

ADB/app_process remains the current/default transport. The architecture may support another local transport in the future, such as direct LAN/TCP or another USB-local channel, but a second transport is implemented only when a concrete need justifies it. Transport extensibility is preserved; speculative transport implementations are not current roadmap work.

### CXI v2

CXI v1 remains the production protocol. CXI v2 is a future protocol design for CrossInput's existing input and data-sharing model. Its goals are semantic messages, normalized/opaque targets, capability negotiation, backend independence, clipboard/data-sharing support, and transport independence.

CXI v2 is not intended to become a universal cross-platform input framework and is not an implementation commitment until a migration gate is explicitly accepted.

## Product principle

> DeX-first, Android-capable.
>
> Preserve proven useful capabilities and justified extension seams, but do not add abstractions or implementations for hypothetical platforms, transports, or input directions without a current requirement.

## Known limitations

- The v1 wire record still exposes raw Android display metadata for compatibility; the leakage and containment plan are recorded in [CXI v2 design](../protocol/v2-design.md).
- Display hot-plug and state changes still require the complete failure-case regression matrix tracked in issue #17.
- The packaged Mac application does not yet auto-deploy a matching helper; `HELLO_ACK` capability negotiation rejects an incompatible helper before input begins. Deployment packaging remains follow-up work.
- Keyboard routing across simultaneous phone/DeX displays needs explicit on-device verification (#92).
- A green local build does not replace the device evidence required by `AGENTS.md` and `docs/testing.md`.
