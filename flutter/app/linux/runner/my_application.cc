#include "my_application.h"
#include "desktop_share.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// GTK owns position policy on Wayland. Restore coordinates only on X11.
static gchar* geometry_path() {
  return g_build_filename(g_get_user_config_dir(), APPLICATION_ID, "window.ini", nullptr);
}
static gboolean save_geometry(GtkWidget* widget, GdkEvent*, gpointer) {
  GtkWindow* window = GTK_WINDOW(widget);
  gint width = 1280, height = 720, x = 0, y = 0;
  // Configure events retain normal geometry while maximized/minimized.
  auto state = static_cast<GdkRectangle*>(g_object_get_data(G_OBJECT(window), "normal-geometry"));
  if (state) { x=state->x; y=state->y; width=state->width; height=state->height; }
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_key_file_set_integer(file, "Window", "width", width);
  g_key_file_set_integer(file, "Window", "height", height);
  g_key_file_set_integer(file, "Window", "x", x);
  g_key_file_set_integer(file, "Window", "y", y);
  g_key_file_set_boolean(file, "Window", "maximized", gtk_window_is_maximized(window));
  g_autofree gchar* path = geometry_path();
  g_autofree gchar* directory = g_path_get_dirname(path);
  g_mkdir_with_parents(directory, 0700);
  // GLib writes a temporary file and renames it atomically.
  g_key_file_save_to_file(file, path, nullptr);
  return FALSE;
}
static gboolean geometry_configure(GtkWidget* widget, GdkEventConfigure*, gpointer) {
  GtkWindow* window = GTK_WINDOW(widget);
  GdkWindow* native = gtk_widget_get_window(widget);
  if (!native || (gdk_window_get_state(native) & (GDK_WINDOW_STATE_MAXIMIZED |
      GDK_WINDOW_STATE_ICONIFIED | GDK_WINDOW_STATE_FULLSCREEN))) return FALSE;
  auto state = static_cast<GdkRectangle*>(g_object_get_data(G_OBJECT(window), "normal-geometry"));
  gtk_window_get_size(window, &state->width, &state->height);
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(widget)))
    gtk_window_get_position(window, &state->x, &state->y);
#endif
  return FALSE;
}
static void restore_geometry(GtkWindow* window) {
  GdkGeometry hints{}; hints.min_width=360; hints.min_height=480;
  gtk_window_set_geometry_hints(window, nullptr, &hints, GDK_HINT_MIN_SIZE);
  auto normal = g_new0(GdkRectangle, 1);
  *normal = {0, 0, 1280, 720};
  g_object_set_data_full(G_OBJECT(window), "normal-geometry", normal, g_free);
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_autofree gchar* path = geometry_path();
  if (g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, nullptr)) {
    gint w=g_key_file_get_integer(file,"Window","width",nullptr);
    gint h=g_key_file_get_integer(file,"Window","height",nullptr);
    gint x=g_key_file_get_integer(file,"Window","x",nullptr);
    gint y=g_key_file_get_integer(file,"Window","y",nullptr);
    if (w>=360 && w<=32768 && h>=480 && h<=32768 &&
        x>=-131072 && x<=131072 && y>=-131072 && y<=131072) {
      GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
      GdkMonitor* monitor = gdk_display_get_monitor_at_point(display, x, y);
      GdkRectangle work{0,0,1280,720};
      if (monitor) gdk_monitor_get_workarea(monitor, &work);
      w=MAX(360,MIN(w,work.width)); h=MAX(480,MIN(h,work.height));
      x=MAX(work.x,MIN(x,work.x+work.width-w));
      y=MAX(work.y,MIN(y,work.y+work.height-h));
      *normal={x,y,w,h};
#ifdef GDK_WINDOWING_X11
      if (GDK_IS_X11_DISPLAY(display)) gtk_window_move(window,x,y);
#endif
    }
    if (g_key_file_get_boolean(file,"Window","maximized",nullptr)) gtk_window_maximize(window);
  }
  gtk_window_set_default_size(window,normal->width,normal->height);
  g_signal_connect(window,"configure-event",G_CALLBACK(geometry_configure),nullptr);
  g_signal_connect(window,"delete-event",G_CALLBACK(save_geometry),nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* existing = gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing) { gtk_window_present(existing); return; }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, APP_DISPLAY_NAME);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, APP_DISPLAY_NAME);
  }

  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icons = g_build_filename(directory, "share", "icons", nullptr);
    gtk_icon_theme_append_search_path(gtk_icon_theme_get_default(), icons);
  }
  gtk_window_set_icon_name(window, APP_ICON_NAME);

  restore_geometry(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  desktop_register_channel(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// GApplication forwards remote argv AND its working directory over the session bus.
static int my_application_command_line(GApplication* application, GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  int argc = 0;
  g_auto(GStrv) arguments = g_application_command_line_get_arguments(command_line, &argc);
  g_autoptr(GError) error = nullptr;
  if (!desktop_queue_arguments(arguments + 1, g_application_command_line_get_cwd(command_line), &error)) {
    g_warning("%s", error->message); return 1;
  }
  if (!self->dart_entrypoint_arguments) self->dart_entrypoint_arguments = g_strdupv(arguments + 1);
  g_application_activate(application);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
