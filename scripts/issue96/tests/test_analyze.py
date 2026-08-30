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

    def rename_fixture_run(self, run: Path, run_id: str) -> None:
        for path in run.rglob("*"):
            if path.is_file():
                path.write_text(path.read_text(encoding="utf-8").replace("run-001", run_id), encoding="utf-8")

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
        self.assertEqual(result["restart"]["broken_marker_pids"], [111])
        self.assertEqual(result["restart"]["recovered_marker_pids"], [222])
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
            self.assertTrue(any("no marker-bound SystemUIServer exit/new-PID" in reason
                                for reason in result["reasons"]))

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
            data["harness_source_sha"] = "different-source"
            (copied / "run.json").write_text(json.dumps(data), encoding="utf-8")
            second = analyze.analyze_run(copied)
        first = analyze.analyze_run(FIXTURE)
        with self.assertRaises(analyze.EvidenceError):
            analyze.compare_runs([first, second])

    def assert_incomplete(self, run: Path, reason: str) -> dict[str, object]:
        result = analyze.analyze_run(run)
        self.assertEqual(result["status"], "INCOMPLETE")
        self.assertTrue(any(reason in item for item in result["reasons"]), result["reasons"])
        return result

    def load_json(self, path: Path) -> object:
        return json.loads(path.read_text(encoding="utf-8"))

    def write_json(self, path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def test_restart_binding_rejects_unrelated_restart_before_broken(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            lifecycle = [
                {"event": "present", "pid": 111, "timestamp_utc": "2026-08-30T10:00:00Z"},
                {"event": "exited", "pid": 111, "timestamp_utc": "2026-08-30T10:04:55Z"},
                {"event": "launched", "pid": 222, "timestamp_utc": "2026-08-30T10:04:56Z"},
            ]
            (copied / "raw/systemuiserver-lifecycle.jsonl").write_text(
                "\n".join(json.dumps(item) for item in lifecycle) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "no marker-bound SystemUIServer exit/new-PID")

    def test_restart_binding_rejects_old_pid_not_in_broken_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            lifecycle = copied / "raw/systemuiserver-lifecycle.jsonl"
            records = [json.loads(line) for line in lifecycle.read_text(encoding="utf-8").splitlines()]
            records[1]["pid"] = 999
            lifecycle.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "exit PID does not match the BROKEN marker PID")

    def test_restart_binding_rejects_new_pid_not_in_recovered_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            lifecycle = copied / "raw/systemuiserver-lifecycle.jsonl"
            records = [json.loads(line) for line in lifecycle.read_text(encoding="utf-8").splitlines()]
            records[2]["pid"] = 333
            lifecycle.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "launch PID does not match the RECOVERED marker PID")

    def test_restart_binding_rejects_same_only_marker_pid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            markers = copied / "markers.jsonl"
            records = [json.loads(line) for line in markers.read_text(encoding="utf-8").splitlines()]
            records[2]["systemuiserver_pids"] = [111]
            markers.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "same only SystemUIServer PID")

    def test_restart_binding_rejects_missing_marker_pid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            markers = copied / "markers.jsonl"
            records = [json.loads(line) for line in markers.read_text(encoding="utf-8").splitlines()]
            records[1]["systemuiserver_pids"] = []
            markers.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "BROKEN marker has no usable SystemUIServer PID")

    def test_restart_binding_rejects_multiple_ambiguous_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            markers = copied / "markers.jsonl"
            marker_records = [json.loads(line) for line in markers.read_text(encoding="utf-8").splitlines()]
            marker_records[1]["systemuiserver_pids"] = [111, 444]
            marker_records[2]["systemuiserver_pids"] = [222, 555]
            markers.write_text("\n".join(json.dumps(item) for item in marker_records) + "\n", encoding="utf-8")
            lifecycle = copied / "raw/systemuiserver-lifecycle.jsonl"
            records = [json.loads(line) for line in lifecycle.read_text(encoding="utf-8").splitlines()]
            records.extend([
                {"event": "exited", "pid": 444, "timestamp_utc": "2026-08-30T10:05:07Z"},
                {"event": "launched", "pid": 555, "timestamp_utc": "2026-08-30T10:05:08Z"},
            ])
            lifecycle.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            self.assert_incomplete(copied, "multiple marker-bound SystemUIServer restart candidates")

    def test_shutdown_contract_clean_stopped_run_is_allowed(self) -> None:
        self.assertEqual(analyze.analyze_run(FIXTURE)["status"], "COMPLETE")

    def test_shutdown_contract_rejects_running_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            data = self.load_json(copied / "run.json")
            assert isinstance(data, dict)
            data["state"] = "running"
            self.write_json(copied / "run.json", data)
            self.assert_incomplete(copied, "capture state is not stopped")

    def test_shutdown_contract_rejects_missing_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            data = self.load_json(copied / "run.json")
            assert isinstance(data, dict)
            del data["shutdown"]
            self.write_json(copied / "run.json", data)
            self.assert_incomplete(copied, "clean shutdown metadata is missing")

    def test_shutdown_contract_rejects_forced_kill(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            data = self.load_json(copied / "run.json")
            assert isinstance(data, dict)
            data["shutdown"]["forced_kill"] = True
            data["shutdown"]["clean"] = False
            self.write_json(copied / "run.json", data)
            self.assert_incomplete(copied, "capture shutdown used forced cleanup")

    def test_shutdown_contract_rejects_malformed_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            data = self.load_json(copied / "run.json")
            assert isinstance(data, dict)
            data["shutdown"] = "malformed"
            self.write_json(copied / "run.json", data)
            self.assert_incomplete(copied, "clean shutdown metadata is missing")

    def test_evidence_contract_accepts_explicit_not_available(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            evidence = copied / "snapshots/002-broken/iohid-event-system-client.txt"
            evidence.write_text('{"evidence":"not_available","reason":"not_exposed"}\n', encoding="utf-8")
            meta_path = copied / "snapshots/002-broken/snapshot.meta.json"
            meta = self.load_json(meta_path)
            assert isinstance(meta, dict)
            for command in meta["commands"]:
                if command["name"] == "iohid_event_system_client":
                    command["evidence"] = "not_available"
            self.write_json(meta_path, meta)
            self.assertEqual(analyze.analyze_run(copied)["status"], "COMPLETE")

    def test_evidence_contract_rejects_zero_byte_required_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            (copied / "snapshots/002-broken/iohid-event-system.txt").write_text("", encoding="utf-8")
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)

    def test_evidence_contract_rejects_malformed_sentinel(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            evidence = copied / "snapshots/002-broken/iohid-event-system.txt"
            evidence.write_text('{"evidence":"not_available"}\n', encoding="utf-8")
            with self.assertRaises(analyze.EvidenceError):
                analyze.analyze_run(copied)

    def test_identity_contract_same_harness_and_app_identity_allows_comparison(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.copy_fixture(root, "run-001")
            second = self.copy_fixture(root, "run-002")
            self.rename_fixture_run(second, "run-002")
            report = analyze.compare_runs([analyze.analyze_run(first), analyze.analyze_run(second)])
            self.assertIn("STATUS: COMPLETE", report)

    def test_identity_contract_different_app_build_blocks_comparison(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.copy_fixture(root, "run-001")
            second = self.copy_fixture(root, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            self.rename_fixture_run(second, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            data["crossinput_build_identity"]["bundle_version"] = "2"
            self.write_json(second / "run.json", data)
            report = analyze.compare_runs([analyze.analyze_run(first), analyze.analyze_run(second)])
            self.assertIn("STATUS: INCOMPLETE", report)
            self.assertNotIn("HIGH` recurring candidate", report)

    def test_identity_contract_unknown_app_blocks_high_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.copy_fixture(root, "run-001")
            second = self.copy_fixture(root, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            self.rename_fixture_run(second, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            data["crossinput_build_identity"]["resolved"] = False
            self.write_json(second / "run.json", data)
            report = analyze.compare_runs([analyze.analyze_run(first), analyze.analyze_run(second)])
            self.assertIn("STATUS: INCOMPLETE", report)
            self.assertIn("compatible resolved CrossInput build identities", report)
            self.assertNotIn("HIGH` recurring candidate", report)

    def test_identity_contract_missing_app_metadata_is_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            data = self.load_json(copied / "run.json")
            assert isinstance(data, dict)
            del data["crossinput_build_identity"]
            self.write_json(copied / "run.json", data)
            self.assert_incomplete(copied, "CrossInput build identity is missing or unresolved")

    def test_identity_contract_rejects_missing_identity_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = self.copy_fixture(Path(temporary))
            (copied / "crossinput-build-identity.json").unlink()
            self.assert_incomplete(copied, "crossinput-build-identity.json is missing")

    def test_comparison_rejects_different_evidence_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.copy_fixture(root, "run-001")
            second = self.copy_fixture(root, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            self.rename_fixture_run(second, "run-002")
            data = self.load_json(second / "run.json")
            assert isinstance(data, dict)
            data["evidence_mode"]["include_hidutil"] = True
            self.write_json(second / "run.json", data)
            for meta_path in second.glob("snapshots/*/snapshot.meta.json"):
                meta = self.load_json(meta_path)
                assert isinstance(meta, dict)
                meta["evidence_mode"]["include_hidutil"] = True
                self.write_json(meta_path, meta)
            report = analyze.compare_runs([analyze.analyze_run(first), analyze.analyze_run(second)])
            self.assertIn("STATUS: INCOMPLETE", report)
            self.assertIn("matching evidence modes", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
