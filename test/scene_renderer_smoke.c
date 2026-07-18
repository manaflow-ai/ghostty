#include <assert.h>
#include <stdio.h>
#include <string.h>

#include <ghostty.h>
#include "scene_renderer_fixture.h"

static ghostty_scene_renderer_frame_s frames[4];
static size_t frame_count = 0;

static void renderer_event(
    void *userdata,
    ghostty_scene_renderer_event_e event,
    const ghostty_scene_renderer_frame_s *frame) {
  (void)userdata;
  if (event != GHOSTTY_SCENE_RENDERER_FRAME_READY) return;
  assert(frame != NULL);
  assert(frame_count < 4);
  frames[frame_count++] = *frame;
}

int main(int argc, char **argv) {
  assert(ghostty_init((uintptr_t)argc, argv) == GHOSTTY_SUCCESS);
  assert(ghostty_input_key_from_macos_keycode(0) == GHOSTTY_KEY_A);
  assert(ghostty_input_key_from_macos_keycode(36) == GHOSTTY_KEY_ENTER);
  assert(scene_renderer_fixture_key_from_macos_keycode(0) == GHOSTTY_KEY_A);
  assert(scene_renderer_fixture_key_from_macos_keycode(36) == GHOSTTY_KEY_ENTER);
  assert(scene_renderer_fixture_key_from_macos_keycode(UINT32_MAX) ==
         GHOSTTY_KEY_UNIDENTIFIED);

  ghostty_config_t config = ghostty_config_new();
  assert(config != NULL);
  ghostty_config_finalize(config);

  const uint8_t terminal_id[16] = {
      0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0x4c, 0xde,
      0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
  };
  const uint8_t presentation_id[16] = {
      0x20, 0x42, 0x64, 0x86, 0xa8, 0xca, 0x4e, 0xf0,
      0x90, 0x22, 0x44, 0x66, 0x88, 0xaa, 0xcc, 0xee,
  };
  scene_renderer_fixture_s scene;
  assert(scene_renderer_fixture_create(
             terminal_id,
             presentation_id,
             &scene) == 0);

  ghostty_scene_renderer_options_s renderer_options = {
      .config = config,
      .width = 800,
      .height = 320,
      .padding_mode = GHOSTTY_SCENE_RENDERER_PADDING_CONFIG,
      .content_scale = 2.0,
      .renderer_epoch = 13,
      .terminal_epoch = 7,
      .presentation_generation = 3,
      .event_callback = renderer_event,
  };
  memcpy(renderer_options.terminal_id, terminal_id, sizeof(terminal_id));
  memcpy(
      renderer_options.presentation_id,
      presentation_id,
      sizeof(presentation_id));
  ghostty_scene_renderer_status_e status = GHOSTTY_SCENE_RENDERER_INTERNAL_ERROR;
  ghostty_scene_renderer_t renderer =
      ghostty_scene_renderer_new(&renderer_options, &status);
  assert(renderer != NULL);
  assert(status == GHOSTTY_SCENE_RENDERER_SUCCESS);
  ghostty_scene_renderer_metrics_s metrics = {0};
  assert(ghostty_scene_renderer_get_metrics(renderer, &metrics) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(metrics.columns > 0);
  assert(metrics.rows > 0);
  assert(metrics.cell_width > 0);
  assert(metrics.cell_height > 0);
  assert(metrics.padding_top > 0);
  assert(metrics.padding_right > 0);
  assert(metrics.padding_bottom > 0);
  assert(metrics.padding_left > 0);
  assert(metrics.columns ==
         (800 - metrics.padding_left - metrics.padding_right) /
             metrics.cell_width);
  assert(metrics.rows ==
         (320 - metrics.padding_top - metrics.padding_bottom) /
             metrics.cell_height);
  assert(ghostty_scene_renderer_apply(
             renderer,
             scene.bytes,
             scene.len) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);

  // Triple buffering remains bounded while every exact IOSurface lease is held.
  assert(ghostty_scene_renderer_render(renderer) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(ghostty_scene_renderer_render(renderer) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(ghostty_scene_renderer_render(renderer) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(frame_count == 3);
  assert(ghostty_scene_renderer_render(renderer) ==
         GHOSTTY_SCENE_RENDERER_BUSY);

  void *surface = NULL;
  assert(ghostty_scene_renderer_borrow_iosurface(
             renderer,
             &frames[1],
             &surface) == GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(surface != NULL);
  assert(frames[1].iosurface_id != 0);

  ghostty_scene_renderer_frame_s wrong = frames[1];
  wrong.frame_sequence++;
  assert(ghostty_scene_renderer_release_frame(renderer, &wrong) ==
         GHOSTTY_SCENE_RENDERER_LEASE_MISMATCH);
  assert(ghostty_scene_renderer_release_frame(renderer, &frames[1]) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);

  // The released middle slot can be selected immediately, despite two older
  // slots still being leased.
  assert(ghostty_scene_renderer_render(renderer) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(frame_count == 4);
  assert(ghostty_scene_renderer_destroy(renderer) ==
         GHOSTTY_SCENE_RENDERER_OUTSTANDING_LEASES);
  assert(ghostty_scene_renderer_release_frame(renderer, &frames[0]) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(ghostty_scene_renderer_release_frame(renderer, &frames[2]) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(ghostty_scene_renderer_release_frame(renderer, &frames[3]) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);
  assert(ghostty_scene_renderer_destroy(renderer) ==
         GHOSTTY_SCENE_RENDERER_SUCCESS);

  scene_renderer_fixture_destroy(&scene);
  ghostty_config_free(config);
  puts("scene renderer smoke: ok");
  return 0;
}
