#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

#include <string>

#include "my_application.h"

// media_kit loads libmpv by name, which would find a system copy first.
// Point it at the one shipped in the bundle's lib directory.
static void use_bundled_libmpv() {
  if (getenv("LIBMPV_LIBRARY_PATH") != nullptr) return;
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return;
  exe[n] = '\0';
  std::string path(exe);
  path = path.substr(0, path.rfind('/')) + "/lib/libmpv.so.2";
  if (access(path.c_str(), R_OK) == 0) {
    setenv("LIBMPV_LIBRARY_PATH", path.c_str(), 1);
  }
}

int main(int argc, char** argv) {
  use_bundled_libmpv();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
