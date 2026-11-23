#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Fallback one-liner for running the RVY suite against a single emulator.
# The preferred way is meson directly (see the README), which registers one
# test per case and runs them in parallel; this script just drives that
# through a throwaway build directory.
#
# Usage: run-rvy-tests.sh <qemu-dir|emulator> [clang]
set -eu

SIM=$1
CC=${2:-}
SRC_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

case "$SIM" in
*qemu*)
    set -- -Dqemu="$SIM"
    ;;
*sail*)
    case "$SIM" in
    *0910*|*0.9.10*)
        set -- -Dsail_0910="$SIM"
        ;;
    *099*|*0.9.9*)
        set -- -Dsail_099="$SIM"
        ;;
    *rvy*)
        set -- -Dsail_0910="$SIM"
        ;;
    *)
        set -- -Dsail_093="$SIM"
        ;;
    esac
    ;;
*)
    set -- -Dqemu="$SIM"
    ;;
esac
if [ -n "$CC" ]; then
    set -- "$@" -Drvy_test_cc="$CC"
fi

meson setup "$BUILD_DIR" "$SRC_ROOT" "$@"
meson test -C "$BUILD_DIR" --print-errorlogs --suite rvy
