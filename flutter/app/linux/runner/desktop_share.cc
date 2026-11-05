#include "desktop_share.h"
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <cstring>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>

// JSON quoting on UTF-8 bytes; GLib's command-line API supplies valid UTF-8.
static std::string quote(const gchar* input) {
  std::string result = "\"";
  for (const unsigned char c : std::string(input)) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 0x20) { char escaped[7]; g_snprintf(escaped, sizeof(escaped), "\\u%04x", c); result += escaped; }
    else result += c;
  }
  return result + '"';
}

gchar* desktop_shares_root() {
#ifdef NDEBUG
  const gchar* name = "Shares";
#else
  const gchar* name = "Shares-Debug";
#endif
  return g_build_filename(g_get_user_data_dir(), APP_ICON_NAME, name, nullptr);
}

gboolean desktop_queue_arguments(gchar** arguments, const gchar* cwd, GError** error) {
  bool importing = false;
  for (gchar** a = arguments; *a; ++a) {
    if (g_str_equal(*a, "--import") || g_str_has_prefix(*a, "--import=") || g_str_equal(*a, "--quick-download")) importing = true;
  }
  if (!importing || (arguments[0] && !arguments[1] && g_str_equal(arguments[0], "--import"))) return TRUE;
  g_autofree gchar* root = desktop_shares_root();
  g_autofree gchar* directory = g_build_filename(root, "Requests", nullptr);
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "shareInbox.directory"); return FALSE;
  }
  g_autofree gchar* id = g_uuid_string_random();
  g_autofree gchar* temporary = g_strdup_printf("%s/%s.partial", directory, id);
  g_autofree gchar* ready = g_strdup_printf("%s/%s.json", directory, id);
  std::string json = "{\"version\":1,\"workingDirectory\":" + quote(cwd) + ",\"arguments\":[";
  bool first = true;
  for (gchar** a = arguments; *a; ++a) {
    if (!first) json += ',';
    first = false; json += quote(*a);
  }
  json += "]}";
  const int fd = g_open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd < 0) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "shareInbox.write"); return FALSE;
  }
  size_t offset = 0;
  bool written = true;
  while (offset < json.size()) {
    const ssize_t count = write(fd, json.data() + offset, json.size() - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { written = false; break; }
    offset += static_cast<size_t>(count);
  }
  if (fsync(fd) != 0) written = false;
  if (close(fd) != 0) written = false;
  if (!written) {
    g_unlink(temporary); g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "shareInbox.write"); return FALSE;
  }
  if (g_rename(temporary, ready) != 0) {
    g_unlink(temporary); g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "shareInbox.publish"); return FALSE;
  }
  return TRUE;
}

// 拷贝 in the viewers: the clipboard offers the file as file managers and chat apps ask for it.
enum { kUriList, kGnomeFiles };

static void clipboard_get(GtkClipboard*, GtkSelectionData* data, guint info, gpointer uri) {
  g_autofree gchar* text = info == kGnomeFiles ? g_strdup_printf("copy\n%s", static_cast<gchar*>(uri))
                                               : g_strdup_printf("%s\r\n", static_cast<gchar*>(uri));
  gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8, reinterpret_cast<const guchar*>(text),
                         static_cast<gint>(strlen(text)));
}

static void clipboard_clear(GtkClipboard*, gpointer uri) { g_free(uri); }

static gboolean copy_file(const gchar* path) {
  gchar* uri = g_filename_to_uri(path, nullptr, nullptr);
  if (uri == nullptr) return FALSE;
  static const GtkTargetEntry targets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, kUriList},
      {const_cast<gchar*>("x-special/gnome-copied-files"), 0, kGnomeFiles},
  };
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (gtk_clipboard_set_with_data(clipboard, targets, G_N_ELEMENTS(targets), clipboard_get, clipboard_clear, uri)) return TRUE;
  g_free(uri);
  return FALSE;
}

static void call_cb(FlMethodChannel*, FlMethodCall* call, gpointer) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_str_equal(fl_method_call_get_name(call), "copyFile")) {
    FlValue* path = fl_method_call_get_args(call);
    if (fl_value_get_type(path) == FL_VALUE_TYPE_STRING && copy_file(fl_value_get_string(path))) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new("copyFile.failed", nullptr, nullptr));
    }
  } else if (g_str_equal(fl_method_call_get_name(call), "getSharesRoot")) {
    g_autofree gchar* root = desktop_shares_root();
    g_autoptr(FlValue) value = fl_value_new_string(root);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

void desktop_register_channel(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "org.twimshelf/share_inbox", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, call_cb, nullptr, nullptr);
  g_object_set_data_full(G_OBJECT(view), "desktop-share-channel",
                         g_steal_pointer(&channel), g_object_unref);
}
