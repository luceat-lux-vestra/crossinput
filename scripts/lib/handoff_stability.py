#!/usr/bin/env python3
"""ADR-0012 Level-3 handoff-stability analyzer.

Offline, fail-closed gate computation over sanitized diagnostics. No device,
ADB, network, or running app required. Reads diag.log-style text and emits
counters plus the STABILITY_GATE verdict.

Cycle contract (ADR-0012): a completed physical cycle requires ALL of
  1. a successful physical remoteActive entry (edgeArmed -> remoteActive),
  2. usable-remote-session evidence while remoteActive (confirmed helper
     deliveries: UHID "report sent ... written=" lines), and
  3. local recovery observed as returning -> localActive.
Credit is granted only at leg 3, only when legs 1 and 2 were both seen for
the same session, and only when the sequence numbers are strictly increasing.
A missing or out-of-order leg is an ambiguous boundary -> HOLD.

Pointer trap: ADR-0012 requires pointer trap = 0 as *evidence*, not as an
assumption. Two diagnostic signatures exist:
  - explicit: suppression held with no recovery until EOF (session never
    returned) -> TRAP_SUSPECTED, or
  - watchdog-based: a remoteActive session whose only exit is a healthy-
    delivery watchdogTimeout (delivery kept flowing yet control never came
    back) is recorded as pointer_trap; per #52's gen-6 signature this is the
    permanent-trap marker.
If a window contains remoteActive sessions but no usable-session evidence at
all (no report lines), trap status cannot be established -> INSUFFICIENT_
EVIDENCE (HOLD), never silently 0.

Status semantics:
  PASS        all criteria incl. completed_physical_cycles >= --required
  INCOMPLETE  structurally clean, cycles < required
  HOLD        adjudication required: UNCLASSIFIED, INSUFFICIENT_EVIDENCE,
              MIXED_CANDIDATES, ambiguous boundaries, missing identity,
              corrupt input
  FAIL        known violation: pointer trap, stuck button, unexplained
              remoteUnavailable, watchdog recovery during remoteActive

Exit codes: 0 PASS/INCOMPLETE, 1 FAIL, 3 HOLD, 2 input error.
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
REPORT_SENT = re.compile(r"report sent .* written=(\d+)")
CANCELLED = "pointer deliveries cancelled"
COALESCED = "pointer scroll batches coalesced"
SHED = "pointer queue saturation shed"
CLEANUP = re.compile(
    r"remote held-pointer-buttons cleanup attempted=(\d+) succeeded=(\d+) failed=(\d+)")

# Production correlation line: when a remoteUnavailable force-return comes from
# an ADB/helper session end, App.swift logs this line immediately beforehand.
# Its presence within the session window classifies the remoteUnavailable as a
# genuine transport/session failure (an ADR-0012 environmental event), NOT an
# unexplained product failure.
REMOTE_UNAVAILABLE_CAUSE = "remote unavailable:"

# Real EdgeSwitchStateMachine TransitionReason values that represent
# exactly-classified environmental exits (ADR-0012 taxonomy).
ENVIRONMENTAL_RELEASE = {"externalControlTakeover", "emergencyReturn",
                         "deactivated"}


class Session:
    """One remoteActive session being reconstructed across its three legs."""

    def __init__(self, seq, ts):
        self.entry_seq = seq
        self.entry_ts = ts
        self.usable_evidence = False      # confirmed helper deliveries seen
        self.transport_cause_logged = False  # "remote unavailable:" seen
        self.returning_seq = None
        self.returning_reason = None


def classify_exit(reason: str) -> str:
    if reason == "boundaryCrossed":
        return "normal_return"
    if reason == "suppressionReleased":
        return "normal_return"
    if reason in ENVIRONMENTAL_RELEASE:
        return "environmental_" + reason
    if reason == "watchdogTimeout":
        return "watchdog_recovery"
    if reason == "remoteUnavailable":
        # transport/session vs queue-pressure cannot be distinguished from the
        # transition line alone; default is unexplained (fail-closed).
        return "remoteUnavailable_unexplained"
    if reason == "emergencyReturn":
        return "environmental_emergencyReturn"
    return "UNCLASSIFIED_reason=" + reason


class Window:
    def __init__(self):
        self.identities = set()           # (candidate, build, app_version)
        self.identity_seen = False
        self.bad_identity_lines = 0       # marker present but fields invalid
        self.entries = 0
        self.completed_cycles = 0
        self.normal_returns = 0
        self.external_takeovers = 0
        self.emergency_returns = 0
        self.transport_failures = 0
        self.remote_unavailable_total = 0
        self.remote_unavailable_unexplained = 0
        self.watchdog_recoveries_remote_active = 0
        self.queue_shed_events = 0
        self.coalescing_events = 0
        self.cancelled_delivery_bursts = 0
        self.cleanup_attempted = 0
        self.cleanup_succeeded = 0
        self.cleanup_failed = 0
        self.pointer_traps = 0            # evidence-derived (see module doc)
        self.stuck_button_incidents = 0
        self.unclassified = 0
        self.insufficient_evidence = []
        self.total_transitions = 0
        self.open_session_at_eof = False


def analyze(lines):
    w = Window()
    session = None          # open Session while remoteActive
    pending_return = None   # (seq, reason) after remoteActive->returning
    saw_any_reports = False

    def close_session_without_recovery(classification=None):
        nonlocal session, pending_return
        if classification == "environmental_deactivated":
            # App disable during remoteActive (ADR-0012 environmental event).
            w.transport_failures += 1
        elif session is not None and pending_return is None:
            # entry with neither returning nor localActive: ambiguous boundary
            w.unclassified += 1
            w.open_session_at_eof = True
        elif pending_return is not None:
            # returning seen but no localActive leg before teardown/EOF:
            # cycle contract incomplete -> HOLD via insufficient evidence
            w.insufficient_evidence.append(
                "session entered at %s returned but no localActive leg" %
                session.entry_ts)
        session = None
        pending_return = None

    for raw in lines:
        line = raw.rstrip("\n")
        if not line.strip():
            continue

        m = IDENTITY.search(line)
        if m:
            w.identity_seen = True
            cand, build, ver = m.group("cand"), m.group("build"), m.group("appver")
            if cand in ("", "none") or build in ("", "none") or ver in ("", "unknown"):
                w.bad_identity_lines += 1
                w.insufficient_evidence.append("invalid identity marker fields")
            else:
                w.identities.add((cand, build, ver))
            continue

        m = TRANSITION.match(line)
        if m:
            w.total_transitions += 1
            frm, to, reason = m.group("frm"), m.group("to"), m.group("reason")
            seq = int(m.group("seq")) if m.group("seq") else None

            if to == "remoteActive" and frm in ("edgeArmed", "localActive"):
                if session is not None or pending_return is not None:
                    # new entry while previous session unresolved
                    close_session_without_recovery()
                session = Session(seq, m.group("ts"))
                w.entries += 1
            elif frm == "remoteActive" and to == "returning":
                if session is None:
                    w.unclassified += 1
                    continue
                cls = classify_exit(reason)
                if cls == "normal_return":
                    w.normal_returns += 1
                elif cls.startswith("environmental_"):
                    if cls.endswith(("externalControl", "externalControlTakeover")):
                        w.external_takeovers += 1
                    elif cls.endswith(("emergencyHotkey", "emergencyReturn")):
                        w.emergency_returns += 1
                    else:
                        w.transport_failures += 1
                elif cls == "watchdog_recovery":
                    w.watchdog_recoveries_remote_active += 1
                    if session.usable_evidence:
                        # #52 gen-6 permanent-trap signature: deliveries kept
                        # flowing yet control never came back on its own.
                        w.pointer_traps += 1
                elif cls.startswith("remoteUnavailable"):
                    w.remote_unavailable_total += 1
                    if "unexplained" in cls:
                        if session.transport_cause_logged:
                            # Correlated with a logged ADB/helper session end:
                            # classified environmental, per PR #66 taxonomy.
                            cls = "environmental_transport_failure"
                            w.transport_failures += 1
                        else:
                            w.remote_unavailable_unexplained += 1
                elif cls.startswith("UNCLASSIFIED"):
                    w.unclassified += 1
                pending_return = (seq, cls)
            elif frm == "returning" and to == "localActive":
                # ---- CYCLE CREDIT LEG: all prior legs must be proven ----
                if pending_return is None or session is None:
                    w.unclassified += 1
                    continue
                ret_seq, cls = pending_return
                # Strict ADR-0012 cycle invariant: all three legs present,
                # all sequences known, and entry < returning < localActive.
                # Any missing/regressed sequence is INSUFFICIENT_EVIDENCE.
                if session.entry_seq is None or ret_seq is None or seq is None:
                    w.insufficient_evidence.append(
                        "cycle legs missing sequence numbers entry=%s "
                        "return=%s local=%s" %
                        (session.entry_seq, ret_seq, seq))
                elif not (session.entry_seq < ret_seq < seq):
                    w.insufficient_evidence.append(
                        "sequence regression within session entry=%s "
                        "return=%s local=%s" %
                        (session.entry_seq, ret_seq, seq))
                elif not session.usable_evidence:
                    w.insufficient_evidence.append(
                        "no usable-session evidence between entry (%s) and "
                        "recovery" % session.entry_ts)
                elif cls != "normal_return":
                    # environmental/watchdog/RU exits are recorded but never
                    # grant completed-cycle credit
                    pass
                else:
                    w.completed_cycles += 1
                session = None
                pending_return = None
            elif frm == "remoteActive" and to in ("disabled", "returning"):
                # Session teardown without a normal localActive leg.
                cls = classify_exit(reason)
                if cls.startswith("UNCLASSIFIED"):
                    w.unclassified += 1
                elif cls.startswith("environmental_"):
                    if cls.endswith(("externalControl", "externalControlTakeover")):
                        w.external_takeovers += 1
                    elif cls.endswith(("emergencyHotkey", "emergencyReturn")):
                        w.emergency_returns += 1
                    else:
                        w.transport_failures += 1
                elif cls == "watchdog_recovery":
                    w.watchdog_recoveries_remote_active += 1
                elif cls.startswith("remoteUnavailable"):
                    w.remote_unavailable_total += 1
                    if "unexplained" in cls and session is not None:
                        if session.transport_cause_logged:
                            w.transport_failures += 1
                        else:
                            w.remote_unavailable_unexplained += 1
                session = None
                pending_return = None
            else:
                # any other transition while a session is open tears the
                # lifecycle down without a proper localActive leg
                if session is not None or pending_return is not None:
                    close_session_without_recovery()
            continue

        rm = REPORT_SENT.search(line)
        if rm:
            if int(rm.group(1)) > 0 and session is not None:
                session.usable_evidence = True
                saw_any_reports = True
            continue

        # Backend-neutral semantic delivery confirmation from the Mac app
        # (logged once per session on first confirmed acceptance).
        if "handoff usable-session confirmed" in line:
            if session is not None:
                session.usable_evidence = True
                saw_any_reports = True
            continue

        if REMOTE_UNAVAILABLE_CAUSE in line and session is not None:
            # Correlation evidence: this remoteUnavailable came from a real
            # ADB/helper transport end (e.g. phone reboot), not from queue
            # pressure or an unexplained product failure.
            session.transport_cause_logged = True
            continue

        if CANCELLED in line:
            w.cancelled_delivery_bursts += 1
        elif COALESCED in line:
            w.coalescing_events += 1
        elif SHED in line:
            w.queue_shed_events += 1
        elif "held-pointer-buttons cleanup" in line:
            mm = CLEANUP.search(line)
            if not mm:
                w.insufficient_evidence.append(
                    "cleanup line without counts: " + line[:80])
                continue
            a, s, f = (int(x) for x in mm.groups())
            w.cleanup_attempted += a
            w.cleanup_succeeded += s
            w.cleanup_failed += f
            if f > 0:
                w.stuck_button_incidents += 1

    close_session_without_recovery()

    # Pointer-trap evidence rule. The #52 gen-6 permanent-trap signature:
    # remoteActive stayed engaged while deliveries kept flowing and no
    # boundaryCrossed ever fired — i.e. a session whose ONLY exit was a
    # healthy-delivery watchdogTimeout — is counted as a trap above via the
    # watchdog counter; here we additionally flag windows whose sessions
    # produced no usable-session evidence at all, because then trap status
    # cannot be established from this log (fail closed).
    if w.entries > 0 and not saw_any_reports:
        w.insufficient_evidence.append(
            "remoteActive entries present but zero usable-session evidence; "
            "trap status undeterminable")

    return w


REQUIRED_CYCLES = 100  # ADR-0012 Level-3 gate; not configurable by design


def verdict(w, lineage_of=None):
    """Compute the fail-closed gate against REQUIRED_CYCLES."""
    required = REQUIRED_CYCLES
    """Compute the fail-closed gate. Returns (status, reasons)."""
    lineage_of = lineage_of or {}
    reasons = []
    if not w.identity_seen:
        reasons.append("MISSING_IDENTITY")
    if w.bad_identity_lines:
        reasons.append("INVALID_IDENTITY_FIELDS=%d" % w.bad_identity_lines)
    cands = {c for c, _, _ in w.identities}
    # ADR-0012 lineage rule: credit belongs to a candidate *lineage*, not to
    # exact SHAs — docs/CI/unrelated changes do NOT reset the window. A
    # manifest maps each SHA to its lineage; SHAs sharing a lineage are one
    # window. Without a manifest, any distinct SHA pair is mixed (fail closed).
    lineages = {lineage_of.get(c, c) for c in cands}
    if len(lineages) > 1:
        reasons.append("MIXED_CANDIDATES=%d" % len(lineages))
    builds = {b for _, b, _ in w.identities}
    if len(builds) > 1 and len(lineages) <= 1:
        reasons.append("MIXED_BUILD_IDENTITIES=%d" % len(builds))
    # Dirty artifacts are not reproducible: never eligible for PASS evidence.
    if any(c.endswith("-dirty") for c in cands):
        reasons.append("DIRTY_CANDIDATE")
    if w.open_session_at_eof:
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
    ap.add_argument("--window-id", default=None, help="evidence window identifier")
    ap.add_argument("--json-out", default=None, help="write machine result JSON here")
    ap.add_argument("--lineage-manifest", default=None,
                    help="JSON manifest of audited candidate lineages. "
                         "Schema: {\"lineages\": [{\"lineage_id\": str, "
                         "\"candidates\": [sha...], \"classification\": "
                         "\"initial|no-reset\", \"reason\": str, "
                         "\"reference\": str}]}. Committed with the evidence "
                         "so lineage groupings are human-auditable; SHAs "
                         "sharing a lineage_id accumulate one window.")
    args = ap.parse_args(argv)
    lineage_of = {}
    if args.lineage_manifest:
        try:
            with open(args.lineage_manifest, "r", encoding="utf-8") as mf:
                doc = json.load(mf)
        except (OSError, ValueError) as exc:
            print(json.dumps({"STABILITY_GATE": "HOLD",
                              "reasons": ["INPUT_ERROR=%s" % exc]}))
            return 2
        # Schema validation: an unaudited or malformed manifest must fail
        # closed rather than silently merging unrelated candidates.
        entries = doc.get("lineages") if isinstance(doc, dict) else None
        if not isinstance(entries, list) or not entries:
            print(json.dumps({"STABILITY_GATE": "HOLD",
                              "reasons": ["MANIFEST_SCHEMA=lineages[] required"]}))
            return 2
        seen_shas = set()
        schema_error = None
        for entry in entries:
            lid = entry.get("lineage_id")
            shas = entry.get("candidates")
            cls = entry.get("classification")
            if (not isinstance(lid, str) or not lid
                    or not isinstance(shas, list) or not shas
                    or cls not in ("initial", "no-reset")):
                schema_error = ("MANIFEST_SCHEMA=entry missing lineage_id/"
                                "candidates/classification")
                break
            if not entry.get("reason") or not entry.get("reference"):
                schema_error = "MANIFEST_SCHEMA=entry missing reason/reference"
                break
            for sha in shas:
                if sha in seen_shas:
                    schema_error = "MANIFEST_SCHEMA=duplicate sha %s" % sha
                    break
                seen_shas.add(sha)
                lineage_of[sha] = lid
            if schema_error:
                break
        if schema_error:
            print(json.dumps({"STABILITY_GATE": "HOLD",
                              "reasons": [schema_error]}))
            return 2

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
    status, reasons = verdict(w, lineage_of)
    result = {
        "window_id": args.window_id,
        "candidates": sorted("%s@%s@%s" % t for t in w.identities),
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
        "insufficient_evidence_detail": w.insufficient_evidence[:10],
        "required_cycles": REQUIRED_CYCLES,
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
