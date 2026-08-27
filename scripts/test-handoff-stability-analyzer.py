#!/usr/bin/env python3
"""Regression fixtures for scripts/lib/handoff_stability.py.

Covers every ADR-0012 gate state and the fail-closed rules. Run:
    python3 scripts/test-handoff-stability-analyzer.py
Exit 0 = all fixtures pass.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZER = os.path.join(HERE, "lib", "handoff_stability.py")

IDENT = ("candidate identity app_version=0.1.0 build_identifier=B1 "
         "candidate_identifier=aaaa1111")
ts_default = "2026-08-26T01:00:01.500"
REPORT_LINE = f"{ts_default} helper: [HidDeviceManager] report sent id=2 len=5 written=11"
SEMANTIC_CONFIRMED_LINE = f"{ts_default} handoff usable-session confirmed"


def entry(n, ts="2026-08-26T01:00:00"):
    return f"{ts} handoff transition localActive -> edgeArmed reason=edgeEntered sequence={n}"


def remote(n, ts="2026-08-26T01:00:01"):
    return f"{ts} handoff transition edgeArmed -> remoteActive reason=edgeEntered sequence={n}"


def returning(n, reason, ts="2026-08-26T01:00:02"):
    return f"{ts} handoff transition remoteActive -> returning reason={reason} sequence={n}"


def local(n, reason, ts="2026-08-26T01:00:03"):
    return f"{ts} handoff transition returning -> localActive reason={reason} sequence={n}"


def clean_cycle(seq, ts="2026-08-26T01:00:00"):
    """Contract-complete cycle: entry, usable-session evidence (confirmed
    helper delivery), returning, localActive."""
    return [
        f"{ts} handoff transition localActive -> edgeArmed reason=edgeEntered sequence={seq}",
        f"{ts} handoff transition edgeArmed -> remoteActive reason=edgeEntered sequence={seq + 1}",
        f"{ts} helper: [HidDeviceManager] report sent id=2 len=5 written=11",
        f"{ts} handoff transition remoteActive -> returning reason=boundaryCrossed sequence={seq + 2}",
        f"{ts} handoff transition returning -> localActive reason=boundaryCrossed sequence={seq + 3}",
    ]


def run_case(name, lines, _unused_required=None, expect_status=None,
             expect_exit=None, extra_checks=None):
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
        fh.write("\n".join(lines) + "\n")
        path = fh.name
    proc = subprocess.run(
        [sys.executable, ANALYZER, path],
        capture_output=True, text=True)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        print(f"FAIL {name}: non-JSON output: {proc.stdout[:200]} {proc.stderr[:200]}")
        return False
    status = result["STABILITY_GATE"]
    ok = True
    if expect_status and status != expect_status:
        print(f"FAIL {name}: expected {expect_status}, got {status} ({result['reasons']})")
        ok = False
    if expect_exit is not None and proc.returncode != expect_exit:
        print(f"FAIL {name}: expected exit {expect_exit}, got {proc.returncode}")
        ok = False
    if extra_checks and not extra_checks(result):
        print(f"FAIL {name}: extra checks failed on {result['counters']}")
        ok = False
    if ok:
        print(f"ok   {name} -> {status} exit={proc.returncode}")
    os.unlink(path)
    return ok


def main():
    passed = 0
    failed = 0

    def check(ok):
        nonlocal passed, failed
        if ok:
            passed += 1
        else:
            failed += 1
    # INCOMPLETE: fewer than 100 clean cycles
    lines = [IDENT]
    for i in range(36):
        lines += clean_cycle(i * 4)
    check(run_case("incomplete_36_cycles", lines, 100, "INCOMPLETE", 0,
                   lambda r: r["counters"]["completed_physical_cycles"] == 36))

    # raw remoteActive without recovery earns no credit; an unclosed session
    # at EOF is a HOLD condition (fail-closed boundary ambiguity)
    lines = [IDENT] + clean_cycle(0) + [entry(10), remote(11)]
    check(run_case("no_credit_without_recovery", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 1
                   and r["counters"]["remote_active_entries"] == 2))

    # second session fully contract-complete (report + localActive): credited
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        returning(12, "boundaryCrossed"),
        local(13, "boundaryCrossed", ts="2026-08-26T01:00:13")]
    check(run_case("credit_with_recovery", lines, 100, "INCOMPLETE", 0,
                   lambda r: r["counters"]["completed_physical_cycles"] == 2))
    lines = [IDENT]
    for i in range(100):
        lines += clean_cycle(i * 4)
    check(run_case("pass_exactly_100", lines, 100, "PASS", 0))

    # PASS: >100 clean cycles
    lines = [IDENT]
    for i in range(101):
        lines += clean_cycle(i * 4)
    check(run_case("pass_over_100", lines, 100, "PASS", 0))

    # FAIL: unexplained remoteUnavailable
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE, returning(12, "remoteUnavailable"),
        local(13, "remoteUnavailable")]
    check(run_case("fail_unexplained_remote_unavailable", lines, 1, "FAIL", 1,
                   lambda r: r["counters"]["remoteUnavailable_total"] == 1))

    # App disable during remoteActive (production path: remoteActive ->
    # disabled reason=deactivated) is an exactly-classified environmental
    # event per ADR-0012 — not unclassified, not a product failure.
    lines = [IDENT]
    for i in range(5):
        lines += clean_cycle(i * 4)
    lines += [
        entry(30), remote(31), REPORT_LINE,
        "2026-08-26T01:00:32 handoff transition remoteActive -> disabled "
        "reason=deactivated sequence=32",
    ]
    check(run_case("environmental_app_disable_not_fail", lines, None,
                   "INCOMPLETE", 0,
                   lambda r: r["counters"]["transport_session_failures_environmental"] == 1
                   and r["counters"]["unclassified_events"] == 0))

    # external takeover classified
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        "2026-08-26T01:00:12 handoff transition remoteActive -> disabled "
        "reason=externalControlTakeover sequence=13"]
    check(run_case("external_takeover_classified", lines, None,
                   "INCOMPLETE", 0,
                   lambda r: r["counters"]["external_takeovers"] == 1
                   and r["counters"]["unclassified_events"] == 0))

    # HOLD: unknown reason on remote exit is an unclassified control event
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        "2026-08-26T01:00:09 handoff transition remoteActive -> disabled reason=somethingWeird"]
    check(run_case("hold_unclassified", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["unclassified_events"] >= 1))

    # HOLD: missing identity marker entirely
    lines = clean_cycle(0)
    check(run_case("hold_missing_identity", lines, 1, "HOLD", 3))

    # HOLD: mixed candidates in one window
    lines = [IDENT,
             "candidate identity app_version=0.1.0 build_identifier=B2 candidate_identifier=bbbb2222"]
    lines += clean_cycle(0)
    check(run_case("hold_mixed_candidates", lines, 1, "HOLD", 3,
                   lambda r: len(r["candidates"]) == 2))

    # FAIL: stuck button via cleanup failure counts
    lines = [IDENT] + clean_cycle(0) + [
        "2026-08-26T01:00:05 remote held-pointer-buttons cleanup attempted=2 succeeded=1 failed=1"]
    check(run_case("fail_stuck_button", lines, 1, "FAIL", 1,
                   lambda r: r["counters"]["stuck_button_incidents"] == 1))

    # watchdog recovery during remoteActive is a FAIL condition per gate
    lines = [IDENT] + clean_cycle(0) + [
        entry(20), remote(21), returning(22, "watchdogTimeout")]
    check(run_case("watchdog_recovery_recorded", lines, 100, None, None,
                   lambda r: r["counters"]["watchdog_recoveries_during_remoteActive"] == 1))

    # ---- review P0/P1/P2 regressions ----

    # 100 entries that return immediately with NO usable-session evidence:
    # zero credit, and trap status undeterminable -> HOLD (fail closed)
    lines = [IDENT]
    for i in range(100):
        s = i * 4
        lines += [
            entry(s), remote(s + 1),
            returning(s + 2, "boundaryCrossed"),
            local(s + 3, "boundaryCrossed"),
        ]
    check(run_case("no_usable_session_no_pass", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 0))

    # returning leg but local recovery leg missing at EOF: no credit, HOLD
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        returning(12, "boundaryCrossed")]  # no local(13)
    check(run_case("missing_local_active_holds", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 1
                   and r["counters"]["insufficient_evidence_items"] >= 1))

    # 99 contract-complete cycles: INCOMPLETE (below threshold)
    lines = [IDENT]
    for i in range(99):
        lines += clean_cycle(i * 4)
    check(run_case("incomplete_99_clean_cycles", lines, 100, "INCOMPLETE", 0,
                   lambda r: r["counters"]["completed_physical_cycles"] == 99))

    # same candidate SHA, DIFFERENT build identifiers: MIXED_BUILD_IDENTITIES
    lines = [
        IDENT,
        ("candidate identity app_version=0.1.0 build_identifier=B2 "
         "candidate_identifier=aaaa1111"),
    ] + clean_cycle(0)
    check(run_case("mixed_build_same_candidate_holds", lines, 1, "HOLD", 3,
                   lambda r: len(r["candidates"]) == 2))

    # invalid app_version in the identity marker: fail closed
    lines = [("candidate identity app_version=unknown build_identifier=B1 "
              "candidate_identifier=aaaa1111")] + clean_cycle(0)
    check(run_case("invalid_app_version_holds", lines, 1, "HOLD", 3,
                   lambda r: r["counters"]["insufficient_evidence_items"] >= 1))

    # pointer-trap evidence: session entered, deliveries flowed, only exit is
    # a healthy-delivery watchdogTimeout, never returned -> trap suspected
    trap_lines = [IDENT]
    for i in range(3):
        trap_lines += clean_cycle(i * 4)
    trap_lines += [
        entry(30), remote(31), REPORT_LINE,
        returning(32, "watchdogTimeout"),
        local(33, "watchdogTimeout", ts="2026-08-26T01:00:33"),
    ]
    check(run_case("pointer_trap_evidence_fails", trap_lines, 3, "FAIL", 1,
                   lambda r: r["counters"]["pointer_traps"] == 1
                   and r["counters"]["watchdog_recoveries_during_remoteActive"] == 1))

    # ---- review round-2 P0/P1 regressions ----

    def REPORT(seq_ts):
        return f"{seq_ts} helper: [HidDeviceManager] report sent id=2 len=5 written=11"

    # sequence regression: localActive seq < returning seq must NOT credit
    lines = [IDENT,
             entry(10), remote(11), REPORT("2026-08-26T01:00:01.500"),
             returning(20, "boundaryCrossed"),
             local(5, "boundaryCrossed")]
    check(run_case("sequence_regression_no_credit", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 0
                   and any("sequence" in s for s in r.get("insufficient_evidence_detail", []))))

    # missing sequence numbers anywhere in the cycle -> no credit, HOLD
    lines = [IDENT,
             "2026-08-26T01:00:00 handoff transition localActive -> edgeArmed reason=edgeEntered",
             "2026-08-26T01:00:01 handoff transition edgeArmed -> remoteActive reason=edgeEntered",
             REPORT("2026-08-26T01:00:01.500"),
             returning(2, "boundaryCrossed"),
             local(3, "boundaryCrossed")]
    check(run_case("missing_sequences_no_credit", lines, 100, "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 0))

    # environmental remoteUnavailable WITH production correlation line:
    # classified, not FAIL, not credit
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        "2026-08-26T01:00:12 remote unavailable: helper session ended",
        returning(12, "remoteUnavailable"),
        local(13, "remoteUnavailable")]
    check(run_case("correlated_transport_failure_not_fail", lines, None,
                   "INCOMPLETE", 0,
                   lambda r: r["counters"]["transport_session_failures_environmental"] == 1
                   and r["counters"]["remoteUnavailable_unexplained"] == 0
                   and r["counters"]["completed_physical_cycles"] == 1))

    # unexplained remoteUnavailable WITHOUT correlation line still FAILs
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), REPORT_LINE,
        returning(12, "remoteUnavailable"),
        local(13, "remoteUnavailable")]
    check(run_case("uncorrelated_remote_unavailable_fails", lines, 1, "FAIL", 1,
                   lambda r: r["counters"]["remoteUnavailable_unexplained"] == 1))

    # Backend-neutral semantic delivery evidence: the Mac app logs this line
    # on the first confirmed acceptance per session, regardless of whether
    # the UHID or InputManager backend served it. (Backend *selection* alone
    # is NOT evidence — selection happens at connect time, before sessions.)
    lines = [IDENT,
             entry(10), remote(11),
             SEMANTIC_CONFIRMED_LINE,
             returning(12, "boundaryCrossed"),
             local(13, "boundaryCrossed")]
    check(run_case("input_manager_semantic_delivery_credited", lines, None,
                   "INCOMPLETE", 0,
                   lambda r: r["counters"]["completed_physical_cycles"] == 1))

    # Backend *selection* without confirmed delivery is NOT usable-session
    # evidence -> no credit, HOLD.
    lines = [IDENT,
             entry(10), remote(11),
             "helper log: pointer backend selected backend=input-manager mode=auto",
             returning(12, "boundaryCrossed"),
             local(13, "boundaryCrossed")]
    check(run_case("backend_selection_alone_not_evidence", lines, None,
                   "HOLD", 3,
                   lambda r: r["counters"]["completed_physical_cycles"] == 0))

    # dirty candidate identifier => HOLD (not reproducible provenance)
    lines = [("candidate identity app_version=0.1.0 build_identifier=B1 "
              "candidate_identifier=aaaa1111-dirty")] + clean_cycle(0)
    check(run_case("dirty_candidate_holds", lines, 1, "HOLD", 3,
                   lambda r: len(r["reasons"]) > 0 and any(
                       "DIRTY" in x for x in r["reasons"])))

    # ---- lineage manifest regressions (review round-3 P0/P1) ----
    #
    # build_identifier is a per-package UTC timestamp, so evidence collected
    # across two packages of the SAME lineage always carries different builds.
    # The mixed-build check is therefore scoped PER CANDIDATE: A@B1 + B@B2
    # inside one audited lineage must accumulate (docs-only and CI-only
    # commits do not reset the window per ADR-0012), while the same exact SHA
    # rebuilt twice, or two distinct lineages, must HOLD.

    def run_with_manifest(name, manifest_doc, lines, expect_status,
                          expect_exit, extra=None):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as mf:
            mf.write(json.dumps(manifest_doc))
            manifest = mf.name
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as lf:
            lf.write("\n".join(lines) + "\n")
            lpath = lf.name
        proc = subprocess.run([sys.executable, ANALYZER,
                               "--lineage-manifest", manifest, lpath],
                              capture_output=True, text=True)
        os.unlink(lpath)
        os.unlink(manifest)
        try:
            result = json.loads(proc.stdout)
        except json.JSONDecodeError:
            print(f"FAIL {name}: non-JSON output: {proc.stdout[:200]} {proc.stderr[:200]}")
            return False
        ok = (result["STABILITY_GATE"] == expect_status
              and proc.returncode == expect_exit
              and (extra is None or extra(result)))
        if not ok:
            print(f"FAIL {name}: expected {expect_status}/exit {expect_exit}, "
                  f"got {result['STABILITY_GATE']}/exit {proc.returncode} "
                  f"reasons={result['reasons']}")
        else:
            print(f"ok   {name} -> {result['STABILITY_GATE']} exit={proc.returncode}")
        return ok

    audited_lineage = {
        "lineages": [{
            "lineage_id": "lineage-A",
            "candidates": ["aaaa1111", "bbbb2222"],
            "classification": "no-reset",
            "reason": "docs-only and CI-only commits do not reset the window",
            "reference": "docs/testing.md (ADR-0012)",
        }]
    }
    two_shas = [IDENT,
                ("candidate identity app_version=0.1.0 build_identifier=B2 "
                 "candidate_identifier=bbbb2222")]

    # Regression the review flagged: the old fixture used the PRE-schema
    # manifest, tripped MANIFEST_SCHEMA, and "passed" because the assertion
    # ignored every reason except MIXED_CANDIDATES. The real case now is
    # 2 SHAs, 2 build identifiers, an audited same-lineage manifest, and 99
    # clean cycles: the window accumulates -> INCOMPLETE, exit 0, no MIXED_*.
    lines = list(two_shas)
    for i in range(99):
        lines += clean_cycle(i * 4)
    check(run_with_manifest(
        "lineage_same_lineage_two_builds_incomplete", audited_lineage,
        lines, "INCOMPLETE", 0,
        extra=lambda r: r["counters"]["completed_physical_cycles"] == 99
        and not any(x.startswith("MIXED_") for x in r["reasons"])))

    # two distinct audited lineages in one window: MIXED_CANDIDATES HOLD
    two_lineages = {
        "lineages": [
            {"lineage_id": "lineage-A", "candidates": ["aaaa1111"],
             "classification": "initial",
             "reason": "first audited candidate", "reference": "ADR-0012"},
            {"lineage_id": "lineage-B", "candidates": ["bbbb2222"],
             "classification": "initial",
             "reason": "second audited candidate", "reference": "ADR-0012"},
        ]
    }
    check(run_with_manifest(
        "lineage_two_lineages_hold", two_lineages,
        two_shas + clean_cycle(0), "HOLD", 3,
        extra=lambda r: any(x.startswith("MIXED_CANDIDATES")
                            for x in r["reasons"])))

    # the same exact candidate rebuilt at two build timestamps: per-candidate
    # MIXED_BUILD_IDENTITIES HOLD even inside one audited lineage
    rebuilt = [IDENT,
               ("candidate identity app_version=0.1.0 build_identifier=B2 "
                "candidate_identifier=aaaa1111")]
    check(run_with_manifest(
        "lineage_same_candidate_rebuilt_holds", audited_lineage,
        rebuilt + clean_cycle(0), "HOLD", 3,
        extra=lambda r: any(x.startswith("MIXED_BUILD_IDENTITIES")
                            for x in r["reasons"])))

    # pre-schema manifest (plain sha->lineage dict) is valid JSON but not an
    # audited lineage document: MANIFEST_SCHEMA HOLD at exit 3, never a
    # silent pass that looks like lineage approval
    check(run_with_manifest(
        "lineage_old_schema_manifest_holds",
        {"aaaa1111": "lineage-A", "bbbb2222": "lineage-A"},
        two_shas + clean_cycle(0), "HOLD", 3,
        extra=lambda r: any(x.startswith("MANIFEST_SCHEMA")
                            for x in r["reasons"])))

    # malformed input fails closed (binary garbage)
    with tempfile.NamedTemporaryFile("wb", suffix=".log", delete=False) as fh:
        fh.write(b"\xff\xfe\x00\x01garbage\xff")
        bad = fh.name
    proc = subprocess.run([sys.executable, ANALYZER, bad],
                          capture_output=True, text=True)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        # analyzer may emit INPUT_ERROR JSON; anything else is failure
        print("FAIL malformed_input: unparsable output")
        check(False)
    else:
        ok = result["STABILITY_GATE"] in ("HOLD",) or proc.returncode == 2
        check(ok)
        if ok:
            print("ok   malformed_input_fails_closed -> HOLD/INPUT_ERROR")
        else:
            print(f"FAIL malformed_input: got {result['STABILITY_GATE']}"
                  f"/exit {proc.returncode}")
    os.unlink(bad)

    # privacy: payload-looking lines are simply not echoed into output
    secret_line = "user typed hunter2 somewhere"
    lines = [IDENT] + clean_cycle(0) + [secret_line]
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
        fh.write("\n".join(lines) + "\n")
        p = fh.name
    proc = subprocess.run([sys.executable, ANALYZER, p], capture_output=True, text=True)
    leaked = "hunter2" in proc.stdout
    check(not leaked)
    if not leaked:
        print("ok   privacy_no_payload_echo")
    os.unlink(p)

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
