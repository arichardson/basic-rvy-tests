# SPDX-License-Identifier: BSD-2-Clause
#
# Standalone build of the RVY test suite, for using this repository on its
# own rather than as QEMU's tests/rvy submodule. Point it at a QEMU build or
# install directory (or binary) and/or Sail simulator binaries:
#
#   meson setup build -Dqemu=/path/to/qemu/build
#   meson test -C build
#
# QEMU does not read this file: its tests/meson.build includes src/ directly,
# which is where the logic both entry points share lives.
project('rvy-tests', meson_version: '>=0.61.0')

subdir('src')
