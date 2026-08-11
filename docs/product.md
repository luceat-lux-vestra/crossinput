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
- Android injection: UHID remains available for system-routed use, while
  target-specific application input requires InputManager explicit-display
  routing. The helper owns this policy.

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
- The packaged Mac application does not yet auto-deploy a matching helper;
  `HELLO_ACK` capability negotiation rejects an old/incompatible helper before
  input begins. Deployment packaging remains follow-up work.
- A target selection is not confirmed by a system-routed UHID backend. The
  current helper requires explicit-display InputManager routing for the normal
  selected-target pointer path.
- The architecture rebaseline does not itself certify a fresh real-device run.
