// Ghostty configuration API for isolated daemon processes.
#ifndef GHOSTTY_CONFIG_H
#define GHOSTTY_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
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

typedef struct {
  const char* message;
} ghostty_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

// Initialize process-global config state. This function is idempotent.
GHOSTTY_API int ghostty_config_init(uintptr_t argc, char** argv);

GHOSTTY_API ghostty_config_t ghostty_config_new(void);
GHOSTTY_API void ghostty_config_free(ghostty_config_t config);

// Load the standard XDG and macOS Application Support config locations.
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t config);

// Load one explicit config file. The path must be absolute and null-terminated.
GHOSTTY_API void ghostty_config_load_file(
    ghostty_config_t config,
    const char* absolute_path);

// Load config bytes with an absolute synthetic path for diagnostics and
// relative path expansion.
GHOSTTY_API void ghostty_config_load_string(
    ghostty_config_t config,
    const char* contents,
    uintptr_t contents_len,
    const char* synthetic_path);

// Load every config-file directive collected by earlier load operations.
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t config);

GHOSTTY_API void ghostty_config_finalize(ghostty_config_t config);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t config);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(
    ghostty_config_t config,
    uint32_t index);

// Serialize resolved values as parseable overrides. Config-source keys are
// omitted so a consumer cannot reopen the original files. The returned bytes
// remain valid after the config is mutated or freed and must be released with
// ghostty_string_free.
GHOSTTY_API ghostty_string_s ghostty_config_serialize(
    ghostty_config_t config);
GHOSTTY_API void ghostty_string_free(ghostty_string_s value);

#ifdef __cplusplus
}
#endif

#endif
