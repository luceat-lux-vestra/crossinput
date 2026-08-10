# CrossInput Product Definition

## Definition

CrossInput is an input bridge that captures input from a local host and safely
hands control to a selected remote target.

The user-facing macOS application is named Ampersand. CrossInput is the product
and repository concept; neither name makes Samsung DeX part of the core domain.

## Current supported topology

```text
macOS host
    → Android remote
        → selected Android display target
```

The current direction is one-way: macOS input goes to Android. The helper is
started through ADB/app_process and does not require a continuously installed
Android application.

## Current inputs and handoff

- Pointer: movement, buttons, and scroll.
- Keyboard: key down/up, modifiers, repeat, and Android IME composition.
- Handoff: configured macOS screen edge.
- Transport: ADB over the existing wireless-debugging workflow.
- Android injection: UHID primary, InputManager fallback.

Samsung DeX is a supported Android target/use case. A phone display and other
Android displays discovered by the helper use the same remote-target model.

## Current behavior and safety

The bridge returns control to macOS on normal boundary return, emergency
release, capture shutdown, timeout, helper failure, and unexpected disconnect.
Remote failure must never permanently trap the local pointer or keyboard.

## Non-goals and future scope

The following are outside the current product scope:

- Android → macOS reverse input.
- Multiple hosts or simultaneous multi-remote control.
- Windows or Linux hosts.
- iOS/iPadOS targets.
- Cloud relay or arbitrary remote-desktop functionality.
- Replacement of ADB, UHID, or the current helper execution model.

Future work may investigate a semantic CXI v2, alternate handoff gestures,
alternate transports, and other host/target platforms. These are future design
axes, not current commitments.

## Limitations

- The v1 wire record still exposes raw Android display metadata for compatibility;
  the leakage and containment plan are recorded in [CXI v2 design](../protocol/v2-design.md).
- Display hot-plug and state changes need the complete failure-case regression
  matrix in issue #17.
- The InputManager pointer fallback remains a separate on-device verification
  item unless a current evidence record says otherwise.
- The architecture rebaseline does not itself certify a fresh real-device run.
