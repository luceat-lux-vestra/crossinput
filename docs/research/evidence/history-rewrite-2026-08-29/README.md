# Git history identity rewrite — 2026-08-29

## Purpose

On 2026-08-29, CrossInput's reachable Git branch and tag history was rewritten
to canonicalize the exact historical identity:

```text
algorist <heathkimdev@gmail.com>
```

as:

```text
luceat-lux-vestra <heathkimdev@gmail.com>
```

This was an intentional destructive maintenance operation so the default
branch and rewritten tags use the canonical Git identity at the object level.
The repository's existing `.mailmap` was retained as documentation and
fallback alias metadata.

## Rewrite record

- Pre-rewrite `main`: `5612cd1a64ed397c6c68da6768cfe2cb3979f5ac`
- Rewritten `main` before this provenance record: `11cd9cef89dc64d71abf680aa6df7e096e27cc51`
- Git: `2.50.1`
- `git-filter-repo`: `2.47.0`
- Command class: `git filter-repo --preserve-commit-hashes` with an external
  mailmap for Git author/committer/tagger fields and an exact message callback
  for the matching `Co-authored-by:` trailer.
- Commit map: `commit-map.txt` records the old-to-new commit object mapping.
- Pre-rewrite refs: `pre-rewrite-refs.txt` records the frozen refs used for
  rollback and coverage validation.

The rewrite retained 223 mapped reachable commits, preserved the ordinary
branches and tag, and produced zero tree differences. Source files, behavior,
architecture, tests, documentation semantics, and historical evidence claims
were not changed by the rewrite.

## Evidence and ADR-0012 treatment

Historical physical-device evidence keeps the exact candidate SHA that was
actually emitted and tested at the time. Those SHA values were not replaced
with rewritten SHA values. The commit map provides traceability only; it does
not migrate physical-test credit.

The active ADR-0012 Level-3 stability evidence window was reset after the
rewrite. Pre-rewrite evidence remains a historical record and contributes zero
cycles to the new post-rewrite candidate window unless a separate ADR approves
continuity.

## GitHub and signatures

The rewritten branch and tag refs were force-updated after the required
protection rules were temporarily disabled, and all changed rulesets were
restored to their exact pre-rewrite configuration. Existing GitHub-generated
commit signatures and Verified state were invalidated by the rewrite and were
not fabricated or reproduced.

GitHub historical surfaces outside writable branch and tag refs may continue to
expose old commit objects or the historical name, including merged pull-request
refs and snapshots, old workflow runs, comments containing SHAs, cached
contributor data, and old unreachable commit URLs. Those surfaces are not
rewritten by this record.
