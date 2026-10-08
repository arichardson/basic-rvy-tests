# Basic RVY tests

Bare-metal assembly tests for CHERI RISC-V, written against the RVY v0.9.10 and
v0.9.9 specifications and also buildable against CHERI 0.9.3. Each test boots on
its own, checks one area of the architecture, and reports a single pass or fail.

The suite is deliberately small and self-contained: there is no libc and no
runtime. Every RVY instruction is emitted with `.insn`, so **the toolchain
does not need CHERI support** and any bare-metal RISC-V clang will do.

## Running

Meson is the preferred way to run the suite: it registers one build target
per ELF and one test per (test, emulator, machine), so `ninja`/`meson test`
build and run cases in parallel and report each one individually, rather
than the whole suite passing or failing as a unit.

As QEMU's `tests/rvy` submodule it registers itself, so `make check-rvy` or
`meson test --suite rvy` runs it against the emulators that build produced.
It is skipped rather than failing if no RISC-V-capable clang is found;
`-Drvy_test_cc=/path/to/clang` names one explicitly.

Standalone, point it at a QEMU build or install directory (or specific
`qemu-system-*` binaries) and/or the Sail simulator binaries:

```sh
meson setup build -Dqemu=/path/to/qemu/build -Dsail_093=/path/to/sail_riscv_sim
meson test -C build
```

`-Dqemu` accepts a QEMU build directory, an SDK `bin` directory (or install
prefix), or a comma-separated list of individual `qemu-system-*` binaries.
When given a directory, it automatically picks up whichever of the four QEMU
targets (`qemu-system-riscv{64,32}{y,cheristd}`) are present. When
`qemu-system-riscv{64,32}y` supports `rvy_spec`, both v0.9.10
(`-global riscv-cpu.rvy_spec=0.9.10`) and v0.9.9
(`-global riscv-cpu.rvy_spec=0.9.9`) are tested. `-Dsail_0910`, `-Dsail_099`,
and `-Dsail_093` select the RVY v0.9.10, RVY v0.9.9, and CHERI 0.9.3 Sail
simulators explicitly:

| Emulator / option | XLEN | CHERI version |
| --- | --- | --- |
| `qemu-system-riscv64y` | 64 | v0.9.10 (`rvy_spec=0.9.10`) and v0.9.9 (`rvy_spec=0.9.9`) |
| `qemu-system-riscv32y` | 32 | v0.9.10 (`rvy_spec=0.9.10`) and v0.9.9 (`rvy_spec=0.9.9`) |
| `qemu-system-riscv64cheristd` | 64 | 0.9.3 |
| `qemu-system-riscv32cheristd` | 32 | 0.9.3 |
| `-Dsail_0910` | 64 (or 32) | v0.9.10 |
| `-Dsail_099` | 64 (or 32) | v0.9.9 |
| `-Dsail_093` | 64 (or 32) | 0.9.3 |

0.9.3 builds get `-DCHERI_093`, v0.9.9 builds get `-DCHERI_099`, and v0.9.10
builds get `-DCHERI_0910`; tests whose subject only exists in RVY (or only in
v0.9.9) are skipped rather than being made to mean something else.

Each test is run on both the `virt` and `spike` machines, because results are
reported twice over: through the HTIF `tohost` register, which spike-like
harnesses including the Sail model understand, and through the `sifive_test`
finisher that `virt` provides. Running both keeps either path from silently
rotting.

Console output goes to both sinks as well. HTIF carries it on `spike` and
under Sail; `virt` has no HTIF but does have a 16550 UART, which the suite
probes for at startup and writes to when it is there, so a run prints the
same thing either way.

To build the test ELFs without running them (for example, to run on another
system or simulator), configure without any emulator options:

```sh
meson setup build
ninja -C build
```

This produces three sets of ELF binaries under `build/src/0.9.3/`,
`build/src/0.9.9/`, and `build/src/0.9.10/` (and registers `rvy-elfs-0.9.3`,
`rvy-elfs-0.9.9`, and `rvy-elfs-0.9.10` alias targets). Pass
`-Dcheri_versions=0.9.10`, `-Dcheri_versions=0.9.9`, or `-Dcheri_versions=0.9.3`
to build only a subset.

Additional `-D` options:

| Option | Default | Meaning |
| --- | --- | --- |
| `cheri_versions` | `['0.9.3', '0.9.9', '0.9.10']` | CHERI specification versions to build test ELFs for |
| `infer_test_binary_paths` | `false` | Search `~/cheri/output/sdk/bin` when no emulator options are given |
| `rvy_test_timeout` | `20` | Wall-clock seconds before a test is considered hung |
| `rvy_sail_insn_limit` | `20000000` | Instruction budget for the Sail model |

### Fallback: a single emulator, no build directory

```sh
./src/run-rvy-tests.sh <emulator> [clang]
```

A thin wrapper for a one-off "does this emulator pass" check: it drives the
same meson setup through a throwaway build directory and forwards its exit
code. Reach for meson directly once you want more than one emulator, a
persistent build directory, or per-case results.

## Reading a failure

Each test writes a TAP stream, so `meson test` reports the individual cases
rather than one verdict per binary, and `--print-errorlogs` shows which case
failed and what it was checking:

```
TAP version 13
# FAIL: asr test 3
ok 1 - root pcc grants ASR so cbo.inval reports the capability fault
ok 2 - a pcc without ASR still runs, and consumes its own traps
not ok 3 - back on the root pcc the ASR-gated CSRs work again
1..3
```

The plan comes last, so a test never has to declare how many cases it has.
Cases are numbered by counting `NEXT_TEST` from the top of the file, and the
name is the string that `NEXT_TEST` was given. The process also exits with the
number of the failing case, which is what the summary line shows.

## What is covered

| Test | Subject |
| --- | --- |
| `test-insn-encodings` | Encoding and semantics of the RVY instructions |
| `test-cap-ops` | Capability manipulation and inspection instructions |
| `test-cap-ops-failures` | Negative, malformed-metadata, and reserved-encoding capability cases |
| `test-representable-range` | Representable range boundaries across E=0 and internal-exponent capabilities |
| `test-ddc-access` | Integer-mode explicit memory accesses authorized through DDC |
| `test-cap-roundtrip` | Storing and loading arbitrary capability bit patterns without loss |
| `test-bounds-causes` | The cause reported for bounds violations, per access type |
| `test-amo-cbo-causes` | Causes for capability atomics and cache-block operations |
| `test-loadstore-x0` | `x0` as a base register: zero in integer mode, NULL in capability mode |
| `test-pcc-bounds-fetch` | Fetching across the end of PCC, including straddling instructions |
| `test-cap-reset-regression` | A stored capability writes out the bits the register holds |
| `test-asr` | Operations gated on the `ASR` permission |
| `test-cap-csrs` | Capability CSR read/write semantics across modes and privileges |
| `test-console` | The shared console helpers, and that they emit what they are asked to |
| `test-cbo-bounds` | CBO.ZERO/INVAL fault on any byte out of bounds, CBO.CLEAN/FLUSH only if all are |
| `test-xepc-detag` | mepc/sepc legalization: misaligned writes, and reads/mret under IALIGN=32 |
| `test-xtvec-detag` | mtvec/stvec legalization and same-block CSR write visibility |
| `test-branches` | `BEQ`/`BNE` with `rs1 <= rs2` in integer and capability modes |
| `test-reserved-branches` | Reserved `BEQ`/`BNE` with `rs1 <= rs2` in capability mode (v0.9.9 only) |
| `test-branch-target-faults` | Control-flow faults are taken at the target, not the branch |
| `test-exception-priority` | Which exception wins when an instruction trips two checks |
| `test-xepc-return` | MRET unseals a sentry epcc and installs it as PCC unchecked |
| `test-misa-y` | Turning CHERI off through `misa.Y`, and the CSRs that go with it |
| `test-svyrg` | `Svyrg` and the `pte.rvy` field, under Sv39 paging |
| `test-translation-priority` | Page table walk faults, and where they rank against the capability checks |

`test-branch-target-faults`, `test-exception-priority`, and `test-xepc-return`
require `>= 0.9.6`; `test-svyrg` and `test-translation-priority` require
`>= 0.9.7`; `test-misa-y` requires `>= 0.9.9`; and `test-reserved-branches` is
v0.9.9 only.

## Layout

| File | Purpose |
| --- | --- |
| `src/meson.build` | Registers the build and test targets; the list of tests lives here |
| `src/testmacros.h` | `.macro` wrapper per instruction, for both CHERI versions, plus the pass/fail reporting |
| `src/exceptions.h` | Trap handlers and the `EXPECT_*` vocabulary for stating what should fault |
| `src/link.ld` | Flat layout at `0x80000000`, with HTIF given a page to itself |
| `src/run-rvy-test.sh` | Runs one already-built ELF through one emulator invocation; called by each meson test() |
| `src/run-rvy-tests.sh` | Fallback wrapper: drives meson for a single emulator without a build directory |
| `src/console.S` | Console output (HTIF and the virt UART) and the exit sequence, linked into every test |
| `src/console.h` | Constants and the calling convention for the above |
| `src/rvy-insns.h` | The RVY instruction encodings, shared by the tests and `console.S` |
| `src/probe.S` | Compiles to nothing; used to detect a usable toolchain |

## Licence

BSD-2-Clause. See `LICENSE`.
