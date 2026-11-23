#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Check basic-rvy-tests suite conventions and repository hygiene."""

from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"

BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
MESON_TEST_NAME_RE = re.compile(r"['\"]name['\"]\s*:\s*['\"](test-[^'\"]+)['\"]")
TEST_NAME_DEF_RE = re.compile(r'^\s*#define\s+TEST_NAME\s+"([^"]+)"', re.MULTILINE)
TRAP_HANDLER_RE = re.compile(r"^\s*TRAP_HANDLER(?:_PCC)?\b", re.MULTILINE)
LA_PSEUDO_RE = re.compile(r"^\s*(?:\d+:\s*|[A-Za-z_.$][\w.$]*:\s*)?la\s+", re.MULTILINE)
RAW_CSR_RE = re.compile(
    r"^\s*csr(?:rw|rs|rc|r|w|s|c|rwi|rsi|rci|wi|si|ci)\b[^\n]*\b(0x100|0x180|mstatus|sstatus|satp)\b",
    re.MULTILINE,
)


def strip_comments(text: str) -> str:
    return LINE_COMMENT_RE.sub("", BLOCK_COMMENT_RE.sub("", text))


def check_suite() -> list[str]:
    errors: list[str] = []

    disk_tests = {p.stem for p in SRC_DIR.glob("test-*.S")}
    meson_text = (SRC_DIR / "meson.build").read_text(encoding="utf-8")
    meson_tests = set(MESON_TEST_NAME_RE.findall(meson_text))

    for missing in sorted(disk_tests - meson_tests):
        errors.append(f"src/{missing}.S is not listed in src/meson.build rvy_tests")
    for extra in sorted(meson_tests - disk_tests):
        errors.append(f"src/meson.build lists {extra!r} but src/{extra}.S does not exist")

    for path in sorted(SRC_DIR.glob("test-*.S")):
        rel = path.relative_to(REPO_ROOT)
        raw = path.read_text(encoding="utf-8")
        code = strip_comments(raw)

        m = TEST_NAME_DEF_RE.search(code)
        expected_name = path.stem.removeprefix("test-")
        if not m:
            errors.append(f"{rel}: missing #define TEST_NAME")
        elif m.group(1) != expected_name:
            errors.append(f"{rel}: TEST_NAME {m.group(1)!r} != {expected_name!r}")

        handlers = TRAP_HANDLER_RE.findall(code)
        if len(handlers) != 1:
            errors.append(f"{rel}: expected 1 TRAP_HANDLER[_PCC], found {len(handlers)}")

        for marker in ("TEST_PASS", "TEST_FAIL"):
            if not re.search(rf"^\s*{marker}\b", code, re.MULTILINE):
                errors.append(f"{rel}: missing {marker}")

        if LA_PSEUDO_RE.search(code):
            errors.append(f"{rel}: use lla instead of la for symbol addresses")

        for csr_match in RAW_CSR_RE.finditer(code):
            errors.append(f"{rel}: use symbolic CSR_* instead of {csr_match.group(1)!r}")

    for root in (SRC_DIR, REPO_ROOT / ".github"):
        for path in sorted(root.rglob("*")):
            if not path.is_file() or "__pycache__" in path.parts:
                continue
            data = path.read_bytes()
            if data and not data.endswith(b"\n"):
                errors.append(f"{path.relative_to(REPO_ROOT)}: missing trailing newline")

    return errors


def main() -> None:
    errors = check_suite()
    if errors:
        for err in errors:
            print(f"error: {err}", file=sys.stderr)
        sys.exit(1)
    print("All suite hygiene checks passed.")


if __name__ == "__main__":
    main()
