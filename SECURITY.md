# Security Policy

## Supported versions

v0.1.0 is the first public release; there are no LTS/stability guarantees yet.
All reports are welcome until a stable release exists.

## Reporting a vulnerability

- Please report through a non-public channel: security@crossinput.example.invalid (placeholder)
- Do not post sensitive information (private keys, ADB credentials, clipboard contents) in issues.
- Response SLA: first response within 7 days.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged.
- No root, Knox bypass, or cloud relay — device-local public APIs only.
- Pointer-trapping code is not allowed on any path except test-only.
