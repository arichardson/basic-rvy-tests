#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Unit tests for .github/summarize-test-results.py."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / ".github" / "summarize-test-results.py"


def load_module():
    spec = importlib.util.spec_from_file_location("summarize_test_results", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


S = load_module()


def make_raw(name, result="OK", stdout="", stderr="", duration=0.5):
    return {
        "name": f"rvy - rvy-tests:rvy-{name}",
        "result": result,
        "stdout": stdout,
        "stderr": stderr,
        "duration": duration,
    }


class SummarizeTestResultsTest(unittest.TestCase):
    def test_parse_entry_tap_and_stderr_filtering(self):
        stdout = "\n".join([
            "TAP version 13",
            "ok 1 - passing case",
            "ok 2 - skipped case # SKIP not supported",
            "not ok 3 - known issue # TODO sail quirk",
            "ok 4 - unexpected pass # TODO fixed",
            "not ok 5 - real failure",
            "1..5",
        ])
        stderr = "\n".join([
            "ASan doesn't fully support makecontext/swapcontext",
            "(test program exited with status code 4)",
            "qemu-system-riscv64y: real warning",
        ])
        entry = S.parse_entry(make_raw("riscv64y-test-foo-virt", "ERROR", stdout, stderr))
        self.assertEqual(entry["target"], "riscv64y (virt)")
        self.assertEqual(entry["test"], "test-foo")
        self.assertFalse(entry["ok"])
        self.assertEqual(entry["passed"], 1)
        self.assertEqual(entry["skipped"], 1)
        self.assertEqual(entry["xfail"], 1)
        self.assertEqual(entry["failed"], 2)
        self.assertEqual(entry["total"], 5)
        self.assertEqual(entry["stderr"], "qemu-system-riscv64y: real warning")

    def test_parse_entry_timeout_without_tap_lines(self):
        entry = S.parse_entry(make_raw("sail-0.9.9-rv64-test-bar", "TIMEOUT"))
        self.assertEqual(entry["target"], "sail-0.9.9-rv64")
        self.assertEqual(entry["test"], "test-bar")
        self.assertFalse(entry["ok"])
        self.assertEqual(entry["total"], 0)
        self.assertEqual(entry["failed"], 1)

    def test_is_new_failure_comparisons(self):
        ok = S.parse_entry(make_raw("riscv64y-test-a-virt", "OK", "ok 1 - a\n1..1\n"))
        fail1 = S.parse_entry(make_raw("riscv64y-test-a-virt", "ERROR", "not ok 1 - a\n1..1\n"))
        fail1_renum = S.parse_entry(
            make_raw("riscv64y-test-a-virt", "ERROR", "ok 1 - x\nnot ok 2 - a\n1..2\n")
        )
        fail2 = S.parse_entry(make_raw("riscv64y-test-a-virt", "ERROR", "not ok 1 - b\n1..1\n"))
        fail_other_target = S.parse_entry(
            make_raw("riscv64y-test-a-spike", "ERROR", "not ok 1 - b\n1..1\n")
        )

        self.assertFalse(S.is_new_failure(ok, None))
        self.assertTrue(S.is_new_failure(fail1, None))
        self.assertTrue(S.is_new_failure(fail1, ok))
        self.assertFalse(S.is_new_failure(fail1_renum, fail1))
        self.assertTrue(S.is_new_failure(fail2, fail1))
        self.assertFalse(S.is_new_failure(fail1, fail_other_target))

    def test_target_sorting_and_compacting(self):
        targets = [
            "riscv32cheristd (spike)",
            "riscv64y (spike)",
            "sail-0.9.9-rv32",
            "riscv64y (virt)",
            "sail-0.9.9-rv64",
            "sail-0.9.10-rv64",
        ]
        self.assertEqual(
            sorted(targets, key=S.target_sort_key),
            [
                "sail-0.9.10-rv64",
                "sail-0.9.9-rv64",
                "sail-0.9.9-rv32",
                "riscv64y (virt)",
                "riscv64y (spike)",
                "riscv32cheristd (spike)",
            ],
        )
        self.assertEqual(
            S.compact_targets(["riscv64y (virt)", "riscv64y (spike)", "sail-0.9.9-rv64"]),
            ["riscv64y (spike, virt)", "sail-0.9.9-rv64"],
        )

    def test_find_test_source_resolves_variants_and_lines(self):
        for variant, expected_file in [
            ("test-console", "src/test-console.S"),
            ("test-console-no-target-info", "src/test-console.S"),
            ("test-misa-y-no-zyhybrid", "src/test-misa-y.S"),
            ("test-local-global-no-zylg", "src/test-local-global.S"),
            ("test-ifetch-exception-priority-no-pmp", "src/test-ifetch-exception-priority.S"),
        ]:
            path, line = S.find_test_source(variant, [])
            self.assertEqual(path, expected_file)
            self.assertEqual(line, 1)

        entry = S.parse_entry(
            make_raw(
                "riscv64y-test-misa-y-no-zyhybrid-virt",
                "ERROR",
                "not ok 1 - misa.Y is set at reset\n1..1\n",
            )
        )
        path, line = S.find_test_source("test-misa-y-no-zyhybrid", [entry])
        self.assertEqual(path, "src/test-misa-y.S")
        self.assertIsNotNone(line)
        self.assertGreater(line, 1)
        src_line = (REPO_ROOT / path).read_text(encoding="utf-8").splitlines()[line - 1]
        self.assertIn('NEXT_TEST "misa.Y is set at reset"', src_line)

        self.assertEqual(S.find_test_source("test-does-not-exist", []), (None, None))

    def test_build_test_annotations_caps_overflow(self):
        failures = [
            S.parse_entry(make_raw(f"riscv64y-test-t{i:02d}-virt", "ERROR", f"not ok 1 - f{i}\n1..1\n"))
            for i in range(12)
        ]
        annotations = S.build_test_annotations(failures)
        self.assertEqual(len(annotations), S.MAX_GHA_ANNOTATIONS)
        _, _, overflow_title, overflow_body = annotations[-1]
        self.assertIn("4 more failing tests:", overflow_title)
        self.assertIn("test-t08", overflow_body)
        self.assertIn("test-t11", overflow_body)

    def test_cli_markdown_and_baseline_diff(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            base_log = tmp / "base.json"
            curr_log = tmp / "curr.json"
            md_out = tmp / "summary.md"

            base_entries = [
                make_raw("sail-0.9.9-rv64-test-a", "OK", "ok 1 - a\n1..1\n"),
                make_raw("sail-0.9.9-rv64-test-b", "ERROR", "not ok 1 - b\n1..1\n"),
                make_raw("sail-0.9.9-rv64-test-c", "ERROR", "not ok 1 - c\n1..1\n"),
            ]
            curr_entries = [
                make_raw("sail-0.9.9-rv64-test-a", "OK", "ok 1 - a\n1..1\n"),
                make_raw("sail-0.9.9-rv64-test-b", "OK", "ok 1 - b\n1..1\n"),
                make_raw("sail-0.9.9-rv64-test-c", "ERROR", "not ok 1 - c\n1..1\n"),
                make_raw("sail-0.9.9-rv64-test-d", "OK", "ok 1 - d\n1..1\n"),
            ]
            base_log.write_text("\n".join(json.dumps(e) for e in base_entries) + "\n", encoding="utf-8")
            curr_log.write_text("\n".join(json.dumps(e) for e in curr_entries) + "\n", encoding="utf-8")

            proc = subprocess.run(
                [sys.executable, str(SCRIPT_PATH), "--markdown", str(md_out), str(curr_log), str(base_log)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            md = md_out.read_text(encoding="utf-8")
            self.assertIn("#### Pre-existing Failures on `main`", md)
            self.assertNotIn("#### New Failures", md)
            self.assertIn("`test-b` | ✅ 1/1 (fixed)", md)
            self.assertIn("`test-d` | ✅ 1/1 (new)", md)
            self.assertIn("WARN sail-0.9.9-rv64", proc.stdout)

            # Adding a new failure should make the script exit non-zero.
            curr_entries.append(make_raw("sail-0.9.9-rv64-test-e", "ERROR", "not ok 1 - e\n1..1\n"))
            curr_log.write_text("\n".join(json.dumps(e) for e in curr_entries) + "\n", encoding="utf-8")
            proc2 = subprocess.run(
                [sys.executable, str(SCRIPT_PATH), "--markdown", str(md_out), str(curr_log), str(base_log)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc2.returncode, 1)
            md2 = md_out.read_text(encoding="utf-8")
            self.assertIn("#### New Failures (relative to `main`)", md2)
            self.assertIn("`test-e` | ❌ 0/1 (1 fail)", md2)


if __name__ == "__main__":
    unittest.main()
