import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app/app_lock.dart';
import 'app/library.dart';
import 'app/prefs.dart';
import 'platform/apple_platform.dart';
import 'platform/data_home.dart';
import 'platform/quick_action.dart';
import 'screens/data_home_page.dart';
import 'screens/share_sheet_app.dart';
import 'platform/desktop_window.dart';
import 'app/shell.dart';
import 'l10n/app_locale.dart';
import 'l10n/l10n.dart';

/// Android's share page, on its own see-through window over the app that shared.
@pragma('vm:entry-point')
Future<void> shareSheetMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await L10n.load();
  await Prefs.load();
  runApp(ShareSheetApp(id: args[0], root: args[1], theme: (b, system) => appTheme(b, system: system)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await L10n.load();
  // Windows, Linux: everything lives in the data folder the person chose (asked on first start)
  if (DataHome.locate()) return _start();
  runApp(MaterialApp(
    locale: AppLocale.current,
    supportedLocales: AppLocale.supported,
    localizationsDelegates: AppLocale.delegates,
    theme: ThemeData(useMaterial3: true, fontFamilyFallback: AppLocale.fontFallback, colorScheme: ColorScheme.fromSeed(seedColor: defaultSeed)),
    darkTheme: ThemeData(useMaterial3: true, fontFamilyFallback: AppLocale.fontFallback, colorScheme: ColorScheme.fromSeed(seedColor: defaultSeed, brightness: Brightness.dark)),
    debugShowCheckedModeBanner: false,
    home: DataHomeSetupPage(onReady: _start),
  ));
}

Future<void> _start() async {
  await Prefs.load();
  AppLock.instance.start();
  await DesktopWindow.setUp();
  ApplePlatform.instance.watch();
  // a platform that fails here only goes without the shortcut
  QuickAction.start().catchError((Object e) => debugPrint('quick action: $e'));
  runApp(const TwimShelfApp());
}


/// Material 3 throughout, from the chosen colour (vivid rather than greyed surfaces), the
/// system's on Android 12+ when none is chosen.
ThemeData appTheme(Brightness b, {ColorScheme? system}) {
  final seed = Prefs.instance.seedColor;
  final scheme = seed == null && system != null
      ? system.harmonized()
      : schemeOf(seed == null ? defaultSeed : Color(seed), b);
  return ThemeData(
      useMaterial3: true,
      fontFamilyFallback: AppLocale.fontFallback,
      colorScheme: scheme,
      // messages float above the content (a bar along the bottom would cover 整理's buttons)
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 420),
      // Material 3 Expressive's shape scale: rounder menus (16), cards (20), sheets and
      // dialogs (28); menus open quickly and all at once
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        menuPadding: const EdgeInsets.all(6),
        color: scheme.surfaceContainer,
        elevation: 3,
      ),
      // dropdowns' menus too
      dropdownMenuTheme: DropdownMenuThemeData(menuStyle: MenuStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
      menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
      cardTheme: CardThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
      bottomSheetTheme: const BottomSheetThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28)))),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );
}

/// A list ends where it ends: Android's overscroll stretches the page out of shape.
class _NoStretch extends MaterialScrollBehavior {
  const _NoStretch();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

class TwimShelfApp extends StatefulWidget {
  const TwimShelfApp({super.key});

  @override
  State<TwimShelfApp> createState() => _TwimShelfAppState();
}

class _TwimShelfAppState extends State<TwimShelfApp> {
  late final Future<LibraryModel> _library = LibraryModel.open();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Prefs.instance,
        builder: (context, _) => DynamicColorBuilder(
          // the wallpaper's colours on Android 12+ (only there: elsewhere the chosen colour)
          builder: (light, dark) => _app(Platform.isAndroid ? light : null, Platform.isAndroid ? dark : null),
        ),
      );

  Widget _app(ColorScheme? light, ColorScheme? dark) => MaterialApp(
        title: 'TwimShelf', // the product name, not translated
        theme: appTheme(Brightness.light, system: light),
        darkTheme: appTheme(Brightness.dark, system: dark),
        themeMode: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][Prefs.instance.brightness.clamp(0, 2)],
        debugShowCheckedModeBanner: false,
        scrollBehavior: const _NoStretch(),
        locale: AppLocale.current,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: AppLocale.delegates,
        builder: (context, child) => AppLockGate(lock: AppLock.instance, child: child!),
        home: FutureBuilder<LibraryModel>(
          future: _library,
          builder: (context, snap) {
            if (snap.hasError) {
              return Scaffold(body: Center(child: Text(L('app.openFailed'))));
            }
            final lib = snap.data;
            if (lib == null) {
              return Scaffold(
                body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(L('app.opening')),
                ])),
              );
            }
            return Shell(library: lib);
          },
        ),
      );
}
