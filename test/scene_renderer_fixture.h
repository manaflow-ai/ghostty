#ifndef GHOSTTY_SCENE_RENDERER_FIXTURE_H
#define GHOSTTY_SCENE_RENDERER_FIXTURE_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  const uint8_t *bytes;
  size_t len;
  void *terminal;
  void *encoder;
  void *buffer;
} scene_renderer_fixture_s;

int scene_renderer_fixture_create(
    const uint8_t terminal_id[16],
    const uint8_t presentation_id[16],
    uint32_t custom_shader_count,
    scene_renderer_fixture_s *out);
uint32_t scene_renderer_fixture_key_from_macos_keycode(uint32_t keycode);
void scene_renderer_fixture_destroy(scene_renderer_fixture_s *fixture);

#endif
