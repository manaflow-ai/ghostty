const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const AnimationFrame = @import("graphics_image.zig").AnimationFrame;
const AnimationState = @import("graphics_image.zig").AnimationState;
const Rect = @import("graphics_image.zig").Rect;
const Command = command.Command;

const log = std.log.scoped(.kitty_gfx);

pub const default_image_count_limit: usize = 4096;
pub const default_placement_count_limit: usize = 16384;
pub const default_image_id: u32 = 2147483647;

/// Process-global counter backing all generation stamps (see
/// ImageStorage.generation and Image.generation). This is global rather
/// than per-storage so that stamps are unique across every storage in
/// the process: two mutation events never produce the same value, even
/// across separate screens (main vs. alt), storage resets, or separate
/// terminals. This lets consumers use a generation value alone as a
/// cache key without any ambiguity.
///
/// Thread-safe because separate terminals may mutate their storages
/// from different threads. On single-threaded targets this lowers to
/// plain operations.
var generation_counter: GenerationCounter = .{};

/// Returns the next generation stamp. Stamps are unique and strictly
/// monotonically increasing process-wide, starting at 1 (0 is reserved
/// to mean "never stamped").
pub fn nextGeneration(io: std.Io) u64 {
    return generation_counter.next(io);
}

/// Backing implementation for the generation counter. We use a
/// lock-free atomic counter where we can, but not all targets support
/// 64-bit atomic operations (e.g. 32-bit ARM Android), so we fall back
/// to a mutex-protected counter on those. This is a cold path (only
/// invoked on content mutations) so the mutex cost is irrelevant.
///
/// The pointer-width check is a conservative proxy for 64-bit atomic
/// support: every 64-bit target supports 64-bit atomics, while 32-bit
/// targets may not (per the compiler's atomic operand validation).
const GenerationCounter = if (@bitSizeOf(usize) >= 64) struct {
    value: std.atomic.Value(u64) = .init(0),

    fn next(self: *@This(), io: std.Io) u64 {
        _ = io;
        return self.value.fetchAdd(1, .monotonic) + 1;
    }
} else struct {
    mutex: std.Io.Mutex = .init,
    value: u64 = 0,

    fn next(self: *@This(), io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value += 1;
        return self.value;
    }
};

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);

    /// IO implementation inherited from the owning screen. This is needed
    /// by mutations exposed through the C API, where only the storage handle
    /// is available.
    io: std.Io = std.Io.failing,

    /// Dirty is set to true if placements or images change. This is
    /// purely informational for the renderer and doesn't affect the
    /// correctness of the program. The renderer must set this to false
    /// if it cares about this value.
    ///
    /// Note that dirty is also set by scrolling and resizing (outside
    /// of this struct) because those move placement pins, even though
    /// the set of images/placements itself is unchanged. See generation
    /// for a signal that only tracks content mutations.
    ///
    /// Invariant: dirty is always set when generation changes
    /// (markMutated sets both); dirty set without a generation change
    /// means a geometry-only event.
    dirty: bool = false,

    /// Generation stamp of the last content mutation to this storage:
    /// any image transmit/replace, placement add, or delete of either.
    /// Zero means the storage has never been mutated (and is therefore
    /// empty).
    ///
    /// Unlike dirty, this is NOT updated by scrolling/resizing, so an
    /// unchanged generation means the placement set and all image data
    /// are identical; only placement geometry (pins) may have moved.
    /// Values come from a process-global monotonic counter, so a value
    /// observed from any storage never recurs for different content,
    /// even across screen switches or storage resets.
    ///
    /// This field must only be written via markMutated.
    generation: u64 = 0,

    /// This is the next automatically assigned image ID. We start mid-way
    /// through the u32 range to avoid collisions with buggy programs.
    /// TODO: This isn't good enough, it's perfectly legal for programs
    ///       to use IDs in the latter half of the range and collisions
    ///       are not gracefully handled.
    next_image_id: u32 = default_image_id,

    /// This is the next automatically assigned placement ID. This is never
    /// user-facing so we can start at 0. This is 32-bits because we use
    /// the same space for external placement IDs. We can start at zero
    /// because any number is valid.
    next_internal_placement_id: u32 = 0,

    /// The set of images that are currently known.
    images: ImageMap = .{},

    /// The set of placements for loaded images.
    placements: PlacementMap = .{},

    /// Non-null if there is an in-progress loading image.
    loading: ?*LoadingImage = null,

    /// The limits of what medium types are allowed for image loading.
    image_limits: LoadingImage.Limits = .direct,

    /// The total bytes of image data that have been loaded and the limit.
    /// If the limit is reached, the oldest images will be evicted to make
    /// space. Unused images take priority.
    total_bytes: usize = 0,
    total_limit: usize = 320 * 1000 * 1000, // 320MB

    /// Maximum number of fully stored images. Adding a new image at the
    /// limit evicts the oldest image, with unused images taking priority.
    /// Replacing an existing image ID does not consume another slot.
    image_count_limit: usize = default_image_count_limit,

    /// Maximum number of placements. A new placement at the limit is
    /// rejected, while replacing an existing external placement remains
    /// allowed.
    placement_count_limit: usize = default_placement_count_limit,

    /// Counts the image and placement entries examined while deriving used
    /// image IDs during eviction. This is test-only instrumentation.
    test_eviction_used_id_operations: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {},

    pub fn deinit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
    ) void {
        if (self.loading) |loading| loading.destroy(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);

        self.clearPlacements(s);
        self.placements.deinit(alloc);
    }

    /// Kitty image protocol is enabled if we have a non-zero limit.
    pub fn enabled(self: *const ImageStorage) bool {
        return self.total_limit != 0;
    }

    /// Returns and advances to the next unused automatic image ID.
    /// Zero is reserved by the protocol to mean that no ID was supplied.
    /// The search spans the full non-zero u32 range and returns null only
    /// when every assignable ID is occupied.
    pub fn allocateImageId(self: *ImageStorage) ?u32 {
        const candidate = self.nextImageId() orelse return null;
        self.next_image_id = candidate +% 1;
        if (self.next_image_id == 0) self.next_image_id = 1;
        return candidate;
    }

    /// Returns the ID that the next automatic allocation would receive
    /// without advancing the cursor.
    pub fn nextImageId(self: *const ImageStorage) ?u32 {
        var candidate = if (self.next_image_id == 0)
            @as(u32, 1)
        else
            self.next_image_id;
        const first = candidate;

        while (self.images.contains(candidate)) {
            candidate +%= 1;
            if (candidate == 0) candidate = 1;
            if (candidate == first) return null;
        }
        return candidate;
    }

    /// Returns the exact cursor that the next automatic allocation probes
    /// first. Unlike nextImageId, this preserves an occupied probe so a later
    /// deletion can make that ID eligible again.
    pub fn imageIdCursor(self: *const ImageStorage) u32 {
        return if (self.next_image_id == 0) 1 else self.next_image_id;
    }

    /// Cursor to install before replaying this storage's serialized state.
    /// A multipart upload reserves an automatic ID as soon as its first
    /// chunk arrives, so replay must begin from that reserved ID rather than
    /// the already-advanced steady-state cursor.
    pub fn replayNextImageId(self: *const ImageStorage) ?u32 {
        const loading = self.loading orelse return self.imageIdCursor();
        if (loading.image.number != 0 or loading.image.implicit_id) {
            return loading.image.id;
        }
        return self.imageIdCursor();
    }

    /// Record a content mutation: marks the storage dirty and assigns a
    /// fresh generation stamp. Must be called by anything that changes
    /// the set of images or placements (or image contents).
    ///
    /// Do NOT call this for geometry-only events (scrolling, resizing,
    /// screen switches); those must set only the dirty flag directly.
    /// Bumping the generation for geometry changes would break the
    /// contract that an unchanged generation means unchanged contents.
    fn markMutated(self: *ImageStorage, io: std.Io) void {
        self.dirty = true;
        self.generation = nextGeneration(io);
    }

    /// Sets the limit in bytes for the total amount of image data that
    /// can be loaded. If this limit is lower, this will do an eviction
    /// if necessary. If the value is zero, then Kitty image protocol will
    /// be disabled.
    pub fn setLimit(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        limit: usize,
    ) !void {
        // Special case disabling by quickly deleting all
        if (limit == 0) {
            const io_impl = self.io;
            const image_limits = self.image_limits;
            const image_count_limit = self.image_count_limit;
            const placement_count_limit = self.placement_count_limit;
            self.deinit(alloc, s);
            self.* = .{
                .io = io_impl,
                .image_limits = image_limits,
                .image_count_limit = image_count_limit,
                .placement_count_limit = placement_count_limit,
                .total_limit = 0,
            };
            self.markMutated(io);
            return;
        }

        // Prepare every fallible allocation before changing either the active
        // upload or stored images. A failed setter leaves the old limit and
        // all associated state intact.
        var eviction_plan: ?ImageCountLimitPlan = null;
        defer if (eviction_plan) |*plan| plan.deinit(alloc);
        if (limit < self.total_bytes) {
            const req_bytes = self.total_bytes - limit;
            log.info("evicting images to lower limit, evicting={}", .{req_bytes});
            eviction_plan = (try self.prepareImageEviction(
                alloc,
                .{ .bytes = req_bytes },
                null,
            )) orelse unreachable;
        }

        if (self.loading) |loading| {
            if (!loading.setByteLimit(limit)) {
                loading.destroy(alloc);
                self.loading = null;
            }
        }
        if (eviction_plan) |*plan| self.applyImageEviction(io, alloc, s, plan);

        self.total_limit = limit;
    }

    /// Sets the maximum number of stored images. Lowering the limit evicts
    /// images with the same deterministic unused-first policy as byte-limit
    /// eviction. Zero allows no stored images but does not disable protocol
    /// parsing.
    pub fn setImageCountLimit(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        screen: *terminal.Screen,
        limit: usize,
    ) Allocator.Error!void {
        var plan = try self.prepareImageCountLimit(alloc, limit);
        defer plan.deinit(alloc);
        self.applyImageCountLimit(io, alloc, screen, limit, &plan);
    }

    /// Prepare every allocation required to lower the stored-image count.
    /// Applying the returned plan cannot fail, so callers can prepare plans
    /// for multiple screens before mutating any of them.
    pub fn prepareImageCountLimit(
        self: *ImageStorage,
        alloc: Allocator,
        limit: usize,
    ) Allocator.Error!ImageCountLimitPlan {
        if (self.images.count() <= limit) return .{};
        const required = self.images.count() - limit;
        return (try self.prepareImageEviction(
            alloc,
            .{ .count = required },
            null,
        )) orelse unreachable;
    }

    /// Apply a previously prepared image-count plan without allocating.
    pub fn applyImageCountLimit(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        screen: *terminal.Screen,
        limit: usize,
        plan: *const ImageCountLimitPlan,
    ) void {
        self.applyImageEviction(io, alloc, screen, plan);
        self.image_count_limit = limit;
    }

    /// Sets the maximum number of placements. Reductions below the current
    /// count are rejected so visible placements are never removed
    /// nondeterministically.
    pub fn setPlacementCountLimit(self: *ImageStorage, limit: usize) bool {
        if (self.placements.count() > limit) return false;
        self.placement_count_limit = limit;
        return true;
    }

    /// Add an already-loaded image to the storage. This will automatically
    /// free any existing image with the same ID.
    pub fn addImage(self: *ImageStorage, alloc: Allocator, img: Image) Allocator.Error!void {
        const image_bytes = img.byteSize();
        // If the image itself is over the limit, then error immediately
        if (image_bytes > self.total_limit) return error.OutOfMemory;

        // If this would put us over the limit, then evict.
        const total_bytes = self.total_bytes + image_bytes;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            log.info("evicting images to make space for {} bytes", .{req_bytes});
            if (!try self.evictImage(alloc, req_bytes)) {
                log.warn("failed to evict enough images for required bytes", .{});
                return error.OutOfMemory;
            }
        }

        // Do the gop op first so if it fails we don't get a partial state
        const gop = try self.images.getOrPut(alloc, img.id);

        log.debug("addImage image={}", .{img: {
            var copy = img;
            copy.data = "";
            break :img copy;
        }});

        // Write our new image
        if (gop.found_existing) {
            self.total_bytes -= gop.value_ptr.byteSize();
            gop.value_ptr.deinit(alloc);
        }

        gop.value_ptr.* = img;
        self.total_bytes += image_bytes;

        // Stamp the stored image with a fresh generation. This gives
        // every add/replace a unique stamp even when the same image ID
        // is retransmitted with identical dimensions, so consumers
        // (e.g. renderer texture caches) can detect content changes.
        self.markMutated(io);
        gop.value_ptr.generation = self.generation;
    }

    pub const AnimationError = error{
        ImageNotFound,
        FrameNotFound,
        InvalidFrame,
        InvalidDimensions,
        OverlappingComposition,
        OutOfMemory,
    };

    /// Compose one decoded frame patch into a complete RGBA canvas before it
    /// enters terminal state. The semantic-scene encoder can therefore export
    /// immutable content-addressed frames without replaying protocol commands.
    pub fn addAnimationFrame(
        self: *ImageStorage,
        alloc: Allocator,
        image_id: u32,
        loading: command.AnimationFrameLoading,
        patch: *const Image,
    ) AnimationError!void {
        const image = self.images.getPtr(image_id) orelse return error.ImageNotFound;
        if (image.frameCount() >= 64 * 1024 and loading.edit_frame == 0)
            return error.OutOfMemory;
        if (patch.width == 0 or patch.height == 0 or
            loading.x > image.width or loading.y > image.height or
            patch.width > image.width - loading.x or
            patch.height > image.height - loading.y)
            return error.InvalidDimensions;

        const target_frame = loading.edit_frame;
        const canvas = if (target_frame > 0)
            try imageFrameRGBA(alloc, image, target_frame)
        else if (loading.create_frame > 0)
            try imageFrameRGBA(alloc, image, loading.create_frame)
        else
            try backgroundCanvas(alloc, image.width, image.height, loading.background);
        errdefer alloc.free(canvas);
        const replaced_bytes: usize = if (target_frame == 1)
            image.data.len
        else if (target_frame > 1)
            image.frames[@intCast(target_frame - 2)].data.len
        else
            0;
        if (canvas.len > self.total_limit -| (self.total_bytes -| replaced_bytes))
            return error.OutOfMemory;
        try compositePatch(
            alloc,
            canvas,
            image.width,
            image.height,
            loading.x,
            loading.y,
            patch,
            loading.composition_mode,
        );

        const new_gap: i32 = if (loading.gap_ms < 0)
            -1
        else if (loading.gap_ms == 0)
            40
        else
            loading.gap_ms;
        const disposal: @import("graphics_image.zig").AnimationDisposal =
            if (target_frame == 0 and loading.create_frame == 0)
                .clear_to_background
            else
                .retain_canvas;
        if (target_frame == 1) {
            const old_bytes = image.data.len;
            alloc.free(image.data);
            image.data = canvas;
            image.format = .rgba;
            image.compression = .none;
            if (loading.gap_ms != 0) image.root_frame_gap_ms = new_gap;
            self.total_bytes = self.total_bytes - old_bytes + canvas.len;
        } else if (target_frame > 1) {
            const index: usize = @intCast(target_frame - 2);
            if (index >= image.frames.len) return error.FrameNotFound;
            const old_bytes = image.frames[index].data.len;
            const old_gap = image.frames[index].gap_ms;
            image.frames[index].deinit(alloc);
            image.frames[index] = .{
                .data = canvas,
                .gap_ms = if (loading.gap_ms == 0)
                    old_gap
                else
                    new_gap,
                .composition = loading.composition_mode,
                .disposal = disposal,
                .source_frame = loading.create_frame,
                .background = loading.background,
            };
            self.total_bytes = self.total_bytes - old_bytes + canvas.len;
        } else {
            const replacement = try alloc.alloc(AnimationFrame, image.frames.len + 1);
            @memcpy(replacement[0..image.frames.len], image.frames);
            replacement[image.frames.len] = .{
                .data = canvas,
                .gap_ms = new_gap,
                .composition = loading.composition_mode,
                .disposal = disposal,
                .source_frame = loading.create_frame,
                .background = loading.background,
            };
            if (image.frames.len > 0) alloc.free(image.frames);
            image.frames = replacement;
            self.total_bytes += canvas.len;
        }
        self.markMutated();
        image.generation = self.generation;
        if (image.current_frame > image.frameCount()) image.current_frame = 1;
    }

    pub fn controlAnimation(
        self: *ImageStorage,
        image_id: u32,
        control: command.AnimationControl,
    ) AnimationError!void {
        const image = self.images.getPtr(image_id) orelse return error.ImageNotFound;
        if (control.frame > image.frameCount() or
            control.current_frame > image.frameCount())
            return error.FrameNotFound;
        if (control.frame > 0 and control.gap_ms != 0) {
            const gap = if (control.gap_ms < 0) -1 else control.gap_ms;
            if (control.frame == 1)
                image.root_frame_gap_ms = gap
            else
                image.frames[@intCast(control.frame - 2)].gap_ms = gap;
        }
        if (control.current_frame > 0) image.current_frame = control.current_frame;
        if (control.loops > 0) image.loop_count = control.loops;
        switch (control.action) {
            .invalid => {},
            .stop => image.animation_state = .stopped,
            .run_wait => image.animation_state = .running_wait_for_frames,
            .run => image.animation_state = .running,
        }
        self.markMutated();
        image.generation = self.generation;
    }

    pub fn composeAnimation(
        self: *ImageStorage,
        alloc: Allocator,
        image_id: u32,
        composition: command.AnimationFrameComposition,
    ) AnimationError!void {
        const image = self.images.getPtr(image_id) orelse return error.ImageNotFound;
        if (composition.frame == 0 or composition.edit_frame == 0)
            return error.InvalidFrame;
        const width = if (composition.width == 0) image.width else composition.width;
        const height = if (composition.height == 0) image.height else composition.height;
        if (composition.x > image.width or composition.y > image.height or
            composition.left_edge > image.width or composition.top_edge > image.height or
            width > image.width - composition.x or
            height > image.height - composition.y or
            width > image.width - composition.left_edge or
            height > image.height - composition.top_edge)
            return error.InvalidDimensions;
        if (composition.frame == composition.edit_frame and
            rectanglesOverlap(
                composition.left_edge,
                composition.top_edge,
                composition.x,
                composition.y,
                width,
                height,
            )) return error.OverlappingComposition;

        const source = try imageFrameRGBA(alloc, image, composition.frame);
        defer alloc.free(source);
        const destination = try imageFrameRGBA(alloc, image, composition.edit_frame);
        errdefer alloc.free(destination);
        compositeRGBARegion(
            destination,
            source,
            image.width,
            image.width,
            composition.x,
            composition.y,
            composition.left_edge,
            composition.top_edge,
            width,
            height,
            composition.composition_mode,
        );
        const old_bytes = if (composition.edit_frame == 1)
            image.data.len
        else
            image.frames[@intCast(composition.edit_frame - 2)].data.len;
        if (destination.len > self.total_limit -| (self.total_bytes -| old_bytes))
            return error.OutOfMemory;
        if (composition.edit_frame == 1) {
            alloc.free(image.data);
            image.data = destination;
            image.format = .rgba;
            image.compression = .none;
        } else {
            const frame = &image.frames[@intCast(composition.edit_frame - 2)];
            alloc.free(frame.data);
            frame.data = destination;
            frame.composition = composition.composition_mode;
            frame.source_frame = composition.frame;
        }
        self.total_bytes = self.total_bytes - old_bytes + destination.len;
        self.markMutated();
        image.generation = self.generation;
    }

    /// Add a placement for a given image. The caller must verify in advance
    /// the image exists to prevent memory corruption.
    pub fn addPlacement(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        screen: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        errdefer p.deinit(screen);
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });

        const external_key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = .{ .tag = .external, .id = placement_id },
        };
        const replaces_external = placement_id != 0 and
            self.placements.contains(external_key);
        if (!replaces_external and
            self.placements.count() >= self.placement_count_limit)
        {
            return error.OutOfMemory;
        }

        // The important piece here is that the placement ID needs to
        // be marked internal if it is zero. This allows multiple placements
        // to be added for the same image. If it is non-zero, then it is
        // an external placement ID and we can only have one placement
        // per (image id, placement id) pair.
        const key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = if (placement_id == 0) .{
                .tag = .internal,
                .id = id: {
                    defer self.next_internal_placement_id +%= 1;
                    break :id self.next_internal_placement_id;
                },
            } else external_key.placement_id,
        };

        const gop = try self.placements.getOrPut(alloc, key);
        if (gop.found_existing) gop.value_ptr.deinit(screen);
        gop.value_ptr.* = p;

        self.markMutated(io);
    }

    fn clearPlacements(self: *ImageStorage, s: *terminal.Screen) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(s);
        self.placements.clearRetainingCapacity();
    }

    /// Get an image by its ID. If the image doesn't exist, null is returned.
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }

    /// Get a pointer to the newest image with the given number.
    pub fn imagePtrByNumber(self: *const ImageStorage, image_number: u32) ?*const Image {
        var newest: ?*const Image = null;

        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) {
                if (newest == null or
                    kv.value_ptr.generation > newest.?.generation)
                {
                    newest = kv.value_ptr;
                }
            }
        }

        return newest;
    }

    /// Get an image by its number. If the image doesn't exist, return null.
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        const image = self.imagePtrByNumber(image_number) orelse return null;
        return image.*;
    }

    /// Assign an image number to an existing image ID.
    ///
    /// This is used by state-restoring embedders after replaying an image by
    /// its stable ID. Bumping both generations preserves the protocol rule
    /// that number lookup resolves to the most recently assigned image.
    pub fn setImageNumber(self: *ImageStorage, image_id: u32, image_number: u32) bool {
        const image = self.images.getPtr(image_id) orelse return false;
        image.number = image_number;
        self.markMutated(self.io);
        image.generation = self.generation;
        return true;
    }

    /// Delete placements, images.
    pub fn delete(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        t: *terminal.Terminal,
        cmd: command.Delete,
    ) void {
        // Deletes only ever remove placements/images, so comparing counts
        // before and after tells us whether anything actually changed.
        // Only then do we mark a mutation. This matters because a
        // delete-all runs on every screen clear (e.g. `ESC [ 2 J`), and
        // we don't want empty clears to dirty the image state or bump
        // the generation.
        const placements_before = self.placements.count();
        const images_before = self.images.count();
        defer if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated(io);

        switch (cmd) {
            .all => |delete_images| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    // Skip virtual placements
                    switch (entry.value_ptr.location) {
                        .pin => {},
                        .virtual => continue,
                    }

                    // Deinit the placement and remove it
                    const image_id = entry.key_ptr.image_id;
                    entry.value_ptr.deinit(t.screens.active);
                    self.placements.removeByPtr(entry.key_ptr);
                    if (delete_images) self.deleteIfUnused(alloc, image_id);
                }

                if (delete_images) {
                    var image_it = self.images.iterator();
                    while (image_it.next()) |kv| self.deleteIfUnused(alloc, kv.key_ptr.*);
                }
            },

            .id => |v| self.deleteById(
                alloc,
                t.screens.active,
                v.image_id,
                v.placement_id,
                v.delete,
            ),

            .newest => |v| newest: {
                const img = self.imageByNumber(v.image_number) orelse break :newest;
                self.deleteById(
                    alloc,
                    t.screens.active,
                    img.id,
                    v.placement_id,
                    v.delete,
                );
            },

            .intersect_cursor => |delete_images| {
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = t.screens.active.cursor.x,
                        .y = t.screens.active.cursor.y,
                    } },
                    delete_images,
                    {},
                    null,
                );
            },

            .intersect_cell => |v| intersect_cell: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell,
                    } },
                    v.delete,
                    {},
                    null,
                );
            },

            .intersect_cell_z => |v| intersect_cell_z: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell_z;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell_z,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell_z,
                    } },
                    v.delete,
                    v.z,
                    struct {
                        fn filter(ctx: i32, p: Placement) bool {
                            return p.z == ctx;
                        }
                    }.filter,
                );
            },

            .column => |v| column: {
                if (v.x <= 0) {
                    log.warn("delete column must be greater than zero", .{});
                    break :column;
                }

                const x = v.x - 1;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;
                    if (rect.top_left.x <= x and rect.bottom_right.x >= x) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .row => |v| row: {
                if (v.y <= 0) {
                    log.warn("delete row must be greater than zero", .{});
                    break :row;
                }

                // v.y is in active coords so we want to convert it to a pin
                // so we can compare by page offsets.
                const target_pin = t.screens.active.pages.pin(.{ .active = .{
                    .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :row,
                } }) orelse break :row;

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;

                    // We need to copy our pin to ensure we are at least at
                    // the top-left x.
                    var target_pin_copy = target_pin;
                    target_pin_copy.x = rect.top_left.x;
                    if (target_pin_copy.isBetween(rect.top_left, rect.bottom_right)) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .z => |v| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.location) {
                        .pin => {},

                        // Virtual placeholders cannot delete by z according
                        // to the spec.
                        .virtual => continue,
                    }

                    if (entry.value_ptr.z == v.z) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            .range => |v| range: {
                if (v.first <= 0 or v.last <= 0) {
                    log.warn("delete range values must be greater than zero", .{});
                    break :range;
                }
                if (v.first > v.last) {
                    log.warn("delete range 'x' ({}) must be less than or equal to 'y' ({})", .{ v.first, v.last });
                    break :range;
                }

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.image_id >= v.first and entry.key_ptr.image_id <= v.last) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            .animation_frames => {
                var changed = false;
                var image_it = self.images.iterator();
                while (image_it.next()) |entry| {
                    const image = entry.value_ptr;
                    if (image.frames.len == 0) continue;
                    for (image.frames) |*frame| {
                        self.total_bytes -= frame.data.len;
                        frame.deinit(alloc);
                    }
                    alloc.free(image.frames);
                    image.frames = &.{};
                    image.current_frame = 1;
                    image.animation_state = .stopped;
                    image.loop_count = 1;
                    changed = true;
                }
                if (changed) self.markMutated();
            },
        }
    }

    fn deleteById(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        delete_unused: bool,
    ) void {
        // If no placement, we delete all placements with the ID
        if (placement_id == 0) {
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.image_id == image_id) {
                    entry.value_ptr.deinit(s);
                    self.placements.removeByPtr(entry.key_ptr);
                }
            }
        } else {
            if (self.placements.getEntry(.{
                .image_id = image_id,
                .placement_id = .{ .tag = .external, .id = placement_id },
            })) |entry| {
                entry.value_ptr.deinit(s);
                self.placements.removeByPtr(entry.key_ptr);
            }
        }

        // If this is specified, then we also delete the image
        // if it is no longer in use.
        if (delete_unused) self.deleteIfUnused(alloc, image_id);
    }

    /// Delete an image if it is unused.
    fn deleteIfUnused(self: *ImageStorage, alloc: Allocator, image_id: u32) void {
        var it = self.placements.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.image_id == image_id) {
                return;
            }
        }

        // If we get here, we can delete the image.
        if (self.images.getEntry(image_id)) |entry| {
            self.total_bytes -= entry.value_ptr.byteSize();
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
        }
    }

    /// Deletes all placements intersecting a screen point.
    fn deleteIntersecting(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        p: point.Point,
        delete_unused: bool,
        filter_ctx: anytype,
        comptime filter: ?fn (@TypeOf(filter_ctx), Placement) bool,
    ) void {
        // Convert our target point to a pin for comparison.
        const target_pin = t.screens.active.pages.pin(p) orelse return;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const img = self.imageById(entry.key_ptr.image_id) orelse continue;
            const rect = entry.value_ptr.rect(img, t) orelse continue;
            if (target_pin.isBetween(rect.top_left, rect.bottom_right)) {
                if (filter) |f| if (!f(filter_ctx, entry.value_ptr.*)) continue;
                entry.value_ptr.deinit(t.screens.active);
                self.placements.removeByPtr(entry.key_ptr);
                if (delete_unused) self.deleteIfUnused(alloc, img.id);
            }
        }
    }

    const EvictionRequest = struct {
        bytes: usize = 0,
        count: usize = 0,
    };

    pub const ImageCountLimitPlan = struct {
        image_ids: std.AutoHashMapUnmanaged(u32, void) = .{},

        pub fn deinit(self: *ImageCountLimitPlan, alloc: Allocator) void {
            self.image_ids.deinit(alloc);
            self.* = .{};
        }
    };

    /// Evict images to satisfy byte and object-count capacity. The oldest
    /// images are removed first, prioritizing unused images as recommended
    /// by the Kitty specification.
    fn evictImages(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        screen: *terminal.Screen,
        request: EvictionRequest,
        excluded_id: ?u32,
    ) !bool {
        var plan = (try self.prepareImageEviction(
            alloc,
            request,
            excluded_id,
        )) orelse return false;
        defer plan.deinit(alloc);
        self.applyImageEviction(io, alloc, screen, &plan);
        return true;
    }

    /// Build a complete eviction plan before changing storage. A null plan
    /// means the request cannot be satisfied with the eligible images.
    fn prepareImageEviction(
        self: *ImageStorage,
        alloc: Allocator,
        request: EvictionRequest,
        excluded_id: ?u32,
    ) Allocator.Error!?ImageCountLimitPlan {
        const Candidate = struct {
            id: u32,
            generation: u64,
            // Map images into four distinct blocks:
            // 0: transient, unused
            // 1: not transient, unused
            // 2: transient, used
            // 3: not transient, used
            block: u2,
            bytes: usize,
        };

        // Derive the used-image set in one placement pass. Reuse this map
        // below for the selected eviction IDs after candidates are sorted.
        var image_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer image_ids.deinit(alloc);
        try image_ids.ensureTotalCapacity(alloc, @intCast(self.placements.count()));
        var placement_it = self.placements.iterator();
        while (placement_it.next()) |entry| {
            if (comptime builtin.is_test) self.test_eviction_used_id_operations += 1;
            try image_ids.put(alloc, entry.key_ptr.image_id, {});
        }

        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(alloc);
        try candidates.ensureTotalCapacity(alloc, self.images.count());
        var it = self.images.iterator();
        while (it.next()) |kv| {
            const img = kv.value_ptr;
            if (img.id == excluded_id) continue;
            if (comptime builtin.is_test) self.test_eviction_used_id_operations += 1;
            const used = image_ids.contains(img.id);
            const transient = img.usage.transient;
            candidates.appendAssumeCapacity(.{
                .id = img.id,
                .generation = img.generation,
                // Map images into four distinct blocks:
                // 0: transient, unused
                // 1: not transient, unused
                // 2: transient, used
                // 3: not transient, used
                .block = (if (transient) @as(u2, 0) else @as(u2, 1)) +
                    (if (used) @as(u2, 2) else @as(u2, 0)),
                .bytes = img.byteSize(),
            });
        }

        // Sort
        std.mem.sortUnstable(
            Candidate,
            candidates.items,
            {},
            struct {
                fn lessThan(
                    ctx: void,
                    lhs: Candidate,
                    rhs: Candidate,
                ) bool {
                    _ = ctx;

                    // If images mapped into different blocks, prioritize lower
                    // numbered blocks.
                    if (lhs.block < rhs.block) return true;
                    if (lhs.block > rhs.block) return false;

                    // If images mapped to the same block, compare generations.
                    return if (lhs.generation == rhs.generation)
                        // If the generation is the same, use the ID to
                        // prioritize evicting "earlier" images.
                        lhs.id < rhs.id
                    else
                        // If the generation is different, prioritize evicting
                        // images from earlied generations.
                        lhs.generation < rhs.generation;
                }
            }.lessThan,
        );

        // Select the shortest sorted prefix satisfying both requirements.
        var selected: usize = 0;
        var selected_bytes: usize = 0;
        while (selected < candidates.items.len and
            (selected_bytes < request.bytes or selected < request.count))
        {
            selected_bytes += candidates.items[selected].bytes;
            selected += 1;
        }
        if (selected_bytes < request.bytes or selected < request.count) return null;
        if (selected == 0) return .{};

        // Build the selected-ID set before mutating anything, so allocation
        // failure leaves the storage unchanged.
        image_ids.clearRetainingCapacity();
        try image_ids.ensureTotalCapacity(alloc, @intCast(selected));
        for (candidates.items[0..selected]) |candidate| {
            try image_ids.put(alloc, candidate.id, {});
        }

        const result: ImageCountLimitPlan = .{ .image_ids = image_ids };
        image_ids = .{};
        return result;
    }

    /// Apply a fully allocated eviction plan. This function cannot fail.
    fn applyImageEviction(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        screen: *terminal.Screen,
        plan: *const ImageCountLimitPlan,
    ) void {
        if (plan.image_ids.count() == 0) return;

        // Remove every selected placement in one pass and release tracked pins.
        var selected_placements = self.placements.iterator();
        while (selected_placements.next()) |entry| {
            if (plan.image_ids.contains(entry.key_ptr.image_id)) {
                entry.value_ptr.deinit(screen);
                self.placements.removeByPtr(entry.key_ptr);
            }
        }

        var selected_images = plan.image_ids.iterator();
        while (selected_images.next()) |selected| {
            if (self.images.getEntry(selected.key_ptr.*)) |entry| {
                const image_bytes = entry.value_ptr.byteSize();
                log.info("evicting image id={} bytes={}", .{
                    entry.key_ptr.*,
                    image_bytes,
                });
                self.total_bytes -= image_bytes;
                entry.value_ptr.deinit(alloc);
                self.images.removeByPtr(entry.key_ptr);
            }
        }

        self.markMutated(io);
    }

    /// Every placement is uniquely identified by the image ID and the
    /// placement ID. If an image ID isn't specified it is assumed to be 0.
    /// Likewise, if a placement ID isn't specified it is assumed to be 0.
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: packed struct {
            tag: enum(u1) { internal, external },
            id: u32,
        },
    };

    pub const Placement = struct {
        /// The location where this placement should be drawn.
        location: Location,

        /// Offset of the x/y from the top-left of the cell.
        x_offset: u32 = 0,
        y_offset: u32 = 0,

        /// Source rectangle for the image to pull from
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,

        /// The columns/rows this image occupies.
        columns: u32 = 0,
        rows: u32 = 0,

        /// The z-index for this placement.
        z: i32 = 0,

        pub const Location = union(enum) {
            /// Exactly placed on a screen pin.
            pin: *PageList.Pin,

            /// Virtual placement (U=1) for unicode placeholders.
            virtual: void,
        };

        pub fn deinit(
            self: *const Placement,
            s: *terminal.Screen,
        ) void {
            switch (self.location) {
                .pin => |p| s.pages.untrackPin(p),
                .virtual => {},
            }
        }

        /// Returns the size of this placement's image in pixels,
        /// taking into account the source rectangle, specified
        /// rows/columns, and aspect ratio.
        pub fn pixelSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            width: u32,
            height: u32,
        } {
            // Height / width of the image in px.
            const width = if (self.source_width > 0) self.source_width else image.width;
            const height = if (self.source_height > 0) self.source_height else image.height;

            // If we don't have any specified cols or rows then the placement
            // should be the native size of the image, and doesn't need to be
            // re-scaled.
            if (self.columns == 0 and self.rows == 0) return .{
                .width = width,
                .height = height,
            };

            // We calculate the size of a cell so that we can multiply
            // it by the specified cols/rows to get the correct px size.
            //
            // We assume that the width is divided evenly by the column
            // count and the height by the row count, because it should be.
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;

            const width_f64: f64 = @floatFromInt(width);
            const height_f64: f64 = @floatFromInt(height);

            // If we have a specified cols AND rows then we calculate
            // the width and height from them directly, we don't need
            // to adjust for aspect ratio.
            if (self.columns > 0 and self.rows > 0) {
                const calc_width = cell_width * self.columns;
                const calc_height = cell_height * self.rows;

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Either the columns or the rows were specified, but not both,
            // so we need to calculate the other one based on the aspect ratio.

            // If only the columns were specified, we determine
            // the height of the image based on the aspect ratio.
            if (self.columns > 0) {
                const aspect = height_f64 / width_f64;
                const calc_width: u32 = cell_width * self.columns;
                const calc_height: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(calc_width)) * aspect,
                ));

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Otherwise, only the rows were specified, so we
            // determine the width based on the aspect ratio.
            {
                const aspect = width_f64 / height_f64;
                const calc_height: u32 = cell_height * self.rows;
                const calc_width: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(calc_height)) * aspect,
                ));

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
        }

        /// Returns the size in grid cells that this placement takes up.
        pub fn gridSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            cols: u32,
            rows: u32,
        } {
            // If we have a specified columns and rows then this is trivial.
            if (self.columns > 0 and self.rows > 0) return .{
                .cols = self.columns,
                .rows = self.rows,
            };

            // Otherwise we calculate the pixel size, divide by
            // cell size, and round up to the nearest integer.
            const calc_size = self.pixelSize(image, t);
            return .{
                .cols = std.math.divCeil(
                    u32,
                    calc_size.width + self.x_offset,
                    t.width_px / t.cols,
                ) catch 0,
                .rows = std.math.divCeil(
                    u32,
                    calc_size.height + self.y_offset,
                    t.height_px / t.rows,
                ) catch 0,
            };
            // NOTE: Above `divCeil`s can only fail if the cell size is 0,
            //       in such a case it seems safe to return 0 for this.
        }

        /// Returns a selection of the entire rectangle this placement
        /// occupies within the screen. This can return null if the placement
        /// doesn't have an associated rect (i.e. a virtual placement).
        pub fn rect(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) ?Rect {
            const grid_size = self.gridSize(image, t);
            const pin = switch (self.location) {
                .pin => |p| p,
                .virtual => return null,
            };

            var br = switch (pin.downOverflow(grid_size.rows - 1)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            br.x = @min(
                // We need to sub one here because the x value is
                // one width already. So if the image is width "1"
                // then we add zero to X because X itself is width 1.
                pin.x + (grid_size.cols - 1),
                t.cols - 1,
            );

            return .{
                .top_left = pin.*,
                .bottom_right = br,
            };
        }
    };
};

fn imageFrameRGBA(
    alloc: Allocator,
    image: *const Image,
    frame_number: u32,
) ImageStorage.AnimationError![]u8 {
    if (frame_number == 0 or frame_number > image.frameCount())
        return error.FrameNotFound;
    if (frame_number > 1) {
        const frame = image.frames[@intCast(frame_number - 2)];
        return alloc.dupe(u8, frame.data) catch error.OutOfMemory;
    }
    return pixelsToRGBA(
        alloc,
        image.data,
        image.width,
        image.height,
        image.format,
    );
}

fn pixelsToRGBA(
    alloc: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    format: command.Transmission.Format,
) ImageStorage.AnimationError![]u8 {
    const pixel_count = std.math.mul(usize, width, height) catch
        return error.InvalidDimensions;
    const expected = std.math.mul(
        usize,
        pixel_count,
        command.Transmission.formatBpp(format),
    ) catch return error.InvalidDimensions;
    if (pixels.len != expected) return error.InvalidDimensions;
    const result = alloc.alloc(u8, pixel_count * 4) catch return error.OutOfMemory;
    switch (format) {
        .rgba => @memcpy(result, pixels),
        .rgb => for (0..pixel_count) |index| {
            result[index * 4 + 0] = pixels[index * 3 + 0];
            result[index * 4 + 1] = pixels[index * 3 + 1];
            result[index * 4 + 2] = pixels[index * 3 + 2];
            result[index * 4 + 3] = 255;
        },
        .gray_alpha => for (0..pixel_count) |index| {
            const gray = pixels[index * 2];
            result[index * 4 + 0] = gray;
            result[index * 4 + 1] = gray;
            result[index * 4 + 2] = gray;
            result[index * 4 + 3] = pixels[index * 2 + 1];
        },
        .gray => for (0..pixel_count) |index| {
            const gray = pixels[index];
            result[index * 4 + 0] = gray;
            result[index * 4 + 1] = gray;
            result[index * 4 + 2] = gray;
            result[index * 4 + 3] = 255;
        },
        .png => unreachable,
    }
    return result;
}

fn backgroundCanvas(
    alloc: Allocator,
    width: u32,
    height: u32,
    background: command.AnimationFrameLoading.Background,
) ImageStorage.AnimationError![]u8 {
    const pixel_count = std.math.mul(usize, width, height) catch
        return error.InvalidDimensions;
    const result = alloc.alloc(u8, pixel_count * 4) catch return error.OutOfMemory;
    for (0..pixel_count) |index| {
        result[index * 4 + 0] = background.r;
        result[index * 4 + 1] = background.g;
        result[index * 4 + 2] = background.b;
        result[index * 4 + 3] = background.a;
    }
    return result;
}

fn compositePatch(
    alloc: Allocator,
    canvas: []u8,
    canvas_width: u32,
    canvas_height: u32,
    x: u32,
    y: u32,
    patch: *const Image,
    mode: command.CompositionMode,
) ImageStorage.AnimationError!void {
    _ = canvas_height;
    const rgba = try pixelsToRGBA(
        alloc,
        patch.data,
        patch.width,
        patch.height,
        patch.format,
    );
    defer alloc.free(rgba);
    compositeRGBARegion(
        canvas,
        rgba,
        canvas_width,
        patch.width,
        x,
        y,
        0,
        0,
        patch.width,
        patch.height,
        mode,
    );
}

fn compositeRGBARegion(
    destination: []u8,
    source: []const u8,
    canvas_width: u32,
    source_canvas_width: u32,
    destination_x: u32,
    destination_y: u32,
    source_x: u32,
    source_y: u32,
    width: u32,
    height: u32,
    mode: command.CompositionMode,
) void {
    for (0..height) |row_usize| for (0..width) |column_usize| {
        const row: u32 = @intCast(row_usize);
        const column: u32 = @intCast(column_usize);
        const destination_index: usize = @intCast(((destination_y + row) * canvas_width +
            destination_x + column) * 4);
        const source_index: usize = @intCast(((source_y + row) * source_canvas_width +
            source_x + column) * 4);
        const dst = destination[destination_index..][0..4];
        const src = source[source_index..][0..4];
        switch (mode) {
            .overwrite => @memcpy(dst, src),
            .alpha_blend => alphaBlend(dst, src),
        }
    };
}

fn alphaBlend(destination: []u8, source: []const u8) void {
    const source_alpha: u32 = source[3];
    const destination_alpha: u32 = destination[3];
    const inverse: u32 = 255 - source_alpha;
    const alpha_numerator = source_alpha * 255 + destination_alpha * inverse;
    if (alpha_numerator == 0) {
        @memset(destination[0..4], 0);
        return;
    }
    for (0..3) |channel| {
        const numerator: u32 = @as(u32, source[channel]) * source_alpha * 255 +
            @as(u32, destination[channel]) * destination_alpha * inverse;
        destination[channel] = @intCast((numerator + alpha_numerator / 2) /
            alpha_numerator);
    }
    destination[3] = @intCast((alpha_numerator + 127) / 255);
}

fn rectanglesOverlap(
    source_x: u32,
    source_y: u32,
    destination_x: u32,
    destination_y: u32,
    width: u32,
    height: u32,
) bool {
    return source_x < destination_x + width and
        destination_x < source_x + width and
        source_y < destination_y + height and
        destination_y < source_y + height;
}

// Our pin for the placement
fn trackPin(
    t: *terminal.Terminal,
    pt: point.Coordinate,
) !*PageList.Pin {
    return try t.screens.active.pages.trackPin(t.screens.active.pages.pin(.{
        .active = pt,
    }).?);
}

test "storage: add placement with zero placement id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }) != null);
}

test "storage: replacing external placement releases old pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 7, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 7, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements and images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements and images preserves limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 5000;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 5000), s.total_limit);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id and unused images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete placement by specific id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 2,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor plus unused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor hits multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(26, 26);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete by column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by column 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 0 }) } });

    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete by row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by row 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 2 }) } });

    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete images by range 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 1 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 1 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.imageById(1) == null);
    try testing.expect(s.imageById(2) != null);
    try testing.expect(s.imageById(3) != null);
    try testing.expect(s.placements.contains(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: range deletion preserves placements outside both bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    for (1..4) |image_id| {
        try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = @intCast(image_id) });
        try s.addPlacement(
            std.testing.io,
            alloc,
            t.screens.active,
            @intCast(image_id),
            1,
            .{ .location = .{
                .pin = try trackPin(&t, .{ .x = 1, .y = 1 }),
            } },
        );
    }

    s.delete(std.testing.io, alloc, &t, .{
        .range = .{ .delete = false, .first = 2, .last = 2 },
    });

    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.contains(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expect(s.placements.contains(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: aspect ratio calculation when only columns or rows specified" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000; // 10 px per col
    t.height_px = 2000; // 20 px per row

    // Case 1: Only columns specified
    {
        const image = Image{ .id = 1, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 10,
            .rows = 0,
        };

        // Image is 16x9, set to a width of 10 columns, at 10px per column
        // that's 100px width. 100px * (9 / 16) = 56.25, which should round
        // to a height of 56px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 100), calc_size.width);
        try testing.expectEqual(@as(u32, 56), calc_size.height);
    }

    // Case 2: Only rows specified
    {
        const image = Image{ .id = 2, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 0,
            .rows = 5,
        };

        // Image is 16x9, set to a height of 5 rows, at 20px per row that's
        // 100px height. 100px * (16 / 9) = 177.77..., which should round to
        // a width of 178px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 178), calc_size.width);
        try testing.expectEqual(@as(u32, 100), calc_size.height);
    }
}

test "storage: generation stamps on image add and replace" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Fresh storage has generation zero (never mutated).
    try testing.expectEqual(@as(u64, 0), s.generation);

    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen1 = s.generation;
    try testing.expect(gen1 > 0);

    const img1 = s.imageById(1).?;
    try testing.expectEqual(gen1, img1.generation);

    // A second image gets a strictly greater stamp.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
    const gen2 = s.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, s.imageById(2).?.generation);

    // Retransmitting the same image ID (identical dimensions) gets a
    // fresh stamp: this is what makes same-sized retransmissions
    // detectable by renderers.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen3 = s.generation;
    try testing.expect(gen3 > gen2);
    try testing.expectEqual(gen3, s.imageById(1).?.generation);

    // Image 2 kept its stamp.
    try testing.expectEqual(gen2, s.imageById(2).?.generation);
}

test "storage: generation bumps on placement and delete" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    const gen_add = s.generation;

    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen_place = s.generation;
    try testing.expect(gen_place > gen_add);

    // Reads don't change the generation.
    _ = s.imageById(1);
    _ = s.imageByNumber(1);
    try testing.expectEqual(gen_place, s.generation);

    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.generation > gen_place);
}

test "storage: generation bumps when setLimit evicts or disables" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    const data = try alloc.dupe(u8, "1234");
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1, .data = data });
    const gen_add = s.generation;

    // Lowering the limit evicts the image and must mark a mutation.
    s.dirty = false;
    try s.setLimit(io, alloc, t.screens.active, 1);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_add);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    const gen_evict = s.generation;

    // Disabling (limit=0) resets the storage and must mark a mutation.
    s.dirty = false;
    try s.setLimit(io, alloc, t.screens.active, 0);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_evict);
}

test "storage: failed limit eviction preserves active upload and old limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 8 };
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(std.testing.io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 2,
        .data = try alloc.dupe(u8, "12345678"),
    });

    const loading = try alloc.create(LoadingImage);
    loading.* = .{
        .image = .{ .id = 2 },
        .quiet = .no,
        .temporary_directory = null,
        .byte_limit = 8,
    };
    try loading.addData(alloc, "1234");
    s.loading = loading;

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        s.setLimit(std.testing.io, failing.allocator(), t.screens.active, 2),
    );

    try testing.expectEqual(@as(usize, 8), s.total_limit);
    try testing.expectEqual(@as(usize, 8), s.total_bytes);
    try testing.expect(s.imageById(1) != null);
    try testing.expectEqual(loading, s.loading.?);
    try testing.expectEqual(@as(usize, 8), s.loading.?.byte_limit);
    try testing.expectEqualStrings("1234", s.loading.?.data.items);
}

test "storage: forced image eviction releases placement pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    const data = try alloc.dupe(u8, "1234");
    try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1, .data = data });
    try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    try s.setLimit(std.testing.io, alloc, t.screens.active, 1);

    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: replacement capacity never evicts the image being replaced" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{ .total_limit = 10 };
    defer s.deinit(alloc, t.screens.active);

    try s.addImage(std.testing.io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .data = try alloc.dupe(u8, "12345678"),
    });
    try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addImage(std.testing.io, alloc, t.screens.active, .{
        .id = 2,
        .width = 1,
        .height = 1,
        .data = try alloc.dupe(u8, "12"),
    });
    try s.addPlacement(std.testing.io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .virtual = {} },
    });

    try s.addImage(std.testing.io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .data = try alloc.dupe(u8, "123456789"),
    });

    try testing.expectEqual(@as(usize, 9), s.total_bytes);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 9), s.imageById(1).?.data.len);
    try testing.expect(s.imageById(2) == null);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: image and placement count limits own rejected objects" {
    if (comptime @hasField(ImageStorage, "image_count_limit") and
        @hasField(ImageStorage, "placement_count_limit"))
    {
        const testing = std.testing;
        const alloc = testing.allocator;
        var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
        defer t.deinit(alloc);
        const tracked = t.screens.active.pages.countTrackedPins();

        var s: ImageStorage = .{
            .image_count_limit = 0,
            .placement_count_limit = 1,
        };
        defer s.deinit(alloc, t.screens.active);

        const rejected_data = try alloc.dupe(u8, "rejected");
        try testing.expectError(
            error.OutOfMemory,
            s.addImage(std.testing.io, alloc, t.screens.active, .{
                .id = 99,
                .width = 1,
                .height = 1,
                .data = rejected_data,
            }),
        );
        try testing.expectEqual(@as(usize, 0), s.images.count());

        s.image_count_limit = 2;
        try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = 1 });
        const evicted_data = try alloc.dupe(u8, "evicted");
        try s.addImage(std.testing.io, alloc, t.screens.active, .{
            .id = 2,
            .width = 1,
            .height = 1,
            .data = evicted_data,
        });

        try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 7, .{
            .location = .{ .virtual = {} },
        });
        try s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 7, .{
            .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
        });
        try testing.expectEqual(@as(usize, 1), s.placements.count());
        try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

        try testing.expectError(
            error.OutOfMemory,
            s.addPlacement(std.testing.io, alloc, t.screens.active, 1, 8, .{
                .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
            }),
        );
        try testing.expectEqual(@as(usize, 1), s.placements.count());
        try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
        try testing.expect(!s.setPlacementCountLimit(0));
        try testing.expectEqual(@as(usize, 1), s.placement_count_limit);

        try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = 3 });
        try testing.expectEqual(@as(usize, 2), s.images.count());
        try testing.expect(s.imageById(1) != null);
        try testing.expect(s.imageById(2) == null);
        try testing.expect(s.imageById(3) != null);
    } else return error.TestExpectedEqual;
}

test "storage: eviction used-id derivation has linear operation bound" {
    if (comptime @hasField(ImageStorage, "image_count_limit") and
        @hasField(ImageStorage, "placement_count_limit") and
        @hasField(ImageStorage, "test_eviction_used_id_operations") and
        @hasDecl(ImageStorage, "setImageCountLimit"))
    {
        const testing = std.testing;
        const alloc = testing.allocator;
        var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .rows = 3, .cols = 3 });
        defer t.deinit(alloc);

        const object_count = 128;
        var s: ImageStorage = .{
            .image_count_limit = object_count,
            .placement_count_limit = object_count,
        };
        defer s.deinit(alloc, t.screens.active);

        for (1..object_count + 1) |id| {
            try s.addImage(std.testing.io, alloc, t.screens.active, .{ .id = @intCast(id) });
            try s.addPlacement(
                std.testing.io,
                alloc,
                t.screens.active,
                @intCast(id),
                1,
                .{ .location = .{ .virtual = {} } },
            );
        }

        s.test_eviction_used_id_operations = 0;
        try s.setImageCountLimit(std.testing.io, alloc, t.screens.active, object_count - 1);

        try testing.expectEqual(object_count - 1, s.images.count());
        try testing.expect(
            s.test_eviction_used_id_operations <= object_count * 2,
        );
    } else return error.TestExpectedEqual;
}

test "storage: imageByNumber returns most recently transmitted" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Two images sharing a number: the newest transmission wins,
    // regardless of insertion order or clock resolution.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .number = 7 });
    try testing.expectEqual(@as(u32, 2), s.imageByNumber(7).?.id);

    // Retransmit the first: it becomes the newest.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);

    // Reassigning the same number is still the newest assignment.
    try testing.expect(s.setImageNumber(2, 7));
    try testing.expectEqual(@as(u32, 2), s.imageByNumber(7).?.id);
}

test "storage: nextGeneration is unique and monotonic" {
    const testing = std.testing;
    const a = nextGeneration(testing.io);
    const b = nextGeneration(testing.io);
    try testing.expect(b > a);
    try testing.expect(a > 0);
}

test "storage: no-op delete does not mark a mutation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A delete-all on an empty storage (this runs on every screen
    // clear) must not dirty the state or bump the generation.
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(!s.dirty);
    try testing.expectEqual(@as(u64, 0), s.generation);

    // Same for a delete that matches nothing.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen = s.generation;
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 42 } });
    try testing.expect(!s.dirty);
    try testing.expectEqual(gen, s.generation);

    // But a delete that removes something does mark a mutation.
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 1 } });
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
}

test "storage: evict unused transient image" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);

    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = false },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = true },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = true },
    });
    try s.addPlacement(
        io,
        alloc,
        t.screens.active,
        2,
        1,
        .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } },
    );

    const gen = s.generation;
    const result = try s.evictImages(
        io,
        alloc,
        t.screens.active,
        .{ .bytes = 32 },
        null,
    );
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
    try testing.expectEqual(true, result);
    try testing.expectEqual(2, s.images.count());
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}
