# Security Policy

## Supported versions

v0.1.0 is the first public release; there are no LTS/stability guarantees yet.
All reports are welcome until a stable release exists.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature for this repository (Security → Report a vulnerability) to report security issues privately. Do not include credentials, ADB pairing information, clipboard contents, keystrokes, or other sensitive data in public issues.

- Response SLA: first response within 7 days.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged (AGENTS.md hard rule 4).
- No cloud relay, root, or Knox bypass. Device interaction remains local. Any internal Android API use must be isolated, documented, feature-detected, and fail safely (AGENTS.md hard rule 9).
- Pointer-trapping code is not allowed on any path except test-only.
