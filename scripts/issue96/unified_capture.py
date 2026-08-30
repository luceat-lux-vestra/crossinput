#!/usr/bin/env python3
"""Capture a small, payload-scrubbed selection of macOS unified logs.

The selected stream is retained as raw evidence for this harness, but only
allowlisted metadata fields and scrubbed state messages are written to disk.
This prevents the diagnostic from becoming an input-report logger.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


PREDICATE = (
    '(process == "SystemUIServer" OR process == "WindowServer" OR '
    'process == "hidd" OR process == "Dock" OR process == "loginwindow" OR '
    'process == "Finder" OR process == "Ampersand") AND ('
    'eventMessage CONTAINS[c] "cursor" OR eventMessage CONTAINS[c] "tracking" OR '
    'eventMessage CONTAINS[c] "pointer" OR eventMessage CONTAINS[c] "display" OR '
    'eventMessage CONTAINS[c] "workspace" OR eventMessage CONTAINS[c] "activation" OR '
    'eventMessage CONTAINS[c] "accessibility" OR eventMessage CONTAINS[c] "event system" OR '
    'eventMessage CONTAINS[c] "IOHID" OR eventMessage CONTAINS[c] "connection" OR '
    'eventMessage CONTAINS[c] "client" OR eventMessage CONTAINS[c] "service" OR '
    'eventMessage CONTAINS[c] "registration" OR eventMessage CONTAINS[c] "menu" OR '
    'eventMessage CONTAINS[c] "CoreGraphics" OR eventMessage CONTAINS[c] "AppKit" OR '
    'eventMessage CONTAINS[c] "event tap")'
)

SENSITIVE = re.compile(
    r"key\s*code|keyboard|keystroke|clipboard|hid\s+report|report\s+descriptor|"
    r"raw\s+report|mouse\s+delta|\bdx\s*=|\bdy\s*=|\bdelta\s*=|"
    r"payload|unicode|characters?\s*=|scroll\s+delta|\bbuttons?\s*=",
    re.IGNORECASE,
)
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b", re.I)
HEX = re.compile(r"\b0x[0-9a-f]{6,}\b", re.I)
VOLATILE = re.compile(
    r"\b(?:pid|ppid|tid|thread|connection|client|session|activity|transaction)\s*[=:]\s*[^\s,;]+",
    re.I,
)
COORDINATE = re.compile(r"\b(?:x|y|location|position)\s*[=:]\s*[-+]?\d+(?:\.\d+)?", re.I)

stop_requested = False
DEFAULT_MAX_SECONDS = 3600.0


def stop(_signum: int, _frame: object) -> None:
    global stop_requested
    stop_requested = True


def timestamp(value: object) -> tuple[str, int, int]:
    now = time.time_ns()
    if isinstance(value, str) and value:
        text = value.replace("+00:00", "Z")
        return text, now, time.monotonic_ns()
    stamp = dt.datetime.fromtimestamp(now / 1_000_000_000, dt.timezone.utc)
    return stamp.isoformat(timespec="microseconds").replace("+00:00", "Z"), now, time.monotonic_ns()


def scrub_message(value: object) -> str | None:
    if not isinstance(value, str) or not value.strip() or SENSITIVE.search(value):
        return None
    value = UUID.sub("<uuid>", value)
    value = HEX.sub("<hex>", value)
    value = VOLATILE.sub(lambda match: match.group(0).split("=", 1)[0].split(":", 1)[0] + "=<volatile>", value)
    value = COORDINATE.sub(lambda match: match.group(0).split("=", 1)[0].split(":", 1)[0] + "=<coordinate>", value)
    return " ".join(value.split())


def safe_record(value: object) -> dict[str, object] | None:
    if not isinstance(value, dict):
        return None
    message = scrub_message(value.get("eventMessage", value.get("message")))
    if message is None:
        return None
    stamp, epoch_ns, monotonic_ns = timestamp(value.get("timestamp"))
    result: dict[str, object] = {
        "schema": 1,
        "timestamp_utc": stamp,
        "epoch_ns": epoch_ns,
        "monotonic_ns": monotonic_ns,
        "process": value.get("process") or Path(str(value.get("processImagePath", "unknown"))).name,
        "subsystem": value.get("subsystem", "unknown"),
        "category": value.get("category", "unknown"),
        "event_type": value.get("eventType", value.get("type", "unknown")),
        "message": message,
    }
    return result


def decode_json_stream(buffer: str, *, final: bool = False) -> tuple[list[object], str, bool]:
    """Decode objects from `log --style json`'s one long JSON array.

    `log stream --style json` emits an opening bracket and pretty-printed
    objects rather than JSONL. Keep incomplete trailing text between reads so
    records are available during a long-running capture.
    """
    decoder = json.JSONDecoder()
    values: list[object] = []
    while True:
        buffer = buffer.lstrip()
        if not buffer:
            return values, buffer, False
        if buffer[0] in "[,":
            buffer = buffer[1:]
            continue
        if buffer[0] == "]":
            return values, buffer[1:], True
        if buffer[0] != "{":
            newline = buffer.find("\n")
            if newline < 0 and not final:
                return values, buffer, False
            # Filtering preamble or malformed source text is never retained.
            buffer = buffer[newline + 1:] if newline >= 0 else ""
            continue
        try:
            value, end = decoder.raw_decode(buffer)
        except json.JSONDecodeError:
            if final:
                return values, "", False
            return values, buffer, False
        values.append(value)
        buffer = buffer[end:]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: unified_capture.py RUN_DIRECTORY", file=sys.stderr)
        return 2
    run = Path(sys.argv[1])
    raw = run / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    output_path = raw / "unified.jsonl"
    errors_path = raw / "unified-capture-errors.log"
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        child = subprocess.Popen(
            ["log", "stream", "--style", "json", "--level", "info", "--predicate", PREDICATE],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except OSError as exc:
        errors_path.write_text(f"log_start_failed={exc}\n", encoding="utf-8")
        return 3
    with output_path.open("a", encoding="utf-8") as output, errors_path.open("a", encoding="utf-8") as errors:
        assert child.stdout is not None
        buffer = ""
        try:
            max_seconds = float(os.environ.get("ISSUE96_MAX_CAPTURE_SECONDS", DEFAULT_MAX_SECONDS))
        except ValueError:
            errors.write("invalid_capture_limit=true\n")
            return 2
        if max_seconds <= 0:
            errors.write("invalid_capture_limit=true\n")
            return 2
        started = time.monotonic()
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        while not stop_requested:
            elapsed = time.monotonic() - started
            if elapsed >= max_seconds:
                errors.write("capture_limit_reached=true\n")
                errors.flush()
                break
            ready = selector.select(timeout=min(0.5, max_seconds - elapsed))
            if not ready:
                continue
            line = child.stdout.readline()
            if not line:
                break
            buffer += line
            values, buffer, _ = decode_json_stream(buffer)
            for parsed in values:
                safe = safe_record(parsed)
                if safe is not None:
                    output.write(json.dumps(safe, sort_keys=True) + "\n")
                    output.flush()
        selector.close()
        values, buffer, _ = decode_json_stream(buffer, final=True)
        for parsed in values:
            safe = safe_record(parsed)
            if safe is not None:
                output.write(json.dumps(safe, sort_keys=True) + "\n")
                output.flush()
        if stop_requested and child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            errors.write("log_stream_term_timeout=true\n")
        if child.returncode not in (0, -signal.SIGTERM, -signal.SIGINT):
            errors.write(f"log_stream_exit={child.returncode}\n")
        if child.stderr is not None:
            stderr = child.stderr.read().strip()
            if stderr:
                # Do not copy log tool diagnostics into the selected evidence.
                errors.write("log_stream_stderr=present\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
