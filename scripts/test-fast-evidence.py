#!/usr/bin/env python3
"""Regression fixtures for the ready-for-review exact-SHA evidence resolver."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOLVER_PATH = ROOT / "scripts" / "resolve-fast-evidence.py"

spec = importlib.util.spec_from_file_location("resolve_fast_evidence", RESOLVER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Could not load {RESOLVER_PATH}")
resolver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = resolver
spec.loader.exec_module(resolver)


def run_payload(run_id: int, conclusion: str, *, status: str = "completed") -> dict:
    return {
        "id": run_id,
        "head_sha": "candidate",
        "event": "pull_request",
        "status": status,
        "conclusion": conclusion,
    }


class FastEvidenceResolverTests(unittest.TestCase):
    def env(self, output: str) -> dict[str, str]:
        return {
            "GITHUB_REPOSITORY": "luceat-lux-vestra/crossinput",
            "BASE_SHA": "base",
            "EXPECTED_SHA": "candidate",
            "EXPECTED_JOB": "Android Helper Build + Test",
            "GITHUB_RUN_ID": "999",
            "GITHUB_OUTPUT": output,
            "SAME_REPOSITORY": "true",
            "FAST_EVIDENCE_MAX_ATTEMPTS": "1",
            "FAST_EVIDENCE_SLEEP_SECONDS": "0",
        }

    def read_output(self, path: str) -> str:
        return pathlib.Path(path).read_text(encoding="utf-8")

    def test_successful_exact_sha_producer_is_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            api = mock.Mock(
                side_effect=[
                    {"workflow_runs": [run_payload(123, "success")]},
                    {
                        "jobs": [
                            {
                                "name": "Android Helper Build + Test",
                                "status": "completed",
                                "conclusion": "success",
                            }
                        ]
                    },
                ]
            )
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["same", "same"]
                ),
                mock.patch.object(resolver, "_api_json", api),
            ):
                self.assertEqual(resolver.resolve(), 0)
            self.assertEqual(self.read_output(output), "reuse=true\n")

    def test_completed_failure_remains_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["same", "same"]
                ),
                mock.patch.object(
                    resolver,
                    "_api_json",
                    return_value={"workflow_runs": [run_payload(123, "failure")]},
                ),
            ):
                with self.assertRaisesRegex(
                    resolver.EvidenceFailure, "concluded 'failure'"
                ):
                    resolver.resolve()
            self.assertFalse(pathlib.Path(output).exists())

    def test_cancelled_latest_producer_falls_back_locally(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            payload = {
                "workflow_runs": [
                    run_payload(120, "success"),
                    run_payload(121, "cancelled"),
                ]
            }
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["same", "same"]
                ),
                mock.patch.object(resolver, "_api_json", return_value=payload),
            ):
                self.assertEqual(resolver.resolve(), 0)
            self.assertEqual(self.read_output(output), "reuse=false\n")

    def test_workflow_mismatch_falls_back_without_querying_runs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            api = mock.Mock()
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["base-blob", "head-blob"]
                ),
                mock.patch.object(resolver, "_api_json", api),
            ):
                self.assertEqual(resolver.resolve(), 0)
            api.assert_not_called()
            self.assertEqual(self.read_output(output), "reuse=false\n")

    def test_successful_workflow_with_failed_expected_job_is_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            api = mock.Mock(
                side_effect=[
                    {"workflow_runs": [run_payload(123, "success")]},
                    {
                        "jobs": [
                            {
                                "name": "Android Helper Build + Test",
                                "status": "completed",
                                "conclusion": "failure",
                            }
                        ]
                    },
                ]
            )
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["same", "same"]
                ),
                mock.patch.object(resolver, "_api_json", api),
            ):
                with self.assertRaisesRegex(
                    resolver.EvidenceFailure, "status=completed conclusion=failure"
                ):
                    resolver.resolve()

    def test_no_completed_evidence_falls_back_to_local_final_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = str(pathlib.Path(directory) / "output")
            with (
                mock.patch.dict(os.environ, self.env(output), clear=True),
                mock.patch.object(
                    resolver, "workflow_blob_sha", side_effect=["same", "same"]
                ),
                mock.patch.object(
                    resolver, "_api_json", return_value={"workflow_runs": []}
                ),
            ):
                self.assertEqual(resolver.resolve(), 0)
            self.assertEqual(self.read_output(output), "reuse=false\n")


class FinalGateStructureTests(unittest.TestCase):
    def test_all_final_components_remain_behind_fail_closed_merge_gate(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "lib"))
        import workflow_yaml

        workflow = workflow_yaml.load_file(str(ROOT / ".github" / "workflows" / "ci.yml"))
        jobs = workflow["jobs"]

        expected_reuse_consumers = {"macos-app", "android-helper", "markdown", "scripts"}
        for job_id in expected_reuse_consumers:
            names = {step.get("name") for step in jobs[job_id].get("steps", [])}
            self.assertIn("Reuse exact-SHA Fast evidence", names)

        gate = jobs["mergeGate"]
        self.assertEqual(
            set(gate["needs"]),
            {
                "macos-app",
                "macos-15-compat",
                "android-helper",
                "markdown",
                "scripts",
                "dependencyReview",
            },
        )
        self.assertEqual(gate["if"], "${{ always() }}")
        gate_script = gate["steps"][0]["run"]
        self.assertIn('if [ "$result" != "success" ]', gate_script)
        self.assertIn('exit "$failed"', gate_script)


if __name__ == "__main__":
    unittest.main()
