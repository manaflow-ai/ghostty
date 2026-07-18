//! Bounded capture of Ghostty's existing static Kitty renderer inputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");
const terminal = @import("../../terminal/main.zig");

pub fn Capture(comptime Scene: type) type {
    return struct {
        resources: []Scene.KittyResource = &.{},
        images: []Scene.KittyImage = &.{},
        placements: []Scene.KittyPlacement = &.{},
        generation: u64 = 0,

        const Self = @This();

        const BorrowedResource = struct {
            digest: Scene.KittyResourceDigest,
            width: u32,
            height: u32,
            format: Scene.KittyPixelFormat,
            pixels: []const u8,
        };

        pub fn capture(
            alloc: Allocator,
            term: *terminal.Terminal,
            limits: Scene.Limits,
            include_canonical: bool,
        ) !Self {
            if (comptime !build_options.kitty_graphics) return .{};
            const storage = &term.screens.active.kitty_images;
            const image_count = storage.images.count();
            if (image_count == 0) return .{ .generation = storage.generation };
            if (image_count > limits.max_kitty_resources)
                return error.LimitExceeded;
            if (storage.placements.count() > limits.max_kitty_placements)
                return error.LimitExceeded;
            if (term.cols == 0 or term.rows == 0 or
                term.width_px < term.cols or term.height_px < term.rows)
                return error.InvalidDimensions;

            var images: []Scene.KittyImage = &.{};
            var resources: []Scene.KittyResource = &.{};
            if (include_canonical) {
                images = try alloc.alloc(Scene.KittyImage, image_count);
                const borrowed = try alloc.alloc(BorrowedResource, image_count);
                var image_it = storage.images.iterator();
                var image_index: usize = 0;
                var scanned_resource_bytes: usize = 0;
                while (image_it.next()) |entry| : (image_index += 1) {
                    const image = entry.value_ptr;
                    const format: Scene.KittyPixelFormat = switch (image.format) {
                        .gray => .gray,
                        .gray_alpha => .gray_alpha,
                        .rgb => .rgb,
                        .rgba => .rgba,
                        .png => return error.UnsupportedCapability,
                    };
                    if (image.width == 0 or image.height == 0 or
                        image.width > 10_000 or image.height > 10_000 or
                        image.compression != .none)
                        return error.InvalidDimensions;
                    const pixel_count = std.math.mul(
                        usize,
                        image.width,
                        image.height,
                    ) catch return error.LimitExceeded;
                    const expected = std.math.mul(
                        usize,
                        pixel_count,
                        format.bytesPerPixel(),
                    ) catch return error.LimitExceeded;
                    if (image.data.len != expected)
                        return error.InvalidDimensions;
                    scanned_resource_bytes = std.math.add(
                        usize,
                        scanned_resource_bytes,
                        image.data.len,
                    ) catch return error.LimitExceeded;
                    if (scanned_resource_bytes > limits.max_kitty_resource_bytes)
                        return error.LimitExceeded;
                    const digest = Scene.kittyResourceDigest(
                        image.width,
                        image.height,
                        format,
                        image.data,
                    );
                    images[image_index] = .{
                        .image_id = entry.key_ptr.*,
                        .generation = image.generation,
                        .resource_digest = digest,
                    };
                    borrowed[image_index] = .{
                        .digest = digest,
                        .width = image.width,
                        .height = image.height,
                        .format = format,
                        .pixels = image.data,
                    };
                }
                std.mem.sortUnstable(Scene.KittyImage, images, {}, imageLessThan);
                std.mem.sortUnstable(BorrowedResource, borrowed, {}, resourceLessThan);

                var unique_count: usize = 0;
                for (borrowed, 0..) |resource, index| {
                    if (index == 0 or !std.mem.eql(
                        u8,
                        &resource.digest,
                        &borrowed[index - 1].digest,
                    )) unique_count += 1;
                }
                resources = try alloc.alloc(Scene.KittyResource, unique_count);
                var resource_bytes: usize = 0;
                var resource_index: usize = 0;
                for (borrowed, 0..) |resource, index| {
                    if (index > 0 and std.mem.eql(
                        u8,
                        &resource.digest,
                        &borrowed[index - 1].digest,
                    )) continue;
                    resource_bytes = std.math.add(
                        usize,
                        resource_bytes,
                        resource.pixels.len,
                    ) catch return error.LimitExceeded;
                    if (resource_bytes > limits.max_kitty_resource_bytes)
                        return error.LimitExceeded;
                    resources[resource_index] = .{
                        .digest = resource.digest,
                        .width = resource.width,
                        .height = resource.height,
                        .format = resource.format,
                        .pixels = try alloc.dupe(u8, resource.pixels),
                    };
                    resource_index += 1;
                }
            }

            var placements: std.ArrayListUnmanaged(Scene.KittyPlacement) = .empty;
            const top = term.screens.active.pages.getTopLeft(.viewport);
            const bottom = term.screens.active.pages.getBottomRight(.viewport) orelse
                return error.InvalidDimensions;
            const top_y = term.screens.active.pages.pointFromPin(.screen, top).?.screen.y;
            const bottom_y = term.screens.active.pages.pointFromPin(.screen, bottom).?.screen.y;

            var placement_it = storage.placements.iterator();
            while (placement_it.next()) |entry| {
                const placement = entry.value_ptr;
                switch (placement.location) {
                    .pin => {},
                    .virtual => continue,
                }
                const image = storage.imageById(entry.key_ptr.image_id) orelse
                    return error.InvalidIdentity;
                const rect = placement.rect(image, term) orelse continue;
                const image_top_y = term.screens.active.pages
                    .pointFromPin(.screen, rect.top_left).?.screen.y;
                const image_bottom_y = term.screens.active.pages
                    .pointFromPin(.screen, rect.bottom_right).?.screen.y;
                if (image_top_y > bottom_y or image_bottom_y < top_y) continue;
                const size = placement.pixelSize(image, term);
                if (size.width == 0 or size.height == 0) continue;
                const source_x = @min(image.width, placement.source_x);
                const source_y = @min(image.height, placement.source_y);
                const source_width = if (placement.source_width > 0)
                    @min(image.width - source_x, placement.source_width)
                else
                    image.width;
                const source_height = if (placement.source_height > 0)
                    @min(image.height - source_y, placement.source_height)
                else
                    image.height;
                try appendPlacement(&placements, alloc, limits, .{
                    .image_id = image.id,
                    .order = (@as(
                        u64,
                        @intFromEnum(entry.key_ptr.placement_id.tag),
                    ) << 62) | entry.key_ptr.placement_id.id,
                    .x = @intCast(rect.top_left.x),
                    .y = @as(i32, @intCast(image_top_y)) -
                        @as(i32, @intCast(top_y)),
                    .z = placement.z,
                    .width = size.width,
                    .height = size.height,
                    .cell_offset_x = placement.x_offset,
                    .cell_offset_y = placement.y_offset,
                    .source_x = source_x,
                    .source_y = source_y,
                    .source_width = source_width,
                    .source_height = source_height,
                });
            }

            var virtual_it = terminal.kitty.graphics.unicode.placementIterator(
                top,
                bottom,
            );
            const cell_width: u32 = term.width_px / term.cols;
            const cell_height: u32 = term.height_px / term.rows;
            var virtual_order: u64 = 0;
            while (virtual_it.next()) |virtual| {
                const image = storage.imageById(virtual.image_id) orelse
                    return error.InvalidIdentity;
                const placement = virtual.renderPlacement(
                    storage,
                    &image,
                    cell_width,
                    cell_height,
                ) catch |err| switch (err) {
                    error.PlacementMissingPlacement => return error.InvalidIdentity,
                    error.PlacementGridOutOfBounds => return error.InvalidDimensions,
                };
                if (placement.dest_width == 0 or placement.dest_height == 0)
                    continue;
                const viewport = term.screens.active.pages.pointFromPin(
                    .viewport,
                    placement.top_left,
                ) orelse return error.InvalidCoordinate;
                try appendPlacement(&placements, alloc, limits, .{
                    .image_id = image.id,
                    .order = (@as(u64, 2) << 62) | virtual_order,
                    .x = @intCast(placement.top_left.x),
                    .y = @intCast(viewport.viewport.y),
                    .z = -1,
                    .width = placement.dest_width,
                    .height = placement.dest_height,
                    .cell_offset_x = placement.offset_x,
                    .cell_offset_y = placement.offset_y,
                    .source_x = placement.source_x,
                    .source_y = placement.source_y,
                    .source_width = placement.source_width,
                    .source_height = placement.source_height,
                });
                virtual_order += 1;
            }
            std.mem.sortUnstable(
                Scene.KittyPlacement,
                placements.items,
                {},
                placementLessThan,
            );

            return .{
                .resources = resources,
                .images = images,
                .placements = try placements.toOwnedSlice(alloc),
                .generation = storage.generation,
            };
        }

        fn appendPlacement(
            placements: *std.ArrayListUnmanaged(Scene.KittyPlacement),
            alloc: Allocator,
            limits: Scene.Limits,
            placement: Scene.KittyPlacement,
        ) !void {
            if (placements.items.len >= limits.max_kitty_placements)
                return error.LimitExceeded;
            try placements.append(alloc, placement);
        }

        fn imageLessThan(
            _: void,
            left: Scene.KittyImage,
            right: Scene.KittyImage,
        ) bool {
            return left.image_id < right.image_id;
        }

        fn resourceLessThan(
            _: void,
            left: BorrowedResource,
            right: BorrowedResource,
        ) bool {
            return std.mem.order(u8, &left.digest, &right.digest) == .lt;
        }

        fn placementLessThan(
            _: void,
            left: Scene.KittyPlacement,
            right: Scene.KittyPlacement,
        ) bool {
            if (left.z != right.z) return left.z < right.z;
            if (left.image_id != right.image_id) return left.image_id < right.image_id;
            if (left.y != right.y) return left.y < right.y;
            if (left.x != right.x) return left.x < right.x;
            if (left.source_y != right.source_y) return left.source_y < right.source_y;
            if (left.source_x != right.source_x) return left.source_x < right.source_x;
            return left.order < right.order;
        }
    };
}
