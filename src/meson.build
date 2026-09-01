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

fs = import('fs')
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

rvy_src_dir = meson.current_source_dir()
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
  rvy_run_test = find_program(rvy_src_dir / 'run-rvy-test.sh')
  rvy_machines = ['virt', 'spike']

  # Every case, and which (xlen, CHERI version) profiles it applies to; a key
  # left out defaults to both xlens and both CHERI versions. This is the
  # canonical list -- a test not named here never runs.
  rvy_tests = [
    {'name': 'test-loadstore-x0'},
    {'name': 'test-amo-cbo-causes'},
    {'name': 'test-bounds-causes'},
    {'name': 'test-pcc-bounds-fetch'},
    {'name': 'test-insn-encodings'},
    {'name': 'test-branches'},
    {'name': 'test-cap-ops'},
    {'name': 'test-cap-reset-regression'},
    {'name': 'test-asr'},
    {'name': 'test-cbo-bounds'},
    # misa.Y, taking control-flow faults at the target, and the exception
    # priority table are all v0.9.9 only.
    {'name': 'test-misa-y', 'cheri_versions': ['v0.9.9']},
    {'name': 'test-branch-target-faults', 'cheri_versions': ['v0.9.9']},
    {'name': 'test-exception-priority', 'cheri_versions': ['v0.9.9']},
    # The reservation is only enforced when asked for.
    {'name': 'test-reserved-branches', 'cheri_versions': ['v0.9.9'],
     'qemu_args': ['-cpu', 'any,x-rvy-strict-branches=on']},
    # Svyrg (and the pte.rvy field it redefines) is RV64-only. The "any" CPU
    # has no supervisor mode, so this needs the default CPU model.
    {'name': 'test-svyrg', 'cheri_versions': ['v0.9.9'], 'xlens': [64],
     'qemu_args': ['-cpu', 'rv64,Svyrg=on']},
  ]

  # Which emulators to test against, and the (xlen, CHERI version, harness)
  # profile each implies -- inferred from its name, the same heuristic
  # run-rvy-tests.sh has always used.
  rvy_emulators_to_test = []
  if is_variable('emulators')
    # Included from QEMU's build: the target name says the profile exactly.
    foreach dir : ['riscv64y-softmmu', 'riscv32y-softmmu',
                   'riscv64cheristd-softmmu', 'riscv32cheristd-softmmu']
      if dir in target_dirs
        target_base = dir.split('-')[0]
        rvy_emulator = emulators['qemu-system-' + target_base]
        rvy_emulators_to_test += [{
          'label': target_base,
          'path': rvy_emulator.full_path(),
          'depends': [rvy_emulator],
          'xlen': target_base.contains('riscv32') ? 32 : 64,
          'cheri_version': target_base.contains('cheristd') ? '0.9.3' : 'v0.9.9',
          'harness': 'qemu',
        }]
      endif
    endforeach
  else
    # Standalone: -Drvy_emulators names already-built binaries somewhere on
    # the system. Left unset, fall back to whichever of the four QEMU
    # targets a cheribuild SDK output tree has, so a bare `meson test` does
    # something useful without always having to be told where they are.
    rvy_emulator_paths = get_option('rvy_emulators')
    if rvy_emulator_paths.length() == 0
      rvy_sdk_bin = fs.expanduser('~/cheri/output/sdk/bin')
      if fs.is_dir(rvy_sdk_bin)
        foreach name : ['qemu-system-riscv64y', 'qemu-system-riscv32y',
                         'qemu-system-riscv64cheristd', 'qemu-system-riscv32cheristd']
          candidate = rvy_sdk_bin / name
          if fs.exists(candidate)
            rvy_emulator_paths += [candidate]
          endif
        endforeach
      endif
      if rvy_emulator_paths.length() > 0
        message('no -Drvy_emulators given: defaulting to the SDK build(s) under ' + rvy_sdk_bin)
      endif
    endif

    foreach emulator : rvy_emulator_paths
      name = fs.name(emulator)
      rvy_emulators_to_test += [{
        'label': name,
        'path': emulator,
        'depends': [],
        'xlen': (name.contains('riscv32') or name.contains('rv32')) ? 32 : 64,
        'cheri_version': (name.contains('cheristd') or name.contains('sail')) ? '0.9.3' : 'v0.9.9',
        'harness': name.contains('sail') ? 'sail' : 'qemu',
      }]
    endforeach
    if rvy_emulators_to_test.length() == 0
      warning('no emulator given: configure with ' +
              '-Drvy_emulators=/path/to/qemu-system-riscv64y to run the suite')
    endif
  endif

  # One ELF per (test, xlen, CHERI version): several emulators can share a
  # profile (e.g. riscv64cheristd and the Sail model are both riscv64/0.9.3),
  # so build it once and let every matching test() depend on it.
  rvy_elf_targets = {}
  foreach emulator : rvy_emulators_to_test
    foreach t : rvy_tests
      xlens = t.get('xlens', [32, 64])
      cheri_versions = t.get('cheri_versions', ['0.9.3', 'v0.9.9'])
      if emulator['xlen'] not in xlens or emulator['cheri_version'] not in cheri_versions
        continue
      endif

      profile = ('@0@-@1@-@2@'.format(t['name'], emulator['xlen'], emulator['cheri_version'])).underscorify()
      if profile not in rvy_elf_targets
        march = emulator['xlen'] == 32 ? 'rv32g' : 'rv64g'
        cflags_cheri = emulator['cheri_version'] == '0.9.3' ? ['-DCHERI_093'] : []
        rvy_elf_targets += {profile: custom_target(
          profile + '.elf',
          input: t['name'] + '.S',
          output: profile + '.elf',
          command: [rvy_test_cc, '--target=riscv' + emulator['xlen'].to_string(),
                     '-march=' + march] + cflags_cheri +
                    ['-nostdlib', '-static', '-fuse-ld=lld',
                     '-Wl,-T,' + (rvy_src_dir / 'link.ld'),
                     '@INPUT@', '-o', '@OUTPUT@'],
          depend_files: files('link.ld', 'testmacros.h', 'exceptions.h'),
          build_by_default: false,
        )}
      endif
      elf = rvy_elf_targets[profile]

      test_id = 'rvy-' + emulator['label'] + '-' + t['name']
      if emulator['harness'] == 'sail'
        test(test_id, rvy_run_test,
             args: ['sail', emulator['path'], elf,
                    get_option('rvy_sail_insn_limit').to_string()],
             depends: emulator['depends'],
             timeout: get_option('rvy_test_timeout'),
             suite: ['rvy'])
      else
        qemu_args = t.get('qemu_args', [])
        foreach machine : rvy_machines
          test(test_id + '-' + machine, rvy_run_test,
               args: ['qemu', emulator['path'], elf, machine] + qemu_args,
               depends: emulator['depends'],
               timeout: get_option('rvy_test_timeout'),
               suite: ['rvy'])
        endforeach
      endif
    endforeach
  endforeach
endif
