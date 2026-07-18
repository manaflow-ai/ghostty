#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <ghostty_config.h>

static int contains(ghostty_string_s value, const char* needle) {
  const size_t needle_len = strlen(needle);
  if (value.ptr == NULL || needle_len > value.len) return 0;
  for (size_t i = 0; i + needle_len <= value.len; ++i) {
    if (memcmp(value.ptr + i, needle, needle_len) == 0) return 1;
  }
  return 0;
}

int main(int argc, char** argv) {
  assert(argc == 2);
  assert(ghostty_config_init((uintptr_t)argc, argv) == 0);
  assert(ghostty_config_init((uintptr_t)argc, argv) == 0);

  ghostty_config_t source = ghostty_config_new();
  assert(source != NULL);
  ghostty_config_load_file(source, argv[1]);
  ghostty_config_load_recursive_files(source);
  ghostty_config_finalize(source);
  assert(ghostty_config_diagnostics_count(source) == 0);
  assert(ghostty_config_get_diagnostic(source, 0).message[0] == '\0');

  ghostty_string_s snapshot = ghostty_config_serialize(source);
  ghostty_config_free(source);
  assert(snapshot.ptr != NULL);
  assert(snapshot.len > 0);
  if (!contains(snapshot, "background = #123456")) {
    fwrite(snapshot.ptr, 1, snapshot.len, stderr);
  }
  assert(contains(snapshot, "font-size = 17.5"));
  assert(contains(snapshot, "background = #123456"));
  assert(!contains(snapshot, "config-file"));

  ghostty_config_t restored = ghostty_config_new();
  assert(restored != NULL);
  ghostty_config_load_string(
      restored,
      snapshot.ptr,
      snapshot.len,
      "/tmp/ghostty-config-kit-smoke.ghostty");
  ghostty_config_finalize(restored);
  assert(ghostty_config_diagnostics_count(restored) == 0);

  ghostty_string_s roundtrip = ghostty_config_serialize(restored);
  assert(roundtrip.ptr != NULL);
  assert(contains(roundtrip, "font-size = 17.5"));
  assert(contains(roundtrip, "background = #123456"));
  ghostty_string_free(roundtrip);
  ghostty_config_free(restored);
  ghostty_string_free(snapshot);
  return 0;
}
