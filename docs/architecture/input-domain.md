# Semantic input boundary

Issue: #103  
Authority: ADR-0016 / #102

## Purpose

The macOS host must not produce Android `KeyEvent` values as its domain model.
CrossInput uses a small platform-neutral `InputDomain` between host capture and
remote delivery, while preserving the current CXI v1 wire format at the remote
adapter boundary.

## SwiftPM dependency direction

```text
                 App
               /     \
      InputCapture   Delivery
           |         /   |   \
           |        /    |    \
           +--> InputDomain   Protocol
                    ^          |
                    |      AndroidBridge
                    |
             no platform deps
```

Relevant target rules:

- `InputDomain` has no dependencies.
- `InputCapture -> InputDomain` translates CoreGraphics/macOS input into semantic input.
- `Delivery -> InputDomain` consumes semantic input.
- `Delivery -> Protocol / AndroidBridge` owns remote/CXI transport concerns.
- `Delivery` does **not** depend on `InputCapture`.
- `InputDomain` must not import CoreGraphics, AppKit, Protocol, AndroidBridge, UHID, or InputManager concepts.

## Translation boundaries

```text
CGEvent / macOS virtual key
  -> InputCapture.KeyCodeMapper
  -> SemanticKeyEvent / SemanticPointerEvent
  -> Delivery.InputSender
  -> Delivery.AndroidKeyCodeMapper
  -> Protocol.Messages KEY_EVENT / pointer payload
  -> Android helper
  -> backend adapter
```

`InputCapture.KeyCodeMapper` owns only macOS virtual-key and modifier interpretation.
`Delivery.AndroidKeyCodeMapper` owns the existing Android key-code, meta-bit, and action encoding required by CXI v1.

## Semantic model

`InputDomain` currently contains:

- `SemanticPointerEvent` — relative motion, button transition, scroll;
- `SemanticKey` — product-supported logical keys;
- `InputModifiers` — shift / alt / control / meta;
- `KeyTransition` — down / up;
- `SemanticKeyEvent` — key + modifiers + transition + repeat count.

The domain intentionally contains no Session/Target/Control mutable owner. Under ADR-0016 an event becomes ownership-bound when admitted through a Control-scoped `InputIngress`; #103 only establishes the semantic value boundary required by that later migration.

## Compatibility contract

CXI v1 remains unchanged in #103. Deterministic tests pin the complete supported key-code table, modifier bits, actions, repeat behavior, and pointer payload semantics. Unsupported macOS keys remain unsupported rather than being assigned Android-specific meaning in the host layer.

## Migration rule

The old Android-shaped input structs and the temporary test compatibility initializer are removed in #103. `InputCapture.PointerEvent` and `CapturedKeyEvent` remain only as source-level aliases to the `InputDomain` semantic types: they add no storage, Android semantics, or translation layer, and Delivery does not depend on them. Their host-facing names are tracked for removal during the #104 InputCapture decomposition.

Production code must not regain Android-shaped host input records, and `Delivery -> InputCapture` must not return.
