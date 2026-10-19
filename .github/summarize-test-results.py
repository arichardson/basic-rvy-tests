#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Summarize Meson's testlog.json into a GitHub Markdown and console report."""

import argparse
import collections
import io
import json
import os
from pathlib import Path
import re
import sys

TAP_LINE_RE = re.compile(
    r"^(ok|not ok)\s+(\d+)(?:\s*-\s*(.*?))?(?:\s*#\s*(SKIP|TODO)\b\s*(.*))?$"
)


def parse_entry(raw: dict) -> dict:
    name = raw["name"].removeprefix("rvy - rvy-tests:rvy-")
    if "-test-" in name:
        emu, rest = name.split("-test-", 1)
        if rest.endswith(("-virt", "-spike")):
            rest, machine = rest.rsplit("-", 1)
            target = f"{emu} ({machine})"
        else:
            target = emu
        test = f"test-{rest}"
    else:
        target, test = "default", name

    passed = xfail = skipped = failed = 0
    bad_lines = []
    for line in raw.get("stdout", "").splitlines():
        m = TAP_LINE_RE.match(line)
        if not m:
            continue
        status, _, _, directive, _ = m.groups()
        if directive == "SKIP":
            skipped += 1
        elif directive == "TODO":
            if status == "not ok":
                xfail += 1
            else:
                failed += 1
                bad_lines.append(line)
        elif status == "ok":
            passed += 1
        else:
            failed += 1
            bad_lines.append(line)

    result = raw.get("result", "UNKNOWN")
    ok = result in ("OK", "SKIP", "EXPECTEDFAIL") and failed == 0
    total = passed + xfail + skipped + failed
    if not ok and failed == 0:
        failed = 1
    stderr_lines = [
        line
        for line in raw.get("stderr", "").splitlines()
        if "ASan doesn't fully support makecontext/swapcontext" not in line
        and not line.startswith("(test program exited with status code ")
    ]
    return {
        "target": target,
        "test": test,
        "result": result,
        "ok": ok,
        "passed": passed,
        "xfail": xfail,
        "skipped": skipped,
        "failed": failed,
        "total": total,
        "duration": raw.get("duration", 0.0),
        "bad_lines": bad_lines,
        "norm_bad": {re.sub(r"^(not ok|ok)\s+\d+\s*", r"\1 ", l) for l in bad_lines},
        "stdout": raw.get("stdout", "").strip(),
        "stderr": "\n".join(stderr_lines).strip(),
    }


def load_log(path: Path) -> list[dict]:
    return [
        parse_entry(json.loads(line))
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def is_new_failure(e: dict, b: dict | None) -> bool:
    if e["ok"]:
        return False
    if b is None or b["ok"]:
        return True
    if e["total"] == 0 and b["total"] == 0:
        return False
    return e["failed"] > b["failed"] or not (e["norm_bad"] <= b["norm_bad"])


def fmt_delta(curr: int, base: int | None, show_zero: bool = False) -> str:
    if base is None:
        return str(curr)
    diff = curr - base
    if diff != 0:
        return f"{curr} ({diff:+d})"
    return f"{curr} (+0)" if show_zero and curr > 0 else str(curr)


def format_cell(r: dict | None, b: dict | None, has_target_base: bool = False) -> str:
    if r is None:
        return "-"
    notes = []
    if r["xfail"]:
        notes.append(f"{r['xfail']} xfail")
    if r["skipped"]:
        notes.append(f"{r['skipped']} skip")
    if r["failed"]:
        notes.append(f"{r['failed']} fail" if r["total"] else r["result"])
    if r["ok"] and b is not None and not b["ok"]:
        notes.append("fixed")
    elif r["ok"] and has_target_base and b is None:
        notes.append("new")
    suffix = f" ({', '.join(notes)})" if notes else ""
    if r["ok"]:
        icon = "✅"
    elif is_new_failure(r, b):
        icon = "❌"
    else:
        icon = "⚠️"
    return f"{icon} {r['passed']}/{r['total']}{suffix}"


def group_failures(failures: list[dict]) -> list[tuple[dict, list[str]]]:
    groups: dict[tuple, tuple[dict, list[str]]] = {}
    for f in sorted(failures, key=lambda x: x["test"]):
        stdout_tail = "" if f["bad_lines"] else f["stdout"][-2000:]
        key = (
            f["test"],
            f["result"],
            f["failed"],
            f["total"],
            tuple(f["bad_lines"]),
            f["stderr"][-2000:],
            stdout_tail,
        )
        if key not in groups:
            groups[key] = (f, [])
        groups[key][1].append(f["target"])
    return list(groups.values())


def failure_status(f: dict) -> str:
    if f["bad_lines"] and f["total"]:
        return f"{f['failed']}/{f['total']} failed"
    return f["result"]


def print_markdown_failure(
    out: io.TextIOBase, f: dict, targets: list[str], icon: str
) -> None:
    targets_html = ", ".join(f"<code>{t}</code>" for t in targets)
    status = failure_status(f)
    out.write(
        f"<details><summary>{icon} <code>{f['test']}</code> "
        f"({status}): {targets_html}</summary>\n\n"
    )
    if f["bad_lines"]:
        out.write("```tap\n")
        out.write("\n".join(f["bad_lines"]) + "\n")
        out.write("```\n")
    elif f["stdout"]:
        out.write("```\n")
        out.write(f["stdout"][-2000:] + "\n")
        out.write("```\n")
    if f["stderr"]:
        out.write("```\n")
        out.write(f["stderr"][-2000:] + "\n")
        out.write("```\n")
    out.write("</details>\n")


def print_console_failures(
    heading: str, failures: list[dict], prefix: str
) -> None:
    if not failures:
        return
    print(f"\n=== {heading} ===")
    for f, targets in group_failures(failures):
        status = failure_status(f)
        target_str = ", ".join(targets)
        print(f"\n{prefix} {f['test']} ({status}) [{target_str}]")
        if f["bad_lines"]:
            for line in f["bad_lines"]:
                print(f"  {line}")
        elif f["stdout"]:
            for line in f["stdout"][-2000:].splitlines():
                print(f"  {line}")
        if f["stderr"]:
            for line in f["stderr"][-2000:].splitlines():
                print(f"  {line}")


def render_markdown(
    entries: list[dict],
    base_entries: list[dict],
    missing_baseline: bool,
    by_target: dict[str, list[dict]],
    by_test: dict[str, dict[str, dict]],
    base_by_target: dict[str, list[dict]],
    base_by_test: dict[str, dict[str, dict]],
    targets: list[str],
    new_failures: list[dict],
    known_failures: list[dict],
) -> str:
    out = io.StringIO()
    out.write("<!-- rvy-test-results -->\n")
    out.write("### RVY Test Results\n\n")
    if missing_baseline:
        out.write(
            "> [!NOTE]\n"
            "> No baseline `testlog.json` artifact found on `main`; "
            "showing results without baseline comparison.\n\n"
        )
    out.write("| Target | Suites | Subtests | Passed | XFail | Skipped | Failed | Time |\n")
    out.write("| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for t in targets:
        items = by_target[t]
        b_items = base_by_target.get(t, []) if base_entries else None
        suites_ok = sum(1 for i in items if i["ok"])
        b_suites_ok = sum(1 for i in b_items if i["ok"]) if b_items is not None else None
        b_len = len(b_items) if b_items is not None else None
        new_fails = sum(
            1 for i in items if is_new_failure(i, base_by_test.get(i["test"], {}).get(t))
        )
        if suites_ok == len(items):
            icon = "✅"
        elif new_fails == 0:
            icon = "⚠️"
        else:
            icon = "❌"
        out.write(
            f"| {icon} `{t}` "
            f"| {fmt_delta(suites_ok, b_suites_ok)}/{fmt_delta(len(items), b_len)} "
            f"| {fmt_delta(sum(i['total'] for i in items), sum(i['total'] for i in b_items) if b_items is not None else None)} "
            f"| {fmt_delta(sum(i['passed'] for i in items), sum(i['passed'] for i in b_items) if b_items is not None else None)} "
            f"| {fmt_delta(sum(i['xfail'] for i in items), sum(i['xfail'] for i in b_items) if b_items is not None else None)} "
            f"| {fmt_delta(sum(i['skipped'] for i in items), sum(i['skipped'] for i in b_items) if b_items is not None else None)} "
            f"| {fmt_delta(sum(i['failed'] for i in items), sum(i['failed'] for i in b_items) if b_items is not None else None, show_zero=True)} "
            f"| {sum(i['duration'] for i in items):.1f}s |\n"
        )

    if new_failures:
        heading = "New Failures (relative to `main`)" if base_entries else "Failures"
        out.write(f"\n#### {heading}\n\n")
        for f, group_targets in group_failures(new_failures):
            print_markdown_failure(out, f, group_targets, "❌")
    if known_failures:
        out.write("\n#### Pre-existing Failures on `main`\n\n")
        for f, group_targets in group_failures(known_failures):
            print_markdown_failure(out, f, group_targets, "⚠️")

    cols = " | ".join(f"`{t}`" for t in targets)
    sep = " | ".join("---:" for _ in targets)
    out.write("\n<details><summary>Per-test breakdown</summary>\n\n")
    out.write(f"| Test | {cols} |\n")
    out.write(f"| :--- | {sep} |\n")
    for test_name in sorted(by_test):
        row = " | ".join(
            format_cell(
                by_test[test_name].get(t),
                base_by_test.get(test_name, {}).get(t),
                t in base_by_target,
            )
            for t in targets
        )
        out.write(f"| `{test_name}` | {row} |\n")
    out.write("\n</details>\n")
    return out.getvalue()


def print_console_summary(
    base_entries: list[dict],
    by_target: dict[str, list[dict]],
    base_by_target: dict[str, list[dict]],
    base_by_test: dict[str, dict[str, dict]],
    targets: list[str],
    new_failures: list[dict],
    known_failures: list[dict],
) -> None:
    rows = []
    for t in targets:
        items = by_target[t]
        b_items = base_by_target.get(t, []) if base_entries else None
        suites_ok = sum(1 for i in items if i["ok"])
        b_suites_ok = sum(1 for i in b_items if i["ok"]) if b_items is not None else None
        b_len = len(b_items) if b_items is not None else None
        new_fails = sum(
            1 for i in items if is_new_failure(i, base_by_test.get(i["test"], {}).get(t))
        )
        if suites_ok == len(items):
            status = "PASS"
        elif new_fails == 0:
            status = "WARN"
        else:
            status = "FAIL"
        rows.append(
            (
                f"{status} {t}",
                f"{fmt_delta(suites_ok, b_suites_ok)}/{fmt_delta(len(items), b_len)}",
                fmt_delta(
                    sum(i["total"] for i in items),
                    sum(i["total"] for i in b_items) if b_items is not None else None,
                ),
                fmt_delta(
                    sum(i["passed"] for i in items),
                    sum(i["passed"] for i in b_items) if b_items is not None else None,
                ),
                fmt_delta(
                    sum(i["xfail"] for i in items),
                    sum(i["xfail"] for i in b_items) if b_items is not None else None,
                ),
                fmt_delta(
                    sum(i["skipped"] for i in items),
                    sum(i["skipped"] for i in b_items) if b_items is not None else None,
                ),
                fmt_delta(
                    sum(i["failed"] for i in items),
                    sum(i["failed"] for i in b_items) if b_items is not None else None,
                    show_zero=True,
                ),
                f"{sum(i['duration'] for i in items):.1f}s",
            )
        )

    headers = ("Target", "Suites", "Subtests", "Passed", "XFail", "Skipped", "Failed", "Time")
    widths = [
        max(len(headers[i]), *(len(r[i]) for r in rows)) if rows else len(headers[i])
        for i in range(len(headers))
    ]
    fmt_row = lambda r: (
        f"{r[0]:<{widths[0]}}  "
        + "  ".join(f"{r[i]:>{widths[i]}}" for i in range(1, len(headers)))
    )
    print(fmt_row(headers))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt_row(r))

    if new_failures:
        heading = "New Failures (relative to main)" if base_entries else "Failures"
        print_console_failures(heading, new_failures, "FAIL")
    if known_failures:
        print_console_failures("Pre-existing Failures on main", known_failures, "WARN")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--markdown",
        type=Path,
        help="Write Markdown report to this file and print text summary to stdout",
    )
    parser.add_argument("testlog", type=Path, help="Path to Meson testlog.json")
    parser.add_argument(
        "baseline",
        nargs="?",
        type=Path,
        help="Optional baseline testlog.json from main",
    )
    args = parser.parse_args()

    entries = load_log(args.testlog)
    base_path = args.baseline
    base_entries = load_log(base_path) if base_path and base_path.is_file() else []
    missing_baseline = base_path is not None and not base_path.is_file()

    by_target: dict[str, list[dict]] = collections.defaultdict(list)
    by_test: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    for e in entries:
        by_target[e["target"]].append(e)
        by_test[e["test"]][e["target"]] = e

    base_by_target: dict[str, list[dict]] = collections.defaultdict(list)
    base_by_test: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    for b in base_entries:
        base_by_target[b["target"]].append(b)
        base_by_test[b["test"]][b["target"]] = b

    targets = list(by_target.keys())
    new_failures = [
        e for e in entries if is_new_failure(e, base_by_test.get(e["test"], {}).get(e["target"]))
    ]
    known_failures = [
        e
        for e in entries
        if not e["ok"] and not is_new_failure(e, base_by_test.get(e["test"], {}).get(e["target"]))
    ]

    md = render_markdown(
        entries,
        base_entries,
        missing_baseline,
        by_target,
        by_test,
        base_by_target,
        base_by_test,
        targets,
        new_failures,
        known_failures,
    )

    if args.markdown:
        args.markdown.write_text(md, encoding="utf-8")
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with Path(step_summary).open("a", encoding="utf-8") as f:
                f.write(md)
        print_console_summary(
            base_entries,
            by_target,
            base_by_target,
            base_by_test,
            targets,
            new_failures,
            known_failures,
        )
    else:
        sys.stdout.write(md)

    sys.exit(1 if new_failures else 0)


if __name__ == "__main__":
    main()
