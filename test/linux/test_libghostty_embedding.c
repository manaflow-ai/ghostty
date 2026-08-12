#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "ghostty.h"

#define ASSERT_API_SIGNATURE(name, signature)                                  \
  _Static_assert(_Generic(&(name), signature : 1, default : 0),                \
                 #name " has a stale public signature")

ASSERT_API_SIGNATURE(ghostty_surface_mouse_pos,
                     bool (*)(ghostty_surface_t, double, double,
                              ghostty_input_mods_e));
ASSERT_API_SIGNATURE(ghostty_surface_mouse_scroll,
                     bool (*)(ghostty_surface_t, double, double,
                              ghostty_input_scroll_mods_t));
ASSERT_API_SIGNATURE(ghostty_surface_ime_point,
                     bool (*)(ghostty_surface_t, double *, double *, double *,
                              double *));
ASSERT_API_SIGNATURE(ghostty_surface_request_close,
                     bool (*)(ghostty_surface_t));
ASSERT_API_SIGNATURE(ghostty_surface_split,
                     bool (*)(ghostty_surface_t,
                              ghostty_action_split_direction_e));
ASSERT_API_SIGNATURE(ghostty_surface_split_focus,
                     bool (*)(ghostty_surface_t,
                              ghostty_action_goto_split_e));
ASSERT_API_SIGNATURE(ghostty_surface_split_resize,
                     bool (*)(ghostty_surface_t,
                              ghostty_action_resize_split_direction_e,
                              uint16_t));
ASSERT_API_SIGNATURE(ghostty_surface_split_equalize,
                     bool (*)(ghostty_surface_t));
ASSERT_API_SIGNATURE(ghostty_surface_complete_clipboard_request,
                     bool (*)(ghostty_surface_t, const char *, void *, bool));
ASSERT_API_SIGNATURE(ghostty_inspector_free,
                     void (*)(ghostty_inspector_t));
ASSERT_API_SIGNATURE(ghostty_inspector_set_focus,
                     bool (*)(ghostty_inspector_t, bool));
ASSERT_API_SIGNATURE(ghostty_inspector_set_content_scale,
                     bool (*)(ghostty_inspector_t, double, double));
ASSERT_API_SIGNATURE(ghostty_inspector_set_size,
                     bool (*)(ghostty_inspector_t, uint32_t, uint32_t));
ASSERT_API_SIGNATURE(ghostty_inspector_mouse_button,
                     bool (*)(ghostty_inspector_t,
                              ghostty_input_mouse_state_e,
                              ghostty_input_mouse_button_e,
                              ghostty_input_mods_e));
ASSERT_API_SIGNATURE(ghostty_inspector_mouse_pos,
                     bool (*)(ghostty_inspector_t, double, double));
ASSERT_API_SIGNATURE(ghostty_inspector_mouse_scroll,
                     bool (*)(ghostty_inspector_t, double, double,
                              ghostty_input_scroll_mods_t));
ASSERT_API_SIGNATURE(ghostty_inspector_key,
                     bool (*)(ghostty_inspector_t, ghostty_input_action_e,
                              ghostty_input_key_e, ghostty_input_mods_e));
ASSERT_API_SIGNATURE(ghostty_inspector_text,
                     bool (*)(ghostty_inspector_t, const char *));

static int fail(const char *message) {
  fprintf(stderr, "libghostty embedding smoke test failed: %s\n", message);
  return 1;
}

typedef struct {
  atomic_uint wakeup_calls;
  atomic_uint action_calls;
} app_probe_s;

typedef struct {
  atomic_uint redraw_calls;
  atomic_uint close_calls;
} surface_probe_s;

typedef struct {
  atomic_uint write_calls;
  atomic_size_t write_len;
  char bytes[128];
} manual_io_probe_s;

static ghostty_app_t expected_action_app;

static void wakeup(void *userdata) {
  app_probe_s *probe = userdata;
  atomic_fetch_add_explicit(&probe->wakeup_calls, 1, memory_order_relaxed);
}

static bool action(ghostty_app_t app, ghostty_target_s target,
                   ghostty_action_s value) {
  (void)target;
  (void)value;
  if (app != expected_action_app) {
    return false;
  }
  app_probe_s *probe = ghostty_app_userdata(app);
  if (probe == NULL) {
    return false;
  }
  atomic_fetch_add_explicit(&probe->action_calls, 1, memory_order_relaxed);
  return true;
}

static bool read_clipboard(void *userdata, ghostty_clipboard_e clipboard,
                           void *request) {
  (void)userdata;
  (void)clipboard;
  (void)request;
  return false;
}

static void confirm_read_clipboard(void *userdata, const char *text,
                                   void *request,
                                   ghostty_clipboard_request_e type) {
  (void)userdata;
  (void)text;
  (void)request;
  (void)type;
}

static void write_clipboard(void *userdata, ghostty_clipboard_e clipboard,
                            const ghostty_clipboard_content_s *content,
                            size_t count, bool confirm) {
  (void)userdata;
  (void)clipboard;
  (void)content;
  (void)count;
  (void)confirm;
}

static void close_surface(void *userdata, bool process_alive) {
  surface_probe_s *probe = userdata;
  (void)process_alive;
  atomic_fetch_add_explicit(&probe->close_calls, 1, memory_order_relaxed);
}

static void redraw_surface(void *userdata) {
  surface_probe_s *probe = userdata;
  atomic_fetch_add_explicit(&probe->redraw_calls, 1, memory_order_relaxed);
}

static void manual_io_write(void *userdata, const char *bytes, uintptr_t len) {
  manual_io_probe_s *probe = userdata;
  const size_t copied = len < sizeof(probe->bytes) ? (size_t)len : sizeof(probe->bytes);
  memcpy(probe->bytes, bytes, copied);
  atomic_store_explicit(&probe->write_len, copied, memory_order_release);
  atomic_fetch_add_explicit(&probe->write_calls, 1, memory_order_release);
}

typedef struct {
  EGLDisplay display;
  EGLConfig config;
} gl_runtime_s;

typedef struct {
  gl_runtime_s *runtime;
  EGLSurface surface;
  EGLContext context;
  bool allow_current;
  unsigned int make_current_calls;
  unsigned int done_current_calls;
} gl_context_probe_s;

static bool make_current(void *userdata) {
  gl_context_probe_s *probe = userdata;
  probe->make_current_calls++;
  return probe->allow_current &&
         eglMakeCurrent(probe->runtime->display, probe->surface, probe->surface,
                        probe->context) == EGL_TRUE;
}

static void *get_proc_address(void *userdata, const char *name) {
  (void)userdata;
  return (void *)eglGetProcAddress(name);
}

static void done_current(void *userdata) {
  gl_context_probe_s *probe = userdata;
  probe->done_current_calls++;
  (void)eglMakeCurrent(probe->runtime->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
}

static int init_gl_runtime(gl_runtime_s *runtime) {
  memset(runtime, 0, sizeof(*runtime));
  runtime->display = EGL_NO_DISPLAY;

#ifdef EGL_PLATFORM_SURFACELESS_MESA
  runtime->display =
      eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY,
                            NULL);
#endif
  if (runtime->display == EGL_NO_DISPLAY) {
    runtime->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  }

  EGLint major = 0;
  EGLint minor = 0;
  if (runtime->display == EGL_NO_DISPLAY ||
      eglInitialize(runtime->display, &major, &minor) != EGL_TRUE ||
      eglBindAPI(EGL_OPENGL_API) != EGL_TRUE) {
    if (runtime->display != EGL_NO_DISPLAY) {
      (void)eglTerminate(runtime->display);
    }
    return fail("could not initialize a surfaceless EGL OpenGL display");
  }

  const EGLint config_attributes[] = {
      EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_RED_SIZE,     8,               EGL_GREEN_SIZE,     8,
      EGL_BLUE_SIZE,    8,               EGL_ALPHA_SIZE,     8,
      EGL_NONE,
  };
  EGLint config_count = 0;
  if (eglChooseConfig(runtime->display, config_attributes, &runtime->config, 1,
                      &config_count) != EGL_TRUE ||
      config_count != 1) {
    (void)eglTerminate(runtime->display);
    return fail("could not choose a surfaceless EGL OpenGL configuration");
  }

  return 0;
}

static void deinit_gl_runtime(gl_runtime_s *runtime) {
  if (runtime->display != EGL_NO_DISPLAY) {
    (void)eglTerminate(runtime->display);
  }
}

static int init_gl_context(gl_runtime_s *runtime,
                           gl_context_probe_s *probe) {
  memset(probe, 0, sizeof(*probe));
  probe->runtime = runtime;
  probe->surface = EGL_NO_SURFACE;
  probe->context = EGL_NO_CONTEXT;

  const EGLint surface_attributes[] = {
      EGL_WIDTH,
      640,
      EGL_HEIGHT,
      480,
      EGL_NONE,
  };
  probe->surface = eglCreatePbufferSurface(runtime->display, runtime->config,
                                           surface_attributes);
  probe->context = eglCreateContext(runtime->display, runtime->config,
                                    EGL_NO_CONTEXT, NULL);
  if (probe->surface == EGL_NO_SURFACE || probe->context == EGL_NO_CONTEXT) {
    if (probe->context != EGL_NO_CONTEXT) {
      (void)eglDestroyContext(runtime->display, probe->context);
    }
    if (probe->surface != EGL_NO_SURFACE) {
      (void)eglDestroySurface(runtime->display, probe->surface);
    }
    return fail("could not create the surfaceless EGL OpenGL context");
  }

  probe->allow_current = true;
  return 0;
}

static void deinit_gl_context(gl_context_probe_s *probe) {
  if (probe->runtime == NULL || probe->runtime->display == EGL_NO_DISPLAY) {
    return;
  }
  (void)eglMakeCurrent(probe->runtime->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
  if (probe->context != EGL_NO_CONTEXT) {
    (void)eglDestroyContext(probe->runtime->display, probe->context);
  }
  if (probe->surface != EGL_NO_SURFACE) {
    (void)eglDestroySurface(probe->runtime->display, probe->surface);
  }
}

static bool bytes_contain(const char *text, size_t text_len,
                          const char *needle) {
  const size_t needle_len = strlen(needle);
  if (text == NULL || needle_len == 0 || text_len < needle_len) {
    return false;
  }
  for (size_t i = 0; i <= text_len - needle_len; ++i) {
    if (memcmp(text + i, needle, needle_len) == 0) {
      return true;
    }
  }
  return false;
}

static void sleep_milliseconds(long milliseconds) {
  const struct timespec duration = {
      .tv_sec = milliseconds / 1000,
      .tv_nsec = (milliseconds % 1000) * 1000000,
  };
  (void)nanosleep(&duration, NULL);
}

static bool string_equals(ghostty_string_s value, const char *expected) {
  const size_t expected_len = strlen(expected);
  return value.ptr != NULL && value.len == expected_len &&
         memcmp(value.ptr, expected, expected_len) == 0;
}

static bool read_viewport_contains(ghostty_surface_t surface,
                                   const char *needle) {
  const ghostty_surface_size_s size = ghostty_surface_size(surface);
  if (size.columns == 0 || size.rows == 0) {
    return false;
  }

  const ghostty_selection_s selection = {
      .top_left =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_EXACT,
              .x = 0,
              .y = 0,
          },
      .bottom_right =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_EXACT,
              .x = size.columns - 1,
              .y = size.rows - 1,
          },
      .rectangle = false,
  };
  ghostty_text_s text = {0};
  const bool read = ghostty_surface_read_text(surface, selection, &text);
  const bool found = read && bytes_contain(text.text, text.text_len, needle);
  ghostty_surface_free_text(surface, &text);
  return found;
}

static bool read_scrollback_contains(ghostty_surface_t surface,
                                     const char *needle) {
  ghostty_text_s text = {0};
  const bool read = ghostty_surface_read_scrollback(surface, 1024 * 1024, &text);
  const bool found = read && bytes_contain(text.text, text.text_len, needle);
  ghostty_surface_free_text(surface, &text);
  return found;
}

static void print_viewport(ghostty_surface_t surface) {
  const ghostty_selection_s selection = {
      .top_left =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_TOP_LEFT,
          },
      .bottom_right =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
          },
      .rectangle = false,
  };
  ghostty_text_s text = {0};
  if (ghostty_surface_read_text(surface, selection, &text)) {
    fprintf(stderr, "live terminal viewport:\n%.*s\n", (int)text.text_len,
            text.text == NULL ? "" : text.text);
  }
  ghostty_surface_free_text(surface, &text);
}

static bool wait_for_viewport_marker(ghostty_app_t app,
                                     ghostty_surface_t surface,
                                     const char *marker) {
  for (unsigned int attempt = 0; attempt < 500; ++attempt) {
    if (!ghostty_app_tick(app) || !ghostty_surface_draw(surface)) {
      return false;
    }
    if (read_viewport_contains(surface, marker)) {
      return true;
    }
    sleep_milliseconds(10);
  }
  return false;
}

static bool wait_for_surface_title(ghostty_app_t app,
                                   ghostty_surface_t surface,
                                   const char *expected) {
  for (unsigned int attempt = 0; attempt < 500; ++attempt) {
    if (!ghostty_app_tick(app) || !ghostty_surface_draw(surface)) {
      return false;
    }

    ghostty_string_s title = ghostty_surface_title(surface);
    const bool matched = string_equals(title, expected);
    ghostty_string_free(title);
    if (matched) {
      return true;
    }

    sleep_milliseconds(10);
  }
  return false;
}

static bool select_viewport_row_containing(ghostty_surface_t surface,
                                           const char *marker) {
  const ghostty_surface_size_s size = ghostty_surface_size(surface);
  for (uint32_t row = 0; row < size.rows; ++row) {
    if (!ghostty_surface_select_viewport_rows(surface, row, row) ||
        !ghostty_surface_has_selection(surface)) {
      return false;
    }

    ghostty_text_s text = {0};
    const bool read = ghostty_surface_read_selection(surface, &text);
    const bool found = read && bytes_contain(text.text, text.text_len, marker);
    ghostty_surface_free_text(surface, &text);
    if (found) {
      return true;
    }
  }
  return false;
}

static int verify_live_terminal(ghostty_app_t app, ghostty_surface_t surface,
                                app_probe_s *app_probe,
                                surface_probe_s *surface_probe,
                                gl_context_probe_s *gl_probe) {
  static const char input_marker[] = "cmux-ghostty-input:host-input";
  static const char expected_title[] = "cmux-ghostty-title";
  bool saw_input_marker = false;
  bool saw_title = false;
  bool saw_pwd = false;
  bool saw_tty = false;
  bool saw_exit = false;

  for (unsigned int attempt = 0; attempt < 500; ++attempt) {
    if (!ghostty_app_tick(app) || !ghostty_surface_draw(surface)) {
      return fail("live terminal event-loop pump failed");
    }

    saw_input_marker = saw_input_marker ||
                       read_viewport_contains(surface, input_marker);
    ghostty_string_s title = ghostty_surface_title(surface);
    saw_title = saw_title || string_equals(title, expected_title);
    ghostty_string_free(title);

    ghostty_string_s pwd = ghostty_surface_pwd(surface);
    saw_pwd = saw_pwd || string_equals(pwd, "/tmp");
    ghostty_string_free(pwd);

    ghostty_string_s tty = ghostty_surface_tty_name(surface);
    saw_tty = saw_tty || (tty.ptr != NULL && tty.len > 0);
    ghostty_string_free(tty);

    saw_exit = saw_exit || ghostty_surface_process_exited(surface);
    const bool woke = atomic_load_explicit(&app_probe->wakeup_calls,
                                           memory_order_relaxed) > 0;
    const bool acted = atomic_load_explicit(&app_probe->action_calls,
                                            memory_order_relaxed) > 0;
    const bool redrew = atomic_load_explicit(&surface_probe->redraw_calls,
                                             memory_order_relaxed) > 0;
    if (saw_input_marker && saw_title && saw_pwd && saw_tty && saw_exit &&
        woke && acted && redrew) {
      if (atomic_load_explicit(&surface_probe->close_calls,
                               memory_order_relaxed) != 0 ||
          gl_probe->make_current_calls == 0 ||
          gl_probe->done_current_calls == 0) {
        return fail("live terminal host callback contract is inconsistent");
      }
      return 0;
    }
    sleep_milliseconds(10);
  }

  fprintf(stderr,
          "live terminal state: input=%d title=%d pwd=%d tty=%d exit=%d "
          "wakeups=%u actions=%u redraws=%u\n",
          saw_input_marker, saw_title, saw_pwd, saw_tty, saw_exit,
          atomic_load_explicit(&app_probe->wakeup_calls, memory_order_relaxed),
          atomic_load_explicit(&app_probe->action_calls, memory_order_relaxed),
          atomic_load_explicit(&surface_probe->redraw_calls,
                               memory_order_relaxed));
  print_viewport(surface);
  return fail("live terminal did not converge before timeout");
}

static int verify_concurrent_surfaces(ghostty_app_t app,
                                      ghostty_surface_t first_surface,
                                      gl_runtime_s *gl_runtime,
                                      gl_context_probe_s *first_probe) {
  static int second_surface_userdata;
  gl_context_probe_s second_probe;
  if (init_gl_context(gl_runtime, &second_probe) != 0) {
    return 1;
  }

  ghostty_surface_config_s config = ghostty_surface_config_new();
  config.platform_tag = GHOSTTY_PLATFORM_LINUX;
  config.platform.linux_gl = (ghostty_platform_linux_s){
      .userdata = &second_probe,
      .make_current = make_current,
      .get_proc_address = get_proc_address,
      .done_current = done_current,
  };
  config.userdata = &second_surface_userdata;
  config.working_directory = "/tmp";
  config.command = "exit 0";
  config.wait_after_command = true;
  config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT;

  ghostty_surface_t second_surface = ghostty_surface_new(app, &config);
  int result = 0;
  if (second_surface == NULL) {
    result = fail("could not create a second Linux embedding surface");
    goto cleanup;
  }
  if (ghostty_surface_userdata(second_surface) != &second_surface_userdata ||
      !ghostty_surface_set_size(second_surface, 480, 320) ||
      !ghostty_surface_display_realized(second_surface) ||
      !ghostty_surface_draw(second_surface)) {
    result = fail("second Linux embedding surface did not render");
    goto cleanup;
  }

  const unsigned int first_make_before = first_probe->make_current_calls;
  const unsigned int first_done_before = first_probe->done_current_calls;
  const unsigned int second_make_before = second_probe.make_current_calls;
  const unsigned int second_done_before = second_probe.done_current_calls;
  if (!ghostty_surface_draw(first_surface) ||
      first_probe->make_current_calls <= first_make_before ||
      first_probe->done_current_calls <= first_done_before ||
      second_probe.make_current_calls != second_make_before ||
      second_probe.done_current_calls != second_done_before ||
      !ghostty_surface_draw(second_surface) ||
      second_probe.make_current_calls <= second_make_before ||
      second_probe.done_current_calls <= second_done_before) {
    result = fail("Linux surfaces did not switch independent GL contexts");
    goto cleanup;
  }

  if (!ghostty_surface_display_unrealized(second_surface)) {
    result = fail("second Linux embedding surface did not unrealize");
    goto cleanup;
  }
  ghostty_surface_free(second_surface);
  second_surface = NULL;

  const unsigned int first_make_after_free = first_probe->make_current_calls;
  const unsigned int second_make_after_free = second_probe.make_current_calls;
  if (!ghostty_surface_draw(first_surface) ||
      first_probe->make_current_calls <= first_make_after_free ||
      second_probe.make_current_calls != second_make_after_free) {
    result = fail("first Linux surface did not survive second surface teardown");
  }

cleanup:
  if (second_surface != NULL) {
    (void)ghostty_surface_display_unrealized(second_surface);
    ghostty_surface_free(second_surface);
  }
  deinit_gl_context(&second_probe);
  return result;
}

static int verify_embedding_info(void) {
  const ghostty_embedding_info_s direct = ghostty_embedding_info();
  ghostty_embedding_info_s queried;
  memset(&queried, 0xA5, sizeof(queried));

  if (!ghostty_embedding_info_query(&queried, sizeof(queried))) {
    return fail("full embedding info query was rejected");
  }
  if (direct.abi_version != GHOSTTY_EMBEDDING_ABI_VERSION ||
      queried.abi_version != direct.abi_version) {
    return fail("embedding ABI version does not match the installed header");
  }
  if (direct.platform != GHOSTTY_PLATFORM_LINUX ||
      direct.renderer_backend != GHOSTTY_RENDERER_BACKEND_OPENGL ||
      !direct.supports_linux_platform || !direct.must_draw_from_app_thread) {
    return fail("library does not report the Linux OpenGL host contract");
  }
  if (direct.surface_max_env_vars != GHOSTTY_SURFACE_MAX_ENV_VARS) {
    return fail("surface environment bound does not match the header");
  }
  if (direct.runtime_config_size != sizeof(ghostty_runtime_config_s) ||
      direct.surface_config_size != sizeof(ghostty_surface_config_s) ||
      direct.platform_linux_size != sizeof(ghostty_platform_linux_s) ||
      direct.input_key_size != sizeof(ghostty_input_key_s) ||
      direct.target_size != sizeof(ghostty_target_s) ||
      direct.action_size != sizeof(ghostty_action_s) ||
      direct.ipc_target_size != sizeof(ghostty_ipc_target_s) ||
      direct.ipc_action_size != sizeof(ghostty_ipc_action_s)) {
    return fail("library and header disagree on an embedding struct size");
  }
  if (queried.layout_fingerprint != direct.layout_fingerprint ||
      queried.constants_fingerprint != direct.constants_fingerprint ||
      direct.layout_fingerprint == 0 || direct.constants_fingerprint == 0) {
    return fail("embedding fingerprints are missing or inconsistent");
  }

  ghostty_embedding_info_s prefix;
  memset(&prefix, 0xA5, sizeof(prefix));
  if (ghostty_embedding_info_query(&prefix, sizeof(prefix.abi_version))) {
    return fail("prefix query incorrectly reported a complete result");
  }
  if (prefix.abi_version != GHOSTTY_EMBEDDING_ABI_VERSION) {
    return fail("prefix query did not return the leading ABI version");
  }

  return 0;
}

static int verify_resources(void) {
  const ghostty_string_s resources = ghostty_resources_dir();
  if (resources.ptr == NULL || resources.len == 0) {
    return fail("installed runtime resources were not resolved from the DSO");
  }

  static const char suffix[] = "/shell-integration";
  if (resources.len > SIZE_MAX - sizeof(suffix)) {
    ghostty_string_free(resources);
    return fail("runtime resource path is too long");
  }

  char *path = malloc(resources.len + sizeof(suffix));
  if (path == NULL) {
    ghostty_string_free(resources);
    return fail("could not allocate runtime resource probe path");
  }
  memcpy(path, resources.ptr, resources.len);
  memcpy(path + resources.len, suffix, sizeof(suffix));

  const int accessible = access(path, R_OK);
  if (accessible != 0) {
    fprintf(stderr, "runtime resource probe failed for %s: %s\n", path,
            strerror(errno));
  }
  free(path);
  ghostty_string_free(resources);
  return accessible == 0 ? 0 : 1;
}

static int verify_config(void) {
  static const char source[] = "font-size = 13\n";
  ghostty_config_t config = ghostty_config_new();
  if (config == NULL) {
    return fail("ghostty_config_new returned null");
  }
  if (!ghostty_config_load_string(config, source, sizeof(source) - 1) ||
      !ghostty_config_finalize(config)) {
    ghostty_config_free(config);
    return fail("installed config API rejected a valid config string");
  }
  if (ghostty_config_diagnostics_count(config) != 0) {
    ghostty_config_free(config);
    return fail("valid config string produced diagnostics");
  }
  ghostty_config_free(config);
  return 0;
}

static int verify_app_and_surface(void) {
  app_probe_s app_probe = {0};
  surface_probe_s surface_probe = {0};
  manual_io_probe_s manual_probe = {0};
  ghostty_config_t config = ghostty_config_new();
  if (config == NULL || !ghostty_config_finalize(config)) {
    ghostty_config_free(config);
    return fail("could not create the embedded app config");
  }

  const ghostty_runtime_config_s runtime = {
      .userdata = &app_probe,
      .supports_selection_clipboard = true,
      .wakeup_cb = wakeup,
      .action_cb = action,
      .read_clipboard_cb = read_clipboard,
      .confirm_read_clipboard_cb = confirm_read_clipboard,
      .write_clipboard_cb = write_clipboard,
      .close_surface_cb = close_surface,
      .redraw_surface_cb = redraw_surface,
  };
  ghostty_app_t app = ghostty_app_new(&runtime, config);
  if (app == NULL) {
    ghostty_config_free(config);
    return fail("ghostty_app_new rejected a complete Linux callback table");
  }
  expected_action_app = app;
  if (ghostty_app_userdata(app) != &app_probe ||
      !ghostty_app_must_draw_from_app_thread(app) || !ghostty_app_tick(app)) {
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("embedded app runtime contract is inconsistent");
  }

  ghostty_surface_config_s invalid_surface = ghostty_surface_config_new();
  invalid_surface.platform_tag = GHOSTTY_PLATFORM_LINUX;
  if (ghostty_surface_new(app, &invalid_surface) != NULL) {
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface accepted a missing GL callback table");
  }

  gl_runtime_s gl_runtime;
  if (init_gl_runtime(&gl_runtime) != 0) {
    ghostty_app_free(app);
    ghostty_config_free(config);
    return 1;
  }
  gl_context_probe_s gl_probe;
  if (init_gl_context(&gl_runtime, &gl_probe) != 0) {
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return 1;
  }
  const ghostty_env_var_s env[] = {{
      .key = "CMUX_GHOSTTY_EMBEDDING_PROBE",
      .value = "1",
  }};
  ghostty_surface_config_s surface_config = ghostty_surface_config_new();
  surface_config.platform_tag = GHOSTTY_PLATFORM_LINUX;
  surface_config.platform.linux_gl = (ghostty_platform_linux_s){
      .userdata = &gl_probe,
      .make_current = make_current,
      .get_proc_address = get_proc_address,
      .done_current = done_current,
  };
  surface_config.userdata = &surface_probe;
  surface_config.working_directory = "/tmp";
  surface_config.command =
      "printf 'cmux-ghostty-ready\\n'; "
      "printf 'cmux-exec-deferred-prompt-first-row\\r\\n'; "
      "printf 'cmux-exec-deferred-prompt-current-row'; "
      "printf '\\033]133;P;k=i\\007\\033]133;B\\007'; "
      "printf '\\033]2;cmux-ghostty-title\\007'; "
      "IFS= read -r value; "
      "printf '\\033]133;C\\007'; "
      "printf 'cmux-ghostty-input:%s\\n' \"$value\"; exit 0";
  surface_config.env_vars = env;
  surface_config.env_var_count = sizeof(env) / sizeof(env[0]);
  surface_config.wait_after_command = true;
  surface_config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;
  static const char restored_output[] =
      "cmux-restored-scrollback-sentinel\r\n"
      "restored prompt > \r\n";
  surface_config.initial_output = restored_output;
  surface_config.initial_output_len = sizeof(restored_output) - 1;

  ghostty_surface_t surface = ghostty_surface_new(app, &surface_config);
  if (surface == NULL) {
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("could not create an unrealized Linux surface");
  }
  if (ghostty_surface_userdata(surface) != &surface_probe ||
      ghostty_surface_app(surface) != app ||
      !ghostty_surface_set_content_scale(surface, 1.25, 1.25) ||
      !ghostty_surface_set_size(surface, 640, 480) ||
      !ghostty_surface_set_focus(surface, true) ||
      !ghostty_surface_set_visible(surface, true) ||
      !ghostty_surface_refresh(surface) || !ghostty_surface_draw(surface)) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("unrealized Linux surface lifecycle contract is inconsistent");
  }

  const ghostty_surface_size_s size = ghostty_surface_size(surface);
  if (size.width_px != 640 || size.height_px != 480 || size.columns == 0 ||
      size.rows == 0 || size.cell_width_px == 0 || size.cell_height_px == 0) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface did not report its allocated terminal size");
  }

  const unsigned int make_current_before = gl_probe.make_current_calls;
  const unsigned int done_current_before = gl_probe.done_current_calls;
  gl_probe.allow_current = false;
  const bool pending_realized = ghostty_surface_display_realized(surface);
  if (!pending_realized ||
      gl_probe.make_current_calls != make_current_before + 1 ||
      gl_probe.done_current_calls != done_current_before ||
      !ghostty_surface_draw(surface) ||
      gl_probe.make_current_calls != make_current_before + 2 ||
      gl_probe.done_current_calls != done_current_before) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface did not preserve pending GL realization state");
  }

  gl_probe.allow_current = true;
  if (!ghostty_surface_draw(surface) ||
      gl_probe.make_current_calls <= make_current_before + 2 ||
      gl_probe.done_current_calls <= done_current_before) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface did not realize its OpenGL display");
  }

  if (!wait_for_viewport_marker(app, surface, "cmux-ghostty-ready")) {
    print_viewport(surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("live terminal did not produce its startup marker");
  }
  if (!wait_for_surface_title(app, surface, "cmux-ghostty-title")) {
    print_viewport(surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("live terminal did not finish its deferred prompt marker");
  }
  if (!select_viewport_row_containing(surface, "cmux-ghostty-ready") ||
      ghostty_surface_select_viewport_rows(surface, size.rows, size.rows) ||
      !ghostty_surface_clear_selection(surface) ||
      ghostty_surface_has_selection(surface)) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("viewport row selection contract is inconsistent");
  }
  if (!read_scrollback_contains(surface,
                                "cmux-restored-scrollback-sentinel")) {
    print_viewport(surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("live terminal discarded its seeded restored scrollback");
  }
  if (read_scrollback_contains(surface,
                               "cmux-exec-deferred-prompt-first-row") ||
      read_scrollback_contains(surface,
                               "cmux-exec-deferred-prompt-current-row")) {
    print_viewport(surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("exec PTY deferred multiline prompt leaked into scrollback");
  }

  static const char host_input[] = "host-input\n";
  if (!ghostty_surface_preedit(surface, "compose", sizeof("compose") - 1) ||
      !ghostty_surface_preedit(surface, NULL, 0) ||
      !ghostty_surface_text(surface, host_input, sizeof(host_input) - 1)) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface did not accept host text or preedit input");
  }

  if (verify_live_terminal(app, surface, &app_probe, &surface_probe,
                           &gl_probe) != 0) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return 1;
  }

  ghostty_surface_config_s manual_config = ghostty_surface_config_new();
  manual_config.platform_tag = GHOSTTY_PLATFORM_LINUX;
  manual_config.platform.linux_gl = (ghostty_platform_linux_s){
      .userdata = &gl_probe,
      .make_current = make_current,
      .get_proc_address = get_proc_address,
      .done_current = done_current,
  };
  manual_config.userdata = &surface_probe;
  manual_config.context = GHOSTTY_SURFACE_CONTEXT_TAB;
  manual_config.io_mode = GHOSTTY_SURFACE_IO_MANUAL;
  manual_config.io_write_cb = manual_io_write;
  manual_config.io_write_userdata = &manual_probe;
  ghostty_surface_t manual_surface = ghostty_surface_new(app, &manual_config);
  if (manual_surface == NULL ||
      !ghostty_surface_set_size(manual_surface, 640, 480) ||
      !ghostty_surface_display_realized(manual_surface)) {
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("could not create a manual IO Linux surface");
  }

  static const char manual_output[] = "cmux-manual-output\r\n";
  if (!ghostty_surface_process_output(manual_surface, manual_output,
                                      sizeof(manual_output) - 1) ||
      !wait_for_viewport_marker(app, manual_surface, "cmux-manual-output") ||
      ghostty_surface_process_exited(manual_surface)) {
    print_viewport(manual_surface);
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("manual IO surface did not render injected process output");
  }

  static const char unmarked_output[] =
      "cmux-unmarked-completed-history\r\n"
      "cmux-unmarked-active-row";
  if (!ghostty_surface_process_output(manual_surface, unmarked_output,
                                      sizeof(unmarked_output) - 1) ||
      !wait_for_viewport_marker(app, manual_surface,
                                "cmux-unmarked-active-row") ||
      !read_scrollback_contains(manual_surface,
                                "cmux-unmarked-completed-history") ||
      read_scrollback_contains(manual_surface, "cmux-unmarked-active-row")) {
    print_viewport(manual_surface);
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("unmarked active terminal row leaked into completed scrollback");
  }

  static const char deferred_multiline_prompt[] =
      "\r\n"
      "cmux-deferred-prompt-first-row\r\n"
      "\033]133;P;k=s\007"
      "cmux-deferred-prompt-continuation";
  if (!ghostty_surface_process_output(manual_surface,
                                      deferred_multiline_prompt,
                                      sizeof(deferred_multiline_prompt) - 1) ||
      !wait_for_viewport_marker(app, manual_surface,
                                "cmux-deferred-prompt-continuation") ||
      read_scrollback_contains(manual_surface,
                               "cmux-deferred-prompt-first-row") ||
      read_scrollback_contains(manual_surface,
                               "cmux-deferred-prompt-continuation")) {
    print_viewport(manual_surface);
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("deferred multiline prompt leaked into completed scrollback");
  }

  static const char resize_output[] =
      "\033]133;A;cl=line\007"
      "host prompt\r\n"
      "\033]133;P;k=s\007"
      "> \033]133;B\007"
      "run-resize-scrollback-probe\r\n"
      "\033]133;C\007"
      "cmux-resize-scrollback-sentinel\r\n"
      "\033]133;D;0\007"
      "\033]133;A;cl=line\007"
      "cmux-active-prompt-sentinel\r\n"
      "\033]133;P;k=s\007"
      "> \033]133;B\007";
  if (!ghostty_surface_process_output(manual_surface, resize_output,
                                      sizeof(resize_output) - 1) ||
      !wait_for_viewport_marker(app, manual_surface,
                                "cmux-resize-scrollback-sentinel") ||
      !read_scrollback_contains(manual_surface,
                                "cmux-resize-scrollback-sentinel") ||
      read_scrollback_contains(manual_surface,
                               "cmux-active-prompt-sentinel") ||
      !ghostty_surface_set_size(manual_surface, 160, 480) ||
      !ghostty_app_tick(app) || !ghostty_surface_draw(manual_surface) ||
      !read_scrollback_contains(manual_surface,
                                "cmux-resize-scrollback-sentinel") ||
      read_scrollback_contains(manual_surface,
                               "cmux-active-prompt-sentinel")) {
    print_viewport(manual_surface);
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("manual IO scrollback did not survive a narrow resize");
  }

  static const char manual_input[] = "manual-input";
  if (!ghostty_surface_text(manual_surface, manual_input,
                            sizeof(manual_input) - 1)) {
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("manual IO surface rejected input");
  }
  for (unsigned int attempt = 0;
       attempt < 200 &&
       atomic_load_explicit(&manual_probe.write_calls, memory_order_acquire) == 0;
       attempt++) {
    (void)ghostty_app_tick(app);
    sleep_milliseconds(1);
  }
  const size_t manual_write_len =
      atomic_load_explicit(&manual_probe.write_len, memory_order_acquire);
  if (manual_write_len != sizeof(manual_input) - 1 ||
      memcmp(manual_probe.bytes, manual_input, manual_write_len) != 0) {
    ghostty_surface_free(manual_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("manual IO surface did not deliver encoded terminal input");
  }
  ghostty_surface_free(manual_surface);

  ghostty_surface_config_s restored_config = ghostty_surface_config_new();
  restored_config.platform_tag = GHOSTTY_PLATFORM_LINUX;
  restored_config.platform.linux_gl = (ghostty_platform_linux_s){
      .userdata = &gl_probe,
      .make_current = make_current,
      .get_proc_address = get_proc_address,
      .done_current = done_current,
  };
  restored_config.userdata = &surface_probe;
  restored_config.working_directory = "/tmp";
  restored_config.initial_output = restored_output;
  restored_config.initial_output_len = sizeof(restored_output) - 1;
  restored_config.initial_width_px = 428;
  restored_config.initial_height_px = 1663;
  restored_config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT;
  ghostty_surface_t restored_surface =
      ghostty_surface_new(app, &restored_config);
  if (restored_surface == NULL) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("could not create an interactive restored Linux surface");
  }
  const ghostty_surface_size_s restored_initial_size =
      ghostty_surface_size(restored_surface);
  if (restored_initial_size.width_px != 428 ||
      restored_initial_size.height_px != 1663 ||
      !ghostty_surface_display_realized(restored_surface) ||
      !ghostty_surface_draw(restored_surface)) {
    ghostty_surface_free(restored_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("could not create an interactive restored Linux surface");
  }
  for (unsigned int attempt = 0; attempt < 100; ++attempt) {
    (void)ghostty_app_tick(app);
    (void)ghostty_surface_draw(restored_surface);
    sleep_milliseconds(10);
  }
  static const char restored_command[] =
      "printf '%s\\n' cmux-restored-live-'command'";
  ghostty_input_key_s enter_key = {
      .action = GHOSTTY_ACTION_PRESS,
      .keycode = GHOSTTY_INPUT_KEYCODE_PHYSICAL_KEY(GHOSTTY_KEY_ENTER),
  };
  if (!ghostty_surface_text(restored_surface, restored_command,
                            sizeof(restored_command) - 1) ||
      !ghostty_surface_key(restored_surface, enter_key) ||
      !wait_for_viewport_marker(app, restored_surface,
                                "cmux-restored-live-command") ||
      !read_scrollback_contains(restored_surface,
                                "cmux-restored-scrollback-sentinel") ||
      !ghostty_surface_set_size(restored_surface, 182, 1663)) {
    print_viewport(restored_surface);
    ghostty_surface_free(restored_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("interactive terminal did not preserve restored scrollback");
  }
  for (unsigned int attempt = 0; attempt < 50; ++attempt) {
    (void)ghostty_app_tick(app);
    (void)ghostty_surface_draw(restored_surface);
    sleep_milliseconds(10);
  }
  if (!read_scrollback_contains(restored_surface,
                                "cmux-restored-scrollback-sentinel") ||
      !read_scrollback_contains(restored_surface,
                                "cmux-restored-live-command")) {
    print_viewport(restored_surface);
    ghostty_surface_free(restored_surface);
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("interactive restored scrollback did not survive resize");
  }
  (void)ghostty_surface_display_unrealized(restored_surface);
  ghostty_surface_free(restored_surface);

  if (verify_concurrent_surfaces(app, surface, &gl_runtime, &gl_probe) != 0 ||
      !ghostty_surface_display_unrealized(surface) ||
      !ghostty_surface_set_renderer_realized(surface, false)) {
    ghostty_surface_free(surface);
    deinit_gl_context(&gl_probe);
    deinit_gl_runtime(&gl_runtime);
    ghostty_app_free(app);
    ghostty_config_free(config);
    return fail("Linux surface did not release its OpenGL display");
  }

  ghostty_surface_free(surface);
  deinit_gl_context(&gl_probe);
  deinit_gl_runtime(&gl_runtime);

  ghostty_app_free(app);
  ghostty_config_free(config);
  return 0;
}

int main(void) {
  if (ghostty_init(0, NULL) != 0) {
    return fail("ghostty_init failed");
  }
  if (verify_embedding_info() != 0 || verify_resources() != 0 ||
      verify_config() != 0 || verify_app_and_surface() != 0) {
    return 1;
  }

  puts("PASS: installed Linux libghostty embedding contract is usable");
  return 0;
}
