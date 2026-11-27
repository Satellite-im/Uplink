// Links opened into the app on Linux (GMFB-34: "A gogho.st/add/<username> link and QR code that opens a friend
// request"). The add-me page (site/add) and the invite page (site/join) open ghostmsg:… links, which the desktop runs
// this app with (linux/packaging/ghost-messaging.desktop: MimeType=x-scheme-handler/ghostmsg, Exec … %u). The app is
// one of its kind (my_application_new, GMFB-47): a second start hands its link to the copy already running through
// the "open-link" action, over the session's bus, and goes. The copy that has the link keeps it until the app asks
// ("take"); later ones are handed over as they come ("open"), as the Mac's AppDelegate and Windows' links.cpp do.
#include "links.h"

#include <string.h>

namespace {

FlMethodChannel* g_channel = nullptr;
// Links that came before the app asked for them, and whether it has asked yet.
GPtrArray* g_pending = nullptr;
gboolean g_taken = FALSE;

// A link came: handed to the app if it has asked for links, else held until it does.
void opened(const gchar* url) {
  if (url == nullptr || url[0] == '\0') return;
  if (g_taken && g_channel != nullptr) {
    g_autoptr(FlValue) arg = fl_value_new_string(url);
    fl_method_channel_invoke_method(g_channel, "open", arg, nullptr, nullptr, nullptr);
    return;
  }
  if (g_pending == nullptr) g_pending = g_ptr_array_new_with_free_func(g_free);
  g_ptr_array_add(g_pending, g_strdup(url));
}

// "open-link" activated, here or from a second start: the link taken, and the window brought to the front where it is
// up. One not shown yet is still starting, and shows itself with its first frame.
void open_link_activated(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  if (parameter == nullptr || !g_variant_is_of_type(parameter, G_VARIANT_TYPE_STRING)) return;
  const gchar* url = g_variant_get_string(parameter, nullptr);
  if (!links_is_link(url)) return;
  opened(url);
  GList* open = gtk_application_get_windows(GTK_APPLICATION(user_data));
  if (open != nullptr) {
    GtkWindow* had = GTK_WINDOW(open->data);
    if (gtk_widget_get_visible(GTK_WIDGET(had))) gtk_window_present(had);
  }
}

void method_call(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  if (strcmp(fl_method_call_get_name(call), "take") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autoptr(FlValue) list = fl_value_new_list();
  if (g_pending != nullptr) {
    for (guint i = 0; i < g_pending->len; i++) {
      fl_value_append_take(list, fl_value_new_string(static_cast<const gchar*>(g_ptr_array_index(g_pending, i))));
    }
    g_ptr_array_set_size(g_pending, 0);
  }
  g_taken = TRUE;
  fl_method_call_respond_success(call, list, nullptr);
}

}  // namespace

gboolean links_is_link(const gchar* arg) {
  return arg != nullptr && strlen(arg) > 9 && g_ascii_strncasecmp(arg, "ghostmsg:", 9) == 0;
}

void links_add_action(GApplication* application) {
  GSimpleAction* action = g_simple_action_new(LINKS_ACTION, G_VARIANT_TYPE_STRING);
  g_signal_connect(action, "activate", G_CALLBACK(open_link_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(action));
  g_object_unref(action);
}

void links_attach(FlView* view) {
  if (g_channel != nullptr) return;
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "ghost_desktop/links", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call, nullptr, nullptr);
}
