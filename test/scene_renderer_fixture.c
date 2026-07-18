#include "scene_renderer_fixture.h"

#include <stdbool.h>
#include <string.h>

#include <ghostty/vt.h>

int scene_renderer_fixture_create(
    const uint8_t terminal_id[16],
    const uint8_t presentation_id[16],
    uint32_t custom_shader_count,
    scene_renderer_fixture_s *out) {
  memset(out, 0, sizeof(*out));
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(
          NULL,
          &terminal,
          (GhosttyTerminalOptions){
              .cols = 40,
              .rows = 10,
              .max_scrollback = 100,
          }) != GHOSTTY_SUCCESS)
    return 1;
  static const uint8_t text[] =
      "\x1b[1;34mcmux renderer worker\x1b[0m\r\nsemantic scene";
  if (ghostty_terminal_resize(terminal, 40, 10, 20, 32) != GHOSTTY_SUCCESS) {
    ghostty_terminal_free(terminal);
    return 2;
  }
  ghostty_terminal_vt_write(terminal, text, sizeof(text) - 1);
  static const uint8_t kitty[] =
      "\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1,z=1;/wAA/w==\x1b\\";
  ghostty_terminal_vt_write(terminal, kitty, sizeof(kitty) - 1);

  GhosttyRenderSceneEncoder encoder = NULL;
  if (ghostty_render_scene_encoder_new(NULL, &encoder) !=
      GHOSTTY_RENDER_SCENE_SUCCESS) {
    ghostty_terminal_free(terminal);
    return 2;
  }
  GhosttyRenderSceneOptions options = {
      .size = sizeof(GhosttyRenderSceneOptions),
      .terminal_epoch = 7,
      .content_sequence = 11,
      .presentation_generation = 3,
      .presentation_sequence = 5,
      .canonical_kind = GHOSTTY_RENDER_SCENE_SECTION_FULL,
      .focused = true,
      .cursor_blink_visible = true,
      .custom_shader_count = custom_shader_count,
      .limits = {
          .size = sizeof(GhosttyRenderSceneLimits),
          .max_encoded_bytes = 64 * 1024 * 1024,
          .max_allocation_bytes = 128 * 1024 * 1024,
          .max_rows = 4096,
          .max_columns = 4096,
          .max_cells = 4 * 1024 * 1024,
          .max_grapheme_codepoints_per_cell = 64,
          .max_total_grapheme_codepoints = 4 * 1024 * 1024,
          .max_preedit_codepoints = 4096,
          .max_highlights = 1024 * 1024,
          .max_overlay_features = 16,
          .max_kitty_resources = 4096,
          .max_kitty_placements = 64 * 1024,
          .max_kitty_resource_bytes = 64 * 1024 * 1024,
      },
      .preedit_utf8 = (const uint8_t *)"a\xEA\xB0\x80",
      .preedit_utf8_len = 4,
  };
  memcpy(options.terminal_id, terminal_id, 16);
  memcpy(options.presentation_id, presentation_id, 16);
  GhosttyRenderSceneBuffer buffer = NULL;
  if (ghostty_render_scene_encode(encoder, terminal, &options, &buffer) !=
      GHOSTTY_RENDER_SCENE_SUCCESS) {
    ghostty_render_scene_encoder_free(encoder);
    ghostty_terminal_free(terminal);
    return 3;
  }
  out->bytes = ghostty_render_scene_buffer_data(buffer);
  out->len = ghostty_render_scene_buffer_size(buffer);
  out->terminal = terminal;
  out->encoder = encoder;
  out->buffer = buffer;
  return 0;
}

uint32_t scene_renderer_fixture_key_from_macos_keycode(uint32_t keycode) {
  return (uint32_t)ghostty_key_from_macos_keycode(keycode);
}

void scene_renderer_fixture_destroy(scene_renderer_fixture_s *fixture) {
  ghostty_render_scene_buffer_free(
      (GhosttyRenderSceneBuffer)fixture->buffer);
  ghostty_render_scene_encoder_free(
      (GhosttyRenderSceneEncoder)fixture->encoder);
  ghostty_terminal_free((GhosttyTerminal)fixture->terminal);
  memset(fixture, 0, sizeof(*fixture));
}
