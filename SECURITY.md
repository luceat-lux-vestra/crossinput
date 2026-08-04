# Security Policy

## Supported versions

v0.1.0 is the first public release; there are no LTS/stability guarantees yet.
All reports are welcome until a stable release exists.

## Reporting a vulnerability

- Private vulnerability reporting is not configured yet. Do not include sensitive details (private keys, ADB credentials, clipboard contents) in a public issue; contact the maintainer first through a minimal, non-sensitive issue.
- Do not post sensitive information (private keys, ADB credentials, clipboard contents) in issues.
- Response SLA: first response within 7 days.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged (AGENTS.md hard rule 4).
- No cloud relay, root, or Knox bypass. Device interaction remains local. Any internal Android API use must be isolated, documented, feature-detected, and fail safely (AGENTS.md hard rule 9).
- Pointer-trapping code is not allowed on any path except test-only.
