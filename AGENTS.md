# Working in this repository

Notes for automated contributors. `README.md` covers what the suite is and
how to run it; this file is about the conventions a change has to keep.

## Before changing a test, read its header

Every test opens with a comment stating the rule it checks and why the cases
are the way they are. That comment is the specification for the file. If a
change makes it wrong, the comment is part of the change.

## Adding a test

1. `test-<subject>.S`, with `#define TEST_NAME "<subject>"` before including
   `testmacros.h` and `exceptions.h`.
2. Add it to the list in `run-rvy-tests.sh`: the shared loop if both CHERI
   versions have the behaviour, the `v0.9.9` block if only RVY does. **A test
   that is not in that list never runs**, and nothing will tell you so.
3. Place exactly one `TRAP_HANDLER` or `TRAP_HANDLER_PCC` in the file.
4. End with `TEST_PASS`, and a `fail:` label reaching `TEST_FAIL`.

Number cases with `NEXT_TEST` rather than literals, so inserting one does not
renumber the rest.

## Version differences

Prefer writing a case so both versions can run it. Where they genuinely
differ, use `TRAP_CAP_<access>(<check>)`, which each version resolves to what
it can observe, or `#ifdef CHERI_093` around the individual case.

Reserve a file-level `#ifdef CHERI_093` / `#error` for tests whose *subject*
does not exist in 0.9.3, such as `misa.Y` or the `pte.rvy` field. Excluding a
whole file because a few cases do not apply loses the coverage that did.

## Registers

`exceptions.h` reserves registers for the trap handlers and poisons their raw
names at the end of the header, so misuse is a build error rather than a
confusing failure. Tests have `s0`, `s1`, `s2`, `s7`, `a0`-`a7` and `t0`-`t4`;
`t5`/`t6` are handler scratch. Give a reserved register a `#define` name if a
test needs to track something across cases, as `expected_epc` does.

## What a test may assert

Only architectural behaviour. Anything that depends on the machine rather
than the architecture will pass on one emulator and fail on another:

- Whether an address is readable, writable, or exists at all. Assert that an
  access was not refused *on capability grounds*, not that it succeeded.
- Whether a region carries tags, or preserves capability stores. This follows
  from the memory region type, which a guest cannot see.
- The reset value of anything the test did not set itself, unless the test is
  specifically about reset values.

`.bss` is placed before `.tohost` in `link.ld` for this reason: HTIF needs a
page to itself, because data sharing it stops behaving like memory. Keep it
that way.

## Ordering and priority cases

When the point is *which* of two exceptions is reported, a single assertion
proves nothing, because it also passes when only one of them was ever
possible. Pair every such case with a control that removes the winning
condition and requires the loser to appear. `test-exception-priority` is the
worked example.

## Verify before committing

Run the full suite on all four QEMU targets and, for anything a 0.9.3 build
covers, the Sail model:

```sh
for t in riscv64y riscv32y riscv64cheristd riscv32cheristd; do
    ./src/run-rvy-tests.sh /path/to/qemu-system-$t
done
./src/run-rvy-tests.sh /path/to/sail_riscv_sim
```

Then mutation-check what you added: change the expected cause to the one you
believe loses, and confirm the test fails at that case number. A test that
still passes is not testing what its comment claims. This is worth the minute
it takes; several tests in this suite were wrong in exactly that way until
they were checked.

## Style

- Commit subjects are plain, with no tag or prefix, in UK English with `-ize`
  endings. Keep the body short, and about *why*, not what the diff shows.
- Comments state the important fact and stop. They describe the code as it
  is, never the debugging that produced it, prior versions, or that something
  was recently fixed.
- No em-dashes in comments or commit messages.
