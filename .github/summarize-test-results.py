#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Summarize Meson's testlog.json into a GitHub Markdown report."""

import collections
import json
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

    ok = raw.get("result") in ("OK", "SKIP", "EXPECTEDFAIL") and failed == 0
    return {
        "target": target,
        "test": test,
        "result": raw.get("result", "UNKNOWN"),
        "ok": ok,
        "passed": passed,
        "xfail": xfail,
        "skipped": skipped,
        "failed": failed,
        "total": passed + xfail + skipped + failed,
        "duration": raw.get("duration", 0.0),
        "bad_lines": bad_lines,
        "stdout": raw.get("stdout", "").strip(),
        "stderr": raw.get("stderr", "").strip(),
    }


def format_cell(r: dict | None) -> str:
    if r is None:
        return "-"
    notes = []
    if r["xfail"]:
        notes.append(f"{r['xfail']} xfail")
    if r["skipped"]:
        notes.append(f"{r['skipped']} skip")
    if r["failed"]:
        notes.append(f"{r['failed']} fail")
    suffix = f" ({', '.join(notes)})" if notes else ""
    icon = "✅" if r["ok"] else "❌"
    return f"{icon} {r['passed']}/{r['total']}{suffix}"


def main() -> None:
    log_path = Path(sys.argv[1])
    entries = [
        parse_entry(json.loads(line))
        for line in log_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    by_target: dict[str, list[dict]] = collections.defaultdict(list)
    by_test: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    for e in entries:
        by_target[e["target"]].append(e)
        by_test[e["test"]][e["target"]] = e
    targets = list(by_target.keys())

    print("<!-- rvy-test-results -->")
    print("### RVY Test Results\n")
    print("| Target | Suites | Subtests | Passed | XFail | Skipped | Failed | Time |")
    print("| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for t in targets:
        items = by_target[t]
        suites_ok = sum(1 for i in items if i["ok"])
        icon = "✅" if suites_ok == len(items) else "❌"
        print(
            f"| {icon} `{t}` | {suites_ok}/{len(items)} "
            f"| {sum(i['total'] for i in items)} "
            f"| {sum(i['passed'] for i in items)} "
            f"| {sum(i['xfail'] for i in items)} "
            f"| {sum(i['skipped'] for i in items)} "
            f"| {sum(i['failed'] for i in items)} "
            f"| {sum(i['duration'] for i in items):.1f}s |"
        )

    failures = [e for e in entries if not e["ok"]]
    if failures:
        print("\n#### Failures\n")
        for f in failures:
            print(f"<details><summary>❌ <code>{f['target']}</code>: <code>{f['test']}</code> ({f['result']})</summary>\n")
            if f["bad_lines"]:
                print("```tap")
                print("\n".join(f["bad_lines"]))
                print("```")
            if f["stderr"]:
                print("```")
                print(f["stderr"][-2000:])
                print("```")
            elif not f["bad_lines"] and f["stdout"]:
                print("```")
                print(f["stdout"][-2000:])
                print("```")
            print("</details>")

    cols = " | ".join(f"`{t}`" for t in targets)
    sep = " | ".join("---:" for _ in targets)
    print("\n<details><summary>Per-test breakdown</summary>\n")
    print(f"| Test | {cols} |")
    print(f"| :--- | {sep} |")
    for test_name in sorted(by_test):
        row = " | ".join(format_cell(by_test[test_name].get(t)) for t in targets)
        print(f"| `{test_name}` | {row} |")
    print("\n</details>")


if __name__ == "__main__":
    main()
