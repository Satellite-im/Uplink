#include "my_application.h"

int main(int argc, char** argv) {
  // Opened by the app itself to start afresh or after an update (GHOST_DESK_AGAIN, lib/desktop/desk.dart restartApp):
  // the copy that opened this one closes right after, and until it has it is still the one of its kind
  // (my_application_new, GMFB-47), which this start would only bring to the front before going. A second for it to
  // have gone.
  const gchar* again = g_getenv("GHOST_DESK_AGAIN");
  if (again != nullptr && again[0] != '\0') g_usleep(G_USEC_PER_SEC);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
