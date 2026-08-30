#!/usr/bin/env python3
"""Low-rate SystemUIServer PID lifecycle anchor for Issue #96."""

from __future__ import annotations

import datetime as dt
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


POLL_SECONDS = 0.5
running = True


def stop(_signum: int, _frame: object) -> None:
    global running
    running = False


def stamp() -> tuple[str, int, int]:
    epoch_ns = time.time_ns()
    value = dt.datetime.fromtimestamp(epoch_ns / 1_000_000_000, dt.timezone.utc)
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z"), epoch_ns, time.monotonic_ns()


def pids() -> list[int]:
    try:
        output = subprocess.check_output(["pgrep", "-x", "SystemUIServer"], text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return []
    values = []
    for item in output.split():
        try:
            values.append(int(item))
        except ValueError:
            continue
    return sorted(set(values))


def process_metadata(pid: int) -> dict[str, object]:
    try:
        output = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "pid=,ppid=,comm="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return {"pid": pid}
    fields = output.split(None, 2)
    result: dict[str, object] = {"pid": pid}
    if len(fields) >= 1:
        result["observed_pid"] = fields[0]
    if len(fields) >= 2:
        result["parent_pid"] = fields[1]
    if len(fields) >= 3:
        result["command"] = fields[2]
    return result


def emit(handle, event: str, pid: int | None = None) -> None:
    timestamp, epoch_ns, monotonic_ns = stamp()
    value: dict[str, object] = {
        "schema": 1,
        "timestamp_utc": timestamp,
        "epoch_ns": epoch_ns,
        "monotonic_ns": monotonic_ns,
        "event": event,
    }
    if pid is not None:
        value.update(process_metadata(pid))
    handle.write(json.dumps(value, sort_keys=True) + "\n")
    handle.flush()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: lifecycle_monitor.py RUN_DIRECTORY", file=sys.stderr)
        return 2
    run = Path(sys.argv[1])
    path = run / "raw" / "systemuiserver-lifecycle.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with path.open("a", encoding="utf-8") as handle:
        current = set(pids())
        for pid in sorted(current):
            emit(handle, "present", pid)
        while running:
            time.sleep(POLL_SECONDS)
            observed = set(pids())
            for pid in sorted(current - observed):
                emit(handle, "exited", pid)
            for pid in sorted(observed - current):
                emit(handle, "launched", pid)
            current = observed
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
