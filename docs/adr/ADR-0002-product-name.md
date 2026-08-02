# ADR-0002: Product Name / Brand (Ampersand + CrossInput)

> Status: **accepted**
> Date: 2026-08-03

## Context

The existing name "DeXCursor" (a) confines the product to DeX (Samsung-only), (b) does not express the essence (a cross-device input bridge), and (c) "InputBridge" conflicts with a commercial product. Since UHID input injection works on regular Android screens too, the name is made device/manufacturer-neutral.

## Decision

| Area | Name |
|---|---|
| Product/brand name (user-facing) | **Ampersand** (`&` logo) |
| Tagline | **CrossInput** — "Ampersand — cross-input between Mac and Android" |
| Technical identifiers (repo/folder/package/protocol) | **crossinput**, package `com.crossinput.helper`, protocol prefix **CXI** |

- Repo name: `crossinput`
- Swift package: `Ampersand` (library `AmpersandCore`, executable `AmpersandApp`)
- Android rootProject: `crossinput-helper`

## Alternatives

- Keep DeXCursor: DeX-specific, inconsistent with the extension direction.
- InputBridge: name conflict with a commercial product (unusable).
- CrossInput alone: accurate but generic and weak branding.
- UniInput/DeXBridge/Shuttle etc.: meaningful, but the Ampersand (brand) + CrossInput (description) combination has clearer role separation.

## Consequences

- Positive: device/manufacturer-neutral, covers extensions (phone→Mac keyboard/touch), provides a branding element (`&`).
- Negative: the "DeX" keyword disappears from the name, slightly lowering search discoverability (compensated by mentioning DeX in docs/tagline).

## Validation

- (done) Bulk rename of repo folder name/package/protocol prefix
- (done) Android helper build (`./gradlew assembleDebug`) passes
- (done) macOS SPM build (`swift build`) passes
