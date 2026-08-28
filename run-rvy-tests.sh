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

# The 0.9.3 emulators and the Sail model predate most of what this suite
# covers, so there they build with -DCHERI_093 and only the tests whose
# behaviour both versions share are run.
case "$QEMU" in
*cheristd*|*sail*) CHERI_VERSION=0.9.3 ; CFLAGS_CHERI=-DCHERI_093 ;;
*) CHERI_VERSION=v0.9.9 ; CFLAGS_CHERI= ;;
esac

# -serial stdio so the HTIF console messages the tests print are visible;
# the virt machine has no HTIF, so there they simply do not appear.
QEMU_ARGS="-bios none -display none -serial stdio"

# Each test reports its result twice: through the HTIF tohost register (which
# is what spike-like harnesses, including the Sail model, understand) and
# through the sifive_test finisher device (virt). Run both machines so that
# neither path silently rots.
: "${RVY_TEST_MACHINES:=virt spike}"

build() {
    "$CC" --target=$TARGET -march=$MARCH $CFLAGS_CHERI -nostdlib -static \
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
    for machine in $RVY_TEST_MACHINES; do
        status=0
        run_with_timeout $QEMU -machine "$machine" $QEMU_ARGS "$@" \
            -kernel "$BUILD_DIR/$test_name.elf" </dev/null || status=$?
        if [ "$status" = 124 ] || [ "$status" = 137 ]; then
            echo "FAIL: $test_name ($machine) $* (timed out after ${RVY_TEST_TIMEOUT}s -- possible infinite loop)"
            exit 1
        fi
        if [ "$status" != "$expected" ]; then
            echo "FAIL: $test_name ($machine) $* (exit code $status, expected $expected)"
            exit 1
        fi
        echo "PASS: $test_name ($machine) $*"
    done
}

# Behaviour both CHERI versions share; the tests skip the individual cases
# that only apply to one of them.
for t in test-loadstore-x0 test-amo-cbo-causes test-bounds-causes \
         test-pcc-bounds-fetch test-insn-encodings test-branches \
         test-cap-ops test-asr; do
    build $t
    run $t 0
done

if [ "$CHERI_VERSION" = v0.9.9 ]; then
    # misa.Y and taking control-flow faults at the target are both v0.9.9.
    for t in test-misa-y test-branch-target-faults; do
        build $t
        run $t 0
    done

    # The reservation is only enforced when asked for.
    build test-reserved-branches
    run test-reserved-branches 0 -cpu any,x-rvy-strict-branches=on

    if [ "$TARGET" = riscv64 ]; then
        # Svyrg (and the pte.rvy field it redefines) is RV64-only. Note: the
        # "any" CPU has no supervisor mode, so use the default CPU model.
        build test-svyrg
        run test-svyrg 0 -cpu rv64,Svyrg=on
    fi
fi

echo "All RVY tests passed ($TARGET, CHERI $CHERI_VERSION)"
