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


def entry(n, ts="2026-08-26T01:00:00"):
    return f"{ts} handoff transition localActive -> edgeArmed reason=edgeEntered sequence={n}"


def remote(n, ts="2026-08-26T01:00:01"):
    return f"{ts} handoff transition edgeArmed -> remoteActive reason=edgeEntered sequence={n}"


def returning(n, reason, ts="2026-08-26T01:00:02"):
    return f"{ts} handoff transition remoteActive -> returning reason={reason} sequence={n}"


def local(n, reason, ts="2026-08-26T01:00:03"):
    return f"{ts} handoff transition returning -> localActive reason={reason} sequence={n}"


def clean_cycle(seq):
    return [entry(seq), remote(seq + 1), returning(seq + 2, "boundaryCrossed"),
            local(seq + 3, "boundaryCrossed")]


def run_case(name, lines, required=100, expect_status=None, expect_exit=None,
             extra_checks=None):
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
        fh.write("\n".join(lines) + "\n")
        path = fh.name
    proc = subprocess.run(
        [sys.executable, ANALYZER, path, "--required", str(required)],
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

    # same unclosed session but with the returning leg present: INCOMPLETE
    lines = [IDENT] + clean_cycle(0) + [entry(10), remote(11),
                                        returning(12, "boundaryCrossed")]
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
        entry(10), remote(11), returning(12, "remoteUnavailable"),
        local(13, "remoteUnavailable")]
    check(run_case("fail_unexplained_remote_unavailable", lines, 1, "FAIL", 1,
                   lambda r: r["counters"]["remoteUnavailable_total"] == 1))

    # environmental transport failure (captureStopped = capture lifecycle end,
    # e.g. ADB loss) stays classified and does not become a product failure
    lines = [IDENT]
    for i in range(5):
        lines += clean_cycle(i * 4)
    lines += [entry(30), remote(31), returning(32, "captureStopped")]
    check(run_case("environmental_not_fail", lines, 5, "PASS", 0,
                   lambda r: r["counters"]["transport_session_failures_environmental"] == 1))

    # external takeover classified
    lines = [IDENT] + clean_cycle(0) + [
        entry(10), remote(11), returning(12, "externalControlTakeover")]
    check(run_case("external_takeover_classified", lines, 100, "INCOMPLETE", 0,
                   lambda r: r["counters"]["external_takeovers"] == 1))

    # HOLD: UNCLASSIFIED event (unknown transition line)
    lines = [IDENT] + clean_cycle(0) + [
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

    # malformed input fails closed (binary garbage)
    with tempfile.NamedTemporaryFile("wb", suffix=".log", delete=False) as fh:
        fh.write(b"\xff\xfe\x00\x01garbage\xff")
        bad = fh.name
    proc = subprocess.run([sys.executable, ANALYZER, bad],
                          capture_output=True, text=True)
    try:
        result = json.loads(proc.stdout)
        check(result["STABILITY_GATE"] in ("HOLD",) or proc.returncode == 2)
        if result["STABILITY_GATE"] == "HOLD":
            print("ok   malformed_input_fails_closed -> HOLD/INPUT_ERROR")
    except json.JSONDecodeError:
        # analyzer may emit INPUT_ERROR JSON; anything else is failure
        print("FAIL malformed_input: unparsable output")
        failed += 1
    else:
        passed += 1
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
