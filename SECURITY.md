# Security Policy

## Supported versions

Currently in the technical verification phase; there are no officially supported versions.
All reports are welcome until a stable release exists.

## Reporting a vulnerability

- Please report through a non-public channel: security@crossinput.example.invalid (placeholder)
- Do not post sensitive information (private keys, ADB credentials, clipboard contents) in issues.
- Response SLA: first response within 7 days.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged.
- No root, Knox bypass, or cloud relay — device-local public APIs only.
- Pointer-trapping code is not allowed on any path except test-only.
