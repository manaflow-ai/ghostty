/**
 * @file render_scene.h
 *
 * Bounded semantic terminal scenes for process-independent rendering.
 */

#ifndef GHOSTTY_VT_RENDER_SCENE_H
#define GHOSTTY_VT_RENDER_SCENE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup render_scene Semantic Render Scene
 *
 * Captures Ghostty's canonical terminal semantics into the same deterministic
 * wire format consumed by an out-of-process Ghostty renderer. The wire bytes
 * contain no pointers, PTY handles, parser state, or GPU objects.
 *
 * @{
 */

/** Canonical section emitted by a render-scene capture. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Refer to the encoder's exact cached canonical scene. */
  GHOSTTY_RENDER_SCENE_SECTION_UNCHANGED = 0,

  /** Emit a complete canonical snapshot and replace the cached base. */
  GHOSTTY_RENDER_SCENE_SECTION_FULL = 1,

  /** Emit a delta from the exact cached canonical base, then replace it. */
  GHOSTTY_RENDER_SCENE_SECTION_DELTA = 2,
  GHOSTTY_RENDER_SCENE_SECTION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderSceneSectionKind;

/** Presentation-local highlight semantics supplied by the daemon. */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_RENDER_SCENE_HIGHLIGHT_SEARCH_MATCH = 0,
  GHOSTTY_RENDER_SCENE_HIGHLIGHT_SEARCH_MATCH_SELECTED = 1,
  GHOSTTY_RENDER_SCENE_HIGHLIGHT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderSceneHighlightKind;

/** One inclusive retained-row highlight range. */
typedef struct GhosttyRenderSceneHighlight {
  uint64_t start_row;
  uint32_t start_column;
  uint64_t end_row;
  uint32_t end_column;
  GhosttyRenderSceneHighlightKind kind;
} GhosttyRenderSceneHighlight;

/** Result of a semantic render-scene operation. */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_RENDER_SCENE_SUCCESS = 0,
  GHOSTTY_RENDER_SCENE_INVALID_VALUE = 1,
  GHOSTTY_RENDER_SCENE_OUT_OF_MEMORY = 2,
  GHOSTTY_RENDER_SCENE_LIMIT_EXCEEDED = 3,
  GHOSTTY_RENDER_SCENE_UNSUPPORTED_KITTY_IMAGES = 4,
  GHOSTTY_RENDER_SCENE_UNSUPPORTED_CUSTOM_SHADERS = 5,
  GHOSTTY_RENDER_SCENE_REQUIRES_FULL_SNAPSHOT = 6,
  GHOSTTY_RENDER_SCENE_INTERNAL_ERROR = 7,
  GHOSTTY_RENDER_SCENE_STATUS_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderSceneStatus;

/** Hard limits applied to capture, allocation, and wire encoding. */
typedef struct GhosttyRenderSceneLimits {
  /** Set to sizeof(GhosttyRenderSceneLimits). */
  size_t size;
  size_t max_encoded_bytes;
  size_t max_allocation_bytes;
  uint32_t max_rows;
  uint32_t max_columns;
  size_t max_cells;
  size_t max_grapheme_codepoints_per_cell;
  size_t max_total_grapheme_codepoints;
  size_t max_preedit_codepoints;
  size_t max_highlights;
  size_t max_overlay_features;
  size_t max_kitty_resources;
  size_t max_kitty_frames;
  size_t max_kitty_placements;
  size_t max_kitty_resource_bytes;
} GhosttyRenderSceneLimits;

/** Caller-owned identity, sequencing, presentation, and limit inputs. */
typedef struct GhosttyRenderSceneOptions {
  /** Set to sizeof(GhosttyRenderSceneOptions). */
  size_t size;
  uint8_t terminal_id[16];
  uint64_t terminal_epoch;
  uint64_t content_sequence;
  uint8_t presentation_id[16];
  uint64_t presentation_generation;
  uint64_t presentation_sequence;
  GhosttyRenderSceneSectionKind canonical_kind;
  bool focused;
  bool cursor_blink_visible;
  /**
   * Number of custom shaders in the presentation's resolved renderer config.
   * Shader paths and source are renderer resources and are not embedded in the
   * terminal scene. A nonzero value negotiates the custom-shader capability.
   */
  uint32_t custom_shader_count;
  GhosttyRenderSceneLimits limits;
  /**
   * Optional presentation-local IME marked text, borrowed only for encode.
   *
   * The bytes must be valid UTF-8. NULL with a zero length means no preedit.
   * Ghostty derives cell widths with its Unicode tables. The terminal cursor
   * encoded in the presentation is the preedit caret anchor, matching the
   * in-process renderer's behavior.
   */
  const uint8_t *preedit_utf8;
  size_t preedit_utf8_len;
  /** AppKit-selected UTF-16 range inside preedit_utf8. */
  uint32_t preedit_selection_start_utf16;
  uint32_t preedit_selection_length_utf16;
  /** UTF-16 insertion caret inside preedit_utf8. */
  uint32_t preedit_caret_utf16;
  /** Daemon-derived search highlights, borrowed only for encode. */
  const GhosttyRenderSceneHighlight *presentation_highlights;
  size_t presentation_highlights_len;
} GhosttyRenderSceneOptions;

/** Create an encoder with no cached canonical base. */
GHOSTTY_API GhosttyRenderSceneStatus ghostty_render_scene_encoder_new(
    const GhosttyAllocator *allocator,
    GhosttyRenderSceneEncoder *out_encoder);

/** Free an encoder and its cached canonical base. */
GHOSTTY_API void ghostty_render_scene_encoder_free(
    GhosttyRenderSceneEncoder encoder);

/** Drop the cached canonical base. The next changed scene must be full. */
GHOSTTY_API void ghostty_render_scene_encoder_reset(
    GhosttyRenderSceneEncoder encoder);

/**
 * Capture and encode one immutable semantic render-scene update.
 *
 * Terminal identity/epoch/sequence and presentation
 * identity/generation/sequence are used exactly as supplied by the caller.
 * Scrollbar and row-space facts are derived from the Ghostty terminal.
 */
GHOSTTY_API GhosttyRenderSceneStatus ghostty_render_scene_encode(
    GhosttyRenderSceneEncoder encoder,
    GhosttyTerminal terminal,
    const GhosttyRenderSceneOptions *options,
    GhosttyRenderSceneBuffer *out_buffer);

/** Borrow the immutable wire bytes until the buffer is freed. */
GHOSTTY_API const uint8_t *ghostty_render_scene_buffer_data(
    GhosttyRenderSceneBuffer buffer);

/** Return the immutable wire byte count. */
GHOSTTY_API size_t ghostty_render_scene_buffer_size(
    GhosttyRenderSceneBuffer buffer);

/** Free an immutable wire buffer. */
GHOSTTY_API void ghostty_render_scene_buffer_free(
    GhosttyRenderSceneBuffer buffer);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_RENDER_SCENE_H */
