#ifndef DESKTOP_SHARE_H_
#define DESKTOP_SHARE_H_
#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
gchar* desktop_shares_root();
gboolean desktop_queue_arguments(gchar** arguments, const gchar* cwd, GError** error);
void desktop_register_channel(FlView* view);
#endif
