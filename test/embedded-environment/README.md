# Embedded environment lifetime regression

This macOS test calls `ghostty_init`, adds environment variables until libc's
environment vector relocates, then finalizes a config that expands `~`. A borrowed
environment vector can crash during that expansion. The test runs a control and
the mutation case in separate processes; the mutation case must relocate the
vector to count as a pass.

Build GhosttyKit and run against its macOS slice:

```sh
zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast -Demit-macos-app=false -Dsentry=false
python3 test/embedded-environment/run.py macos/GhosttyKit.xcframework/macos-arm64_x86_64
```

The test needs Xcode command-line tools and Python 3. It does not launch a GUI or
write user configuration. Core dumps are disabled for the subprocesses.

Snapshot ownership, retained views, empty environments, and allocation failures
are also covered by four tests in `src/os/EnvironSnapshots.zig`. Run only those
tests without building the full Ghostty test target:

```sh
zig test src/os/EnvironSnapshots.zig
```

On POSIX systems, the output should end with `All 4 tests passed.`

The tests are also included in the regular Zig test target. Zig matches filters
against fully qualified test names, which include `os.EnvironSnapshots.test.`,
so the module name selects these tests even though their declarations use
descriptive names:

```sh
zig build test -Dtest-filter=EnvironSnapshots -Demit-macos-app=false -Dsentry=false --summary all
```

The snapshot protects reads after initialization from later host environment
changes. It does not synchronize concurrent host `setenv` calls with initialization
or explicit environment refreshes; those operations must be quiescent.
