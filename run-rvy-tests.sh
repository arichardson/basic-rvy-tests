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

# run <test> <expected-exit-code> [extra qemu args...]
run() {
    test_name=$1
    expected=$2
    shift 2
    status=0
    $QEMU $QEMU_ARGS "$@" -kernel "$BUILD_DIR/$test_name.elf" || status=$?
    if [ "$status" != "$expected" ]; then
        echo "FAIL: $test_name $* (exit code $status, expected $expected)"
        exit 1
    fi
    echo "PASS: $test_name $*"
}

build test-insn-encodings
build test-misa-y
build test-branches

run test-insn-encodings 0
run test-misa-y 0
run test-branches 0
run test-branches 3 -cpu any,x-rvy-strict-branches=on

echo "All RVY tests passed ($TARGET)"
