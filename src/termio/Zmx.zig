//! Zmx implements a termio backend that connects to a zmx daemon session
//! over a Unix domain socket instead of spawning a direct PTY subprocess.
//! The zmx daemon owns the PTY and persists independently of the surface,
//! enabling session persistence across restarts.
const Zmx = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;

const log = std.log.scoped(.io_zmx);

// ──────────────────────────────────────────────────────────────────────
// IPC protocol — matches zmx ipc.zig exactly
// ──────────────────────────────────────────────────────────────────────

pub const IpcTag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
};

pub const IpcHeader = packed struct {
    tag: IpcTag,
    len: u32,
};

pub const IpcResize = packed struct {
    rows: u16,
    cols: u16,
};

const DisconnectMetadata = struct {
    exit_code: u32,
    runtime_ms: u64,
};

fn ipcSend(fd: posix.fd_t, tag: IpcTag, data: []const u8) !void {
    const header = IpcHeader{
        .tag = tag,
        .len = @intCast(data.len),
    };
    const header_bytes = std.mem.asBytes(&header);
    try writeAll(fd, header_bytes);
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

const IpcSocketMsg = struct {
    header: IpcHeader,
    payload: []const u8,
};

const SocketBuffer = struct {
    buf: std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    head: usize,

    fn init(alloc: Allocator) !SocketBuffer {
        var buf = std.ArrayListUnmanaged(u8){};
        try buf.ensureTotalCapacity(alloc, 4096);
        return .{
            .buf = buf,
            .alloc = alloc,
            .head = 0,
        };
    }

    fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Read from fd into buffer. Returns bytes read (0 = EOF).
    fn read(self: *SocketBuffer, fd: posix.fd_t) !usize {
        // Compact: shift unprocessed data to front
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Returns next complete IPC message or null.
    fn next(self: *SocketBuffer) ?IpcSocketMsg {
        const available = self.buf.items[self.head..];
        const hdr_size = @sizeOf(IpcHeader);
        if (available.len < hdr_size) return null;

        const hdr = std.mem.bytesToValue(IpcHeader, available[0..hdr_size]);
        const total = hdr_size + hdr.len;
        if (available.len < total) return null;

        const pay = available[hdr_size..total];
        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

// ──────────────────────────────────────────────────────────────────────
// Zmx backend state
// ──────────────────────────────────────────────────────────────────────

session_name: [:0]const u8,
socket_dir: []const u8,
create_if_missing: bool,
working_directory: ?[]const u8,
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 0, .height = 0 },
socket_fd: ?posix.fd_t = null,
arena: std.heap.ArenaAllocator,

pub const Config = struct {
    session_name: []const u8,
    create_if_missing: bool = true,
    working_directory: ?[]const u8 = null,
};

/// Initialize zmx backend state. Does NOT connect — connection happens
/// in threadEnter on the IO thread.
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Zmx {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const session_name = try arena_alloc.dupeZ(u8, cfg.session_name);

    // Resolve socket directory: $ZMX_DIR > $XDG_RUNTIME_DIR/zmx > $TMPDIR/zmx-{uid}
    const socket_dir = try resolveSocketDir(arena_alloc);

    // Validate socket path length
    const full_path = try std.fmt.allocPrint(arena_alloc, "{s}/{s}", .{ socket_dir, session_name });
    _ = std.net.Address.initUnix(full_path) catch {
        return error.SocketPathTooLong;
    };

    // Only session creation requires a local zmx binary. Attach-only mode can
    // still connect to an already-running daemon session without it.
    if (cfg.create_if_missing and !findZmxBinary()) {
        return error.ZmxNotFound;
    }

    const working_directory = if (cfg.working_directory) |wd|
        try arena_alloc.dupe(u8, wd)
    else
        null;

    return .{
        .session_name = session_name,
        .socket_dir = socket_dir,
        .create_if_missing = cfg.create_if_missing,
        .working_directory = working_directory,
        .arena = arena,
    };
}

pub fn deinit(self: *Zmx) void {
    if (self.socket_fd) |fd| posix.close(fd);
    self.arena.deinit();
}

pub fn initTerminal(self: *Zmx, term: *terminal.Terminal) void {
    if (self.working_directory) |wd| term.setPwd(wd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Zmx,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    const start = try std.time.Instant.now();

    const socket_path = try std.fmt.allocPrint(
        self.arena.allocator(),
        "{s}/{s}",
        .{ self.socket_dir, self.session_name },
    );

    // Session creation / readiness probing if needed.
    const had_ready_socket = socketReady(socket_path);
    if (self.create_if_missing and !had_ready_socket) {
        try self.createSession(socket_path);
    } else if (!had_ready_socket) {
        try waitForSocketReady(socket_path, 20, 50);
    }

    // Connect to Unix domain socket
    const sock = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(sock);

    const addr = try std.net.Address.initUnix(socket_path);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Send Init with terminal dimensions
    const init_resize = IpcResize{
        .rows = @intCast(self.grid_size.rows),
        .cols = @intCast(self.grid_size.columns),
    };
    try ipcSend(sock, .Init, std.mem.asBytes(&init_resize));

    // Send Resize immediately after Init (zmx 0.3.0 requirement)
    try ipcSend(sock, .Resize, std.mem.asBytes(&init_resize));

    // Create quit pipe for read thread signaling
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup write stream on socket fd
    var stream = xev.Stream.initFd(sock);
    errdefer stream.deinit();

    // Allocate shutdown flag (heap-allocated for stable pointer to read thread)
    const shutting_down = try alloc.create(std.atomic.Value(bool));
    shutting_down.* = std.atomic.Value(bool).init(false);
    errdefer alloc.destroy(shutting_down);

    // Spawn read thread
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMain,
        .{ sock, io, pipe[0], shutting_down, start },
    );
    read_thread.setName("zmx-reader") catch {};

    // Set ThreadData — ownership transfers here, cancel errdefers above
    td.backend = .{ .zmx = .{
        .start = start,
        .write_stream = stream,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .socket_fd = sock,
        .shutting_down = shutting_down,
    } };
    self.socket_fd = sock;
}

pub fn threadExit(self: *Zmx, td: *termio.Termio.ThreadData) void {
    const zmx_td = &td.backend.zmx;

    // Signal read thread that upcoming EOF from Detach is expected
    zmx_td.shutting_down.store(true, .release);

    // Send Detach — keeps session alive for reconnection
    ipcSend(zmx_td.socket_fd, .Detach, &.{}) catch |err| {
        log.warn("error sending detach err={}", .{err});
    };

    // Signal and join read thread
    _ = posix.write(zmx_td.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };
    zmx_td.read_thread.join();
    self.socket_fd = null;
}

pub fn focusGained(
    self: *Zmx,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    // No-op: zmx doesn't own the PTY, no termios state to poll
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Zmx,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    if (self.socket_fd) |fd| {
        const resize_msg = IpcResize{
            .rows = @intCast(grid_size.rows),
            .cols = @intCast(grid_size.columns),
        };
        ipcSend(fd, .Resize, std.mem.asBytes(&resize_msg)) catch |err| {
            log.warn("error sending resize err={}", .{err});
        };
    }
}

pub fn queueWrite(
    self: *Zmx,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const zmx_td = &td.backend.zmx;

    // Chunk data through write pool, wrapping each chunk in IPC Input message
    var i: usize = 0;
    while (i < data.len) {
        const req = try zmx_td.write_req_pool.getGrow(alloc);
        const buf = try zmx_td.write_buf_pool.getGrow(alloc);

        // Reserve space for IPC header at the beginning of each buffer
        const hdr_size = @sizeOf(IpcHeader);
        const payload_buf = buf[hdr_size..];

        const payload_len: usize = payload_len: {
            const max = @min(data.len, i + payload_buf.len);

            if (!linefeed) {
                fastmem.copy(u8, payload_buf, data[i..max]);
                const len = max - i;
                i = max;
                break :payload_len len;
            }

            // Slow path: replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < payload_buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    payload_buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                payload_buf[buf_i] = '\r';
                payload_buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :payload_len buf_i;
        };

        // Write IPC header into the reserved space
        const header = IpcHeader{
            .tag = .Input,
            .len = @intCast(payload_len),
        };
        const header_bytes = std.mem.asBytes(&header);
        @memcpy(buf[0..hdr_size], header_bytes);

        const total_len = hdr_size + payload_len;

        zmx_td.write_stream.queueWrite(
            td.loop,
            &zmx_td.write_queue,
            req,
            .{ .slice = buf[0..total_len] },
            termio.Zmx.ThreadData,
            zmx_td,
            ttyWrite,
        );
    }
}

fn ttyWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    _ = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };

    return .disarm;
}

pub fn childExitedAbnormally(
    self: *Zmx,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = exit_code;
    _ = runtime_ms;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const session_info = try std.fmt.allocPrint(alloc, "zmx session: {s}", .{self.session_name});

    // Move cursor to column 0
    t.carriageReturn();
    try t.setAttribute(.{ .unset = {} });

    // If there is content, add a separator
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }

    // Output error message
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("zmx session disconnected unexpectedly:");
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(session_info);
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("The zmx daemon session may have exited or the socket was removed.");
    try t.setAttribute(.{ .unset = {} });
}

// ──────────────────────────────────────────────────────────────────────
// ThreadData
// ──────────────────────────────────────────────────────────────────────

pub const ThreadData = struct {
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    start: std.time.Instant,
    write_stream: xev.Stream,
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},
    write_queue: xev.WriteQueue = .{},
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    socket_fd: posix.fd_t,

    /// Heap-allocated so the read thread has a stable pointer independent
    /// of ThreadData. Set to true by threadExit before sending Detach.
    /// The read thread checks this on EOF to suppress .child_exited for
    /// planned detach.
    shutting_down: *std.atomic.Value(bool),

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);
        self.write_stream.deinit();
        alloc.destroy(self.shutting_down);
    }
};

// ──────────────────────────────────────────────────────────────────────
// ReadThread
// ──────────────────────────────────────────────────────────────────────

const ReadThread = struct {
    fn threadMain(
        socket_fd: posix.fd_t,
        io: *termio.Termio,
        quit: posix.fd_t,
        shutting_down: *std.atomic.Value(bool),
        start: std.time.Instant,
    ) void {
        defer posix.close(quit);

        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"zmx-reader".*);
        }

        // Set socket to non-blocking for tight read loop
        if (posix.fcntl(socket_fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                socket_fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("zmx read thread failed to set non-blocking err={}", .{err});
            };
        } else |err| {
            log.warn("zmx read thread failed to get flags err={}", .{err});
        }

        // Poll both socket and quit pipe
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = socket_fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var sock_buf = SocketBuffer.init(std.heap.c_allocator) catch {
            log.err("zmx read thread failed to allocate socket buffer", .{});
            return;
        };
        defer sock_buf.deinit();

        while (true) {
            // Tight read loop — read and dispatch as many messages as possible
            while (true) {
                const n = sock_buf.read(socket_fd) catch |err| {
                    switch (err) {
                        error.WouldBlock => break,
                        error.ConnectionResetByPeer,
                        error.NotOpenForReading,
                        => {
                            handleDisconnect(io, shutting_down, start);
                            return;
                        },
                        else => {
                            log.err("zmx read error err={}", .{err});
                            handleDisconnect(io, shutting_down, start);
                            return;
                        },
                    }
                };

                // EOF — socket closed
                if (n == 0) {
                    handleDisconnect(io, shutting_down, start);
                    return;
                }

                // Dispatch all complete messages
                while (sock_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Output => {
                            @call(.always_inline, termio.Termio.processOutput, .{ io, msg.payload });
                        },
                        .Ack => {
                            log.debug("zmx ack received", .{});
                        },
                        else => {
                            log.debug("zmx unexpected tag={}", .{msg.header.tag});
                        },
                    }
                }
            }

            // Wait for data
            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("zmx poll failed, exiting read thread err={}", .{err});
                return;
            };

            // Check quit signal
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("zmx read thread got quit signal", .{});
                return;
            }

            // Check socket HUP
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                handleDisconnect(io, shutting_down, start);
                return;
            }
        }
    }

    fn handleDisconnect(
        io: *termio.Termio,
        shutting_down: *std.atomic.Value(bool),
        start: std.time.Instant,
    ) void {
        if (shutting_down.load(.acquire)) {
            // Planned detach — just exit quietly
            log.info("zmx read thread: planned detach, exiting", .{});
            return;
        }

        // Unexpected disconnect — notify surface
        log.warn("zmx session disconnected unexpectedly", .{});
        const meta = disconnectMetadata(start);
        _ = io.surface_mailbox.push(.{
            .child_disconnected = .{
                .exit_code = meta.exit_code,
                .runtime_ms = meta.runtime_ms,
            },
        }, .{ .forever = {} });
    }
};

// ──────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────

fn resolveSocketDir(alloc: Allocator) ![]const u8 {
    return resolveSocketDirWithEnv(
        alloc,
        std.posix.getenv("ZMX_DIR"),
        std.posix.getenv("XDG_RUNTIME_DIR"),
        std.posix.getenv("TMPDIR"),
    );
}

fn resolveSocketDirWithEnv(
    alloc: Allocator,
    zmx_dir: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    tmpdir: ?[]const u8,
) ![]const u8 {
    // Priority: $ZMX_DIR > $XDG_RUNTIME_DIR/zmx > $TMPDIR/zmx-{uid}
    if (zmx_dir) |dir| return try alloc.dupe(u8, dir);
    if (xdg_runtime_dir) |dir| return try std.fmt.allocPrint(alloc, "{s}/zmx", .{dir});
    return try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir orelse "/tmp", std.c.getuid() });
}

fn findZmxBinary() bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/zmx", .{dir}) catch continue;
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}

fn socketReady(socket_path: []const u8) bool {
    const sock = posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    ) catch return false;
    defer posix.close(sock);

    const addr = std.net.Address.initUnix(socket_path) catch return false;
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

fn waitForSocketReady(socket_path: []const u8, max_attempts: usize, sleep_ms: u64) !void {
    for (0..max_attempts) |_| {
        if (socketReady(socket_path)) return;
        std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
    }
    return error.ZmxSessionTimeout;
}

fn createSession(self: *Zmx, socket_path: []const u8) !void {
    // Spawn `zmx run {session_name}`
    var argv = [_]?[*:0]const u8{ "zmx", "run", self.session_name.ptr, null };
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child: set working directory if provided
        if (self.working_directory) |wd| {
            std.posix.chdir(wd) catch {};
        }
        // Exec zmx
        std.posix.execvpeZ(
            "zmx",
            @ptrCast(&argv),
            @ptrCast(std.c.environ),
        ) catch {};
        std.posix.exit(1);
    }

    var reaped = false;
    errdefer if (!reaped) {
        // If we fail in this function, ensure we don't leave a zombie behind.
        _ = posix.waitpid(pid, 0);
    };

    // Parent: wait for socket readiness (100ms intervals, 5s timeout)
    const max_attempts: usize = 50;
    for (0..max_attempts) |_| {
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Reap child if it has exited so we don't create zombies.
        if (!reaped) {
            const res = posix.waitpid(pid, std.c.W.NOHANG);
            if (res.pid != 0) reaped = true;
        }

        if (socketReady(socket_path)) {
            if (!reaped) {
                const res = posix.waitpid(pid, std.c.W.NOHANG);
                if (res.pid != 0) reaped = true;
            }
            return;
        }
    }

    if (!reaped) {
        // Timed out waiting for a socket: terminate/reap launcher process.
        posix.kill(pid, posix.SIG.TERM) catch {};
        _ = posix.waitpid(pid, 0);
        reaped = true;
    }

    return error.ZmxSessionTimeout;
}

fn disconnectMetadata(start: std.time.Instant) DisconnectMetadata {
    const runtime_ms: u64 = runtime: {
        const end = std.time.Instant.now() catch break :runtime 0;
        break :runtime end.since(start) / std.time.ns_per_ms;
    };

    return .{
        .exit_code = 1,
        .runtime_ms = runtime_ms,
    };
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

test "IPC header serialization round-trip" {
    const header = IpcHeader{ .tag = .Input, .len = 42 };
    const bytes = std.mem.asBytes(&header);
    const decoded = std.mem.bytesToValue(IpcHeader, bytes);
    try std.testing.expectEqual(header.tag, decoded.tag);
    try std.testing.expectEqual(header.len, decoded.len);
}

test "IPC header size is 8 bytes packed" {
    // Zig 0.15 rounds this packed struct up to 8 bytes.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(IpcHeader));
}

test "socket path resolution with ZMX_DIR" {
    const alloc = std.testing.allocator;
    const dir = try resolveSocketDirWithEnv(alloc, "/tmp/custom-zmx", null, null);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings("/tmp/custom-zmx", dir);
}

test "socket path length validation" {
    const alloc = std.testing.allocator;

    // A reasonable path should succeed
    const short_path = try std.fmt.allocPrint(alloc, "/tmp/zmx/test-session", .{});
    defer alloc.free(short_path);
    const addr = std.net.Address.initUnix(short_path);
    try std.testing.expect(addr != error.NameTooLong);
}

test "SocketBuffer accumulation and framing" {
    const alloc = std.testing.allocator;
    var sock_buf = try SocketBuffer.init(alloc);
    defer sock_buf.deinit();

    // Manually inject a complete message into the buffer
    const header = IpcHeader{ .tag = .Output, .len = 5 };
    try sock_buf.buf.appendSlice(alloc, std.mem.asBytes(&header));
    try sock_buf.buf.appendSlice(alloc, "hello");

    // Should yield exactly one message
    const msg = sock_buf.next();
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(IpcTag.Output, msg.?.header.tag);
    try std.testing.expectEqualStrings("hello", msg.?.payload);

    // No more messages
    try std.testing.expect(sock_buf.next() == null);
}

test "disconnect metadata uses abnormal exit code and runtime" {
    const start = try std.time.Instant.now();
    std.Thread.sleep(2 * std.time.ns_per_ms);

    const meta = disconnectMetadata(start);
    try std.testing.expectEqual(@as(u32, 1), meta.exit_code);
    try std.testing.expect(meta.runtime_ms >= 1);
}
