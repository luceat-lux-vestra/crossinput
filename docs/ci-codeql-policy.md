# CrossInput CodeQL scan scheduling and release publication security

## Decision (2026-10-14)

CodeQL is no longer dispatched by `pull_request` or `push`. Every **scheduled**
(Monday 04:17 UTC) and explicit `workflow_dispatch` run analyzes **all four**
languages: Actions, Java/Kotlin, Python, Swift. Swift retains macOS-15 autobuild;
Android retains Linux ARM64. No security query, source scope, or language was
removed from the **full scan**.

This deliberately changes *detection timing*: pull requests do not receive the
full four-language security scan. Security findings can wait until the next
weekly scan, or until an operator manually initiates a full exact-main SHA scan.
A narrow exception exists for maintenance of the trusted CodeQL runtime itself:
relevant workflow/action-pin changes selectively execute the production-pinned
Actions-language `init` + `analyze` runtime in the existing read-only PR DAG,
with `build-mode: none`, `upload: never`, runner-local SARIF, and explicit
rejection of PR output as production/release evidence. That compatibility probe
is **not** PR-time full CodeQL coverage and does not guarantee the same security
discovery deadline. The required PR Merge Gate validates its seven current
producers, including read-only Dependency Submission validation and Dependency
Review, but it is **not** a substitute for full CodeQL.

## Trusted exact SHA workflow

Run only from protected main using its full 40-character commit:

```shell
SHA="$(gh api repos/luceat-lux-vestra/crossinput/git/ref/heads/main --jq .object.sha)"
gh workflow run codeql.yml -R luceat-lux-vestra/crossinput --ref main -f "candidate_sha=$SHA"
```

Manual and weekly runs require that the event SHA, expected SHA and live protected
main coincide. They preserve one **raw** SARIF artifact per language for 90 days,
and reject corrupt results, missing security severity and High/Critical (7+)
findings through `scripts/release_codeql_verdict.py`. Matrix and run-level success
alone are not sufficient evidence of security acceptance.

## Release safety and limits

Before the repository's *automatic first* `gh release create`, the release
workflow requires all four original SARIF files from a successful trusted
scheduled/manual CodeQL run whose commit SHA is the **exact immutable release
tag target**, and whose source is an ancestor of reviewed main. The security
gate fails closed when evidence is absent, invalid, expired or unacceptable.

The release flow still verifies immutable tag/ref provenance, main ancestry,
version, package smoke, code signature, checksum and DMG attestation before
publication. Already-published releases preserve legitimate legacy
`gh release upload --clobber` recovery, which **does not certify their initial
publication**. An owner can still publish independently through GitHub UI/API;
this workflow cannot prevent or retroactively validate such out-of-band releases.
The previous scan on an older SHA must **never** be treated as the current
release SHA's evidence.

## Performance interpretation

- **required merge-ready latency**: until required Merge Gate passes.
- **all-security-complete latency**: when applicable, independent full CodeQL
  finishes. The selective Actions runtime compatibility probe is not a full
  security-completion event; therefore these metrics remain incomparable with
  historical routine PR scans.
- **runner work/cost**: count actual job execution minutes by OS and billing
  multipliers separately. Historical PR CodeQL duration is not an invoice.
- **security detection delay**: up to the next weekly scan without manual
  intervention, subject to runs being successful; a failed scan extends delay.

Evidence prior to retirement: [#38524071347](https://github.com/luceat-lux-vestra/crossinput/actions/runs/38524071347)
(full 4-language exact-main manual CodeQL, first attempt SUCCESS with four retained
original SARIF artifacts and SARIF-verdict steps successful).
Follow-up issue: [#252](https://github.com/luceat-lux-vestra/crossinput/issues/252);
portfolio coordination: [R2A #93](https://github.com/luceat-lux-vestra/research-to-action/issues/93).
The historical PR language-impact classifier and fixtures remain archived in
`scripts/`, not executed automatically. They are no longer production controls.
