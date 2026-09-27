# Contributing to Ampersand

## Before you start

1. Read [AGENTS.md](AGENTS.md) — PRs violating the hard rules are rejected.
2. Check the current Phase in [docs/roadmap.md](docs/roadmap.md).
3. Read the relevant docs (docs/, protocol/) before starting work.

## Work rules

- **PR merge is forbidden without**: on-device (or explicitly specified procedure) verification records, or decisions made without docs/adr/.
- Protocol changes must update `protocol/protocol.md` + `protocol/fixtures/` golden fixtures together.
- Copying upstream code requires updating `THIRD_PARTY_NOTICES.md`.

## CI scope

A documentation-only PR gets the bounded fast path only when every changed file
is `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, or Markdown under `docs/**`.
macOS/Android runtime work is skipped, while documentation, evidence/tooling,
and dependency validation remain active. Mixed or unprovable scope runs the
full validation set. Protocol, workflow, tooling, source, and build files are
never treated as documentation-only.

## PR checklist

- [ ] build + lint + related tests pass
- [ ] verification records attached (on-device logs, screen captures, or a reproducible command list)
- [ ] write an ADR in `docs/adr/` for any decisions
- [ ] docs updated (README / docs / protocol)

## Issue templates

- See [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/).
