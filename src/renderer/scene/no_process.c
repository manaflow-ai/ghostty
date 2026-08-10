#include <errno.h>
#include <sys/types.h>
#include <unistd.h>

static pid_t deny_process_pid(void) {
  errno = ENOTSUP;
  return (pid_t)-1;
}

static int deny_process_int(void) {
  errno = ENOTSUP;
  return -1;
}

pid_t fork(void) {
  return deny_process_pid();
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  (void)path;
  (void)argv;
  (void)envp;
  return deny_process_int();
}

int cmux_scene_process_capabilities_fail_closed_probe(void) {
  errno = 0;
  if (deny_process_pid() != (pid_t)-1 || errno != ENOTSUP) return 1;

  errno = 0;
  if (deny_process_int() != -1 || errno != ENOTSUP) return 2;

  return 0;
}
