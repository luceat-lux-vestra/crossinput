#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("codeql-scope.py")
SPEC = importlib.util.spec_from_file_location("codeql_scope", MODULE_PATH)
assert SPEC and SPEC.loader
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


class CodeqlScopeTests(unittest.TestCase):
    def classify(self, records, count=None):
        return SCOPE.classify(records, len(records) if count is None else count)

    def assert_impacts(self, records, *, swift=False, java=False, python=False, count=None):
        result = self.classify(records, count)
        self.assertTrue(result["actions_impact"])
        self.assertEqual(result["swift_impact"], swift)
        self.assertEqual(result["java_impact"], java)
        self.assertEqual(result["python_impact"], python)
        return result

    def test_docs_and_unrelated_files_do_not_trigger_heavy_languages(self):
        self.assert_impacts([
            {"status": "modified", "filename": "CHANGELOG.md"},
            {"status": "modified", "filename": "docs/testing.md"},
        ])

    def test_swift_tree_triggers_swift(self):
        self.assert_impacts(
            [{"status": "modified", "filename": "apps/macos/Sources/App/App.swift"}],
            swift=True,
        )
        self.assert_impacts(
            [{"status": "modified", "filename": "apps/macos/Package.swift"}],
            swift=True,
        )
        self.assert_impacts(
            [{"status": "modified", "filename": "apps/macos/Resources/Info.plist"}],
            swift=True,
        )

    def test_android_tree_and_codeql_build_helpers_trigger_java(self):
        paths = [
            "android/helper/app/src/main/java/com/crossinput/helper/Main.kt",
            "android/helper/build.gradle.kts",
            "android/helper/gradle/wrapper/gradle-wrapper.jar",
            "scripts/setup-android-arm64-build-tools.sh",
            "scripts/check-android-toolchain.sh",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.assert_impacts(
                    [{"status": "modified", "filename": path}],
                    java=True,
                )

    def test_python_source_and_configuration_trigger_python(self):
        paths = [
            "scripts/check-workflow-policy.py",
            "tools/example.pyi",
            "pyproject.toml",
            "requirements-dev.txt",
            "uv.lock",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.assert_impacts(
                    [{"status": "modified", "filename": path}],
                    python=True,
                )

    def test_mixed_swift_and_android_changes_trigger_both(self):
        self.assert_impacts(
            [
                {"status": "modified", "filename": "apps/macos/Sources/App/App.swift"},
                {
                    "status": "modified",
                    "filename": "android/helper/app/src/main/java/com/crossinput/helper/Main.kt",
                },
            ],
            swift=True,
            java=True,
        )

    def test_non_codeql_workflow_change_keeps_actions_only(self):
        self.assert_impacts(
            [{"status": "modified", "filename": ".github/workflows/ci.yml"}]
        )

    def test_codeql_control_changes_force_full_scan(self):
        paths = [
            ".github/workflows/codeql.yml",
            "scripts/codeql-scope.py",
            ".github/codeql/config.yml",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.assert_impacts(
                    [{"status": "modified", "filename": path}],
                    swift=True,
                    java=True,
                    python=True,
                )

    def test_rename_and_copy_check_previous_path(self):
        self.assert_impacts(
            [{
                "status": "renamed",
                "filename": "docs/old-app.md",
                "previous_filename": "apps/macos/Sources/App/Old.swift",
            }],
            swift=True,
        )
        self.assert_impacts(
            [{
                "status": "copied",
                "filename": "docs/copied.md",
                "previous_filename": "android/helper/app/src/main/java/example/Old.kt",
            }],
            java=True,
        )

    def test_removed_inputs_still_trigger(self):
        self.assert_impacts(
            [{"status": "removed", "filename": "apps/macos/Package.swift"}],
            swift=True,
        )
        self.assert_impacts(
            [{"status": "removed", "filename": "android/helper/build.gradle.kts"}],
            java=True,
        )

    def test_unknown_or_malformed_evidence_fails_closed(self):
        cases = [
            ([{"status": "mystery", "filename": "docs/x.md"}], 1),
            ([{}], 1),
            ([{"status": "modified", "filename": "../src/lib.py"}], 1),
            ([{"status": "renamed", "filename": "docs/x.md"}], 1),
            ([{"status": "modified", "filename": "docs/x.md", "previous_filename": "docs/y.md"}], 1),
            ([], 0),
        ]
        for records, count in cases:
            with self.subTest(records=records, count=count):
                result = self.assert_impacts(
                    records,
                    swift=True,
                    java=True,
                    python=True,
                    count=count,
                )
                self.assertNotEqual(result["reason"], "no-heavy-language-input-change")

    def test_count_mismatch_fails_closed(self):
        self.assert_impacts(
            [{"status": "modified", "filename": "docs/x.md"}],
            swift=True,
            java=True,
            python=True,
            count=2,
        )

    def test_flatten_pages_accepts_slurp_and_single_page_shapes(self):
        row = {"status": "modified", "filename": "docs/x.md"}
        self.assertEqual(SCOPE.flatten_pages([[row]]), [row])
        self.assertEqual(SCOPE.flatten_pages([row]), [row])

    def test_bad_page_shape_fails_closed(self):
        result = SCOPE.classify_payload({"changed_files": 1}, [["bad-record"]])
        self.assertTrue(result["swift_impact"])
        self.assertTrue(result["java_impact"])
        self.assertTrue(result["python_impact"])
        self.assertTrue(result["reason"].startswith("metadata-error:"))

    def test_cli_input_failure_emits_full_scan(self):
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            meta = root / "meta.json"
            pages = root / "pages.json"
            out = root / "result.json"
            ghout = root / "github-output.txt"

            meta.write_text("{not-json", encoding="utf-8")
            pages.write_text("[]", encoding="utf-8")

            rc = SCOPE.main([
                "--meta", str(meta),
                "--pages", str(pages),
                "--output-json", str(out),
                "--github-output", str(ghout),
            ])
            self.assertEqual(rc, 0)

            result = json.loads(out.read_text(encoding="utf-8"))
            self.assertTrue(result["swift_impact"])
            self.assertTrue(result["java_impact"])
            self.assertTrue(result["python_impact"])
            output = ghout.read_text(encoding="utf-8")
            self.assertIn("actions_impact=true", output)
            self.assertIn("swift_impact=true", output)
            self.assertIn("java_impact=true", output)
            self.assertIn("python_impact=true", output)


if __name__ == "__main__":
    unittest.main()
