// cmux fork: compile-time check that include/ghostty.h keeps the
// ghostty_surface_config_s layout pinned by the Zig test
// "embedded surface config field offsets are pinned" (src/apprt/embedded.zig),
// and that the surface constructors keep their C signatures.
//
//   cc -std=c11 -fsyntax-only -Iinclude test/embedded-abi/surface_config.c
//
// Check the other 64-bit embedders with Zig's bundled libc headers:
//
//   zig cc -target x86_64-windows-gnu -std=c11 -Iinclude \
//     -c test/embedded-abi/surface_config.c -o /tmp/surface_config.o
//
// (likewise x86_64-linux-gnu and aarch64-linux-gnu).
#include <stddef.h>
#include "ghostty.h"

#define AT(field, offset)                                              \
  _Static_assert(offsetof(ghostty_surface_config_s, field) == (offset), \
                 #field " moved")

_Static_assert(sizeof(void*) == 8, "the pinned layout is for 64-bit targets");
_Static_assert(sizeof(ghostty_surface_config_s) == 168, "size changed");
AT(platform_tag, 0);
AT(platform, 8);
AT(userdata, 48);
AT(scale_factor, 56);
AT(font_size, 64);
AT(working_directory, 72);
AT(command, 80);
AT(env_vars, 88);
AT(env_var_count, 96);
AT(initial_input, 104);
AT(wait_after_command, 112);
AT(context, 116);
AT(io_mode, 120);
AT(io_write_cb, 128);
AT(io_write_userdata, 136);
AT(renderer_event_cb, 144);
AT(pty_tee_cb, 152);
AT(pty_tee_userdata, 160);

// Signature checks: these fail to compile if a declaration changes.
static ghostty_surface_t (*const check_new)(ghostty_app_t,
                                            const ghostty_surface_config_s*) =
    ghostty_surface_new;
static ghostty_surface_t (*const check_new_with_argv)(
    ghostty_app_t,
    const ghostty_surface_config_s*,
    const char* const*,
    size_t) = ghostty_surface_new_with_argv;

int ghostty_surface_config_abi_check(void) {
  return check_new != 0 && check_new_with_argv != 0;
}
