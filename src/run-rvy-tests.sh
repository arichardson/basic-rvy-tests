#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Fallback one-liner for running the RVY suite against a single emulator.
# The preferred way is meson directly (see the README), which registers one
# test per case and runs them in parallel; this script just drives that
# through a throwaway build directory.
#
# Usage: run-rvy-tests.sh <emulator> [clang]
set -eu

SIM=$1
CC=${2:-}
SRC_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

set -- -Drvy_emulators="$SIM"
if [ -n "$CC" ]; then
    set -- "$@" -Drvy_test_cc="$CC"
fi

meson setup "$BUILD_DIR" "$SRC_ROOT" "$@"
meson test -C "$BUILD_DIR" --print-errorlogs --suite rvy
