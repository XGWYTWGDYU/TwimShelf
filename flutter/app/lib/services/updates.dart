import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/prefs.dart';
import '../l10n/l10n.dart';
import '../platform/arch.dart';
import '../platform/os.dart';

/// 检查更新, in GitHub builds only: they are built with `--dart-define=TL_UPDATE_REPO=owner/name`;
/// every other build has none and never looks. At most once a day when the app opens, or when
/// asked in Settings. iOS and iPadOS open the release page; elsewhere the release's installer
/// is downloaded, checked against the release (size, SHA-256) and started.
class Updates {
  Updates._();
  static const repo = String.fromEnvironment('TL_UPDATE_REPO');
  static bool get enabled => repo.contains('/');

  static Future<String> current() async => (await PackageInfo.fromPlatform()).version;

  /// Installer endings for this platform, preferred first; empty: the release page.
  static List<String> get _suffixes {
    if (OS.isMacOS) return const ['.dmg'];
    if (OS.isAndroid) return const ['.apk'];
    if (OS.isWindows) return const ['.msix', '.exe'];
    // an AppImage replaces itself; installed any other way, the release page
    if (OS.isLinux && OS.environment['APPIMAGE'] != null) return const ['.AppImage'];
    return const [];
  }

  static String? get _arch => currentArch();

  /// Checks off the UI isolate; null when current (or a skipped version, unless [manual]).
  static Future<UpdateInfo?> check({bool manual = false}) async {
    final p = Prefs.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!manual && now - p.updateLastCheck < const Duration(days: 1).inMilliseconds) return null;
    final version = await current();
    final suffixes = _suffixes, arch = _arch;
    final info = await coreRunAsync(() => Core.checkUpdate(repo: repo, current: version, suffixes: suffixes, arch: arch));
    p.updateLastCheck = now;
    if (info != null && !manual && p.updateSkipped == info.version) return null;
    return info;
  }

  /// When the app opens: quiet unless there is a newer release (a failure is not shown).
  static Future<void> checkOnLaunch(BuildContext context) async {
    if (!enabled) return;
    try {
      final info = await check();
      if (info != null && context.mounted) await offer(context, info);
    } catch (_) {}
  }

  /// From Settings: says when there is nothing newer, and why a check failed.
  static Future<void> checkNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(L('update.checking'))));
    try {
      final info = await check(manual: true);
      messenger.hideCurrentSnackBar();
      if (!context.mounted) return;
      if (info == null) {
        messenger.showSnackBar(SnackBar(content: Text(L('update.current', [await current()]))));
      } else {
        await offer(context, info);
      }
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(L('update.failed', ['$e']))));
    }
  }

  static Future<void> offer(BuildContext context, UpdateInfo info) async {
    final installs = info.asset_url != null;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('update.available.title', [info.version])),
        content: FutureBuilder(future: current(), builder: (c, v) => Text(L('update.available.message', [v.data ?? '']))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'skip'), child: Text(L('update.skip'))),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('update.later'))),
          FilledButton(
            key: const ValueKey('updateGo'),
            onPressed: () => Navigator.pop(c, 'go'),
            child: Text(installs ? L('update.install') : L('update.openPage')),
          ),
        ],
      ),
    );
    if (choice == 'skip') Prefs.instance.updateSkipped = info.version;
    if (choice != 'go' || !context.mounted) return;
    if (!installs) {
      final u = Uri.tryParse(info.page_url);
      if (u != null && u.scheme == 'https') await launchUrl(u, mode: LaunchMode.externalApplication);
      return;
    }
    await _install(context, info);
  }

  /// Puts a downloaded AppImage in the place of [self]. The download may be on another file
  /// system, where a rename fails: it is copied beside [self] first, and only that last step
  /// replaces the program, so a full disk leaves the old one as it was.
  @visibleForTesting
  static Future<void> replaceAppImage(String file, String self) async {
    final next = File('$self.update');
    try {
      await File(file).copy(next.path);
      final chmod = await Process.run('chmod', ['+x', next.path]);
      if (chmod.exitCode != 0) throw FileSystemException('chmod', next.path);
      await next.rename(self);
    } catch (_) {
      if (await next.exists()) await next.delete();
      rethrow;
    }
    await File(file).delete();
  }

  static Future<void> _install(BuildContext context, UpdateInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(L('update.downloading')), duration: const Duration(minutes: 10)));
    try {
      final dir = await TlNative.updatesDir() ?? '${(await getTemporaryDirectory()).path}${OS.pathSeparator}updates';
      final file = await coreRunAsync(() => Core.downloadUpdate(info, dir));
      messenger.hideCurrentSnackBar();
      if (OS.isAndroid) {
        await TlNative.installApk(file);
      } else if (OS.isMacOS) {
        await Process.run('open', [file]);
        messenger.showSnackBar(SnackBar(content: Text(L('update.opened.mac'))));
      } else if (OS.isWindows) {
        // the installer (MSIX: App Installer) takes over and replaces this version
        await Process.start('explorer.exe', [file], mode: ProcessStartMode.detached);
      } else if (OS.isLinux) {
        // an AppImage is the app: the new one takes the old one's place, then starts
        final self = OS.environment['APPIMAGE']!;
        await replaceAppImage(file, self);
        await Process.start(self, const [], mode: ProcessStartMode.detached);
        exit(0);
      }
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(L('update.failed', ['$e']))));
    }
  }
}
