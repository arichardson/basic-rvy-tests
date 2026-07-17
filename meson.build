# RVY (CHERI for RISC-V) bare-metal test suite: builds and runs the tests
# under tests/rvy/*.S against the riscv64y-softmmu / riscv32y-softmmu
# emulators using run-rvy-tests.sh.
#
# This needs a bare-metal RISC-V clang (no CHERI support required; all RVY
# instructions are emitted via .insn). -Drvy_test_cc=/path/to/clang selects
# one explicitly (hard error if it doesn't support RISC-V); left at its
# default (empty), the suite instead auto-detects a working clang and is
# silently skipped if none is found -- so a plain `ninja test` doesn't
# break on machines without one.
#
# Apple's system clang (/usr/bin/clang) is normally built without the
# RISC-V backend, so on macOS we look for Homebrew's llvm formula
# (`brew install llvm`) before falling back to whatever "clang" resolves
# to on PATH.
#
# Once enabled, `ninja test` / `meson test --suite rvy` runs it, and (via
# the usual meson->make bridge) so does `make check-rvy` -- handy for CI.

rvy_test_cc_path = get_option('rvy_test_cc')
if rvy_test_cc_path != ''
  rvy_candidates = [rvy_test_cc_path]
  rvy_test_cc_required = true
else
  rvy_candidates = []
  if host_machine.system() == 'darwin'
    brew = find_program('brew', required: false)
    if brew.found()
      brew_llvm = run_command(brew, '--prefix', 'llvm', check: false)
      if brew_llvm.returncode() == 0
        rvy_candidates += [brew_llvm.stdout().strip() / 'bin' / 'clang']
      endif
    endif
  endif
  rvy_candidates += ['clang']
  rvy_test_cc_required = false
endif

rvy_probe_src = files('probe.S')
rvy_test_cc_found = false
foreach candidate : rvy_candidates
  cand_prog = find_program(candidate, required: false)
  if cand_prog.found()
    probe = run_command(cand_prog, '--target=riscv64', '-march=rv64g',
                        '-c', '-o', '/dev/null', rvy_probe_src, check: false)
    if probe.returncode() == 0
      rvy_test_cc = cand_prog
      rvy_test_cc_found = true
      break
    elif rvy_test_cc_required
      error('-Drvy_test_cc=@0@ does not support RISC-V:\n@1@'
           .format(candidate, probe.stderr().strip()))
    endif
  elif rvy_test_cc_required
    error('-Drvy_test_cc: @0@ not found'.format(candidate))
  endif
endforeach

if rvy_test_cc_found
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
