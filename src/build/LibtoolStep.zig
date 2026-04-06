//! A zig builder step that runs "libtool" against a list of libraries
//! in order to create a single combined static library.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []LazyPath,
};

/// The step to depend on.
step: *Step,

/// The output file from the libtool run.
output: LazyPath,

/// Run libtool against a list of library files to combine into a single
/// static library.
pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");
    const env = std.process.getEnvMap(b.allocator) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("libtool {s}", .{opts.name}));
    const env_map = b.allocator.create(std.process.EnvMap) catch @panic("OOM");
    env_map.* = .init(b.allocator);
    if (env.get("PATH")) |path| env_map.put("PATH", path) catch @panic("OOM");
    run_step.env_map = env_map;
    run_step.addArgs(&.{
        "/bin/sh",
        "-c",
        \\set -euo pipefail
        \\out="$1"
        \\shift
        \\tmp="$(mktemp -d "${TMPDIR:-/tmp}/libtool-step.XXXXXX")"
        \\cleanup() { rm -rf "$tmp"; }
        \\trap cleanup EXIT
        \\filelist="$tmp/objects.txt"
        \\: > "$filelist"
        \\index=0
        \\for source in "$@"; do
        \\  ext="${source##*.}"
        \\  if [ "$ext" = "o" ]; then
        \\    printf '%s\n' "$source" >> "$filelist"
        \\  else
        \\    dir="$tmp/$index"
        \\    mkdir -p "$dir"
        \\    cp "$source" "$dir/input.a"
        \\    (
        \\      cd "$dir"
        \\      ar -x input.a
        \\    )
        \\    find "$dir" -type f -name '*.o' -exec chmod u+r {} +
        \\    find "$dir" -type f -name '*.o' | LC_ALL=C sort >> "$filelist"
        \\  fi
        \\  index=$((index + 1))
        \\done
        \\mkdir -p "$(dirname "$out")"
        \\/usr/bin/libtool -static -filelist "$filelist" -o "$out"
        \\/usr/bin/ranlib "$out"
        ,
        "libtool-step",
    });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources) |source| run_step.addFileArg(source);

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}
