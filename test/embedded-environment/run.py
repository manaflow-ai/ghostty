#!/usr/bin/env python3
"""Check the embedding environment lifetime using a prebuilt macOS archive."""
import argparse
from pathlib import Path
import resource
import subprocess
import tempfile


def disable_core_dumps():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slice", type=Path, help="macOS GhosttyKit slice containing Headers and ghostty-internal.a")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ghostty-environ-") as directory:
        executable = Path(directory) / "test-environ"
        command = ["xcrun", "clang", str(Path(__file__).with_name("main.c")),
                   "-I", str(args.slice / "Headers"),
                   str(args.slice / "ghostty-internal.a"), "-o", str(executable),
                   "-lc++", "-liconv", "-lz"]
        for framework in ("Cocoa", "Metal", "QuartzCore", "CoreText", "CoreGraphics",
                          "Carbon", "IOSurface", "IOKit", "UniformTypeIdentifiers"):
            command += ["-framework", framework]
        subprocess.run(command, check=True)
        for case in ([], ["mutate"]):
            result = subprocess.run([str(executable), *case], timeout=20,
                                    preexec_fn=disable_core_dumps)
            if result.returncode:
                raise SystemExit(f"environment case {case or ['control']} failed: {result.returncode}")
    print("PASS: embedded config survives host environment mutation")


if __name__ == "__main__":
    main()
