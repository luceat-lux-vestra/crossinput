#!/usr/bin/env python3
"""Fail-closed semantic analysis for the Issue #96 observation harness.

This module intentionally has no macOS dependencies.  The capture scripts
write bounded, metadata-only evidence; this file normalizes that evidence and
never attempts to infer the rendered cursor shape.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
REQUIRED_MARKERS = ("healthy", "broken", "recovered")
REQUIRED_SNAPSHOT_LABELS = REQUIRED_MARKERS
EXPECTED_SNAPSHOT_FILES = {
    "systemuiserver-process.txt",
    "iohid-device-registry.txt",
    "iohid-event-system.txt",
    "iohid-event-system-client.txt",
    "iohid-event-service.txt",
    "display-workspace.json",
    "systemuiserver-service.txt",
}
OPTIONAL_SNAPSHOT_FILES = {"hidutil-list.txt", "ampersand-diag.filtered.log"}
REQUIRED_SNAPSHOT_COMMANDS = {
    "systemuiserver_process": "systemuiserver-process.txt",
    "iohid_device_registry": "iohid-device-registry.txt",
    "iohid_event_system": "iohid-event-system.txt",
    "iohid_event_system_client": "iohid-event-system-client.txt",
    "iohid_event_service": "iohid-event-service.txt",
    "display_workspace_accessibility": "display-workspace.json",
    "systemui_launchctl_state": "systemuiserver-service.txt",
}
OPTIONAL_SNAPSHOT_COMMANDS = {
    "hidutil_list": "hidutil-list.txt",
    "ampersand_metadata_diag": "ampersand-diag.filtered.log",
}

VOLATILE_KEYS = {
    "timestamp", "timestamp_utc", "captured_at_utc", "captured_epoch_ns",
    "marker_timestamp_utc", "time", "date", "epoch_ns",
    "monotonic_ns", "uptime", "elapsed", "duration", "pid", "ppid",
    "process_id", "processid", "parent_pid", "launch_time", "exit_time",
    "activity_identifier", "activityid", "transaction_identifier",
    "connection_id", "connectionid", "client_id", "clientid", "session_id",
    "sessionid", "uuid", "boot_uuid", "bootuuid", "thread_id", "threadid",
}

SENSITIVE_MESSAGE = re.compile(
    r"key\s*code|keyboard|keystroke|clipboard|hid\s+report|report\s+descriptor|"
    r"raw\s+report|mouse\s+delta|\bdx\s*=|\bdy\s*=|\bdelta\s*=|"
    r"payload|unicode|characters?\s*=|scroll\s+delta",
    re.IGNORECASE,
)
UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)
HEX_ADDRESS_RE = re.compile(r"\b0x[0-9a-f]{6,}\b", re.IGNORECASE)
STABLE_HEX_RE = re.compile(
    r"\b(?:locationid|registryid|ioregistryentryid)\s*[=:]?\s*(0x[0-9a-f]+)",
    re.IGNORECASE,
)
VOLATILE_ASSIGNMENT_RE = re.compile(
    r"\b(?:pid|ppid|tid|thread|connection|client|session|activity|transaction)"
    r"\s*[=:]\s*[^\s,;]+",
    re.IGNORECASE,
)
NUMBERED_ASSIGNMENT_RE = re.compile(
    r"\b(?:x|y|location|position)\s*[=:]\s*[-+]?\d+(?:\.\d+)?",
    re.IGNORECASE,
)
WHITESPACE_RE = re.compile(r"\s+")

CATEGORY_RULES = (
    ("HID / pointing", re.compile(
        r"hid|pointing|karabiner|virtual.?mouse|event.?system|iohid", re.I)),
    ("cursor / tracking", re.compile(
        r"cursor|tracking|cursor.?rect|presentation|mouse.?cursor", re.I)),
    ("WindowServer", re.compile(r"window.?server|windowserver|cgs|compositor", re.I)),
    ("SystemUIServer", re.compile(r"system.?ui|systemuiserver|menu.?bar|status.?item", re.I)),
    ("display", re.compile(r"display|screen|topology|cgdisplay|resolution|bounds", re.I)),
    ("workspace / activation", re.compile(
        r"workspace|frontmost|activate|deactivate|active.?space|application", re.I)),
    ("accessibility", re.compile(r"accessib|axtrusted|axisprocess", re.I)),
)


class EvidenceError(Exception):
    """An evidence file is malformed or does not satisfy the run contract."""


def parse_timestamp(value: Any, *, reference_date: dt.date | None = None) -> float:
    """Parse the timestamp forms emitted by the harness and log fixtures.

    ISO timestamps preserve nanosecond text as far as Python's microsecond
    datetime allows; the returned value is used only for bounded windows.
    Compact ``HH:MM:SS[.fraction]`` values are accepted for isolated unit
    fixtures when a reference date is supplied (or as seconds since midnight).
    """

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"invalid timestamp: {value!r}")
    text = value.strip()
    if re.fullmatch(r"\d{2}:\d{2}:\d{2}(?:\.\d+)?", text):
        parsed = dt.datetime.strptime(text, "%H:%M:%S.%f" if "." in text else "%H:%M:%S")
        if reference_date is None:
            return (parsed.hour * 3600 + parsed.minute * 60 + parsed.second
                    + parsed.microsecond / 1_000_000)
        return dt.datetime.combine(reference_date, parsed.time(), tzinfo=dt.timezone.utc).timestamp()
    normalized = text.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise EvidenceError(f"invalid timestamp: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.timestamp()


def redact_volatile_text(value: str) -> str:
    """Remove identifiers and coordinates without changing semantic words."""

    if SENSITIVE_MESSAGE.search(value):
        return "<payload-bearing record omitted>"
    value = UUID_RE.sub("<uuid>", value)
    stable_hex: list[str] = []

    def protect_stable_hex(match: re.Match[str]) -> str:
        stable_hex.append(match.group(1))
        prefix = match.group(0)[:-len(match.group(1))]
        return prefix + f"<stable-hex-{len(stable_hex) - 1}>"

    value = STABLE_HEX_RE.sub(protect_stable_hex, value)
    value = HEX_ADDRESS_RE.sub("<hex>", value)
    for index, literal in enumerate(stable_hex):
        value = value.replace(f"<stable-hex-{index}>", literal)
    value = VOLATILE_ASSIGNMENT_RE.sub(
        lambda match: match.group(0).split("=", 1)[0].split(":", 1)[0] + "=<volatile>",
        value,
    )
    value = NUMBERED_ASSIGNMENT_RE.sub(
        lambda match: match.group(0).split("=", 1)[0].split(":", 1)[0] + "=<coordinate>",
        value,
    )
    value = WHITESPACE_RE.sub(" ", value).strip()
    return value


def is_volatile_key(key: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", key.lower())
    return normalized in {re.sub(r"[^a-z0-9]", "", item) for item in VOLATILE_KEYS}


def normalize_json(value: Any, prefix: str = "") -> list[str]:
    """Flatten JSON into order-independent semantic records."""

    records: list[str] = []
    if isinstance(value, dict):
        for key in sorted(value):
            if is_volatile_key(str(key)):
                continue
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            records.extend(normalize_json(value[key], child_prefix))
        return records
    if isinstance(value, list):
        for item in value:
            records.extend(normalize_json(item, f"{prefix}[]"))
        return records
    if value is None:
        return [f"{prefix}=null"] if prefix else []
    if isinstance(value, bool):
        rendered = "true" if value else "false"
    else:
        rendered = redact_volatile_text(str(value))
    return [f"{prefix}={rendered}"] if prefix else []


def normalize_text_line(line: str) -> str:
    """Normalize one safe text line from a snapshot or selected log."""

    line = line.strip()
    if not line:
        return ""
    line = re.sub(r"^\d{4}-\d\d-\d\d[T ][^ ]+\s+", "", line)
    line = re.sub(r"^\d\d:\d\d:\d\d(?:\.\d+)?\s+", "", line)
    # `ps -o pid=,ppid=,comm=` has unlabelled leading process IDs. They are
    # lifecycle anchors, not stable device/service identity.
    line = re.sub(r"^\s*\d+\s+\d+\s+", "", line)
    return redact_volatile_text(line)


def category_for(text: str, filename: str = "") -> str:
    combined = f"{filename} {text}"
    for category, pattern in CATEGORY_RULES:
        if pattern.search(combined):
            return category
    return "other"


def parse_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise EvidenceError(f"missing evidence file: {path}")
    records: list[dict[str, Any]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise EvidenceError(f"malformed JSON at {path}:{number}") from exc
        if not isinstance(value, dict):
            raise EvidenceError(f"expected object at {path}:{number}")
        records.append(value)
    return records


def load_run(run_path: str | Path) -> dict[str, Any]:
    path = Path(run_path).expanduser().resolve()
    if not path.is_dir():
        raise EvidenceError(f"run directory does not exist: {path}")
    metadata_path = path / "run.json"
    if not metadata_path.is_file():
        raise EvidenceError(f"missing run metadata: {metadata_path}")
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"malformed run metadata: {metadata_path}") from exc
    if metadata.get("schema") != SCHEMA_VERSION or not metadata.get("run_id"):
        raise EvidenceError(f"unsupported or incomplete run metadata: {metadata_path}")
    metadata["_path"] = path
    return metadata


def load_markers(run: dict[str, Any]) -> dict[str, dict[str, Any]]:
    path = run["_path"] / "markers.jsonl"
    values = parse_jsonl(path)
    markers: dict[str, dict[str, Any]] = {}
    for marker in values:
        label = marker.get("marker")
        if label not in REQUIRED_MARKERS:
            continue
        if marker.get("run_id") != run["run_id"]:
            raise EvidenceError(f"marker run_id mismatch in {path}")
        if label in markers:
            raise EvidenceError(f"duplicate {label} marker in {path}")
        marker["_time"] = parse_timestamp(marker.get("timestamp_utc"))
        markers[label] = marker
    missing = [label for label in REQUIRED_MARKERS if label not in markers]
    if missing:
        raise EvidenceError(f"missing marker(s): {', '.join(missing)}")
    if not markers["healthy"]["_time"] < markers["broken"]["_time"] < markers["recovered"]["_time"]:
        raise EvidenceError("markers are not ordered HEALTHY < BROKEN < RECOVERED")
    return markers


def load_lifecycle(run: dict[str, Any]) -> list[dict[str, Any]]:
    path = run["_path"] / "raw" / "systemuiserver-lifecycle.jsonl"
    values = parse_jsonl(path)
    for value in values:
        value["_time"] = parse_timestamp(value.get("timestamp_utc"))
    return values


def marker_pids(marker: dict[str, Any], label: str) -> tuple[set[int], str | None]:
    values = marker.get("systemuiserver_pids")
    if not isinstance(values, list):
        return set(), f"{label.upper()} marker has no usable SystemUIServer PID list"
    pids = {value for value in values if isinstance(value, int) and not isinstance(value, bool) and value > 1}
    if not pids:
        return set(), f"{label.upper()} marker has no usable SystemUIServer PID"
    if len(pids) != len(values):
        return pids, f"{label.upper()} marker contains an unusable SystemUIServer PID value"
    return pids, None


def find_restart(lifecycle: list[dict[str, Any]], markers: dict[str, dict[str, Any]]) -> tuple[dict[str, Any] | None, list[str]]:
    """Find exactly one restart bound to the BROKEN/RECOVERED marker PIDs.

    A nearby restart is intentionally never used as a fallback. The marker
    PID sets are the identity boundary for the physical recovery experiment.
    """

    broken = markers["broken"]["_time"]
    recovered = markers["recovered"]["_time"]
    broken_pids, broken_issue = marker_pids(markers["broken"], "broken")
    recovered_pids, recovered_issue = marker_pids(markers["recovered"], "recovered")
    reasons = [issue for issue in (broken_issue, recovered_issue) if issue]
    if broken_pids == recovered_pids and len(broken_pids) == 1:
        reasons.append("BROKEN and RECOVERED record the same only SystemUIServer PID")
    if reasons:
        return None, reasons

    interval_exits = [item for item in lifecycle
                      if item.get("event") == "exited"
                      and broken <= item["_time"] <= recovered]
    interval_launches = [item for item in lifecycle
                         if item.get("event") == "launched"
                         and broken < item["_time"] <= recovered]
    if any(not isinstance(item.get("pid"), int) or isinstance(item.get("pid"), bool)
           or item["pid"] not in broken_pids for item in interval_exits):
        reasons.append("observed SystemUIServer exit PID does not match the BROKEN marker PID (marker evidence conflict)")
    if any(not isinstance(item.get("pid"), int) or isinstance(item.get("pid"), bool)
           or item["pid"] not in recovered_pids for item in interval_launches):
        reasons.append("observed SystemUIServer launch PID does not match the RECOVERED marker PID (marker evidence conflict)")
    if reasons:
        return None, reasons

    exits = [item for item in lifecycle
             if item.get("event") == "exited"
             and isinstance(item.get("pid"), int)
             and item["pid"] in broken_pids
             and broken <= item["_time"] <= recovered]
    launches = [item for item in lifecycle
                if item.get("event") == "launched"
                and isinstance(item.get("pid"), int)
                and item["pid"] in recovered_pids
                and item["_time"] <= recovered]
    candidates = [
        (exited, launched)
        for exited in exits
        for launched in launches
        if launched["_time"] > exited["_time"]
        and launched["pid"] != exited["pid"]
    ]
    if len(candidates) > 1:
        return None, ["multiple marker-bound SystemUIServer restart candidates are ambiguous"]
    if not candidates:
        if interval_exits and any(item.get("pid") not in broken_pids for item in interval_exits):
            reasons.append("observed SystemUIServer exit PID does not match the BROKEN marker PID")
        if interval_launches and any(item.get("pid") not in recovered_pids for item in interval_launches):
            reasons.append("observed SystemUIServer launch PID does not match the RECOVERED marker PID")
        if not reasons:
            reasons.append("no marker-bound SystemUIServer exit/new-PID launch pair observed between BROKEN and RECOVERED")
        return None, reasons

    exited, launched = candidates[0]
    return {
        "old_pid": exited["pid"],
        "new_pid": launched["pid"],
        "broken_marker_pids": sorted(broken_pids),
        "recovered_marker_pids": sorted(recovered_pids),
        "exit_time": exited["_time"],
        "launch_time": launched["_time"],
    }, []


def validate_run_metadata(run: dict[str, Any]) -> list[str]:
    reasons: list[str] = []
    if run.get("state") != "stopped":
        reasons.append("capture state is not stopped")
    shutdown = run.get("shutdown")
    if not isinstance(shutdown, dict):
        reasons.append("clean shutdown metadata is missing")
    else:
        if shutdown.get("requested") is not True:
            reasons.append("shutdown metadata does not record a requested stop")
        if shutdown.get("clean") is not True:
            reasons.append("capture shutdown was not clean")
        if shutdown.get("forced_kill") is not False:
            reasons.append("capture shutdown used forced cleanup")
        if shutdown.get("remaining_pids") != []:
            reasons.append("shutdown metadata records remaining observer processes")
        if not isinstance(shutdown.get("requested_at_utc"), str) or not shutdown.get("requested_at_utc"):
            reasons.append("shutdown request timestamp is missing")
    if not isinstance(run.get("stopped_at_utc"), str) or not run.get("stopped_at_utc"):
        reasons.append("capture stop timestamp is missing")

    if (not isinstance(run.get("harness_source_sha"), str)
            or not run.get("harness_source_sha")
            or run.get("harness_source_sha") == "unknown"):
        reasons.append("harness_source_sha is missing")
    if run.get("harness_worktree_clean") is not True:
        reasons.append("harness worktree was not recorded clean")

    identity = run.get("crossinput_build_identity")
    required_identity = (
        "bundle_identifier", "bundle_short_version", "bundle_version",
        "bundle_path", "executable_path",
    )
    if not isinstance(identity, dict) or identity.get("resolved") is not True:
        reasons.append("CrossInput build identity is missing or unresolved")
    elif any(not isinstance(identity.get(key), str) or not identity.get(key) or identity.get(key) == "unknown"
             for key in required_identity):
        reasons.append("CrossInput build identity is missing a required field")
    elif any(not isinstance(identity.get(key), str) or not identity.get(key)
             for key in ("crossinput_source_sha", "crossinput_build_identifier")):
        reasons.append("CrossInput build identity has a malformed optional identity field")
    identity_path = run["_path"] / "crossinput-build-identity.json"
    if not identity_path.is_file():
        reasons.append("crossinput-build-identity.json is missing")
    else:
        try:
            recorded_identity = json.loads(identity_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            reasons.append("crossinput-build-identity.json is malformed")
        else:
            if recorded_identity != identity:
                reasons.append("CrossInput build identity file disagrees with run metadata")

    evidence_mode = run.get("evidence_mode")
    if not isinstance(evidence_mode, dict) or not isinstance(evidence_mode.get("include_hidutil"), bool):
        reasons.append("evidence mode metadata is missing")
    return reasons


def evidence_file_status(path: Path) -> str:
    """Validate a snapshot evidence contract and return present/not_available."""

    if not path.is_file():
        raise EvidenceError(f"missing evidence file: {path}")
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        raise EvidenceError(f"empty evidence file: {path}")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        if re.search(r"not_available|[\"']?evidence[\"']?\s*[:=]", text, re.IGNORECASE):
            raise EvidenceError(f"malformed not_available sentinel: {path}")
        return "present"
    if isinstance(value, dict) and "evidence" in value:
        if (set(value) != {"evidence", "reason"}
                or value.get("evidence") != "not_available"
                or not isinstance(value.get("reason"), str)
                or not value["reason"]):
            raise EvidenceError(f"malformed not_available sentinel: {path}")
        return "not_available"
    return "present"


def snapshot_paths(run: dict[str, Any], markers: dict[str, dict[str, Any]] | None = None) -> dict[str, Path]:
    root = run["_path"] / "snapshots"
    if not root.is_dir():
        raise EvidenceError(f"missing snapshots directory: {root}")
    result: dict[str, Path] = {}
    for path in sorted(root.glob("*-*")):
        if not path.is_dir():
            continue
        meta_path = path / "snapshot.meta.json"
        if not meta_path.is_file():
            raise EvidenceError(f"missing snapshot metadata: {meta_path}")
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise EvidenceError(f"malformed snapshot metadata: {meta_path}") from exc
        label = meta.get("label")
        if label not in REQUIRED_SNAPSHOT_LABELS:
            continue
        if meta.get("run_id") != run["run_id"]:
            raise EvidenceError(f"snapshot run_id mismatch: {meta_path}")
        if meta.get("evidence_contract_schema") != 1:
            raise EvidenceError(f"unsupported evidence contract metadata: {meta_path}")
        if meta.get("evidence_mode") != run.get("evidence_mode"):
            raise EvidenceError(f"snapshot evidence mode mismatch: {meta_path}")
        if markers and meta.get("marker_timestamp_utc") != markers[label].get("timestamp_utc"):
            raise EvidenceError(f"snapshot {label} does not match its marker timestamp")
        if label in result:
            raise EvidenceError(f"duplicate {label} snapshot")
        commands = meta.get("commands")
        if not isinstance(commands, list):
            raise EvidenceError(f"missing command manifest: {meta_path}")
        command_map: dict[str, dict[str, Any]] = {}
        for item in commands:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                raise EvidenceError(f"malformed command manifest: {meta_path}")
            name = item["name"]
            if name in command_map:
                raise EvidenceError(f"duplicate command in manifest: {meta_path}: {name}")
            command_map[name] = item
        for name in REQUIRED_SNAPSHOT_COMMANDS:
            item = command_map.get(name)
            if not item:
                raise EvidenceError(f"snapshot {label} is missing required command: {name}")
            if item.get("required") is not True or item.get("status") != "ok":
                raise EvidenceError(f"snapshot {label} has failed required command: {name}")
            if item.get("evidence") not in {"present", "not_available"}:
                raise EvidenceError(f"snapshot {label} has invalid evidence status for {name}")
        missing_files = sorted(name for name in EXPECTED_SNAPSHOT_FILES if not (path / name).is_file())
        if missing_files:
            raise EvidenceError(f"snapshot {label} is missing evidence file(s): {', '.join(missing_files)}")
        for name, filename in {**REQUIRED_SNAPSHOT_COMMANDS, **OPTIONAL_SNAPSHOT_COMMANDS}.items():
            evidence_path = path / filename
            if not evidence_path.is_file() and name in OPTIONAL_SNAPSHOT_COMMANDS:
                continue
            evidence = evidence_file_status(evidence_path)
            item = command_map.get(name)
            if item is None:
                if name in REQUIRED_SNAPSHOT_COMMANDS:
                    raise EvidenceError(f"snapshot {label} is missing command metadata: {name}")
                continue
            if item.get("evidence") != evidence:
                raise EvidenceError(f"snapshot {label} evidence metadata disagrees for {name}")
            if evidence == "not_available" and item.get("status") != "ok":
                raise EvidenceError(f"snapshot {label} not_available evidence is not successful for {name}")
        result[label] = path
    missing = [label for label in REQUIRED_SNAPSHOT_LABELS if label not in result]
    if missing:
        raise EvidenceError(f"missing snapshot(s): {', '.join(missing)}")
    return result


def snapshot_records(snapshot: Path) -> dict[str, set[str]]:
    """Return categorized, order-independent semantic records for one snapshot."""

    grouped: dict[str, set[str]] = defaultdict(set)
    ignored = {"snapshot.meta.json", "commands.tsv", "state-errors.log"}
    for path in sorted(snapshot.iterdir()):
        if not path.is_file() or path.name in ignored or path.name.endswith(".stderr"):
            continue
        if path.name in EXPECTED_SNAPSHOT_FILES | OPTIONAL_SNAPSHOT_FILES:
            if evidence_file_status(path) == "not_available":
                continue
        if path.name.endswith(".json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                raise EvidenceError(f"malformed snapshot JSON: {path}") from exc
            values = normalize_json(value)
        else:
            values = [normalize_text_line(line) for line in path.read_text(encoding="utf-8").splitlines()]
            values = [value for value in values if value]
        for value in values:
            if value.startswith("<payload-bearing record omitted>"):
                continue
            category = category_for(value, path.name)
            grouped[category].add(f"{path.name}:{value}")
    return dict(grouped)


def delta(before: dict[str, set[str]], after: dict[str, set[str]]) -> dict[str, dict[str, set[str]]]:
    categories = sorted(set(before) | set(after))
    return {
        category: {
            "added": after.get(category, set()) - before.get(category, set()),
            "removed": before.get(category, set()) - after.get(category, set()),
        }
        for category in categories
        if after.get(category, set()) - before.get(category, set())
        or before.get(category, set()) - after.get(category, set())
    }


def load_unified(run: dict[str, Any]) -> list[dict[str, Any]]:
    path = run["_path"] / "raw" / "unified.jsonl"
    error_path = run["_path"] / "raw" / "unified-capture-errors.log"
    if error_path.is_file():
        errors = error_path.read_text(encoding="utf-8")
        fatal_tokens = ("capture_limit_reached", "invalid_capture_limit", "malformed_log_record", "log_start_failed",
                        "log_stream_term_timeout", "log_stream_exit")
        if any(token in errors for token in fatal_tokens):
            raise EvidenceError(f"unified capture has fatal error(s): {error_path}")
    values = parse_jsonl(path)
    if not values:
        raise EvidenceError(f"unified log is empty: {path}")
    for value in values:
        value["_time"] = parse_timestamp(value.get("timestamp_utc"))
    return values


def load_workspace_events(run: dict[str, Any]) -> list[dict[str, Any]]:
    path = run["_path"] / "raw" / "workspace-events.jsonl"
    values = parse_jsonl(path)
    if not values:
        raise EvidenceError(f"workspace notification evidence is empty: {path}")
    for value in values:
        value["_time"] = parse_timestamp(value.get("timestamp_utc"))
    return values


def unified_window_records(unified: list[dict[str, Any]], markers: dict[str, dict[str, Any]],
                           restart: dict[str, Any] | None) -> list[dict[str, Any]]:
    broken = markers["broken"]["_time"]
    recovered = markers["recovered"]["_time"]
    start = min(broken - 10, restart["exit_time"] if restart else broken - 10)
    end = max(recovered + 10, restart["launch_time"] if restart else recovered + 10)
    result = []
    for item in unified:
        if start <= item["_time"] <= end:
            text = str(item.get("message", ""))
            normalized = redact_volatile_text(text)
            if normalized == "<payload-bearing record omitted>":
                continue
            item = dict(item)
            item["_normalized"] = normalized
            item["category"] = category_for(
                " ".join(str(item.get(key, "")) for key in ("process", "subsystem", "category", "message")),
            )
            result.append(item)
    return result


def rank_unified(item: dict[str, Any], restart: dict[str, Any] | None) -> str:
    text = item.get("_normalized", "")
    if re.search(r"launch|exit|terminated|heartbeat", text, re.I):
        return "NOISE"
    relevant = re.search(r"cursor|tracking|presentation|event.?system|client|service|register|display", text, re.I)
    if relevant and restart and restart["exit_time"] - 2 <= item["_time"] <= restart["launch_time"] + 10:
        return "MEDIUM"
    if relevant:
        return "LOW"
    return "NOISE"


def meaningful_delta(semantic_delta: dict[str, dict[str, set[str]]]) -> set[str]:
    values: set[str] = set()
    for category, changes in semantic_delta.items():
        for direction in ("added", "removed"):
            for value in changes[direction]:
                if "<volatile>" not in value and "<coordinate>" not in value:
                    values.add(f"{category}|{direction}|{value}")
    return values


def analyze_run(run_path: str | Path) -> dict[str, Any]:
    run = load_run(run_path)
    markers = load_markers(run)
    lifecycle = load_lifecycle(run)
    snapshots = snapshot_paths(run, markers)
    snapshot_states = {label: snapshot_records(path) for label, path in snapshots.items()}
    restart, restart_reasons = find_restart(lifecycle, markers)
    unified = load_unified(run)
    workspace = load_workspace_events(run)
    log_records = unified_window_records(unified, markers, restart)
    transition_delta = delta(snapshot_states["healthy"], snapshot_states["broken"])
    recovery_delta = delta(snapshot_states["broken"], snapshot_states["recovered"])
    reasons = validate_run_metadata(run) + restart_reasons
    status = "COMPLETE" if not reasons else "INCOMPLETE"
    if not log_records:
        status = "INCOMPLETE"
        reasons.append("no relevant unified-log records in the bounded analysis window")
    return {
        "run": run,
        "markers": markers,
        "lifecycle": lifecycle,
        "snapshots": snapshots,
        "snapshot_states": snapshot_states,
        "restart": restart,
        "unified": log_records,
        "workspace": workspace,
        "transition_delta": transition_delta,
        "recovery_delta": recovery_delta,
        "status": status,
        "reasons": reasons,
    }


def _fmt_time(value: float | None) -> str:
    if value is None:
        return "unknown"
    return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc).isoformat(timespec="milliseconds")


def _append_changes(lines: list[str], changes: dict[str, dict[str, set[str]]], limit: int = 80) -> None:
    count = 0
    for category in sorted(changes):
        lines.append(f"### {category}")
        for direction in ("added", "removed"):
            for value in sorted(changes[category][direction]):
                if count >= limit:
                    lines.append("- additional normalized changes omitted for bounded report size")
                    return
                lines.append(f"- `{direction}` `{value}`")
                count += 1


def render_run_report(result: dict[str, Any]) -> str:
    run = result["run"]
    markers = result["markers"]
    restart = result["restart"]
    lines = [
        "# Issue #96 semantic recovery report",
        "",
        f"STATUS: {result['status']}",
        f"RUN: `{run['run_id']}`",
        f"HARNESS SOURCE SHA: `{run.get('harness_source_sha', 'unknown')}`",
        f"CROSSINPUT BUILD IDENTITY: `{json.dumps(run.get('crossinput_build_identity', {}), sort_keys=True)}`",
        "",
        "The marker labels are operator assertions only. The analyzer does not classify the rendered cursor shape.",
        "",
        "## Marker timeline",
        "",
    ]
    for label in REQUIRED_MARKERS:
        lines.append(f"- {label.upper()}: `{markers[label].get('timestamp_utc', 'unknown')}`")
    lines.extend(["", "## SystemUIServer lifecycle anchor", ""])
    if restart:
        lines.append(
            f"- BROKEN marker PID: `{restart['old_pid']}`"
        )
        lines.append(
            f"- observed exit: PID `{restart['old_pid']}` at `{_fmt_time(restart['exit_time'])}`"
        )
        lines.append(
            f"- observed launch: PID `{restart['new_pid']}` at `{_fmt_time(restart['launch_time'])}`"
        )
        lines.append(
            f"- RECOVERED marker PID: `{restart['new_pid']}`"
        )
        lines.append("- restart binding: `VALID`")
    else:
        lines.append("- restart binding: `INVALID`")
        for reason in result["reasons"]:
            if "SystemUIServer" in reason or "restart" in reason:
                lines.append(f"- {reason}")
    lines.extend([
        "",
        "## Semantic snapshot delta: HEALTHY -> BROKEN",
        "",
    ])
    _append_changes(lines, result["transition_delta"])
    if not result["transition_delta"]:
        lines.append("- no normalized snapshot delta")
    lines.extend(["", "## Semantic snapshot delta: BROKEN -> RECOVERED", ""])
    _append_changes(lines, result["recovery_delta"])
    if not result["recovery_delta"]:
        lines.append("- no normalized snapshot delta")
    lines.extend(["", "## Bounded unified-log findings", ""])
    findings = [item for item in result["unified"] if rank_unified(item, restart) != "NOISE"]
    if findings:
        for item in findings[:80]:
            rank = rank_unified(item, restart)
            source = "/".join(str(item.get(key, "unknown")) for key in ("process", "subsystem", "category"))
            lines.append(f"- `{rank}` `{item['category']}` `{_fmt_time(item['_time'])}` `{source}` — {item['_normalized']}")
    else:
        lines.append("- no non-noise records in the bounded window")
    lines.extend(["", "## Workspace notification findings", ""])
    workspace_start = markers["broken"]["_time"] - 10
    workspace_end = markers["recovered"]["_time"] + 10
    workspace_events = [item for item in result["workspace"]
                        if workspace_start <= item["_time"] <= workspace_end
                        and item.get("event") != "observer_started"]
    if workspace_events:
        for item in workspace_events[:40]:
            application = item.get("application") or item.get("frontmost") or {}
            bundle = application.get("bundle_id", "unknown") if isinstance(application, dict) else "unknown"
            lines.append(f"- `LOW` `{item.get('event', 'unknown')}` `{_fmt_time(item['_time'])}` bundle=`{bundle}`")
    else:
        lines.append("- no selected NSWorkspace notification in the bounded window")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "- `SystemUIServer` restart recovering the cursor does not prove that `SystemUIServer` owns the defective state.",
        "- The rendered native cursor remains human-observed because public cursor APIs do not reliably expose the WindowServer-composited cursor shape.",
    ])
    if result["recovery_delta"]:
        lines.append("- The recovery snapshot contains observable changes; they are candidates for repeated-run comparison, not a root-cause claim.")
    elif not findings:
        lines.append("- No supported externally observable state transition explains recovery in this run's normalized snapshots.")
    else:
        lines.append("- No stable snapshot transition was observed; selected log messages are correlational and insufficient to explain recovery in one run.")
    if result["reasons"]:
        lines.extend(["", "## Fail-closed reasons", ""])
        lines.extend(f"- {reason}" for reason in result["reasons"])
    lines.extend([
        "",
        "## Evidence locations",
        "",
        "- Raw selected log stream: `raw/unified.jsonl`",
        "- SystemUIServer lifecycle: `raw/systemuiserver-lifecycle.jsonl`",
        "- Workspace notifications: `raw/workspace-events.jsonl`",
        "- Normalized snapshot files: `snapshots/`",
    ])
    return "\n".join(lines) + "\n"


def compare_runs(results: list[dict[str, Any]]) -> str:
    if len(results) < 2:
        raise EvidenceError("at least two runs are required for comparison")
    ids = [item["run"]["run_id"] for item in results]
    if len(set(ids)) != len(ids):
        raise EvidenceError("comparison requires distinct run IDs")
    harness_shas = {item["run"].get("harness_source_sha", "unknown") for item in results}
    if len(harness_shas) != 1 or "unknown" in harness_shas:
        raise EvidenceError("comparison requires matching known harness_source_sha values")
    if any(item["run"].get("harness_worktree_clean") is not True for item in results):
        raise EvidenceError("comparison requires clean harness worktrees")
    evidence_modes = {
        json.dumps(item["run"].get("evidence_mode"), sort_keys=True)
        for item in results
    }
    if len(evidence_modes) != 1:
        compatible = False
        comparison_reason = "comparison requires matching evidence modes"
    else:
        identities = []
        for item in results:
            identity = item["run"].get("crossinput_build_identity")
            if not isinstance(identity, dict) or identity.get("resolved") is not True:
                identities.append(None)
                continue
            identity_keys = (
                "bundle_identifier", "bundle_short_version", "bundle_version",
                "bundle_path", "executable_path", "crossinput_source_sha",
                "crossinput_build_identifier",
            )
            if any(not isinstance(identity.get(key), str) or not identity.get(key)
                   for key in identity_keys):
                identities.append(None)
            else:
                identities.append(tuple(identity[key] for key in identity_keys))
        compatible = all(identity is not None for identity in identities) and len(set(identities)) == 1
        comparison_reason = None if compatible else "comparison requires compatible resolved CrossInput build identities"
    complete = all(item["status"] == "COMPLETE" for item in results) and compatible
    transitions = [meaningful_delta(item["recovery_delta"]) for item in results]
    recurring = set.intersection(*transitions) if transitions and complete else set()
    lines = [
        "# Issue #96 repeated-run semantic comparison",
        "",
        f"STATUS: {'COMPLETE' if complete else 'INCOMPLETE'}",
        f"RUNS: {', '.join(f'`{value}`' for value in ids)}",
        "",
        "This is a set comparison of normalized BROKEN -> RECOVERED changes. It is not a cursor-shape classifier or a root-cause proof.",
        "",
        "## Recurring recovery transitions",
        "",
    ]
    if recurring:
        for item in sorted(recurring):
            lines.append(f"- `HIGH` recurring candidate: `{item}`")
    else:
        lines.append("- none common to every supplied run")
    lines.extend(["", "## Per-run status", ""])
    for result in results:
        lines.append(f"- `{result['run']['run_id']}`: `{result['status']}`")
        for reason in result["reasons"]:
            lines.append(f"  - {reason}")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "- A recurring delta is a candidate boundary for a new experiment; it does not establish ownership by SystemUIServer, WindowServer, HID, AppKit, or Karabiner.",
        "- SystemUIServer restart recovering the cursor does not prove that SystemUIServer owns the defective state.",
        "- The rendered native cursor remains human-observed because public cursor APIs do not reliably expose the WindowServer-composited cursor shape.",
    ])
    if comparison_reason:
        lines.extend(["", "## Fail-closed comparison reason", "", f"- {comparison_reason}"])
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", help="one run directory, or two/three run directories to compare")
    parser.add_argument("--output", type=Path, help="report path; defaults beside the run(s)")
    args = parser.parse_args(argv)
    try:
        results = [analyze_run(path) for path in args.runs]
        if len(results) == 1:
            report = render_run_report(results[0])
            output = args.output or (results[0]["run"]["_path"] / "semantic-report.md")
            exit_code = 0 if results[0]["status"] == "COMPLETE" else 3
        else:
            report = compare_runs(results)
            output = args.output or (Path(args.runs[0]).expanduser().resolve().parent / "issue96-comparison-report.md")
            exit_code = 0 if all(item["status"] == "COMPLETE" for item in results) else 3
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(report, encoding="utf-8")
        print(report, end="")
        return exit_code
    except EvidenceError as exc:
        print(f"STATUS: INCOMPLETE\nERROR: {exc}", file=sys.stderr)
        return 3
    except OSError as exc:
        print(f"STATUS: INCOMPLETE\nERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
