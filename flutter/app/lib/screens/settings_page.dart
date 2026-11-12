import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/app_lock.dart';
import '../actions/search_export.dart';
import '../app/library.dart';
import '../app/prefs.dart';
import '../app/shell.dart';
import '../l10n/l10n.dart';
import '../mascot/mascot.dart';
import '../platform/secrets.dart';
import '../platform/data_home.dart';
import '../services/updates.dart';
import '../widgets/choice_menu.dart';
import 'data_home_page.dart';
import 'settings/about_page.dart';
import 'settings/ai_page.dart';
import 'settings/downloads_page.dart';
import 'settings/extension_page.dart';
import '../services/extension_receiver.dart';
import 'settings/storage_page.dart';
import 'settings/sync_page.dart';
import 'settings/tags_page.dart';
import 'settings/transfer_page.dart';
import '../app/jobs.dart';
import '../widgets/text_menu.dart';
import '../platform/os.dart';
import '../widgets/haptics.dart';

/// 设置, in the native app's sections: the library's counts, content (import and backup, tags,
/// the account cookies) and clearing everything. Checking the media and the diagnostics are on
/// the about page, behind ten taps on the icon.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.library, this.layout = ShellLayout.sidebar});
  final LibraryModel library;
  /// The window's layout: 整理 mode is offered only at a phone's width.
  final ShellLayout layout;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  LibraryModel get library => widget.library;

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 导出诊断信息: errors and numbers only (no pictures, text, tag names or cookies), as native.
  Future<void> _exportDiagnostics() async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final out = await outputPath(L('settings.diagnostics.fileName', ['${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}']));
    if (out == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(L('settings.diagnostics.collecting'))));
    try {
      await Core.exportDiagnosticsAsync(out, {
        'platform': OS.operatingSystem,
        'os_version': OS.operatingSystemVersion,
        'flutter': true,
        'exported_at': now.toUtc().toIso8601String(),
        'prefs': {'headphones_only': Prefs.instance.headphonesOnly, 'auto_tag': library.aiModels.autoTag, 'has_tagger': library.aiModels.activeTaggerId != null},
      });
      messenger.hideCurrentSnackBar();
      await deliver(out);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }


  Future<void> _wipe() async {
    final word = L('settings.wipe.word');
    final typed = TextEditingController();
    var models = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(L('settings.wipe.title')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(L('settings.wipe.message') + (models ? L('settings.wipe.modelsToo') : '')),
            const SizedBox(height: 12),
            Text(L('settings.wipe.typeToConfirm', [word])),
            TextField(contextMenuBuilder: appTextMenu, controller: typed, autofocus: true, onChanged: (_) => set(() {})),
            CheckboxListTile(contentPadding: EdgeInsets.zero, value: models, title: Text(L('settings.wipe.withModels')), onChanged: (v) => set(() => models = v ?? false)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L('common.cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
              onPressed: typed.text.trim() == word ? () => Navigator.pop(c, true) : null,
              child: Text(L('settings.wipe.confirm')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final problems = await library.wipeEverything(includeModels: models);
    if (!mounted) return;
    _toast(problems.isEmpty ? L('settings.wipe.doneMessage') : '${L('settings.wipe.doneMessage')}\n${problems.join('\n')}');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, Prefs.instance]),
      builder: (context, _) {
        final s = library.stats;
        final prefs = Prefs.instance;
        final scheme = Theme.of(context).colorScheme;
        void push(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
        Widget nav(Key? key, IconData icon, String title, String? detail, Widget Function() page, {String? mascot}) => ListTile(
              key: key,
              leading: SettingsIcon(icon, mascot: mascot),
              title: Text(title),
              subtitle: detail == null ? null : Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(page()),
            );
        final bad = s?.bad ?? 0;
        return Scaffold(
          appBar: AppBar(title: Text(L('place.settings'))),
          body: ListView(
            padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              // syncing with another device: first, as the native app's card (only this part
              // follows the sync model's 1.5 s poll, not the whole page)
              ListenableBuilder(
                listenable: library.sync,
                builder: (context, _) => switch (library.sync.status) {
                  final st? when st.syncing > 0 => _Section(children: [_SyncCard(status: st)]),
                  _ => const SizedBox.shrink(),
                },
              ),
              _Section(title: L('common.library'), children: [
                if (s != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(children: [
                      Expanded(child: _Stat(value: s.posts, label: L('common.posts'), icon: Icons.chat_bubble, color: Colors.blue)),
                      Expanded(child: _Stat(value: s.photos, label: L('search.kw.photo.word'), icon: Icons.photo, color: Colors.orange)),
                      Expanded(child: _Stat(value: s.videos, label: L('place.videos'), icon: Icons.smart_display, color: Colors.pink)),
                      Expanded(child: _Stat(value: s.tags, label: L('common.tags'), icon: Icons.sell, color: Colors.purple)),
                    ]),
                  ),
              ]),
              _Section(title: L('settings.section.content'), children: [
                nav(const ValueKey('settings-downloads'), Icons.download, L('common.downloadPosts'),
                    library.downloads.phase.name == 'running' ? L('settings.downloading') : null,
                    () => DownloadsPage(downloads: library.downloads, library: library),
                    mascot: library.downloads.phase.name == 'running' ? 'bag' : null),
                nav(null, Icons.inventory_2, L('common.importAndBackup'), null, () => TransferPage(library: library)),
                nav(const ValueKey('settings-tags'), Icons.sell, L('common.tags'), s == null ? null : L('common.count', [s.tags]), () => TagsPage(library: library)),
              ]),
              _Section(title: L('appearance.title'), footer: OS.isAndroid ? L('appearance.footer') : null, children: [
                const _ColorChoice(),
                ListTile(
                  leading: const SettingsIcon(Icons.contrast),
                  title: Text(L('appearance.mode')),
                  trailing: ChoiceMenu<int>(
                    key: const ValueKey('appearance-mode'),
                    value: prefs.brightness,
                    items: [(0, L('common.auto')), (1, L('appearance.light')), (2, L('appearance.dark'))],
                    onChanged: (v) => prefs.brightness = v,
                  ),
                ),
              ]),
              _Section(title: L('mascot.title'), footer: L('mascot.footer'), children: [
                SwitchListTile(
                  key: const ValueKey('mascot-switch'),
                  secondary: const ClawdIcon('settings', size: 30),
                  title: Text(L('mascot.toggle')),
                  value: prefs.mascot,
                  onChanged: withHaptic((v) => prefs.mascot = v),
                ),
                ListTile(
                  leading: const SettingsIcon(Icons.gavel),
                  title: Text(L('mascot.licenses')),
                  onTap: () => MascotCredits.showLicenses(context),
                ),
              ]),
              _Section(title: L('settings.section.browse'), children: [
                if (prefs.aboutExtras && (bad > 0 || prefs.badOnly))
                  SwitchListTile(
                    secondary: const SettingsIcon(Icons.warning, danger: true),
                    title: Text(L('settings.badOnly', [bad])),
                    value: prefs.badOnly,
                    onChanged: withHaptic((v) => prefs.badOnly = v),
                  ),
                // the Mac and phones and tablets: not Windows and Linux
                if (!OS.isWindows && !OS.isLinux) SwitchListTile(
                  secondary: const SettingsIcon(Icons.headphones),
                  title: Text(L('settings.headphonesOnly')),
                  value: prefs.headphonesOnly,
                  onChanged: withHaptic((v) => prefs.headphonesOnly = v),
                ),
                SwitchListTile(
                  secondary: const SettingsIcon(Icons.do_not_touch),
                  title: Text(L('settings.noGestures')),
                  value: prefs.playerGesturesOff,
                  onChanged: withHaptic((v) => prefs.playerGesturesOff = v),
                ),
                if (!kIsWeb && (OS.isIOS || OS.isAndroid))
                  SwitchListTile(
                    secondary: const SettingsIcon(Icons.screen_rotation),
                    title: Text(L('settings.autoLandscape')),
                    value: prefs.autoLandscape,
                    onChanged: withHaptic((v) => prefs.autoLandscape = v),
                  ),
              ]),
              // how many cards a row of 浏览 holds: a large screen's choice (a phone shows one)
              if (_largeScreen(context))
                _Section(title: L('cards.section'), footer: L('cards.footer'), children: [
                  _DensityRow(title: L('cards.portrait'), icon: Icons.view_column_outlined, value: prefs.densityPortrait, onChanged: (v) => prefs.densityPortrait = v),
                  _DensityRow(title: L('cards.landscape'), icon: Icons.view_week_outlined, value: prefs.densityLandscape, onChanged: (v) => prefs.densityLandscape = v),
                ]),
              if (AppLock.offered)
                _Section(title: L('applock.section'), children: [
                  AppLockSwitch(lock: AppLock.instance, icon: const SettingsIcon(Icons.lock)),
                ]),
              _Section(title: L('settings.section.smart'), children: [
                nav(const ValueKey('settings-ai'), Icons.auto_awesome, L('models.tagging'),
                    library.aiModels.activeTaggerId == null ? L('models.external') : library.aiModels.find(library.aiModels.activeTaggerId!)?.title ?? L('models.external'),
                    () => AiPage(models: library.aiModels, ai: library.ai, tagger: library.tagger, sync: library.sync),
                    mascot: library.tagger.running ? 'camera' : null),
                nav(const ValueKey('settings-sync'), Icons.sync, L('common.lanSync'),
                    library.sync.joined ? L('sync.state.on') : L('sync.state.notJoined'), () => SyncPage(sync: library.sync, onDeleteEverything: _wipe)),
                if (ExtensionReceiver.offered)
                  nav(const ValueKey('settings-extension'), Icons.extension, L('ext.title'), extensionSummary(), () => const ExtensionPage()),
              ]),
              // Windows, Linux: where everything is kept
              if (DataHome.path != null) DataHomeSection(library: library),
              // GitHub builds only
              if (Updates.enabled)
                _Section(footer: L('update.footer'), children: [
                  ListTile(
                    key: const ValueKey('settings-update'),
                    leading: const SettingsIcon(Icons.system_update),
                    title: Text(L('update.check')),
                    onTap: () => Updates.checkNow(context),
                  ),
                ]),
              // last: what the app takes on this device, the app itself, and clearing everything
              _Section(children: [
                nav(const ValueKey('settings-storage'), Icons.storage, L('storage.title'), null, () => StoragePage(library: library)),
                nav(const ValueKey('settings-about'), Icons.info_outline, L('settings.about'), null, () => AboutPage(onExportDiagnostics: _exportDiagnostics, logFile: '${library.directory}${OS.pathSeparator}logs${OS.pathSeparator}diagnostics.log')),
              ]),
              // the web build: this browser's sign-in
              if (OS.isWeb)
                _Section(footer: L('settings.signOut.footer'), children: [
                  ListTile(key: const ValueKey('settings-signout'), leading: const SettingsIcon(Icons.logout), title: Text(L('settings.signOut')), onTap: signOut),
                ]),
              _Section(footer: L('settings.wipe.footer'), children: [
                ListTile(
                  leading: const SettingsIcon(Icons.delete_forever, danger: true),
                  title: Text(L('settings.wipe.button'), style: TextStyle(color: scheme.error)),
                  onTap: _wipe,
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}

/// The account cookies (needed for locked accounts' posts): kept in the platform's secret store,
/// never synced.
class CookieSection extends StatefulWidget {
  const CookieSection({super.key});

  @override
  State<CookieSection> createState() => _CookieSectionState();
}

class _CookieSectionState extends State<CookieSection> {
  final _auth = TextEditingController();
  final _ct0 = TextEditingController();
  bool _checking = false;

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _save() async {
    final a = await Secrets.write('auth_token', _auth.text.trim());
    final b = await Secrets.write('ct0', _ct0.text.trim());
    if (a is SecretsUnavailable || b is SecretsUnavailable) return _toast(L('settings.cookie.notSaved'));
    await Session.applyStoredCookies();
    _auth.clear();
    _ct0.clear();
    _toast(_auth.text.isEmpty && _ct0.text.isEmpty ? L('settings.cookie.saved') : L('settings.cookie.cleared'));
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final auth = await Secrets.read('auth_token'), ct0 = await Secrets.read('ct0');
    final a = auth is SecretValue<String?> ? auth.value ?? '' : '', c = ct0 is SecretValue<String?> ? ct0.value ?? '' : '';
    final r = await checkCookies(a, c);
    if (!mounted) return;
    setState(() => _checking = false);
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(r.error == null ? '@${r.screen_name ?? ''}' : L('cookie.invalid')),
        content: r.error == null ? (r.name == null ? null : Text(r.name!)) : Text(r.error!),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.ok')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _Section(title: L('settings.cookie.header'), footer: L('settings.cookie.footer'), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(contextMenuBuilder: appTextMenu, controller: _auth, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'auth_token')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(contextMenuBuilder: appTextMenu, controller: _ct0, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'ct0')),
        ),
        ListTile(leading: const SettingsIcon(Icons.key), title: Text(L('settings.cookie.save')), onTap: _save),
        ListTile(
          leading: _checking ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const SettingsIcon(Icons.verified_user),
          title: Text(_checking ? L('settings.cookie.checking') : L('settings.cookie.check')),
          onTap: _checking ? null : _check,
        ),
      ]);
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.icon, required this.color});
  final int value;
  final String label;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FittedBox(fit: BoxFit.scaleDown, child: Text('$value', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
      Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      ]),
    ]);
  }
}

/// A tablet's or a desktop's screen, whatever size the window has now (a narrowed iPad window
/// still has the setting: it is for the screen, and the window may widen again).
bool _largeScreen(BuildContext context) {
  if (OS.isMacOS || OS.isWindows || OS.isLinux) return true;
  final display = View.of(context).display;
  return display.size.shortestSide / display.devicePixelRatio >= 600;
}

/// 少 / 适中 / 多 for a row of 浏览, as a menu on the row's end.
class _DensityRow extends StatelessWidget {
  const _DensityRow({required this.title, required this.icon, required this.value, required this.onChanged});
  final String title;
  final IconData icon;
  final int value;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
        leading: SettingsIcon(icon),
        title: Text(title),
        trailing: ChoiceMenu<int>(
          value: value.clamp(0, 2),
          items: [(0, L('cards.fewer')), (1, L('cards.medium')), (2, L('cards.more'))],
          onChanged: onChanged,
        ),
      );
}

/// A settings row's icon: a white symbol on a coloured tile, as the native settings.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key, this.mascot, this.danger = false});
  final IconData icon;
  /// The mascot mode's icon in its place (no tile: the crab has its own colours).
  final String? mascot;
  /// What cannot be undone keeps its warning colour.
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MascotIcon(
      mascot,
      size: 30,
      fallback: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: danger ? scheme.errorContainer : scheme.secondaryContainer, shape: BoxShape.circle),
        child: Icon(icon, size: 20, color: danger ? scheme.onErrorContainer : scheme.onSecondaryContainer),
      ),
    );
  }
}

/// 颜色: the colour the theme is made from, or the system's (on Android 12+ the wallpaper's). A
/// theme colour is a whole set of colours: each tile shows its set, in the set's own tint.
class _ColorChoice extends StatelessWidget {
  const _ColorChoice();

  @override
  Widget build(BuildContext context) {
    final prefs = Prefs.instance;
    // only Android has a system colour (the wallpaper's); elsewhere no choice is the default colour
    final android = OS.isAndroid;
    final current = prefs.seedColor ?? (android ? null : defaultSeed.toARGB32());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SettingsIcon(Icons.palette),
          const SizedBox(width: 16),
          Text(L('appearance.color'), style: Theme.of(context).textTheme.bodyLarge),
        ]),
        const SizedBox(height: 12),
        GridView.extent(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          maxCrossAxisExtent: 66,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.76,
          children: [
            if (android) _ColorTile(seed: null, name: L('appearance.color.system'), selected: current == null, onTap: () => prefs.seedColor = null),
            for (final e in seedColors.entries)
              _ColorTile(
                seed: e.value,
                name: L('appearance.color.${e.key}'), // i18n-exempt: keys appearance.color.<name>, checked by test/screens/about_page_test.dart
                selected: current == e.value.toARGB32(),
                onTap: () => prefs.seedColor = e.value.toARGB32(),
              ),
          ],
        ),
      ]),
    );
  }
}

class _ColorTile extends StatelessWidget {
  const _ColorTile({required this.seed, required this.name, required this.selected, required this.onTap});
  /// Null: the system's colours.
  final Color? seed;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = seed == null ? null : schemeOf(seed!, theme.brightness);
    final tint = set?.surfaceContainer ?? theme.colorScheme.surfaceContainer;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('seed-${seed?.toARGB32() ?? 'system'}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(children: [
          AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: CustomPaint(
                  painter: _ColorSetPainter(set: set, hole: selected ? tint : null),
                  child: selected ? Center(child: Icon(Icons.check, size: 14, color: set?.primary ?? theme.colorScheme.primary)) : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(name, maxLines: 1, style: theme.textTheme.labelMedium?.copyWith(color: selected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

/// A circle: the top half the primary colour, the bottom quarters the tertiary and the primary
/// container. The system's colours are not known here: all the colours. Chosen, its middle opens.
class _ColorSetPainter extends CustomPainter {
  _ColorSetPainter({required this.set, required this.hole});
  final ColorScheme? set;
  final Color? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final circle = Rect.fromCircle(center: center, radius: radius);
    final s = set;
    if (s == null) {
      canvas.drawCircle(center, radius, Paint()..shader = const SweepGradient(colors: [Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple, Colors.red]).createShader(circle));
    } else {
      void slice(double start, double sweep, Color color) => canvas.drawArc(circle, start, sweep, true, Paint()..color = color);
      slice(math.pi, math.pi, s.primary);
      slice(math.pi / 2, math.pi / 2, s.tertiary);
      slice(0, math.pi / 2, s.primaryContainer);
    }
    if (hole != null) canvas.drawCircle(center, radius * 0.6, Paint()..color = hole!);
  }

  @override
  bool shouldRepaint(_ColorSetPainter old) => old.set != set || old.hole != hole;
}

/// A row of a section: only the group's outer corners are large. On its own for a list too long
/// to build at once (the tags).
class SettingsPiece extends StatelessWidget {
  const SettingsPiece({super.key, required this.first, required this.last, required this.child});
  final bool first, last;
  final Widget child;
  static const _outer = Radius.circular(18), _inner = Radius.circular(4);

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: first ? _outer : _inner, bottom: last ? _outer : _inner)),
        child: child,
      );
}

class _Section extends StatelessWidget {
  const _Section({super.key, this.title, this.footer, required this.children});
  final String? title;
  final String? footer;
  final List<Widget> children;

  /// A list of its own rows, each a piece: a thin gap between them, and only the group's outer
  /// corners are large.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Text(title!, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
              ),
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 3),
              SettingsPiece(first: i == 0, last: i == children.length - 1, child: children[i]),
            ],
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(footer!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// A settings section for the subpages.
class SettingsSection extends _Section {
  const SettingsSection({super.key, super.title, super.footer, required super.children});
}

/// 正在与其他设备同步 / 正在从其他设备接收媒体, with what is left and a bar, as the native card.
class _SyncCard extends StatefulWidget {
  const _SyncCard({required this.status});
  final SyncStatus status;
  @override
  State<_SyncCard> createState() => _SyncCardState();
}

class _SyncCardState extends State<_SyncCard> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  static String _bytes(int b) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB']; // i18n-exempt: unit symbols
    var v = b.toDouble();
    var u = 0;
    while (v >= 1000 && u < units.length - 1) {
      v /= 1000;
      u++;
    }
    return '${u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = widget.status.receiving;
    final String title;
    final String detail;
    double? progress;
    if (t != null && t.total > 0) {
      final inFlight = t.current_size > 0 ? t.current_done / t.current_size : 0.0;
      final left = t.total > t.received ? t.total - t.received : 0;
      var d = L('activity.filesLeft', [left]);
      if (t.total_bytes > 0) {
        d += ' · ${_bytes(t.total_bytes > t.bytes ? t.total_bytes - t.bytes : 0)}';
        d += L('activity.received', [t.received, t.total, _bytes(t.bytes), _bytes(t.total_bytes)]);
      } else {
        d += L('activity.receivedShort', [t.received, t.total, _bytes(t.bytes)]);
      }
      if (t.current_size > 8000000) d += L('activity.currentFile', [(inFlight * 100).round()]);
      title = L('activity.receiving');
      detail = d;
      progress = (t.total_bytes > 0 ? t.bytes / t.total_bytes : (t.received + inFlight) / t.total).clamp(0.0, 1.0);
    } else {
      title = L('activity.syncing');
      detail = L('activity.syncDetail');
    }
    return Padding(
      key: const ValueKey('settings-sync-card'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
          child: RotationTransition(turns: _spin, child: Icon(Icons.sync, color: scheme.primary)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(detail, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: progress, minHeight: 4)),
          ]),
        ),
      ]),
    );
  }
}
