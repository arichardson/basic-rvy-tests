# SPDX-License-Identifier: BSD-2-Clause
#
# Standalone build of the RVY test suite, for using this repository on its
# own rather than as QEMU's tests/rvy submodule. Point it at one or more
# already-built emulators:
#
#   meson setup build -Drvy_emulators=/path/to/qemu-system-riscv64y
#   meson test -C build
#
# QEMU does not read this file: its tests/meson.build includes src/ directly,
# which is where the logic both entry points share lives.
project('rvy-tests', meson_version: '>=0.61.0')

subdir('src')
