#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Run one already-built RVY test ELF through one emulator invocation. This is
# the leaf that meson.build's test() entries call directly, one per (test,
# emulator, machine); it exists only to smooth over the two harnesses'
# different pass/fail signals, not to loop or build anything.
#
# Usage:
#   run-rvy-test.sh qemu <emulator> <elf> <machine> [extra qemu args...]
#   run-rvy-test.sh sail <emulator> <elf> <insn-limit>
set -eu

HARNESS=$1
EMULATOR=$2
ELF=$3
shift 3

case "$HARNESS" in
qemu)
    MACHINE=$1
    shift
    # The guest's own exit code (via the sifive_test finisher, virt, or HTIF
    # tohost, spike) is the verdict; meson takes it from here.
    exec "$EMULATOR" -machine "$MACHINE" -bios none -display none \
        -serial stdio "$@" -kernel "$ELF" </dev/null
    ;;
sail)
    INSN_LIMIT=$1
    # The model's own exit status is the verdict, but it does not print which
    # case failed, so keep the HTIF console log (-t) to show on failure.
    LOGDIR=$(mktemp -d)
    trap 'rm -rf "$LOGDIR"' EXIT
    status=0
    "$EMULATOR" -l "$INSN_LIMIT" -t "$LOGDIR/term" "$ELF" \
        </dev/null >"$LOGDIR/log" 2>&1 || status=$?
    if [ "$status" != 0 ]; then
        if [ -s "$LOGDIR/term" ]; then
            cat "$LOGDIR/term"
        else
            # Nothing reached the console: show where the model ended up,
            # which is where a trap loop or an unimplemented CSR shows up.
            tail -5 "$LOGDIR/log"
        fi
    fi
    exit "$status"
    ;;
*)
    echo "run-rvy-test.sh: unknown harness '$HARNESS'" >&2
    exit 1
    ;;
esac
