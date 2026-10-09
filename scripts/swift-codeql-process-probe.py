#!/usr/bin/env python3
"""Diagnostic-only, argument-free process snapshots for the Swift CodeQL autobuilder.

Only records PID, parent PID, process basename, CPU% and timestamp.
Never logs command arguments, environment, URLs, credentials or source contents.
"""
import collections
import os
import pathlib
import subprocess
import sys
import time

NAMES = {
    "swift", "swiftc", "swift-frontend", "swift-driver", "swift-build",
    "swift-autobuilder", "swift-package", "swift-plugin-server",
    "xcodebuild", "XCBBuildService", "clang", "clang-17", "ld", "ld64",
    "codeql", "java", "codesign", "dsymutil", "git", "curl",
}
INTERVAL_SECONDS = 5
MAX_SECONDS = 25 * 60


def sample_file(path, stop):
    start = time.monotonic()
    with open(path, "w", encoding="utf-8") as sink:
        sink.write("relative_seconds\tpid\tppid\tcpu_percent\tprogram\n")
        sink.flush()
        while time.monotonic() - start <= MAX_SECONDS and not os.path.exists(stop):
            elapsed = round(time.monotonic() - start)
            result = subprocess.run(
                ["ps", "-axo", "pid=,ppid=,pcpu=,comm="],
                capture_output=True, text=True, check=True,
            )
            for line in result.stdout.splitlines():
                columns = line.strip().split(maxsplit=3)
                if len(columns) != 4:
                    continue
                pid, ppid, cpu, executable = columns
                name = pathlib.PurePath(executable).name
                if name not in NAMES:
                    continue
                sink.write(f"{elapsed}\t{pid}\t{ppid}\t{cpu}\t{name}\n")
            sink.flush()
            time.sleep(INTERVAL_SECONDS)


def report(path, stop):
    pathlib.Path(stop).touch()
    if not os.path.isfile(path):
        raise SystemExit("Swift CodeQL process probe missing: NOT VERIFIED")
    rows = []
    with open(path, encoding="utf-8") as source:
        next(source)
        for line in source:
            tokens = line.rstrip("\n").split("\t")
            if len(tokens) != 5:
                raise SystemExit("Malformed Swift CodeQL process profile: NOT VERIFIED")
            rel, pid, ppid, cpu, name = tokens
            rows.append((int(rel), pid, ppid, float(cpu), name))
    if not rows:
        raise SystemExit("Swift CodeQL process sampler recorded no processes")
    print("Swift CodeQL process profile (5s sampling, argument-free)")
    print("Records:", len(rows), "last sample:", max(r[0] for r in rows), "seconds")
    seen = collections.defaultdict(lambda: collections.defaultdict(list))
    for rel, _pid, _ppid, cpu, name in rows:
        seen[(rel // 30) * 30][name].append(cpu)
    for interval in sorted(seen):
        processes = seen[interval]
        line = ", ".join(
            f"{name}:n{len(values)},peak{max(values):.0f}%"
            for name, values in sorted(processes.items())
        )
        print(f"t+{interval:04d}-{interval+29:04d}s {line}")
    names = {r[4] for r in rows}
    print("Observed process families:", ", ".join(sorted(names)))
    # A snapshot cannot prove that absent process names were not running between samples.
    # The mandatory CodeQL database and scan outcome remain the actual validation gate.


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in {"sample", "report"}:
        raise SystemExit("usage: swift-codeql-process-probe.py sample|report FILE STOP_FILE")
    if sys.argv[1] == "sample":
        sample_file(sys.argv[2], sys.argv[3])
    else:
        report(sys.argv[2], sys.argv[3])
