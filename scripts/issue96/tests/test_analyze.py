#!/usr/bin/env python3
"""Fixture-backed pure tests for the Issue #96 semantic analyzer."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import analyze  # noqa: E402
import unified_capture  # noqa: E402


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "complete-run"


def analyze_json_stream_fixture() -> tuple[list[object], str, bool]:
    """Feed the same bracketed shape emitted by macOS log stream."""
    buffer = "Filtering the log data using predicate\n[\n"
    buffer += json.dumps({
        "eventMessage": "cursor tracking refreshed",
        "processImagePath": "/System/Library/PrivateFrameworks/SkyLight.framework/WindowServer",
        "timestamp": "2026-08-30 10:05:07.000000+0000",
    })
    buffer += ",\n"
    first, remainder, closed = unified_capture.decode_json_stream(buffer)
    # Leave one complete second object for the final decoder call.
    remainder += json.dumps({
        "eventMessage": "keyboard keyCode=12",
        "processImagePath": "/System/Library/PrivateFrameworks/SkyLight.framework/WindowServer",
        "timestamp": "2026-08-30 10:05:08.000000+0000",
    })
    return first, remainder, closed


class Issue96AnalyzerTests(unittest.TestCase):
    def copy_fixture(self, root: Path, name: str = "run-001") -> Path:
        destination = root / name
        shutil.copytree(FIXTURE, destination)
        return destination

    def test_timestamp_parsing_accepts_iso_and_compact_forms(self) -> None:
        self.assertAlmostEqual(
            analyze.parse_timestamp("2026-08-30T10:05:00.123456Z"),
            analyze.parse_timestamp("2026-08-30 10:05:00.123456+00:00"),
        )
        self.assertAlmostEqual(analyze.parse_timestamp("10:05:00.250"), 36300.25)
        with self.assertRaises(analyze.EvidenceError):
            analyze.parse_timestamp("not-a-time")

    def test_unified_json_array_stream_is_decoded_and_payload_is_dropped(self) -> None:
        first, remainder, closed = analyze_json_stream_fixture()
        self.assertFalse(closed)
        second, remainder, closed = unified_capture.decode_json_stream(remainder + "\n]", final=True)
        self.assertTrue(closed)
        values = first + second
        self.assertEqual(len(values), 2)
        self.assertIsNotNone(unified_capture.safe_record(values[0]))
        self.assertIsNone(unified_capture.safe_record(values[1]))

    def test_unified_capture_predicate_is_bounded_and_state_oriented(self) -> None:
        self.assertIn("SystemUIServer", unified_capture.PREDICATE)
        self.assertIn("WindowServer", unified_capture.PREDICATE)
        self.assertIn("CoreGraphics", unified_capture.PREDICATE)
        self.assertEqual(unified_capture.DEFAULT_MAX_SECONDS, 3600.0)

    def test_marker_parsing_requires_ordered_unique_markers(self) -> None:
        run = analyze.load_run(FIXTURE)
        markers = analyze.load_markers(run)
        self.assertEqual(tuple(markers), ("healthy", "broken", "recovered"))
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            with (copied / "markers.jsonl").open("a", encoding="utf-8") as fh:
                fh.write("{\"marker\":\"broken\",\"run_id\":\"run-001\",\"timestamp_utc\":\"2026-08-30T11:00:00Z\"}\n")
            with self.assertRaises(analyze.EvidenceError):
                analyze.load_markers(analyze.load_run(copied))

    def test_json_normalization_removes_volatile_fields(self) -> None:
        records = analyze.normalize_json({
            "pid": 42,
            "uuid": "11111111-1111-4111-8111-111111111111",
            "stable": "mouse",
            "nested": {"connection_id": 99, "transport": "USB"},
        })
        self.assertEqual(records, ["nested.transport=USB", "stable=mouse"])
        self.assertEqual(analyze.normalize_text_line("42 1 /SystemUIServer pid=42 x=100"),
                         "/SystemUIServer pid=<volatile> x=<coordinate>")
        self.assertEqual(analyze.normalize_text_line("RegistryID 0x1000009fd LocationID=0x12340000"),
                         "RegistryID 0x1000009fd LocationID=0x12340000")

    def test_snapshot_grouping_and_pid_noise_removal(self) -> None:
        run = analyze.load_run(FIXTURE)
        snapshots = analyze.snapshot_paths(run)
        healthy = analyze.snapshot_records(snapshots["healthy"])
        broken = analyze.snapshot_records(snapshots["broken"])
        recovered = analyze.snapshot_records(snapshots["recovered"])
        self.assertIn("HID / pointing", healthy)
        self.assertIn("display", healthy)
        self.assertEqual(analyze.delta(healthy, broken), {})
        self.assertEqual(analyze.delta(broken, recovered), {})

    def test_complete_fixture_has_restart_and_report_is_human_observation_only(self) -> None:
        result = analyze.analyze_run(FIXTURE)
        self.assertEqual(result["status"], "COMPLETE")
        self.assertEqual(result["restart"]["old_pid"], 111)
        self.assertEqual(result["restart"]["new_pid"], 222)
        report = analyze.render_run_report(result)
        self.assertIn("does not prove that `SystemUIServer` owns", report)
        self.assertIn("rendered native cursor remains human-observed", report)
        self.assertNotIn("cursor shape: HEALTHY", report)

    def test_failed_command_and_missing_file_are_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            meta_path = copied / "snapshots" / "002-broken" / "snapshot.meta.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            meta["commands"][0]["status"] = "failed"
            meta_path.write_text(json.dumps(meta), encoding="utf-8")
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            (copied / "snapshots" / "003-recovered" / "iohid-event-system.txt").unlink()
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)

    def test_malformed_unified_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            with (copied / "raw" / "unified.jsonl").open("a", encoding="utf-8") as fh:
                fh.write("not-json\n")
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)

    def test_unified_capture_error_sidecar_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            (copied / "raw" / "unified-capture-errors.log").write_text(
                "capture_limit_reached=true\n", encoding="utf-8")
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)

    def test_missing_systemuiserver_restart_is_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            lifecycle = copied / "raw" / "systemuiserver-lifecycle.jsonl"
            lifecycle.write_text(lifecycle.read_text(encoding="utf-8").splitlines()[0] + "\n", encoding="utf-8")
            result = analyze.analyze_run(copied)
            self.assertEqual(result["status"], "INCOMPLETE")
            self.assertIn("no SystemUIServer exit/new-PID", result["reasons"][0])

    def test_repeated_run_intersection_promotes_only_recurring_delta(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = []
            for index in (1, 2):
                run = self.copy_fixture(root, f"run-00{index}")
                for path in run.rglob("*"):
                    if path.is_file():
                        data = path.read_text(encoding="utf-8")
                        path.write_text(data.replace("run-001", f"run-00{index}"), encoding="utf-8")
                service = run / "snapshots" / "003-recovered" / "systemuiserver-service.txt"
                service.write_text(service.read_text(encoding="utf-8") + "registration_refresh = observed\n", encoding="utf-8")
                results.append(analyze.analyze_run(run))
            report = analyze.compare_runs(results)
            self.assertIn("HIGH` recurring candidate", report)
            self.assertIn("registration_refresh", report)

    def test_comparison_rejects_duplicate_run_ids(self) -> None:
        result = analyze.analyze_run(FIXTURE)
        with self.assertRaises(analyze.EvidenceError):
            analyze.compare_runs([result, result])

    def test_comparison_rejects_mismatched_source_sha(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary), "run-002")
            data = json.loads((copied / "run.json").read_text(encoding="utf-8"))
            data["source_sha"] = "different-source"
            (copied / "run.json").write_text(json.dumps(data), encoding="utf-8")
            second = analyze.analyze_run(copied)
        first = analyze.analyze_run(FIXTURE)
        with self.assertRaises(analyze.EvidenceError):
            analyze.compare_runs([first, second])


if __name__ == "__main__":
    unittest.main(verbosity=2)
