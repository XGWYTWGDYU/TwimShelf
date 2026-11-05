import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'setup.dart';
import 'setup_page.dart';
import 'strings.dart';

/// The Windows setup: install, uninstall — Material 3, sharp at any display scale.
///   tl_setup.exe --payload `dir`   install the program in `dir` (the setup.exe stub passes it)
///   tl_setup.exe --uninstall       from the installed copy: remove it
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // no system title bar: the page reaches the top edge and draws its own caption buttons
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  await windowManager.setResizable(false);
  final here = File(Platform.resolvedExecutable).parent.path;
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final payload = arg('--payload');
  final productFile = payload != null ? File('$payload\\..\\payload.json') : File('$here\\payload.json');
  final product = Product.fromJson(jsonDecode(productFile.readAsStringSync()) as Map<String, dynamic>);
  final mode = args.contains('--uninstall') ? Mode.uninstall : Mode.install;
  runApp(SetupApp(product: product, mode: mode, payload: payload, setupFolder: here));
}

class SetupApp extends StatelessWidget {
  const SetupApp({super.key, required this.product, required this.mode, this.payload, required this.setupFolder});
  final Product product;
  final Mode mode;
  final String? payload;
  final String setupFolder;

  @override
  Widget build(BuildContext context) {
    // Chinese and Japanese share code points but not glyphs: without a language and fonts, the
    // fonts are guessed by character (Japanese forms, uneven weights within a line)
    final system = PlatformDispatcher.instance.locale;
    final hant = system.scriptCode == 'Hant' || const ['TW', 'HK', 'MO'].contains(system.countryCode);
    final locale = switch (system.languageCode) {
      'zh' => Locale.fromSubtags(languageCode: 'zh', scriptCode: hant ? 'Hant' : 'Hans'),
      'ja' => const Locale('ja'),
      _ => const Locale('en'),
    };
    final fonts = switch (locale.languageCode) {
      'ja' => const ['Yu Gothic UI', 'Meiryo UI', 'Microsoft YaHei UI'],
      _ when hant => const ['Microsoft JhengHei UI', 'Microsoft YaHei UI', 'Yu Gothic UI'],
      _ => const ['Microsoft YaHei UI', 'Microsoft JhengHei UI', 'Yu Gothic UI'],
    };
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          fontFamilyFallback: fonts,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D6DCC), brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.vibrant),
        );
    return MaterialApp(
      title: product.name,
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ja'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: SetupPage(product: product, mode: mode, payload: payload, setupFolder: setupFolder, strings: S.of(system)),
    );
  }
}

