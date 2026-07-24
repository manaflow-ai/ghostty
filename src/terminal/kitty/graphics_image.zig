const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const fastmem = @import("../../fastmem.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const sys = @import("../sys.zig");

const temp_dir = struct {
    const TempDir = @import("../../os/TempDir.zig");
    const allocTmpDir = @import("../../os/file.zig").allocTmpDir;
    const freeTmpDir = @import("../../os/file.zig").freeTmpDir;
};

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// Maximum size in bytes, taken from Kitty.
const max_size = 400 * 1024 * 1024; // 400MB

/// An image that is still being loaded. The image should be initialized
/// using init on the first chunk and then addData for each subsequent
/// chunk. Once all chunks have been added, complete should be called
/// to finalize the image.
pub const LoadingImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .{},

    /// This is non-null when a transmit and display command is given
    /// so that we display the image after it is fully loaded.
    display: ?command.Display = null,

    /// Quiet is the quiet settings for the initial load command. This is
    /// used if q isn't set on subsequent chunks.
    quiet: command.Command.Quiet,

    /// Maximum compressed, encoded, or decoded bytes retained while loading.
    /// This is capped by max_size even if the storage limit is higher.
    byte_limit: usize = max_size,

    /// The limits of the Kitty Graphics protocol we should allow.
    ///
    /// This can be used to restrict the type of images and other
    /// parameters for resource or security reasons. Note that depending
    /// on how libghostty is compiled, some of these may be fully unsupported
    /// and ignored (e.g. "file" on wasm32-freestanding).
    pub const Limits = packed struct {
        file: bool,
        temporary_file: bool,
        shared_memory: bool,

        pub const all: Limits = .{
            .file = true,
            .temporary_file = true,
            .shared_memory = true,
        };

        pub const direct: Limits = .{
            .file = false,
            .temporary_file = false,
            .shared_memory = false,
        };
    };

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(
        alloc: Allocator,
        cmd: *const command.Command,
        limits: Limits,
    ) !LoadingImage {
        return initWithLimit(alloc, cmd, limits, max_size);
    }

    /// Initialize an image while bounding all retained input and decoded data.
    pub fn initWithLimit(
        alloc: Allocator,
        cmd: *const command.Command,
        limits: Limits,
        byte_limit: usize,
    ) !LoadingImage {
        // Build our initial image from the properties sent via the control.
        // These can be overwritten by the data loading process. For example,
        // PNG loading sets the width/height from the data.
        const t = cmd.transmission().?;
        var result: LoadingImage = .{
            .image = .{
                .id = t.image_id,
                .number = t.image_number,
                .width = t.width,
                .height = t.height,
                .compression = t.compression,
                .format = t.format,
            },

            .display = cmd.display(),
            .quiet = cmd.quiet,
            .byte_limit = @min(byte_limit, max_size),
        };
        errdefer result.deinit(alloc);

        // Special case for the direct medium, we just add the chunk directly.
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }

        // Verify our capabilities and limits allow this.
        {
            // Special case if we don't support decoding PNGs and the format
            // is a PNG we can save a lot of memory/effort buffering the
            // data but failing up front.
            if (t.format == .png and
                sys.decode_png == null)
            {
                return error.UnsupportedMedium;
            }

            // Verify the medium is allowed
            switch (t.medium) {
                .direct => unreachable,
                .file => if (!limits.file) return error.UnsupportedMedium,
                .temporary_file => if (!limits.temporary_file) return error.UnsupportedMedium,
                .shared_memory => if (!limits.shared_memory) return error.UnsupportedMedium,
            }
        }

        // Otherwise, the payload data is guaranteed to be a path.

        if (comptime builtin.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                // posix.realpath *asserts* that the path does not have
                // internal nulls instead of erroring.
                log.warn("failed to get absolute path: BadPathName", .{});
                return error.InvalidData;
            }
        }

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = switch (t.medium) {
            .direct => unreachable, // handled above
            .file, .temporary_file => posix.realpath(cmd.data, &abs_buf) catch |err| {
                log.warn("failed to get absolute path: {}", .{err});
                return error.InvalidData;
            },
            .shared_memory => cmd.data,
        };

        // Depending on the medium, load the data from the path.
        switch (t.medium) {
            .direct => unreachable, // handled above
            .file => try result.readFile(.file, alloc, t, path),
            .temporary_file => try result.readFile(.temporary_file, alloc, t, path),
            .shared_memory => try result.readSharedMemory(alloc, t, path),
        }

        return result;
    }

    /// Reads the data from a shared memory segment.
    fn readSharedMemory(
        self: *LoadingImage,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        // android does not support POSIX shared memory.
        // windows is currently unsupported, does it support shm?
        if (comptime builtin.abi.isAndroid() or builtin.target.os.tag == .windows) {
            return error.UnsupportedMedium;
        }

        // libc is required for shm_open
        if (comptime !builtin.link_libc) {
            return error.UnsupportedMedium;
        }

        // Since we're only supporting posix then max_path_bytes should
        // be enough to stack allocate the path.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.InvalidData;

        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), 0);
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        defer _ = std.c.close(fd);
        defer _ = std.c.shm_unlink(pathz);

        // The size from stat on may be larger than our expected size because
        // shared memory has to be a multiple of the page size.
        const stat_size: usize = stat: {
            const stat = std.posix.fstat(fd) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat @intCast(stat.size);
        };

        const expected_size: usize = switch (self.image.format) {
            // Png we decode the full data size because later decoding will
            // get the proper dimensions and assert validity.
            .png => stat_size,

            // For these formats we have a size we must have.
            .gray, .gray_alpha, .rgb, .rgba => size: {
                const bpp = command.Transmission.formatBpp(self.image.format);
                break :size self.image.width * self.image.height * bpp;
            },
        };

        // Our stat size must be at least the expected size otherwise
        // the shared memory data is invalid.
        if (stat_size < expected_size) {
            log.warn(
                "shared memory size too small expected={} actual={}",
                .{ expected_size, stat_size },
            );
            return error.InvalidData;
        }

        const map = std.posix.mmap(
            null,
            stat_size, // mmap always uses the stat size
            std.c.PROT.READ,
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);

        // Our end size always uses the expected size so we cut off the
        // padding for mmap alignment.
        const start: usize = @intCast(t.offset);
        const end: usize = if (t.size > 0) @min(
            @as(usize, @intCast(t.offset)) + @as(usize, @intCast(t.size)),
            expected_size,
        ) else expected_size;

        assert(self.data.items.len == 0);
        try self.addData(alloc, map[start..end]);
    }

    /// Reads the data from a temporary file and returns it. This allocates
    /// and does not free any of the data, so the caller must free it.
    ///
    /// This will also delete the temporary file if it is in a safe location.
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }

        // Verify file seems "safe". This is logic copied directly from Kitty,
        // mostly. This is really rough but it will catch obvious bad actors.
        if (std.mem.startsWith(u8, path, "/proc/") or
            std.mem.startsWith(u8, path, "/sys/") or
            (std.mem.startsWith(u8, path, "/dev/") and
                !std.mem.startsWith(u8, path, "/dev/shm/")))
        {
            return error.InvalidData;
        }

        // Temporary file logic
        if (medium == .temporary_file) {
            if (!isPathInTempDir(path)) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(u8, path, "tty-graphics-protocol") == null) {
                return error.TemporaryFileNotNamedCorrectly;
            }
        }
        defer if (medium == .temporary_file) {
            posix.unlink(path) catch |err| {
                log.warn("failed to delete temporary file: {}", .{err});
            };
        };

        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.warn("failed to open temporary file: {}", .{err});
            return error.InvalidData;
        };
        defer file.close();

        // File must be a regular file
        if (file.stat()) |stat| {
            if (stat.kind != .file) {
                log.warn("file is not a regular file kind={}", .{stat.kind});
                return error.InvalidData;
            }
        } else |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        }

        if (t.offset > 0) {
            file.seekTo(@intCast(t.offset)) catch |err| {
                log.warn("failed to seek to offset {}: {}", .{ t.offset, err });
                return error.InvalidData;
            };
        }

        var buf: [4096]u8 = undefined;
        var buf_reader = file.reader(&buf);
        const reader = &buf_reader.interface;

        assert(self.data.items.len == 0);
        var remaining: usize = if (t.size > 0)
            @intCast(t.size)
        else
            std.math.maxInt(usize);
        var chunk: [4096]u8 = undefined;
        while (remaining > 0) {
            const requested = @min(chunk.len, remaining);
            const n = reader.readSliceShort(chunk[0..requested]) catch {
                log.warn("failed to read temporary file: {?}", .{buf_reader.err});
                return error.InvalidData;
            };
            if (n == 0) break;

            // addData grows precisely and rejects the chunk before allocating
            // if it would cross the configured storage byte limit.
            try self.addData(alloc, chunk[0..n]);
            remaining -= n;
        }
    }

    /// Returns true if path appears to be in a temporary directory.
    /// Copies logic from Kitty.
    fn isPathInTempDir(path: []const u8) bool {
        if (std.mem.startsWith(u8, path, "/tmp")) return true;
        if (std.mem.startsWith(u8, path, "/dev/shm")) return true;
        const dir = temp_dir.allocTmpDir(std.heap.page_allocator) catch return false;
        defer temp_dir.freeTmpDir(std.heap.page_allocator, dir);
        if (std.mem.startsWith(u8, path, dir)) return true;

        // The temporary dir is sometimes a symlink. On macOS for
        // example /tmp is /private/var/...
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (posix.realpath(dir, &buf)) |real_dir| {
            if (std.mem.startsWith(u8, path, real_dir)) return true;
        } else |_| {}

        return false;
    }

    pub fn deinit(self: *LoadingImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn destroy(self: *LoadingImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    /// Updates the configured loading limit. Returns false when bytes already
    /// retained by this load exceed the new limit.
    pub fn setByteLimit(self: *LoadingImage, limit: usize) bool {
        self.byte_limit = @min(limit, max_size);
        return self.data.items.len <= self.byte_limit and
            self.data.capacity <= self.byte_limit;
    }

    /// Adds a chunk of data to the image. Use this if the image
    /// is coming in chunks (the "m" parameter in the protocol).
    pub fn addData(self: *LoadingImage, alloc: Allocator, data: []const u8) !void {
        // If no data, skip
        if (data.len == 0) return;

        // If our data would get too big, return an error before growing the
        // backing allocation. Check subtraction first to avoid overflow.
        if (self.data.items.len > max_size or
            data.len > max_size - self.data.items.len)
        {
            log.warn("image data too large max_size={}", .{max_size});
            return error.InvalidData;
        }
        if (self.data.items.len > self.byte_limit or
            data.len > self.byte_limit - self.data.items.len)
        {
            log.warn("image data exceeds storage byte limit={}", .{self.byte_limit});
            return error.OutOfMemory;
        }

        const new_len = self.data.items.len + data.len;
        try ensureBoundedCapacity(
            &self.data,
            alloc,
            new_len,
            self.byte_limit,
        );

        const start_i = self.data.items.len;
        self.data.items.len = new_len;
        fastmem.copy(u8, self.data.items[start_i..], data);
    }

    /// Grow geometrically so chunked inputs remain amortized linear while
    /// never reserving more than the configured byte limit.
    fn ensureBoundedCapacity(
        list: *std.ArrayList(u8),
        alloc: Allocator,
        minimum: usize,
        limit: usize,
    ) Allocator.Error!void {
        assert(minimum <= limit);
        assert(limit <= max_size);
        if (minimum <= list.capacity) return;

        // Limits are capped at max_size, so this arithmetic cannot overflow.
        const geometric = @min(
            limit,
            list.capacity + list.capacity / 2 + 8,
        );
        try list.ensureTotalCapacityPrecise(
            alloc,
            @max(minimum, geometric),
        );
    }

    /// Complete the chunked image, returning a completed image.
    pub fn complete(self: *LoadingImage, alloc: Allocator) !Image {
        const img = &self.image;

        // Raw formats have dimensions from the command, so validate their
        // decoded resource requirement before decompression allocates output.
        if (img.format != .png) {
            const expected_len = try self.expectedDataLen();
            if (expected_len > self.byte_limit) return error.OutOfMemory;
        }

        // Decompress the data if it is compressed.
        try self.decompress(alloc);

        // Decode the png if we have to
        if (img.format == .png) try self.decodePng(alloc);

        // Data length must be what we expect
        const expected_len = try self.expectedDataLen();
        if (expected_len > self.byte_limit) return error.OutOfMemory;
        const actual_len = self.data.items.len;
        if (actual_len != expected_len) {
            const bpp = command.Transmission.formatBpp(img.format);
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = try self.data.toOwnedSlice(alloc);
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    fn expectedDataLen(self: *const LoadingImage) !usize {
        const img = &self.image;
        if (img.width == 0 or img.height == 0) return error.DimensionsRequired;
        if (img.width > max_dimension or img.height > max_dimension) {
            return error.DimensionsTooLarge;
        }

        const pixel_count = std.math.mul(
            usize,
            @intCast(img.width),
            @intCast(img.height),
        ) catch return error.DimensionsTooLarge;
        return std.math.mul(
            usize,
            pixel_count,
            command.Transmission.formatBpp(img.format),
        ) catch return error.DimensionsTooLarge;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(self: LoadingImage) !void {
        if (comptime builtin.mode != .Debug) @compileError("debugDump in non-debug");

        var buf: [1024]u8 = undefined;
        const filename = try std.fmt.bufPrint(
            &buf,
            "image-{s}-{s}-{d}x{d}-{}.data",
            .{
                @tagName(self.image.format),
                @tagName(self.image.compression),
                self.image.width,
                self.image.height,
                self.image.id,
            },
        );
        const cwd = std.fs.cwd();
        const f = try cwd.createFile(filename, .{});
        defer f.close();

        const writer = f.writer();
        try writer.writeAll(self.data.items);
    }

    /// Decompress the data in-place.
    fn decompress(self: *LoadingImage, alloc: Allocator) !void {
        return switch (self.image.compression) {
            .none => {},
            .zlib_deflate => self.decompressZlib(alloc),
        };
    }

    fn decompressZlib(self: *LoadingImage, alloc: Allocator) !void {
        // Open our zlib stream
        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var reader: std.Io.Reader = .fixed(self.data.items);
        var stream: std.compress.flate.Decompress = .init(&reader, .zlib, &buf);

        // Stream into precisely-sized growth so neither a compression bomb
        // nor ArrayList capacity rounding can allocate beyond byte_limit.
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);
        var output: [4096]u8 = undefined;
        while (true) {
            const n = stream.reader.readSliceShort(&output) catch {
                log.warn("failed to read decompressed data: {?}", .{stream.err});
                return error.DecompressionFailed;
            };
            if (n == 0) break;
            if (list.items.len > self.byte_limit or
                n > self.byte_limit - list.items.len)
            {
                log.warn(
                    "decompressed image exceeds storage byte limit={}",
                    .{self.byte_limit},
                );
                return error.OutOfMemory;
            }

            const new_len = list.items.len + n;
            try ensureBoundedCapacity(
                &list,
                alloc,
                new_len,
                self.byte_limit,
            );
            list.appendSliceAssumeCapacity(output[0..n]);
        }

        // Empty our current data list, take ownership over managed array list
        self.data.deinit(alloc);
        self.data = .{ .items = list.items, .capacity = list.capacity };

        // Make sure we note that our image is no longer compressed
        self.image.compression = .none;
    }

    /// Decode the data as PNG. This will also updated the image dimensions.
    fn decodePng(self: *LoadingImage, alloc: Allocator) !void {
        assert(self.image.format == .png);

        // PNG dimensions are stored in the mandatory first IHDR chunk. Check
        // the decoded RGBA requirement before the decoder allocates it.
        const dimensions = try pngDimensions(self.data.items);
        if (dimensions.width > max_dimension or dimensions.height > max_dimension) {
            return error.DimensionsTooLarge;
        }
        const pixel_count = std.math.mul(
            usize,
            @intCast(dimensions.width),
            @intCast(dimensions.height),
        ) catch return error.DimensionsTooLarge;
        const decoded_len = std.math.mul(
            usize,
            pixel_count,
            command.Transmission.formatBpp(.rgba),
        ) catch return error.DimensionsTooLarge;
        if (decoded_len > max_size) return error.InvalidData;
        if (decoded_len > self.byte_limit) return error.OutOfMemory;

        const decode_png_fn = sys.decode_png orelse
            return error.UnsupportedFormat;
        const result = decode_png_fn(
            alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.InvalidData => return error.InvalidData,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer alloc.free(result.data);

        if (result.width != dimensions.width or
            result.height != dimensions.height or
            result.data.len != decoded_len)
        {
            log.warn(
                "png decoder result disagrees with IHDR expected={}x{} bytes={} actual={}x{} bytes={}",
                .{
                    dimensions.width,
                    dimensions.height,
                    decoded_len,
                    result.width,
                    result.height,
                    result.data.len,
                },
            );
            return error.InvalidData;
        }

        // Replace the encoded bytes by taking ownership of the decoder output.
        self.data.deinit(alloc);
        self.data = .{
            .items = result.data,
            .capacity = result.data.len,
        };

        // Store updated image dimensions
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }

    const PngDimensions = struct {
        width: u32,
        height: u32,
    };

    fn pngDimensions(data: []const u8) !PngDimensions {
        const signature = "\x89PNG\r\n\x1a\n";
        if (data.len < 24 or !std.mem.eql(u8, data[0..8], signature)) {
            return error.InvalidData;
        }
        if (std.mem.readInt(u32, data[8..12], .big) != 13 or
            !std.mem.eql(u8, data[12..16], "IHDR"))
        {
            return error.InvalidData;
        }

        const width = std.mem.readInt(u32, data[16..20], .big);
        const height = std.mem.readInt(u32, data[20..24], .big);
        if (width == 0 or height == 0) return error.InvalidData;
        return .{ .width = width, .height = height };
    }
};

/// Image represents a single fully loaded image.
///
/// The image data is always fully decoded raw pixels: loading inflates
/// any zlib-compressed payload and decodes PNG into RGBA before an image
/// is completed, so `compression` is always `.none` and `format` is
/// never `.png` for a stored image, and `data.len` always equals
/// `width * height * bytes-per-pixel`.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: []const u8 = "",

    /// Unique, monotonically increasing stamp assigned each time an
    /// image is added to (or replaced in) an ImageStorage. A changed
    /// generation for a given image ID means the image contents may
    /// have changed, even if the dimensions and byte length are the
    /// same (e.g. a retransmission of the same ID). Stamps order by
    /// transmission time. Zero means "never stored".
    generation: u64 = 0,

    /// Set this to true if this image was loaded by a command that
    /// doesn't specify an ID or number, since such commands should
    /// not be responded to, even though we do currently give them
    /// IDs in the public range (which is bad!).
    implicit_id: bool = false,

    pub const Error = error{
        InvalidData,
        DecompressionFailed,
        DimensionsRequired,
        DimensionsTooLarge,
        FilePathTooLong,
        TemporaryFileNotInTempDir,
        TemporaryFileNotNamedCorrectly,
        UnsupportedFormat,
        UnsupportedMedium,
        UnsupportedDepth,
    };

    pub fn deinit(self: *Image, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        copy.data = "";
        return copy;
    }
};

/// The rect taken up by some image placement, in grid cells. This will
/// be rounded up to the nearest grid cell since we can't place images
/// in partial grid cells.
pub const Rect = struct {
    top_left: PageList.Pin,
    bottom_right: PageList.Pin,
};

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
        .data = try alloc.dupe(u8, data[0..1024]),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked with zero initial chunk" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: temporary file without correct path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(alloc, &cmd, .all));

    // Temporary file should still be there
    try tmp_dir.dir.access(path, .{});
}

test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .all);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(path, .{}));
}

test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .all);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(path, .{});
}

test "image load: png, not compressed, regular file" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .file,
            .compression = .none,
            .width = 0,
            .height = 0,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .all);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(path, .{});
}

test "image load: png decoded size is rejected before decoder allocation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Decoder = struct {
        var called: bool = false;

        fn decode(_: Allocator, _: []const u8) sys.DecodeError!sys.Image {
            called = true;
            return error.InvalidData;
        }
    };

    const previous_decoder = sys.decode_png;
    defer sys.decode_png = previous_decoder;
    Decoder.called = false;
    sys.decode_png = &Decoder.decode;

    // A valid PNG signature and IHDR declaring 5x5 RGBA pixels. The encoded
    // header fits the 64-byte limit, but its 100 decoded bytes do not.
    const png_header = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1A, '\n',
        0x00, 0x00, 0x00, 0x0D, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x05,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    };
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, &png_header),
    };
    defer cmd.deinit(alloc);

    var loading = try LoadingImage.initWithLimit(alloc, &cmd, .direct, 64);
    defer loading.deinit(alloc);
    try testing.expectError(error.OutOfMemory, loading.complete(alloc));
    try testing.expect(!Decoder.called);
}

test "image load: file input never allocates beyond byte limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const byte_limit = 4096;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = [_]u8{0xA5} ** (byte_limit + 1);
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = &data,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &path_buf);
    var loading: LoadingImage = .{
        .image = .{},
        .quiet = .no,
        .byte_limit = byte_limit,
    };
    defer loading.deinit(alloc);

    try testing.expectError(
        error.OutOfMemory,
        loading.readFile(.file, alloc, .{ .medium = .file }, path),
    );
    try testing.expectEqual(byte_limit, loading.data.items.len);
    try testing.expectEqual(byte_limit, loading.data.capacity);
}

test "image load: chunked input grows geometrically within byte limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const byte_limit = 1024;
    var loading: LoadingImage = .{
        .image = .{},
        .quiet = .no,
        .byte_limit = byte_limit,
    };
    defer loading.deinit(alloc);

    for (0..513) |_| try loading.addData(alloc, "x");

    try testing.expectEqual(@as(usize, 513), loading.data.items.len);
    try testing.expect(loading.data.capacity > loading.data.items.len);
    try testing.expect(loading.data.capacity <= byte_limit);
    const capacity = loading.data.capacity;
    try testing.expectError(
        error.OutOfMemory,
        loading.addData(alloc, &([_]u8{0xA5} ** 512)),
    );
    try testing.expectEqual(capacity, loading.data.capacity);
}

test "limits: direct medium always allowed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);

    // Direct medium should work even with the most restrictive limits
    var loading = try LoadingImage.init(alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "limits: file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(alloc, &cmd, .direct));
}

test "limits: file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .{
        .file = true,
        .temporary_file = false,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
}

test "limits: temporary file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(alloc, &cmd, .{
        .file = true,
        .temporary_file = false,
        .shared_memory = true,
    }));

    // File should still exist since we blocked before reading
    try tmp_dir.dir.access("tty-graphics-protocol-image.data", .{});
}

test "limits: temporary file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd, .{
        .file = false,
        .temporary_file = true,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
}
