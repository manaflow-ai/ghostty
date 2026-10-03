#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <crt_externs.h>
#include "ghostty.h"
int main(int argc, char **argv) {
  if (setenv("CMUX_REPRO_BEFORE_INIT", "1", 1) != 0) return 4;
  char *gargv[] = {"ghostty-env-repro", NULL};
  if (ghostty_init(1, gargv) != 0) return 2;
  ghostty_info_s info = ghostty_info();
  fprintf(stderr, "Ghostty version=%.*s\n", (int)info.version_len, info.version);
  char **before = *_NSGetEnviron();
  if (argc > 1) {
    for (int i = 0; i < 512; i++) {
      char key[80]; snprintf(key, sizeof key, "CMUX_REPRO_AFTER_INIT_%d", i);
      if (setenv(key, "controlled-test-value", 1) != 0) return 4;
    }
  }
  fprintf(stderr,"environment vector relocated=%d; mutation=%d\n",before != *_NSGetEnviron(), argc > 1);
  if (argc > 1 && before == *_NSGetEnviron()) {
    fprintf(stderr, "test requires environment vector relocation\n");
    return 5;
  }
  ghostty_config_t config = ghostty_config_new();
  if (!config) return 3;
  const char *text = "working-directory = ~/cmux-env-repro\n";
  ghostty_config_load_string(config, text, strlen(text), "env-repro");
  ghostty_config_finalize(config);
  ghostty_config_free(config);
  fprintf(stderr,"CONFIG_FINALIZE_PASSED\n");
  return 0;
}
