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
    {'name': 'test-console'},
    {'name': 'test-cbo-bounds'},
    {'name': 'test-xepc-detag'},
    {'name': 'test-xtvec-detag'},
    # misa.Y, taking control-flow faults at the target, and the exception
    # priority table are all 0.9.9 only.
    {'name': 'test-misa-y', 'cheri_versions': ['0.9.9']},
    {'name': 'test-branch-target-faults', 'cheri_versions': ['0.9.9']},
    {'name': 'test-exception-priority', 'cheri_versions': ['0.9.9']},
    {'name': 'test-xepc-return', 'cheri_versions': ['0.9.9']},
    # The reservation is only enforced when asked for.
    {'name': 'test-reserved-branches', 'cheri_versions': ['0.9.9'],
     'qemu_args': ['-cpu', 'any,x-rvy-strict-branches=on']},
    # Svyrg (and the pte.rvy field it redefines) is RV64-only. The "any" CPU
    # has no supervisor mode, so this needs the default CPU model.
    {'name': 'test-svyrg', 'cheri_versions': ['0.9.9'], 'xlens': [64],
     'qemu_args': ['-cpu', 'rv64,Svyrg=on']},
    {'name': 'test-translation-priority', 'cheri_versions': ['0.9.9'],
     'xlens': [64], 'qemu_args': ['-cpu', 'rv64,Svyrg=on']},
    # Sv39 is RV64-only, and S-mode needs the default CPU model.
    {'name': 'test-noncanonical-addr', 'cheri_versions': ['0.9.9'],
     'xlens': [64], 'qemu_args': ['-cpu', 'rv64']},
    {'name': 'test-int-amo', 'cheri_versions': ['0.9.9'], 'xlens': [64]},
    {'name': 'test-pmp', 'cheri_versions': ['0.9.9'], 'xlens': [64],
     'qemu_args': ['-cpu', 'rv64']},
    # The capability-mode C and F encodings and the RV64 (128-bit) level and
    # permission layout are what these check.
    {'name': 'test-capmode-rvc-fp', 'cheri_versions': ['0.9.9'],
     'xlens': [64]},
    {'name': 'test-cap-levels', 'cheri_versions': ['0.9.9'], 'xlens': [64]},
  ]

  used_as_qemu_submodule = is_variable('emulators')
  rvy_enabled_cheri_versions = used_as_qemu_submodule ? ['0.9.3', '0.9.9'] : get_option('cheri_versions')

  # Build one set of ELF files per enabled CHERI version in its own
  # subdirectory (<build>/src/0.9.3/ and <build>/src/0.9.9/). Standalone builds
  # enable build_by_default so `ninja -C build` produces the ELFs without
  # needing an emulator; when included as QEMU's tests/rvy submodule, only the
  # ELFs pulled in by active test() targets are built.
  rvy_depend_files = files('link.ld', 'testmacros.h', 'exceptions.h',
                           'console.h', 'rvy-insns.h')
  rvy_elf_targets = {}
  foreach rvy_cheri_ver : rvy_enabled_cheri_versions
    rvy_ver_elfs = []
    rvy_cflags_cheri = rvy_cheri_ver == '0.9.3' ? ['-DCHERI_093'] : []
    foreach t : rvy_tests
      xlens = t.get('xlens', [32, 64])
      cheri_versions = t.get('cheri_versions', ['0.9.3', '0.9.9'])
      if rvy_cheri_ver not in cheri_versions
        continue
      endif
      foreach xlen : xlens
        march = xlen == 32 ? 'rv32g' : 'rv64g'
        profile = ('@0@_@1@_@2@'.format(t['name'], xlen, rvy_cheri_ver)).underscorify()
        elf_name = ('@0@_@1@'.format(t['name'], xlen)).underscorify() + '.elf'
        elf_tgt = custom_target(
          profile + '.elf',
          input: [t['name'] + '.S', 'console.S'],
          output: elf_name,
          build_subdir: rvy_cheri_ver, # requires Meson >= 1.10.0
          command: [rvy_test_cc, '--target=riscv' + xlen.to_string(),
                    '-march=' + march] + rvy_cflags_cheri +
                   ['-nostdlib', '-static', '-fuse-ld=lld',
                    '-Wl,-T,' + (rvy_src_dir / 'link.ld'),
                    '@INPUT@', '-o', '@OUTPUT@'],
          depend_files: rvy_depend_files,
          build_by_default: not used_as_qemu_submodule,
        )
        rvy_elf_targets += {profile: elf_tgt}
        rvy_ver_elfs += [elf_tgt]
      endforeach
    endforeach
    alias_target('rvy-elfs-' + rvy_cheri_ver, rvy_ver_elfs)
  endforeach

  # Which emulators to test against, and the (xlen, CHERI version, harness)
  # profile each implies.
  rvy_qemu_targets = ['riscv64y', 'riscv32y',
                      'riscv64cheristd', 'riscv32cheristd']
  rvy_emulators_to_test = []
  if used_as_qemu_submodule
    # Included from QEMU's build: the target name says the profile exactly.
    foreach target_base : rvy_qemu_targets
      if (target_base + '-softmmu') in target_dirs
        rvy_emulator = emulators['qemu-system-' + target_base]
        rvy_emulators_to_test += [{
          'label': target_base,
          'path': rvy_emulator.full_path(),
          'depends': [rvy_emulator],
          'xlen': target_base.contains('riscv32') ? 32 : 64,
          'cheri_version': target_base.contains('cheristd') ? '0.9.3' : '0.9.9',
          'harness': 'qemu',
        }]
      endif
    endforeach
  else
    # Standalone: -Dqemu takes one or more QEMU build/install directories or
    # qemu-system-* binary paths, and -Dsail_099 / -Dsail_093 point at the
    # Sail simulators. Both a QEMU build root and an SDK bin/ directory have
    # qemu-system-riscv{64,32}{y,cheristd} at the top level (and an install
    # prefix has them under bin/). Default paths under ~/cheri/output/sdk/bin
    # are only probed when -Dinfer_test_binary_paths=true is explicitly set.
    qemu_opts = get_option('qemu')
    sail_099 = get_option('sail_099')
    sail_093 = get_option('sail_093')
    infer_paths = get_option('infer_test_binary_paths')

    if qemu_opts.length() == 0 and sail_099.length() == 0 and sail_093.length() == 0 and not infer_paths
      message('no emulator given: building test ELFs only; pass -Dqemu=..., ' +
              '-Dsail_099=..., or -Dsail_093=... to also register test targets')
    else
      qemu_inputs = qemu_opts
      if qemu_inputs.length() == 0 and infer_paths
        rvy_sdk_bin = fs.expanduser('~/cheri/output/sdk/bin')
        if fs.is_dir(rvy_sdk_bin)
          qemu_inputs = [rvy_sdk_bin]
        endif
      endif

      qemu_bins = []
      foreach qemu_entry : qemu_inputs
        qemu_path = fs.expanduser(qemu_entry)
        if fs.is_file(qemu_path)
          qemu_bins += [qemu_path]
        elif fs.is_dir(qemu_path)
          qemu_found = 0
          foreach target_base : rvy_qemu_targets
            bin_name = 'qemu-system-' + target_base
            cand = ''
            foreach subpath : [bin_name, 'bin' / bin_name,
                               (target_base + '-softmmu') / bin_name]
              if cand == '' and fs.exists(qemu_path / subpath)
                cand = qemu_path / subpath
              endif
            endforeach
            if cand != ''
              qemu_found += 1
              qemu_bins += [cand]
            endif
          endforeach
          if qemu_opts.length() == 0 and qemu_found > 0
            message('inferred QEMU build(s) under ' + qemu_path)
          elif qemu_opts.length() > 0 and qemu_found == 0
            error('-Dqemu=@0@ contains no qemu-system-riscv{64,32}{y,cheristd} binaries'
                  .format(qemu_entry))
          endif
        elif qemu_opts.length() > 0
          error('-Dqemu: @0@ not found'.format(qemu_entry))
        endif
      endforeach

      foreach qemu_bin : qemu_bins
        dev_help = run_command(qemu_bin, '-device', 'any-riscv-cpu,help', check: false)
        cpu_help = run_command(qemu_bin, '-cpu', 'help', check: false)
        dev_out = dev_help.stdout() + dev_help.stderr()
        cpu_out = cpu_help.stdout()
        if dev_out.contains('Zysentry') or dev_out.contains('Svyrg')
          cheri_ver = '0.9.9'
        elif dev_out.contains('cheri_pte') or dev_out.contains('Zyhybrid')
          cheri_ver = '0.9.3'
        else
          error('@0@ does not support RVY v0.9.9 or CHERI 0.9.3'.format(qemu_bin))
        endif
        xlen = cpu_out.contains('rv32') ? 32 : 64
        label = 'riscv@0@@1@'.format(xlen, cheri_ver == '0.9.3' ? 'cheristd' : 'y')
        rvy_emulators_to_test += [{
          'label': label,
          'path': qemu_bin,
          'depends': [],
          'xlen': xlen,
          'cheri_version': cheri_ver,
          'harness': 'qemu',
        }]
      endforeach

      rvy_sail_bin_names = ['sail_riscv_sim', 'riscv_sim_rv64d', 'riscv_sim_rv32d',
                            'cheri_riscv_sim_RV64', 'cheri_riscv_sim_RV32']
      foreach sail_opt : [
        {'opt': 'sail_099', 'label': 'sail-0.9.9', 'cheri_version': '0.9.9'},
        {'opt': 'sail_093', 'label': 'sail-0.9.3', 'cheri_version': '0.9.3'},
      ]
        sail_bins = []
        foreach sail_entry : get_option(sail_opt['opt'])
          sail_path = fs.expanduser(sail_entry)
          if fs.is_file(sail_path)
            sail_bins += [sail_path]
          elif fs.is_dir(sail_path)
            sail_found = 0
            foreach bin_name : rvy_sail_bin_names
              cand = ''
              foreach subpath : [bin_name, 'c_emulator' / bin_name, 'bin' / bin_name]
                if cand == '' and fs.exists(sail_path / subpath)
                  cand = sail_path / subpath
                endif
              endforeach
              if cand != ''
                sail_found += 1
                sail_bins += [cand]
              endif
            endforeach
            if sail_found == 0
              error('-D@0@=@1@ contains no Sail simulator binaries'
                    .format(sail_opt['opt'], sail_entry))
            endif
          else
            error('-D@0@: @1@ not found'.format(sail_opt['opt'], sail_entry))
          endif
        endforeach

        foreach sail_bin : sail_bins
          arch_probe = run_command(sail_bin, '-a', check: false)
          arch_str = arch_probe.stdout().strip()
          if arch_probe.returncode() == 0 and (arch_str == 'RV32' or arch_str == 'RV64')
            xlen = arch_str == 'RV32' ? 32 : 64
          else
            cfg_probe = run_command(sail_bin, '--print-default-config', check: false)
            if cfg_probe.returncode() == 0
              xlen = cfg_probe.stdout().contains('"xlen": 32') ? 32 : 64
            else
              sail_name = fs.name(sail_bin)
              xlen = (sail_name.contains('riscv32') or sail_name.contains('rv32') or
                      sail_name.contains('RV32')) ? 32 : 64
            endif
          endif
          rvy_emulators_to_test += [{
            'label': '@0@-rv@1@'.format(sail_opt['label'], xlen),
            'path': sail_bin,
            'depends': [],
            'xlen': xlen,
            'cheri_version': sail_opt['cheri_version'],
            'harness': 'sail',
          }]
        endforeach
      endforeach

      if rvy_emulators_to_test.length() == 0
        error('no emulators found under ~/cheri/output/sdk/bin; pass -Dqemu=..., ' +
              '-Dsail_099=..., or -Dsail_093=... explicitly')
      endif
    endif
  endif

  foreach emulator : rvy_emulators_to_test
    foreach t : rvy_tests
      profile = ('@0@_@1@_@2@'.format(t['name'], emulator['xlen'], emulator['cheri_version'])).underscorify()
      if profile not in rvy_elf_targets
        continue
      endif
      elf = rvy_elf_targets[profile]

      test_id = 'rvy-' + emulator['label'] + '-' + t['name']
      if emulator['harness'] == 'sail'
        test(test_id, rvy_run_test,
             args: ['sail', emulator['path'], elf,
                    get_option('rvy_sail_insn_limit').to_string()],
             depends: emulator['depends'],
             timeout: get_option('rvy_test_timeout'),
             protocol: 'tap',
             suite: ['rvy'])
      else
        qemu_args = t.get('qemu_args', [])
        foreach machine : rvy_machines
          test(test_id + '-' + machine, rvy_run_test,
               args: ['qemu', emulator['path'], elf, machine] + qemu_args,
               depends: emulator['depends'],
               timeout: get_option('rvy_test_timeout'),
               protocol: 'tap',
               suite: ['rvy'])
        endforeach
      endif
    endforeach
  endforeach
endif
