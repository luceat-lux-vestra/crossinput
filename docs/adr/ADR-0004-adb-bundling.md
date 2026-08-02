# ADR-0004: ADB Bundling (include the latest platform-tools in release artifacts)

> Status: **accepted**
> Date: 2026-08-03

## Context

v1 runs the helper via ADB over Wi-Fi (wireless debugging). Users cannot be forced to install adb, so adb is bundled with the product binary. Precedent: scrcpy ships its own adb bundle.

## Decision

1. **Bundle the adb binary from the latest platform-tools in each release** (download/verification automated in CI).
   - macOS: pick per Apple Silicon/Intel (or single universal binary)
   - Windows/Linux out of scope (macOS app)
2. **adb resolution priority (fallback chain)**:
   - environment variable override (`AMPERSAND_ADB`)
   - bundled adb (default)
   - system adb (`ANDROID_HOME`/PATH) — if configured by the user
3. **License**: adb is Apache-2.0 — record the version in `THIRD_PARTY_NOTICES.md` (AGENTS.md rule 7).
4. **Wireless debugging pairing**: the Mac app guides onboarding (Developer options → Wireless debugging → pairing code). One-time.

## Alternatives

- Depend on system adb: most users don't install it — distribution failure.
- Regular installed app + direct TCP connection (no adb): requires `/dev/uhid` to be accessible from the app uid — **to be verified by experiment (see ADR-0006)**, a potential adb replacement path on success.

## Consequences

- Positive: guaranteed to work regardless of user environment. scrcpy precedent.
- Negative: larger release size (~4MB), needs platform-tools sync per release (automated by CI).

## Validation

- (pending) CI release pipeline: download platform-tools → verify adb version → bundle → integrate with the notarization pipeline
