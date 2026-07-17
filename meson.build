# RVY (CHERI for RISC-V) bare-metal test suite: builds and runs the tests
# under tests/rvy/*.S against the riscv64y-softmmu / riscv32y-softmmu
# emulators using run-rvy-tests.sh.
#
# This needs a bare-metal RISC-V clang (no CHERI support required; all RVY
# instructions are emitted via .insn) that is not otherwise detected by the
# QEMU build, so the suite is opt-in: configure with
# -Drvy_test_cc=/path/to/clang to enable it. It is skipped by default.
#
# Once enabled, `ninja test` / `meson test --suite rvy` runs it, and (via
# the usual meson->make bridge) so does `make check-rvy` -- handy for CI.

rvy_test_cc_path = get_option('rvy_test_cc')
if rvy_test_cc_path != ''
  rvy_test_cc = find_program(rvy_test_cc_path)
  rvy_runner = find_program(meson.current_source_dir() / 'run-rvy-tests.sh')

  foreach dir : ['riscv64y-softmmu', 'riscv32y-softmmu']
    if dir in target_dirs
      target_base = dir.split('-')[0]
      rvy_emulator = emulators['qemu-system-' + target_base]
      test('rvy-' + target_base,
           rvy_runner,
           args: [rvy_emulator.full_path(), rvy_test_cc.full_path()],
           depends: rvy_emulator,
           timeout: 300,
           suite: ['rvy'])
    endif
  endforeach
endif
