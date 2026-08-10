// Ghostty semantic-scene renderer API for isolated renderer workers.
#ifndef GHOSTTY_SCENE_H
#define GHOSTTY_SCENE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef GHOSTTY_API
#if defined(GHOSTTY_STATIC)
#define GHOSTTY_API
#elif defined(_WIN32) || defined(_WIN64)
#ifdef GHOSTTY_BUILD_SHARED
#define GHOSTTY_API __declspec(dllexport)
#else
#define GHOSTTY_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define GHOSTTY_API __attribute__((visibility("default")))
#else
#define GHOSTTY_API
#endif
#endif

typedef void* ghostty_config_t;
typedef void* ghostty_scene_renderer_t;

typedef struct {
  const char* message;
} ghostty_diagnostic_s;

typedef enum {
  GHOSTTY_SCENE_RENDERER_SUCCESS = 0,
  GHOSTTY_SCENE_RENDERER_INVALID_ARGUMENT = 1,
  GHOSTTY_SCENE_RENDERER_UNSUPPORTED = 2,
  GHOSTTY_SCENE_RENDERER_OUT_OF_MEMORY = 3,
  GHOSTTY_SCENE_RENDERER_INVALID_SCENE = 4,
  GHOSTTY_SCENE_RENDERER_REPLAY_REJECTED = 5,
  GHOSTTY_SCENE_RENDERER_UNSUPPORTED_CAPABILITY = 6,
  GHOSTTY_SCENE_RENDERER_LIMIT_EXCEEDED = 7,
  GHOSTTY_SCENE_RENDERER_NO_SCENE = 8,
  GHOSTTY_SCENE_RENDERER_BUSY = 9,
  GHOSTTY_SCENE_RENDERER_LEASE_MISMATCH = 10,
  GHOSTTY_SCENE_RENDERER_GPU_ERROR = 11,
  GHOSTTY_SCENE_RENDERER_OUTSTANDING_LEASES = 12,
  GHOSTTY_SCENE_RENDERER_INTERNAL_ERROR = 13,
} ghostty_scene_renderer_status_e;

typedef enum {
  GHOSTTY_SCENE_RENDERER_FRAME_READY = 1,
  GHOSTTY_SCENE_RENDERER_HEALTHY = 2,
  GHOSTTY_SCENE_RENDERER_UNHEALTHY = 3,
} ghostty_scene_renderer_event_e;

typedef enum {
  GHOSTTY_SCENE_RENDERER_PADDING_EXPLICIT = 0,
  GHOSTTY_SCENE_RENDERER_PADDING_CONFIG = 1,
} ghostty_scene_renderer_padding_mode_e;

typedef struct {
  uint64_t renderer_epoch;
  uint8_t terminal_id[16];
  uint64_t terminal_epoch;
  uint64_t content_sequence;
  uint8_t presentation_id[16];
  uint64_t presentation_generation;
  uint64_t presentation_sequence;
  uint64_t frame_sequence;
  uint32_t iosurface_id;
  uint32_t width;
  uint32_t height;
} ghostty_scene_renderer_frame_s;

typedef void (*ghostty_scene_renderer_event_cb)(
    void* userdata,
    ghostty_scene_renderer_event_e event,
    const ghostty_scene_renderer_frame_s* frame);

typedef struct {
  ghostty_config_t config;
  uint32_t width;
  uint32_t height;
  uint32_t padding_top;
  uint32_t padding_right;
  uint32_t padding_bottom;
  uint32_t padding_left;
  ghostty_scene_renderer_padding_mode_e padding_mode;
  double content_scale;
  uint64_t renderer_epoch;
  uint8_t terminal_id[16];
  uint64_t terminal_epoch;
  uint8_t presentation_id[16];
  uint64_t presentation_generation;
  size_t max_scene_bytes;
  size_t max_allocation_bytes;
  void* userdata;
  ghostty_scene_renderer_event_cb event_callback;
} ghostty_scene_renderer_options_s;

typedef struct {
  uint32_t columns;
  uint32_t rows;
  uint32_t cell_width;
  uint32_t cell_height;
  uint32_t padding_top;
  uint32_t padding_right;
  uint32_t padding_bottom;
  uint32_t padding_left;
} ghostty_scene_renderer_metrics_s;

typedef struct {
  uint32_t width;
  uint32_t height;
  uint32_t padding_top;
  uint32_t padding_right;
  uint32_t padding_bottom;
  uint32_t padding_left;
  uint64_t renderer_epoch;
  uint8_t terminal_id[16];
  uint64_t terminal_epoch;
  uint8_t presentation_id[16];
  uint64_t presentation_generation;
} ghostty_scene_renderer_configure_s;

GHOSTTY_API int ghostty_scene_init(uintptr_t argc, char** argv);

GHOSTTY_API ghostty_config_t ghostty_config_new(void);
GHOSTTY_API void ghostty_config_free(ghostty_config_t config);
GHOSTTY_API void ghostty_config_load_string(
    ghostty_config_t config,
    const char* contents,
    uintptr_t contents_len,
    const char* synthetic_path);
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t config);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t config);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(
    ghostty_config_t config,
    uint32_t index);

GHOSTTY_API ghostty_scene_renderer_t ghostty_scene_renderer_new(
    const ghostty_scene_renderer_options_s* options,
    ghostty_scene_renderer_status_e* status);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_destroy(
    ghostty_scene_renderer_t renderer);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_configure(
    ghostty_scene_renderer_t renderer,
    const ghostty_scene_renderer_configure_s* configure);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_get_metrics(
    ghostty_scene_renderer_t renderer,
    ghostty_scene_renderer_metrics_s* metrics);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_apply(
    ghostty_scene_renderer_t renderer,
    const uint8_t* scene,
    size_t scene_len);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_render(
    ghostty_scene_renderer_t renderer);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_should_animate(
    ghostty_scene_renderer_t renderer,
    bool visible,
    bool* result);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_borrow_iosurface(
    ghostty_scene_renderer_t renderer,
    const ghostty_scene_renderer_frame_s* frame,
    void** iosurface);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_retain_iosurface(
    ghostty_scene_renderer_t renderer,
    const ghostty_scene_renderer_frame_s* frame,
    void** iosurface);
GHOSTTY_API void ghostty_scene_renderer_release_retained_iosurface(void* iosurface);
GHOSTTY_API ghostty_scene_renderer_status_e ghostty_scene_renderer_release_frame(
    ghostty_scene_renderer_t renderer,
    const ghostty_scene_renderer_frame_s* frame);

#ifdef __cplusplus
}
#endif

#endif
