#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Build and run the bare-metal RVY tests against a qemu-system-riscv{32,64}y
# binary. Requires a RISC-V clang (no CHERI support needed; all RVY
# instructions are emitted with .insn).
#
# Usage: run-rvy-tests.sh <qemu-system-riscv64y|qemu-system-riscv32y> [clang]
set -eu

QEMU=$1
CC=${2:-clang}
SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# A test bug (e.g. a miscomputed jump offset) can leave the guest spinning
# forever instead of hitting the finisher device, so every run is bounded by
# a wall-clock timeout instead of being allowed to hang indefinitely.
: "${RVY_TEST_TIMEOUT:=20}"
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout -k 5"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout -k 5"
else
    TIMEOUT_CMD=""
fi

case "$QEMU" in
*riscv32*) TARGET=riscv32 ; MARCH=rv32g ;;
*) TARGET=riscv64 ; MARCH=rv64g ;;
esac

QEMU_ARGS="-machine virt -bios none -display none -serial none"

build() {
    "$CC" --target=$TARGET -march=$MARCH -nostdlib -static \
        -fuse-ld=lld -Wl,-T,"$SRC_DIR/link.ld" \
        "$SRC_DIR/$1.S" -o "$BUILD_DIR/$1.elf"
}

# Run "$@" with a wall-clock timeout, without relying on timeout(1) being
# installed (portable fallback: background the job under a sleep watchdog).
run_with_timeout() {
    if [ -n "$TIMEOUT_CMD" ]; then
        $TIMEOUT_CMD "$RVY_TEST_TIMEOUT" "$@"
        return $?
    fi
    "$@" &
    job=$!
    ( sleep "$RVY_TEST_TIMEOUT"; kill -TERM "$job" 2>/dev/null ) &
    watchdog=$!
    status=0
    wait "$job" || status=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$status"
}

# run <test> <expected-exit-code> [extra qemu args...]
run() {
    test_name=$1
    expected=$2
    shift 2
    status=0
    run_with_timeout $QEMU $QEMU_ARGS "$@" -kernel "$BUILD_DIR/$test_name.elf" || status=$?
    if [ "$status" = 124 ] || [ "$status" = 137 ]; then
        echo "FAIL: $test_name $* (timed out after ${RVY_TEST_TIMEOUT}s -- possible infinite loop)"
        exit 1
    fi
    if [ "$status" != "$expected" ]; then
        echo "FAIL: $test_name $* (exit code $status, expected $expected)"
        exit 1
    fi
    echo "PASS: $test_name $*"
}

build test-insn-encodings
build test-misa-y
build test-branches
build test-loadstore-x0
build test-amo-cbo-causes

run test-insn-encodings 0
run test-misa-y 0
run test-branches 0
run test-branches 3 -cpu any,x-rvy-strict-branches=on
run test-loadstore-x0 0
run test-amo-cbo-causes 0

if [ "$TARGET" = riscv64 ]; then
    # Svyrg (and the pte.rvy field it redefines) is RV64-only. Note: the
    # "any" CPU has no supervisor mode, so use the default CPU model.
    build test-svyrg
    run test-svyrg 0 -cpu rv64,Svyrg=on
fi

echo "All RVY tests passed ($TARGET)"
