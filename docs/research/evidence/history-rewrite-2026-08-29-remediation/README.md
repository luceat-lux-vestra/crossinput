# Git history identity remediation — 2026-08-29

## Purpose

This follow-up remediation canonicalizes a second historical identity that
was incorrectly attributed to the GitHub `@algorist` / Chris Walters account:

```text
algorist <algorist@users.noreply.github.com>
```

The canonical identity is:

```text
luceat-lux-vestra <heathkimdev@gmail.com>
```

The exact identity was changed in reachable commit author, committer, and
annotated-tag-tagger fields when present. The exact matching trailer was also
changed:

```text
Co-authored-by: algorist <algorist@users.noreply.github.com>
```

became:

```text
Co-authored-by: luceat-lux-vestra <heathkimdev@gmail.com>
```

No blanket `algorist` replacement was used. No other identity, bot, source
file, documentation meaning, historical evidence claim, or physical-evidence
SHA was rewritten.

## Rewrite record

- Pre-remediation `main`: `76ad69fd038a22f289f270c58b2749c3ef6f9200`
- Rewritten `main` before this provenance record: `1fc4db15f4e5d019812eb51833fe5afb1edbc73c`
- Date: 2026-08-29
- Git: `2.50.1`
- `git-filter-repo`: `2.47.0`
- Command class: one `git filter-repo --preserve-commit-hashes` operation
  using an external exact mailmap and an exact `Co-authored-by:` message
  callback.
- The rewrite mapped 292 commit objects. The five ordinary refs (four
  branches and `v0.1.0`) remained present, with 74 ordinary reachable commit
  objects and zero tree, parent, identity, message, tagger, or ref-validation
  mismatches.
- `v0.1.0` changed from `cdbfd3765c573fdc60b8525f55f13f926cc1a85c` to
  `5fe9ff634450a58cc719b2b40511b0cee59bef50` in this remediation. The GitHub
  release remains associated with the valid `v0.1.0` tag.

The rewrite changed Git object identity only. Mapped old/new commits have
equal tree SHAs, so existing source files, behavior, architecture, tests,
documentation semantics, and historical evidence file contents were not
changed by this remediation. The subsequent provenance record adds only the
files in this directory.

## Provenance and mapping chain

- `commit-map.txt` is the independent old-to-new map produced by this
  remediation.
- `mapping-chain.tsv` links the first rewrite map to this remediation. It has
  223 rows: 75 rows compose `original -> first rewrite -> remediation` for
  objects retained in the current branch/tag lineage. The other 148 rows are
  explicitly marked as direct `original -> remediation` mappings because
  GitHub-managed `refs/pull/*` were not force-pushed during the first rewrite;
  their first-rewrite objects were not present in this remediation snapshot.
  The first map remains preserved in
  `../history-rewrite-2026-08-29/commit-map.txt` and is not overwritten.
- `pre-remediation-refs.txt` records the complete frozen ref set used for
  rollback and coverage checks.
- Only ordinary `refs/heads/*` and `refs/tags/*` were force-updated. No
  `refs/pull/*` or other GitHub-managed ref was pushed.

## Evidence and ADR-0012 treatment

Existing physical-device evidence continues to record the exact candidate
SHAs that were emitted and tested at the time. Those SHA claims were not
replaced with rewritten SHAs. The mapping files provide traceability only and
do not migrate physical-test credit.

The first rewrite had already reset the active ADR-0012 Level-3 window. The
recorded range after that rewrite contained only the first provenance commit
and no new physical Level-3 cycle evidence. This second operation is
metadata-only, so the active window remains fail-closed at zero cycles from
the already-reset state. No continuity credit is claimed.

## GitHub rules and signatures

The `Protect main` and `Protect v release tags` rulesets were temporarily
disabled only for the required non-fast-forward updates, then restored to
their exact saved policy fields. Both are active with no bypass actors.

Rewritten commits cannot retain the original GitHub-generated commit
signatures or Verified state. No signatures were fabricated or reproduced.

GitHub historical surfaces outside writable branch/tag history may continue
to expose old commit objects or names, including merged pull-request refs and
snapshots, old workflow runs, comments containing SHAs, cached contributor
data, and old unreachable commit URLs. Those surfaces were not force-pushed by
this operation. The reachable branch/tag attribution source is validated
separately from such immutable or cached surfaces.
