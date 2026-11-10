import 'dart:convert';
import 'dart:io';

import '../app/identity.g.dart';
import 'os.dart';

/// Labels are supplied from assets/l10n catalogs by the packager or runtime.
String desktopEntry(
  String executable,
  Map<String, String> labels, {
  String icon = desktopId,
  String applicationId = desktopId,
}) {
  if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(applicationId)) {
    throw ArgumentError.value(applicationId);
  }
  if (executable.contains(RegExp(r'[=\r\n\x00]'))) {
    throw ArgumentError.value(executable);
  }
  final quoted = executable
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('`', '\\`')
      .replaceAll(r'$', r'\$')
      .replaceAll('%', '%%')
      .replaceAll('\\', '\\\\');
  String value(String text) => text
      .replaceAll('\\', '\\\\')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  // "open with" for pictures and videos: the share setting of config.yaml (passed by build.sh)
  const share = bool.fromEnvironment('TL_SHARE', defaultValue: true);
  return '''[Desktop Entry]
Type=Application
Name=${value(labels['en']!)}
Name[ja]=${value(labels['ja']!)}
Name[zh]=${value(labels['zh-Hans']!)}
Name[zh_CN]=${value(labels['zh-Hans']!)}
Name[zh_SG]=${value(labels['zh-Hans']!)}
Name[zh_TW]=${value(labels['zh-Hant']!)}
Name[zh_HK]=${value(labels['zh-Hant']!)}
Name[zh_MO]=${value(labels['zh-Hant']!)}
Exec="$quoted" --import %F
Terminal=false
Icon=${value(icon)}
Categories=Graphics;AudioVideo;
StartupWMClass=$applicationId
Actions=download;
${share ? '' : '#'}MimeType=image/jpeg;image/png;image/gif;image/webp;image/avif;image/heic;image/heif;image/tiff;image/bmp;video/mp4;video/quicktime;video/webm;video/x-matroska;video/x-msvideo;video/mpeg;

[Desktop Action download]
Name=${value(labels['download.en'] ?? labels['en']!)}
Name[ja]=${value(labels['download.ja'] ?? labels['ja']!)}
Name[zh]=${value(labels['download.zh-Hans'] ?? labels['zh-Hans']!)}
Name[zh_CN]=${value(labels['download.zh-Hans'] ?? labels['zh-Hans']!)}
Name[zh_SG]=${value(labels['download.zh-Hans'] ?? labels['zh-Hans']!)}
Name[zh_TW]=${value(labels['download.zh-Hant'] ?? labels['zh-Hant']!)}
Name[zh_HK]=${value(labels['download.zh-Hant'] ?? labels['zh-Hant']!)}
Name[zh_MO]=${value(labels['download.zh-Hant'] ?? labels['zh-Hant']!)}
Exec="$quoted" --quick-download
''';
}

Future<Map<String, String>> _labels(Directory catalogs, String app) async {
  final labels = <String, String>{};
  for (final language in ['en', 'ja', 'zh-Hans', 'zh-Hant']) {
    final data = jsonDecode(
      await File('${catalogs.path}/$language.json').readAsString(),
    ) as Map;
    labels[language] = (data['share.title'] as String).replaceAll('{app}', app);
    labels['download.$language'] = data['shortcut.downloadPosts'] as String;
  }
  return labels;
}

Future<void> installDesktopEntry() async {
  // an AppImage runs from a mount that changes every start: the entry starts the AppImage file
  final appImage = OS.environment['APPIMAGE'];
  final program = File(OS.resolvedExecutable).absolute.path;
  final executable = appImage ?? program;
  final catalogs = Directory(
    '${File(program).parent.path}/data/flutter_assets/assets/l10n',
  );
  final home = OS.environment['HOME'];
  final data =
      OS.environment['XDG_DATA_HOME'] ??
      (home == null ? null : '$home/.local/share');
  if (data == null) return;
  const release =
      bool.fromEnvironment('dart.vm.product') ||
      bool.fromEnvironment('dart.vm.profile');
  const applicationId = release ? desktopId : '$desktopId.debug';
  final entry = File('$data/applications/$applicationId.desktop');
  var icon = '${File(program).parent.path}/share/icons/hicolor/512x512/apps/$desktopId.png';
  if (appImage != null) {
    // the icon leaves the mount too, beside the other users' icons
    final kept = File('$data/icons/hicolor/512x512/apps/$applicationId.png');
    await kept.parent.create(recursive: true);
    await File(icon).copy(kept.path);
    icon = kept.path;
  }
  await entry.parent.create(recursive: true);
  final temporary = File('${entry.path}.$pid.partial');
  await temporary.writeAsString(
    desktopEntry(
      executable,
      await _labels(catalogs, appName),
      applicationId: applicationId,
      icon: icon,
    ),
    flush: true,
  );
  await temporary.rename(entry.path);
  try {
    await Process.run('update-desktop-database', [entry.parent.path]);
  } on ProcessException {
    // Minimal desktops may not ship the MIME cache tool; the entry still works.
  }
}

/// "Uninstalling" an AppImage is deleting the file; this takes its menu entry and icon away too.
Future<void> removeDesktopEntry() async {
  final home = OS.environment['HOME'];
  final data = OS.environment['XDG_DATA_HOME'] ?? (home == null ? null : '$home/.local/share');
  if (data == null) return;
  for (final id in [desktopId, '$desktopId.debug']) {
    for (final f in [File('$data/applications/$id.desktop'), File('$data/icons/hicolor/512x512/apps/$id.png')]) {
      if (await f.exists()) await f.delete();
    }
  }
}

/// Also used by Linux CMake, with the SDK's Dart executable.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    throw ArgumentError('catalog-directory output executable app-name');
  }
  await File(arguments[1]).writeAsString(
    desktopEntry(arguments[2], await _labels(Directory(arguments[0]), arguments[3])),
  );
}
