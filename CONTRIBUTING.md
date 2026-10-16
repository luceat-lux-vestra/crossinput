# Contributing to Ampersand

## Before you start

1. Read [AGENTS.md](AGENTS.md) — PRs violating the hard rules are rejected.
2. Check the current program, backlog, and evidence gates in [docs/roadmap.md](docs/roadmap.md).
3. Read the relevant docs (docs/, protocol/) before starting work.

## Work rules

- **PR merge is forbidden without**: on-device (or explicitly specified procedure) verification records, or decisions made without docs/adr/.
- Protocol changes must update `protocol/protocol.md` + `protocol/fixtures/` golden fixtures together.
- Copying upstream code requires updating `THIRD_PARTY_NOTICES.md`.

## CI scope

A documentation-only PR gets the bounded fast path only when every changed file
is `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, or Markdown under `docs/**`.
macOS/Android runtime work is skipped, while documentation, evidence/tooling,
and dependency validation remain active. The required `Merge Gate` aggregates
those five internal component jobs and succeeds only when all five succeed.
Mixed or unprovable scope runs the full validation set. Protocol, workflow,
tooling, source, and build files are never treated as documentation-only.

## GitHub Actions lifecycle

Research and temporary workflows should stay off the protected default branch
where practical. If an exceptional ephemeral workflow is checked in under
`.github/workflows`, filenames beginning with `research-`, `temporary-`,
`tmp-`, or `experiment-` must include non-empty `# lifecycle-owner:` and
`# lifecycle-retire:` header comments.

Historical Actions runs/artifacts are not automatically evidence. Preserve them when a concrete issue, PR, R2A campaign, security/release decision, benchmark, or migration record consumes them as immutable proof. Orphaned temporary/research/one-off history with no such consumer may be deleted after exact workflow-ID/path/run-count validation; never delete evidence-bearing history solely for sidebar cosmetics. Old run history is not a reason to keep or recreate obsolete workflow source.

## PR checklist

- [ ] build + lint + related tests pass
- [ ] verification records attached (on-device logs, screen captures, or a reproducible command list)
- [ ] write an ADR in `docs/adr/` for any decisions
- [ ] docs updated (README / docs / protocol)

## Issue templates

- See [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/).
