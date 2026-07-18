//! Process-independent semantic renderer scene model.
//!
//! Canonical terminal content and presentation-local state have distinct
//! identities and sequencing. Wire-visible values contain no PTY, parser,
//! GPU object, renderer, or process-local pointer. Owned wrappers use arenas
//! only to define local decode lifetimes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Identity = [16]u8;
pub const TerminalIdentity = Identity;
pub const PresentationIdentity = Identity;
pub const HyperlinkIdentity = Identity;

pub const Limits = struct {
    max_encoded_bytes: usize = 64 * 1024 * 1024,
    max_allocation_bytes: usize = 128 * 1024 * 1024,
    max_rows: u32 = 4096,
    max_columns: u32 = 4096,
    max_cells: usize = 4 * 1024 * 1024,
    max_grapheme_codepoints_per_cell: usize = 64,
    max_total_grapheme_codepoints: usize = 4 * 1024 * 1024,
    max_preedit_codepoints: usize = 4096,
    max_highlights: usize = 1024 * 1024,
    max_overlay_features: usize = 16,
};

pub const CutoverEligibility = enum {
    eligible,
    requires_live_kitty_image_state,
    requires_renderer_custom_shader_state,
};

pub const SequenceError = error{
    InvalidSequence,
    SequenceExhausted,
};

/// Return the next value for a non-wrapping scene sequence. Zero is reserved
/// for invalid/uninitialized state, and reaching maxInt requires a new epoch
/// or presentation generation rather than wrapping.
pub fn nextSequence(current: u64) SequenceError!u64 {
    if (current == 0) return error.InvalidSequence;
    if (current == std.math.maxInt(u64)) return error.SequenceExhausted;
    return current + 1;
}

pub const Capability = enum(u6) {
    semantic_cells_v1 = 0,
    stable_row_anchors = 1,
    stable_hyperlinks = 2,
    presentation_envelopes = 3,
    images = 4,
    custom_shaders = 5,
};

/// Every envelope declares all features required to interpret it. A zero
/// manifest is invalid, so a producer cannot accidentally omit negotiation.
pub const CapabilityManifest = struct {
    bits: u64,

    pub const known_mask: u64 = blk: {
        var bits: u64 = 0;
        for (std.meta.tags(Capability)) |capability|
            bits |= bit(capability);
        break :blk bits;
    };

    pub const baseline: CapabilityManifest = .{ .bits = bit(.semantic_cells_v1) |
        bit(.stable_row_anchors) |
        bit(.stable_hyperlinks) |
        bit(.presentation_envelopes) };

    pub fn bit(capability: Capability) u64 {
        return @as(u64, 1) << @intFromEnum(capability);
    }

    pub fn contains(self: CapabilityManifest, capability: Capability) bool {
        return self.bits & bit(capability) != 0;
    }

    pub fn containsAll(self: CapabilityManifest, required: CapabilityManifest) bool {
        return required.bits & ~self.bits == 0;
    }

    pub fn validRequired(self: CapabilityManifest) bool {
        return self.bits & ~known_mask == 0 and
            self.containsAll(baseline);
    }
};

pub const SnapshotKind = enum(u8) {
    full = 1,
    delta = 2,
};

/// Each independently cached section can either carry a new snapshot or
/// reference the receiver's exact cached section without a payload.
pub const SectionKind = enum(u8) {
    unchanged = 0,
    full = 1,
    delta = 2,
};

pub const CanonicalSceneRef = struct {
    terminal_id: TerminalIdentity,
    terminal_epoch: u64,
    content_sequence: u64,
    row_space_revision: u64,
};

pub const PresentationSceneRef = struct {
    presentation_id: PresentationIdentity,
    generation: u64,
    sequence: u64,
};

/// Stable terminal row-space identity referenced by presentation state.
/// Deliberately excludes content_sequence so a compatible canonical update
/// does not force an otherwise unchanged presentation revision.
pub const TerminalSpaceRef = struct {
    terminal_id: TerminalIdentity,
    terminal_epoch: u64,
    row_space_revision: u64,
};

/// Route, lifetime, replay, and capability fence for a decoder.
pub const DecodeExpectation = struct {
    terminal_id: TerminalIdentity,
    terminal_epoch: u64,
    /// Exact canonical section currently cached by the receiver. Null means
    /// this must be an initial full snapshot.
    canonical_ref: ?CanonicalSceneRef,
    /// Required when decoding a canonical row delta. The decoder clones this
    /// validated cache and applies bounded row replacements atomically.
    canonical_cache: ?*const CanonicalSceneEnvelope = null,
    presentation_id: PresentationIdentity,
    presentation_generation: u64,
    /// Exact presentation section currently cached by the receiver. Null
    /// means this must be an initial full snapshot.
    presentation_ref: ?PresentationSceneRef,
    supported_capabilities: CapabilityManifest,
};

pub const EncodeOptions = struct {
    supported_capabilities: CapabilityManifest,
    canonical_kind: SectionKind = .full,
    presentation_kind: SectionKind = .full,
    /// Exact base used to produce a canonical row delta.
    canonical_base: ?*const CanonicalSceneEnvelope = null,
};

pub const Bounds = struct {
    rows: u32,
    columns: u32,
};

/// Absolute row identity within one explicit row-space revision.
pub const RowAnchor = struct {
    row_space_revision: u64,
    absolute_row: u64,
};

pub const Coordinate = struct {
    row: RowAnchor,
    column: u32,
};

pub const ViewportCoordinate = struct {
    row: u32,
    column: u32,
};

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const StyleColor = union(enum) {
    none,
    palette: u8,
    rgb: RGB,
};

pub const Underline = enum(u8) {
    none,
    single,
    double,
    curly,
    dotted,
    dashed,
};

pub const Style = struct {
    foreground: StyleColor = .none,
    background: StyleColor = .none,
    underline_color: StyleColor = .none,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: Underline = .none,
};

pub const WideRole = enum(u8) {
    narrow,
    wide,
    spacer_tail,
    spacer_head,
};

pub const SemanticContent = enum(u8) {
    output,
    input,
    prompt,
};

pub const CellContent = union(enum) {
    codepoint: u21,
    grapheme: []const u21,
    background_palette: u8,
    background_rgb: RGB,
};

pub const Cell = struct {
    column: u32,
    content: CellContent,
    wide_role: WideRole,
    protected: bool,
    hyperlink: ?HyperlinkIdentity,
    semantic_content: SemanticContent,
    style: Style,
};

pub const SemanticPrompt = enum(u8) {
    none,
    prompt,
    prompt_continuation,
};

pub const Row = struct {
    anchor: RowAnchor,
    backing_index: u32,
    column_start: u32,
    column_count: u32,
    wrap: bool,
    wrap_continuation: bool,
    semantic_prompt: SemanticPrompt,
    kitty_virtual_placeholder: bool,
    cells: []Cell,
};

pub const Screen = enum(u8) {
    primary,
    alternate,
};

pub const Colors = struct {
    /// Only colors authored by the terminal byte stream belong in the
    /// canonical scene. Presentation-local config supplies every default.
    background_override: ?RGB = null,
    foreground_override: ?RGB = null,
    cursor_override: ?RGB = null,
    reverse: bool = false,
    palette_mask: [32]u8 = [_]u8{0} ** 32,
    /// Entries whose mask bit is clear must remain zero. They are never
    /// encoded and therefore cannot leak a producer's presentation theme.
    palette: [256]RGB = [_]RGB{.{ .r = 0, .g = 0, .b = 0 }} ** 256,

    pub const empty: Colors = .{};

    pub fn paletteIsSet(self: *const Colors, index: u8) bool {
        const byte_index: usize = index / 8;
        const bit_index: u3 = @intCast(index % 8);
        return self.palette_mask[byte_index] & (@as(u8, 1) << bit_index) != 0;
    }

    pub fn setPalette(self: *Colors, index: u8, value: RGB) void {
        const byte_index: usize = index / 8;
        const bit_index: u3 = @intCast(index % 8);
        self.palette_mask[byte_index] |= @as(u8, 1) << bit_index;
        self.palette[index] = value;
    }
};

pub const CursorStyle = enum(u8) {
    bar,
    block,
    underline,
    block_hollow,
};

pub const CursorViewport = struct {
    coordinate: ViewportCoordinate,
    wide_tail: bool,
};

/// Renderer-relevant semantics of the terminal's active cursor cell. The
/// process-local style and hyperlink IDs in page.Cell are intentionally not
/// transported. These fields preserve wide cursor geometry and color-only
/// cell backgrounds used by the renderer.
pub const CursorCellContent = union(enum) {
    text,
    background_palette: u8,
    background_rgb: RGB,
};

pub const CursorCell = struct {
    content: CursorCellContent = .text,
    wide_role: WideRole = .narrow,
};

pub const Cursor = struct {
    active: ViewportCoordinate,
    cell: CursorCell,
    style: Style,
    visual_style: CursorStyle,
    password_input: bool,
    visible: bool,
    blinking: bool,
};

pub const Content = struct {
    /// Active terminal grid size. This is canonical terminal state and does
    /// not identify which rows a presentation currently views.
    bounds: Bounds,
    /// First absolute row captured in `rows`. The captured backing window may
    /// contain more rows than one viewport and is independent of scroll.
    row_start: u64,
    /// Total rows in the canonical terminal row space. Presentations choose a
    /// viewport inside this extent but cannot redefine it.
    row_total: u64,
    screen: Screen,
    colors: Colors,
    cursor: Cursor,
    rows: []Row,
    image_count: u32,
};

pub const ColumnRange = struct {
    row: RowAnchor,
    start: u32,
    end: u32,
};

pub const HighlightKind = enum(u8) {
    search_match,
    search_match_selected,
};

pub const Highlight = struct {
    row: RowAnchor,
    start: u32,
    end: u32,
    kind: HighlightKind,
};

pub const Scrollbar = struct {
    offset: u64,
    len: u64,
    row_space_revision: u64,
};

pub const PreeditCodepoint = struct {
    codepoint: u21,
    wide: bool = false,
};

pub const OverlayFeature = enum(u8) {
    highlight_hyperlinks,
    semantic_prompts,
};

pub const Presentation = struct {
    selections: []ColumnRange,
    highlights: []Highlight,
    active_links: []Coordinate,
    preedit: []PreeditCodepoint,
    overlay_features: []OverlayFeature,
    hover: ?Coordinate,
    cursor_viewport: ?CursorViewport,
    focused: bool,
    cursor_blink_visible: bool,
    scrollbar: Scrollbar,
    custom_shader_count: u32,
};

pub const CanonicalSceneEnvelope = struct {
    ref: CanonicalSceneRef,
    snapshot_kind: SnapshotKind,
    base_content_sequence: ?u64,
    required_capabilities: CapabilityManifest,
    content: Content,
};

pub const PresentationEnvelope = struct {
    ref: PresentationSceneRef,
    snapshot_kind: SnapshotKind,
    base_sequence: ?u64,
    terminal_space: TerminalSpaceRef,
    content: Presentation,
};

pub const Owned = struct {
    canonical_arena: std.heap.ArenaAllocator,
    presentation_arena: std.heap.ArenaAllocator,
    canonical_budget: ?*AllocationBudget = null,
    presentation_budget: ?*AllocationBudget = null,
    canonical: CanonicalSceneEnvelope,
    presentation: PresentationEnvelope,

    pub fn deinit(self: *Owned) void {
        self.presentation_arena.deinit();
        if (self.presentation_budget) |budget| budget.release();
        self.canonical_arena.deinit();
        if (self.canonical_budget) |budget| budget.release();
        self.* = undefined;
    }
};

pub const OwnedCanonicalSection = struct {
    arena: std.heap.ArenaAllocator,
    budget: ?*AllocationBudget = null,
    value: CanonicalSceneEnvelope,

    pub fn deinit(self: *OwnedCanonicalSection) void {
        self.arena.deinit();
        if (self.budget) |budget| budget.release();
        self.* = undefined;
    }
};

pub const OwnedPresentationSection = struct {
    arena: std.heap.ArenaAllocator,
    budget: ?*AllocationBudget = null,
    value: PresentationEnvelope,

    pub fn deinit(self: *OwnedPresentationSection) void {
        self.arena.deinit();
        if (self.budget) |budget| budget.release();
        self.* = undefined;
    }
};

/// Heap-stable allocator wrapper that enforces an actual aggregate allocation
/// ceiling across any number of arenas. Arenas retain this object explicitly,
/// so their allocator context never points at a decoder stack frame.
pub const AllocationBudget = struct {
    child: Allocator,
    owner: Allocator,
    limit: usize,
    used: usize = 0,
    limit_exceeded: bool = false,
    refs: std.atomic.Value(usize) = .{ .raw = 1 },
    mutex: std.Thread.Mutex = .{},

    pub fn create(owner_alloc: Allocator, limit: usize) Allocator.Error!*AllocationBudget {
        // Control metadata is intentionally outside the payload allocator.
        // This preserves the protocol guarantee that an unchanged/empty
        // section performs no caller-visible allocation while keeping the
        // allocator context heap-stable for non-empty retained arenas.
        const control_alloc = std.heap.page_allocator;
        const self = try control_alloc.create(AllocationBudget);
        self.* = .{
            .child = owner_alloc,
            .owner = control_alloc,
            .limit = limit,
        };
        return self;
    }

    pub fn retain(self: *AllocationBudget) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *AllocationBudget) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.used == 0);
        const owner = self.owner;
        owner.destroy(self);
    }

    pub fn allocator(self: *AllocationBudget) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (len > self.limit -| self.used) {
            self.limit_exceeded = true;
            return null;
        }
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse
            return null;
        self.used += len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const growth = new_len -| memory.len;
        if (growth > self.limit -| self.used) {
            self.limit_exceeded = true;
            return false;
        }
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr))
            return false;
        if (new_len >= memory.len)
            self.used += new_len - memory.len
        else
            self.used -= memory.len - new_len;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const growth = new_len -| memory.len;
        if (growth > self.limit -| self.used) {
            self.limit_exceeded = true;
            return null;
        }
        const result = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            ret_addr,
        ) orelse return null;
        if (new_len >= memory.len)
            self.used += new_len - memory.len
        else
            self.used -= memory.len - new_len;
        return result;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child.rawFree(memory, alignment, ret_addr);
        std.debug.assert(memory.len <= self.used);
        self.used -= memory.len;
    }
};

/// Canonical storage owned once by a cache and borrowed by any number of
/// concurrently retained presentation sections. The cache must outlive its
/// presentation views; presentation teardown never touches canonical memory.
pub const CanonicalCache = struct {
    section: OwnedCanonicalSection,

    pub fn deinit(self: *CanonicalCache) void {
        self.section.deinit();
        self.* = undefined;
    }
};

pub const PresentationCache = struct {
    section: OwnedPresentationSection,

    pub fn deinit(self: *PresentationCache) void {
        self.section.deinit();
        self.* = undefined;
    }
};

pub const CachedView = struct {
    canonical: *const CanonicalSceneEnvelope,
    presentation: *const PresentationEnvelope,
};

pub const CanonicalUpdate = union(enum) {
    unchanged: CanonicalSceneRef,
    full: OwnedCanonicalSection,
};

pub const PresentationUpdate = union(enum) {
    unchanged: PresentationSceneRef,
    full: OwnedPresentationSection,
};

/// A decoded independently sequenced update. Unchanged sections contain only
/// an exact reference and therefore own no arena and allocate no memory.
/// Partial updates are not renderable on their own and must be passed to
/// Scene.applyUpdate, which validates them against the retained other section.
pub const Update = struct {
    required_capabilities: CapabilityManifest,
    canonical: CanonicalUpdate,
    presentation: PresentationUpdate,

    pub fn deinit(self: *Update) void {
        switch (self.presentation) {
            .unchanged => {},
            .full => |*section| section.deinit(),
        }
        switch (self.canonical) {
            .unchanged => {},
            .full => |*section| section.deinit(),
        }
        self.* = undefined;
    }
};

pub fn identityIsZero(identity: Identity) bool {
    for (identity) |byte| if (byte != 0) return false;
    return true;
}
