# ADR-0005: Distribution Strategy (ad-hoc signing + GitHub Releases + Homebrew tap)

> Status: **accepted** (re-evaluate when account/monetization decisions are made)
> Date: 2026-08-03

## Context

A distribution path usable by regular users is needed without an Apple Developer account ($99/year). Unsigned apps don't open under Gatekeeper ("damaged"), so at minimum ad-hoc signing is required.

## Decision

1. **Two parallel distribution paths**:
   - **GitHub Releases**: ad-hoc signed (`codesign -s -`) `.app` zip. User does "right-click → Open" once.
   - **Homebrew tap** (`brew install`): brew automatically removes quarantine, so frictionless installation without an account. Update automation possible.
2. **CI automation**: the release pipeline automates ad-hoc signing + zip packaging + Homebrew tap repo update (version/hash).
3. **Fully frictionless (double-click install) requires a paid account + notarization** — re-evaluate when the product reaches the adoption phase (extend this decision, don't reverse it).

## Alternatives

- Get a developer account now: cost + premature commitment while the product is unfinished.
- Distribute unsigned: Gatekeeper "damaged" — effectively unusable.
- TestFlight/App Store: account required; store review risk given the nature of DeX input capture (accessibility permission).

## Consequences

- Positive: immediately distributable without an account. Standard path for technical users.
- Negative: regular users face "right-click → Open" friction (nearly zero for Homebrew users).
- Negative: the Homebrew tap can run on a free GitHub repo initially.

## Validation

- (done) Gatekeeper behavior of an ad-hoc signed app shipped via GitHub Releases (v0.1.0) — first launch needs right-click → Open once, then works; see [ADR-0008](ADR-0008-v0.1.0-release-packaging.md) (which supersedes the `.app` zip packaging detail)
- (pending) Homebrew tap install/upgrade e2e check
