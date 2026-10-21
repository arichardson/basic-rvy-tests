#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Run one already-built RVY test ELF through one emulator invocation. This is
# the leaf that meson.build's test() entries call directly, one per (test,
# emulator, machine); it exists only to smooth over the two harnesses'
# different pass/fail signals, not to loop or build anything.
#
# Usage:
#   run-rvy-test.sh [--extra-elf <elf>] qemu <emulator> <elf> <machine> [extra qemu args...]
#   run-rvy-test.sh [--extra-elf <elf>] sail <emulator> <elf> <insn-limit> [extra sail args...]
set -eu

EXTRA_ELF=
while [ $# -gt 0 ]; do
    case "$1" in
    --extra-elf)
        EXTRA_ELF=$2
        shift 2
        ;;
    *)
        break
        ;;
    esac
done

HARNESS=$1
EMULATOR=$2
ELF=$3
shift 3

case "$HARNESS" in
qemu)
    MACHINE=$1
    shift
    if [ -n "$EXTRA_ELF" ]; then
        set -- -device "loader,file=$EXTRA_ELF" "$@"
    fi
    # The guest's own exit code (via the sifive_test finisher, virt, or HTIF
    # tohost, spike) is the verdict; meson takes it from here.
    exec "$EMULATOR" -machine "$MACHINE" -bios none -display none \
        -serial stdio "$@" -kernel "$ELF" </dev/null
    ;;
sail)
    INSN_LIMIT=$1
    shift
    # The model writes the guest console to the file -t names rather than to
    # its own stdout, so that file is where the TAP stream comes from.
    LOGDIR=$(mktemp -d)
    trap 'rm -rf "$LOGDIR"' EXIT
    set -- "$@" "$ELF"
    if [ -n "$EXTRA_ELF" ]; then
        set -- "$@" "$EXTRA_ELF"
    fi
    status=0
    "$EMULATOR" --inst-limit "$INSN_LIMIT" --terminal-log "$LOGDIR/term" "$@" \
        </dev/null >"$LOGDIR/log" 2>&1 || status=$?
    # The console carries the TAP stream, so it always goes to stdout. The
    # model's own chatter stays out of it, and is only worth showing when
    # nothing reached the console at all -- a trap loop or an unimplemented
    # CSR looks like that. Prefix it so it stays a TAP comment.
    if [ -f "$LOGDIR/term" ]; then
        cat "$LOGDIR/term"
    fi
    if [ "$status" != 0 ] && [ ! -s "$LOGDIR/term" ]; then
        sed -e 's/^/# /' "$LOGDIR/log" | tail -5
    fi
    exit "$status"
    ;;
*)
    echo "run-rvy-test.sh: unknown harness '$HARNESS'" >&2
    exit 1
    ;;
esac
