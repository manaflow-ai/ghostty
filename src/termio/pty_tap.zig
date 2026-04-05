//! A lock-free SPSC (single-producer, single-consumer) ring buffer for
//! tapping raw PTY output. The producer is the PTY read path and the
//! consumer is an external reader (e.g. a bridge server streaming terminal
//! data to a mobile client).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PtyTap = struct {
    buf: []u8,
    capacity: usize,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    active: std.atomic.Value(bool),
    alloc: Allocator,

    pub fn init(alloc: Allocator, capacity: usize) !*PtyTap {
        const self = try alloc.create(PtyTap);
        self.* = .{
            .buf = try alloc.alloc(u8, capacity),
            .capacity = capacity,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .active = std.atomic.Value(bool).init(false),
            .alloc = alloc,
        };
        return self;
    }

    pub fn deinit(self: *PtyTap) void {
        const alloc = self.alloc;
        alloc.free(self.buf);
        alloc.destroy(self);
    }

    /// Producer: write data to the ring buffer. Drops oldest data on overflow.
    pub fn write(self: *PtyTap, data: []const u8) void {
        if (!self.active.load(.acquire)) return;
        if (data.len == 0) return;

        var head = self.head.load(.acquire);
        const cap = self.capacity;

        for (data) |byte| {
            const pos = head % cap;
            self.buf[pos] = byte;
            head +%= 1;

            // If we would overwrite unread data, advance tail (drop oldest)
            const tail = self.tail.load(.acquire);
            if (head -% tail > cap) {
                _ = self.tail.cmpxchgStrong(tail, tail +% 1, .release, .monotonic);
            }
        }

        // Batch update head after writing all bytes
        self.head.store(head, .release);
    }

    /// Consumer: read available data from the ring buffer. Returns bytes read.
    pub fn read(self: *PtyTap, out: []u8) usize {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);

        if (head == tail) return 0;

        const avail = head -% tail;
        const to_read = @min(avail, out.len);
        const cap = self.capacity;

        var i: usize = 0;
        while (i < to_read) : (i += 1) {
            out[i] = self.buf[(tail +% i) % cap];
        }

        self.tail.store(tail +% to_read, .release);
        return to_read;
    }

    /// Returns number of bytes available to read.
    pub fn available(self: *PtyTap) usize {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);
        return head -% tail;
    }
};
