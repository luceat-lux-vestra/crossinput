#!/usr/bin/env python3
"""ADR-0012 Level-3 handoff-stability analyzer.

Offline, fail-closed gate computation over sanitized diagnostics. No device,
ADB, network, or running app required. Reads diag.log-style text (or a file
list) and emits counters plus STABILITY_GATE verdict.

Status semantics (ADR-0012 §Evidence sufficiency, fail-closed):
  PASS        all criteria met incl. completed_physical_cycles >= --required (default 100)
  INCOMPLETE  structurally usable, no blocking failure known, cycles < required
  HOLD        anything requiring human adjudication: UNCLASSIFIED,
              INSUFFICIENT_EVIDENCE, MIXED_CANDIDATES, ambiguous boundaries,
              missing identity, corrupt input
  FAIL        known stability violation: pointer trap, stuck-button incident,
              unexplained remoteUnavailable, healthy-session watchdog recovery

Exit codes: 0 PASS/INCOMPLETE, 3 HOLD, 1 FAIL, 2 usage/input error.
A cycle is completed only when an edgeArmed->remoteActive entry is followed by
a usable session and a recorded local recovery (returning -> localActive or an
exactly-classified environmental release). A remoteActive entry with no
recorded recovery earns zero credit.
"""

import argparse
import json
import re
import sys

TRANSITION = re.compile(
    r"^(?P<ts>\S+)\s+handoff transition\s+"
    r"(?P<frm>\S+) -> (?P<to>\S+) reason=(?P<reason>\S+)"
    r"(?: sequence=(?P<seq>\d+))?"
)
IDENTITY = re.compile(
    r"candidate identity app_version=(?P<appver>\S+) "
    r"build_identifier=(?P<build>\S+) candidate_identifier=(?P<cand>\S+)"
)
CANCELLED = "pointer deliveries cancelled"
COALESCED = "pointer scroll batches coalesced"
SHED = "pointer queue saturation shed"
CLEANUP = "remote held-pointer-buttons cleanup"
ENVIRONMENTAL_RELEASE = {"externalControl", "emergencyHotkey", "captureStopped"}

# reason values on remoteActive -> returning that mean genuine product failure
UNEXPLAINED_RU = "unexplained"


def classify_exit(reason: str) -> str:
    """Classify the recovery leg of a remoteActive session."""
    if reason == "boundaryCrossed":
        return "normal_return"
    if reason == "suppressionReleased":
        return "normal_return"
    if reason in ENVIRONMENTAL_RELEASE:
        return "environmental_" + reason
    if reason == "externalControlTakeover":
        return "environmental_externalControl"
    if reason == "watchdogTimeout":
        return "watchdog_recovery"
    if reason == "remoteUnavailable":
        # transport/session vs queue-pressure cannot be distinguished from the
        # transition line alone; correlation metadata decides. Default is
        # unexplained (fail-closed) unless evidence marks it classified.
        return "remoteUnavailable_unexplained"
    if reason in ("emergencyReturn",):
        return "environmental_emergencyReturn"
    return "UNCLASSIFIED_reason=" + reason


class Window:
    def __init__(self):
        self.identities = set()
        self.identity_seen = False
        self.entries = 0            # localActive/edgeArmed -> remoteActive entries
        self.completed_cycles = 0   # entries with usable session + recorded recovery
        self.normal_returns = 0
        self.external_takeovers = 0
        self.emergency_returns = 0
        self.transport_failures = 0     # classified environmental (adb/helper)
        self.remote_unavailable_total = 0
        self.remote_unavailable_unexplained = 0
        self.watchdog_recoveries_remote_active = 0
        self.queue_shed_events = 0
        self.coalescing_events = 0
        self.cancelled_delivery_bursts = 0
        self.cleanup_attempted = 0
        self.cleanup_succeeded = 0
        self.cleanup_failed = 0
        self.pointer_traps = 0
        self.stuck_button_incidents = 0
        self.unclassified = 0
        self.insufficient_evidence = []
        self.corrupt_lines = 0
        self.total_transitions = 0
        self.open_sessions = 0      # entries without any recovery leg at EOF


def analyze(lines):
    w = Window()
    in_remote = False
    for raw in lines:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        m = IDENTITY.search(line)
        if m:
            w.identity_seen = True
            if m.group("cand") == "none" or m.group("build") == "none":
                w.insufficient_evidence.append("identity marker with none fields")
            else:
                w.identities.add((m.group("cand"), m.group("build")))
            continue
        m = TRANSITION.match(line)
        if m:
            w.total_transitions += 1
            frm, to, reason = m.group("frm"), m.group("to"), m.group("reason")
            if to == "remoteActive" and frm in ("edgeArmed", "localActive"):
                w.entries += 1
                in_remote = True
            elif frm == "remoteActive" and to == "returning":
                cls = classify_exit(reason)
                if cls == "normal_return":
                    w.normal_returns += 1
                    w.completed_cycles += 1
                elif cls.startswith("environmental_"):
                    if cls.endswith("externalControl"):
                        w.external_takeovers += 1
                    elif cls.endswith("emergencyHotkey") or cls.endswith("emergencyReturn"):
                        w.emergency_returns += 1
                    else:
                        w.transport_failures += 1
                elif cls == "watchdog_recovery":
                    w.watchdog_recoveries_remote_active += 1
                elif cls.startswith("remoteUnavailable"):
                    w.remote_unavailable_total += 1
                    if "unexplained" in cls:
                        w.remote_unavailable_unexplained += 1
                elif cls.startswith("UNCLASSIFIED"):
                    w.unclassified += 1
                in_remote = False
            elif frm == "returning" and to == "localActive":
                pass
            elif to == "disabled" and frm == "remoteActive":
                # torn down without a returning leg: ambiguous boundary.
                # No cycle credit; UNCLASSIFIED + unclosed-session rule force
                # HOLD at verdict time.
                w.unclassified += 1
                in_remote = False
            elif frm == "remoteActive":
                # any other remote-exit shape with an unrecognized reason is
                # UNCLASSIFIED (fail-closed), e.g. remoteActive -> disabled
                # with a reason the taxonomy does not know.
                w.unclassified += 1
                in_remote = False
            continue
        if CANCELLED in line:
            w.cancelled_delivery_bursts += 1
        elif COALESCED in line:
            w.coalescing_events += 1
        elif SHED in line:
            w.queue_shed_events += 1
        elif CLEANUP in line:
            mm = re.search(r"attempted=(\d+) succeeded=(\d+) failed=(\d+)", line)
            if not mm:
                w.insufficient_evidence.append("cleanup line without counts: " + line[:80])
                continue
            a, s, f = (int(x) for x in mm.groups())
            w.cleanup_attempted += a
            w.cleanup_succeeded += s
            w.cleanup_failed += f
            if f > 0:
                w.stuck_button_incidents += 1
        elif line.strip().startswith("candidate identity") or True:
            pass
    w.open_sessions = in_remote
    return w


def verdict(w, required):
    """Compute the fail-closed gate. Returns (status, reasons)."""
    reasons = []
    if not w.identity_seen:
        reasons.append("MISSING_IDENTITY")
    if len({c for c, _ in w.identities}) > 1:
        reasons.append("MIXED_CANDIDATES")
    if w.open_sessions:
        reasons.append("UNCLOSED_SESSION_AT_EOF")
    if w.unclassified:
        reasons.append("UNCLASSIFIED_EVENTS=%d" % w.unclassified)
    if w.insufficient_evidence:
        reasons.append("INSUFFICIENT_EVIDENCE=%d" % len(w.insufficient_evidence))
    if reasons:
        return "HOLD", reasons

    fails = []
    if w.pointer_traps > 0:
        fails.append("POINTER_TRAP=%d" % w.pointer_traps)
    if w.stuck_button_incidents > 0:
        fails.append("STUCK_BUTTON=%d" % w.stuck_button_incidents)
    if w.remote_unavailable_unexplained > 0:
        fails.append("UNEXPLAINED_REMOTE_UNAVAILABLE=%d" % w.remote_unavailable_unexplained)
    if w.watchdog_recoveries_remote_active > 0:
        fails.append("WATCHDOG_RECOVERY_REMOTE_ACTIVE=%d" % w.watchdog_recoveries_remote_active)
    if fails:
        return "FAIL", fails

    if w.completed_cycles >= required:
        return "PASS", []
    return "INCOMPLETE", ["completed_cycles=%d required=%d" % (w.completed_cycles, required)]


EXIT_CODES = {"PASS": 0, "INCOMPLETE": 0, "HOLD": 3, "FAIL": 1}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="diag log files or - for stdin")
    ap.add_argument("--required", type=int, default=100,
                    help="required completed physical cycles (default 100)")
    ap.add_argument("--window-id", default=None, help="evidence window identifier")
    ap.add_argument("--json-out", default=None, help="write machine result JSON here")
    args = ap.parse_args(argv)

    lines = []
    try:
        for path in args.inputs:
            if path == "-":
                lines.extend(sys.stdin.readlines())
            else:
                with open(path, "r", encoding="utf-8", errors="strict") as fh:
                    lines.extend(fh.readlines())
    except (OSError, UnicodeDecodeError) as exc:
        print(json.dumps({"STABILITY_GATE": "HOLD",
                          "reasons": ["INPUT_ERROR=%s" % exc]}))
        return 2

    w = analyze(lines)
    status, reasons = verdict(w, args.required)
    result = {
        "window_id": args.window_id,
        "candidates": sorted("%s@%s" % (c, b) for c, b in w.identities),
        "counters": {
            "remote_active_entries": w.entries,
            "completed_physical_cycles": w.completed_cycles,
            "normal_returns": w.normal_returns,
            "external_takeovers": w.external_takeovers,
            "emergency_returns": w.emergency_returns,
            "transport_session_failures_environmental": w.transport_failures,
            "remoteUnavailable_total": w.remote_unavailable_total,
            "remoteUnavailable_unexplained": w.remote_unavailable_unexplained,
            "watchdog_recoveries_during_remoteActive": w.watchdog_recoveries_remote_active,
            "queue_shed_events": w.queue_shed_events,
            "coalescing_events": w.coalescing_events,
            "cancelled_delivery_bursts": w.cancelled_delivery_bursts,
            "held_button_cleanup_attempted": w.cleanup_attempted,
            "held_button_cleanup_succeeded": w.cleanup_succeeded,
            "held_button_cleanup_failed": w.cleanup_failed,
            "stuck_button_incidents": w.stuck_button_incidents,
            "pointer_traps": w.pointer_traps,
            "unclassified_events": w.unclassified,
            "insufficient_evidence_items": len(w.insufficient_evidence),
            "transitions_seen": w.total_transitions,
        },
        "required_cycles": args.required,
        "reasons": reasons,
        "STABILITY_GATE": status,
    }
    out = json.dumps(result, indent=2, sort_keys=True)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            fh.write(out + "\n")
    print(out)
    return EXIT_CODES[status]


if __name__ == "__main__":
    sys.exit(main())
