# ADR-0002: Product Name / Brand (Ampersand + CrossInput)

> Status: **superseded by ADR-0014**
> Date: 2026-08-03

## Context

The existing name "DeXCursor" (a) confines the product to DeX (Samsung-only), (b) does not express the essence (a cross-device input bridge), and (c) "InputBridge" conflicts with a commercial product. Since UHID input injection works on regular Android screens too, the name is made device/manufacturer-neutral.

> Historical note: this ADR predates the DeX-first product-scope rebaseline in ADR-0013. Its reference to possible future phone→Mac keyboard/touch extensions is no longer part of the current product direction or naming rationale. See ADR-0014 for the current product-brand and technical-naming contract.

## Decision

| Area | Name |
|---|---|
| Product/brand name (user-facing) | **Ampersand** (`&` logo) |
| Tagline | **CrossInput** — "Ampersand — cross-input between Mac and Android" |
| Technical identifiers (repo/folder/package/protocol) | **crossinput**, package `com.crossinput.helper`, protocol prefix **CXI** |

- Repo name: `crossinput`
- Swift package: `Ampersand` (library `AmpersandCore`, executable `Ampersand`, distributed as `Ampersand.app`)
- Android rootProject: `crossinput-helper`

## Alternatives

- Keep DeXCursor: DeX-specific, inconsistent with the extension direction.
- InputBridge: name conflict with a commercial product (unusable).
- CrossInput alone: accurate but generic and weak branding.
- UniInput/DeXBridge/Shuttle etc.: meaningful, but the Ampersand (brand) + CrossInput (description) combination has clearer role separation.

## Consequences

Historical consequences at the time of this decision:

- Positive: device/manufacturer-neutral and provides a branding element (`&`).
- Negative: the "DeX" keyword disappears from the name, slightly lowering search discoverability (compensated by mentioning DeX in docs/tagline).

The earlier expectation that the name should cover future phone→Mac keyboard/touch extensions has been superseded by ADR-0013 and ADR-0014.

## Validation

- (done) Bulk rename of repo folder name/package/protocol prefix
- (done) Android helper build (`./gradlew assembleDebug`) passes
- (done) macOS SPM build (`swift build`) passes
