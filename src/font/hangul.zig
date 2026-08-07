//! Algorithmic Hangul canonical composition (The Unicode Standard,
//! chapter 3.12, "Conjoining Jamo Behavior").
//!
//! A decomposed (NFD) Hangul grapheme cluster — a leading consonant,
//! a vowel, and optionally a trailing consonant — is canonically
//! equivalent to a single precomposed syllable in the U+AC00–U+D7A3
//! block. The mapping is fully algorithmic: no tables are required and
//! it is complete for the modern jamo ranges, so composing a cluster
//! here yields exactly its NFC form.
//!
//! Font selection uses this to resolve canonically equivalent NFC and
//! NFD text to the same face (issue: canonically equivalent Korean
//! NFC/NFD text selecting different fallback fonts). Terminal cell
//! contents are never rewritten; only the resolver query changes.

const std = @import("std");

/// First leading consonant (choseong) jamo, U+1100.
const l_base: u21 = 0x1100;
/// First vowel (jungseong) jamo, U+1161.
const v_base: u21 = 0x1161;
/// One before the first trailing consonant (jongseong) jamo, U+11A7.
/// Trailing index 0 means "no trailing consonant".
const t_base: u21 = 0x11A7;
/// First precomposed syllable (가), U+AC00.
const s_base: u21 = 0xAC00;
const l_count: u21 = 19;
const v_count: u21 = 21;
const t_count: u21 = 28;
const n_count: u21 = v_count * t_count; // 588
const s_count: u21 = l_count * n_count; // 11172

fn isL(cp: u21) bool {
    return cp >= l_base and cp < l_base + l_count;
}

fn isV(cp: u21) bool {
    return cp >= v_base and cp < v_base + v_count;
}

fn isT(cp: u21) bool {
    return cp > t_base and cp < t_base + t_count;
}

/// A precomposed syllable with no trailing consonant (an "LV" syllable).
fn isLV(cp: u21) bool {
    return cp >= s_base and cp < s_base + s_count and
        (cp - s_base) % t_count == 0;
}

/// Returns the precomposed Hangul syllable canonically equivalent to the
/// grapheme cluster formed by `primary` followed by `rest`, or null when
/// the cluster has no precomposed equivalent. Null covers non-Hangul
/// clusters, archaic jamo (outside the modern L/V/T ranges), partial
/// clusters such as a lone jamo, and clusters carrying any additional
/// codepoints.
pub fn composedSyllable(primary: u21, rest: []const u21) ?u21 {
    // L + V, optionally + T
    if (isL(primary)) {
        if (rest.len < 1 or rest.len > 2) return null;
        if (!isV(rest[0])) return null;
        const lv = s_base +
            (primary - l_base) * n_count +
            (rest[0] - v_base) * t_count;
        if (rest.len == 1) return lv;
        if (!isT(rest[1])) return null;
        return lv + (rest[1] - t_base);
    }

    // An already-precomposed LV syllable + T composes to LVT.
    if (isLV(primary)) {
        if (rest.len != 1) return null;
        if (!isT(rest[0])) return null;
        return primary + (rest[0] - t_base);
    }

    return null;
}

test "composedSyllable composes modern jamo clusters" {
    const testing = std.testing;

    // 회 = ᄒ + ᅬ (L + V)
    try testing.expectEqual(@as(?u21, 0xD68C), composedSyllable(0x1112, &.{0x116C}));
    // 법 = ᄇ + ᅥ + ᆸ (L + V + T)
    try testing.expectEqual(@as(?u21, 0xBC95), composedSyllable(0x1107, &.{ 0x1165, 0x11B8 }));
    // 인 = ᄋ + ᅵ + ᆫ (L + V + T)
    try testing.expectEqual(@as(?u21, 0xC778), composedSyllable(0x110B, &.{ 0x1175, 0x11AB }));
    // 법 = 버 (LV syllable) + ᆸ (T)
    try testing.expectEqual(@as(?u21, 0xBC95), composedSyllable(0xBC84, &.{0x11B8}));
}

test "composedSyllable round-trips every precomposed syllable" {
    const testing = std.testing;

    var s: u21 = s_base;
    while (s < s_base + s_count) : (s += 1) {
        const index = s - s_base;
        const l = l_base + index / n_count;
        const v = v_base + (index % n_count) / t_count;
        const t_index = index % t_count;

        if (t_index == 0) {
            try testing.expectEqual(@as(?u21, s), composedSyllable(l, &.{v}));
        } else {
            const t = t_base + t_index;
            try testing.expectEqual(@as(?u21, s), composedSyllable(l, &.{ v, t }));
            // LV + T form of the same syllable.
            try testing.expectEqual(@as(?u21, s), composedSyllable(s - t_index, &.{t}));
        }
    }
}

test "composedSyllable rejects clusters without a precomposed equivalent" {
    const testing = std.testing;

    // Lone jamo and wrong ordering.
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x1112, &.{}));
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x116C, &.{0x1112}));
    // V where T is required and vice versa.
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x1112, &.{ 0x116C, 0x116C }));
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x1112, &.{0x11B8}));
    // Archaic jamo outside the modern ranges (e.g. choseong filler).
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x115F, &.{0x1161}));
    // LVT syllable cannot take another trailing consonant.
    try testing.expectEqual(@as(?u21, null), composedSyllable(0xBC95, &.{0x11B8}));
    // Extra codepoints beyond a full LVT cluster.
    try testing.expectEqual(@as(?u21, null), composedSyllable(0x1107, &.{ 0x1165, 0x11B8, 0x11B8 }));
    // Non-Hangul cluster (e + combining acute).
    try testing.expectEqual(@as(?u21, null), composedSyllable('e', &.{0x0301}));
}
