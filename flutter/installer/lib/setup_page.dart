import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'setup.dart';
import 'strings.dart';

enum _Step { ready, working, done, failed }

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.product, required this.payload, required this.setupFolder, required this.strings, this.setup});
  final Product product;
  final String? payload;
  final String setupFolder;
  final S strings;
  final Setup? setup;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

/// Every step of installing and uninstalling has one layout: who and what at the top, one panel
/// with what this step is about, and at the bottom a note on the left with the actions on the right.
class _SetupPageState extends State<SetupPage> {
  late final Setup setup = widget.setup ?? Setup(widget.product);
  S get s => widget.strings;
  Product get p => widget.product;
  bool get installing => widget.payload != null;

  late final InstalledCopy? copy = setup.installedCopy();
  late final InstallKind kind = installKind(copy, p.version);
  /// A copy that is there is replaced where it is: a second folder would leave the old one behind.
  late String folder = copy?.folder ?? (installing ? setup.defaultFolder : Directory(widget.setupFolder).parent.path);
  late final String? data = installing ? null : setup.dataFolder();
  late bool desktop = copy != null && setup.hasDesktopShortcut();
  bool launch = true, removeData = false;
  _Step step = _Step.ready;
  double progress = 0;
  String? error;

  Future<void> _run() async {
    setState(() {
      step = _Step.working;
      progress = 0;
    });
    void onProgress(double v) => setState(() => progress = v);
    try {
      final payload = widget.payload;
      if (payload != null) {
        await setup.install(payload: payload, setupFolder: widget.setupFolder, folder: folder, desktopShortcut: desktop, progress: onProgress);
      } else {
        await setup.uninstall(folder: folder, dataFolder: removeData ? data : null, progress: onProgress);
      }
      setState(() => step = _Step.done);
    } catch (e) {
      setState(() {
        step = _Step.failed;
        error = '$e';
      });
    }
  }

  Future<void> _finish() async {
    if (installing && step == _Step.done && launch) {
      await Process.start('$folder\\${p.executable}', const [], mode: ProcessStartMode.detached, workingDirectory: folder);
    }
    exit(0);
  }

  String _v(String version) => 'v$version';

  String get _title => switch ((installing, step, kind)) {
        (_, _Step.failed, _) => s.failed,
        (true, _Step.ready, InstallKind.fresh) => s.installTitle(p.name),
        (true, _Step.ready, InstallKind.upgrade) => s.upgradeTitle(p.name),
        (true, _Step.ready, _) => s.overwriteTitle(p.name),
        (true, _Step.working, InstallKind.fresh) => s.installing(p.name),
        (true, _Step.working, InstallKind.upgrade) => s.upgrading(p.name),
        (true, _Step.working, _) => s.overwriting(p.name),
        (true, _Step.done, InstallKind.upgrade) => s.upgraded(p.name, _v(p.version)),
        (true, _Step.done, _) => s.installed(p.name),
        (false, _Step.ready, _) => s.uninstallTitle(p.name),
        (false, _Step.working, _) => s.uninstalling(p.name),
        (false, _Step.done, _) => s.uninstalled(p.name),
      };

  String? get _subtitle => switch ((installing, step, kind)) {
        (true, _Step.ready, InstallKind.fresh) => s.installBody,
        // an older version may not open what a newer one wrote: its notice says so instead
        (true, _Step.ready, InstallKind.downgrade) => null,
        (true, _Step.ready, _) => s.keepsData,
        (true, _Step.done, _) => s.installedBody,
        (false, _Step.ready, _) => s.uninstallBody,
        _ => null,
      };

  /// The version beside the title: from and to when upgrading.
  String? get _pill {
    if (!installing) return copy?.version == null ? null : _v(copy!.version!);
    if (kind != InstallKind.upgrade) return _v(p.version);
    return step == _Step.done ? null : '${_v(copy!.version!)} → ${_v(p.version)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: Column(children: [
        _Caption(brightness: t.brightness, canClose: step != _Step.working),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 4, 32, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Header(title: _title, version: _pill, subtitle: _subtitle),
              const SizedBox(height: 24),
              Expanded(child: SingleChildScrollView(child: _panel(t))),
              const SizedBox(height: 16),
              _actions(t),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _panel(ThemeData t) => switch (step) {
        _Step.ready => _Panel(children: installing ? _installOptions(t) : _uninstallOptions(t)),
        _Step.working => _Panel(children: [
            Row(children: [
              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: progress, minHeight: 8))),
              const SizedBox(width: 12),
              Text('${(progress * 100).round()}%', style: t.textTheme.labelLarge),
            ]),
          ]),
        _Step.done => _Panel(children: installing ? _installed(t) : _uninstalled(t)),
        _Step.failed => _Panel(color: t.colorScheme.errorContainer, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline_rounded, size: 20, color: t.colorScheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(child: SelectableText(error ?? '', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onErrorContainer))),
            ]),
          ]),
      };

  List<Widget> _installOptions(ThemeData t) {
    final notice = switch (kind) {
      InstallKind.fresh => null,
      InstallKind.upgrade => s.upgradeNotice(_v(copy!.version!), _v(p.version)),
      InstallKind.reinstall => s.reinstallNotice(_v(p.version)),
      InstallKind.downgrade => s.downgradeNotice(_v(copy!.version!), _v(p.version)),
      InstallKind.unknownVersion => s.unknownNotice(_v(p.version)),
    };
    return [
      if (notice != null) ...[
        _Line(
          key: const ValueKey('installedNotice'),
          icon: kind == InstallKind.downgrade ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
          color: kind == InstallKind.downgrade ? t.colorScheme.error : t.colorScheme.primary,
          text: notice,
        ),
        const _Rule(),
      ],
      _Label(kind == InstallKind.fresh ? s.folder : s.installedFolder),
      const SizedBox(height: 8),
      _PathField(
        path: folder,
        changeLabel: kind == InstallKind.fresh ? s.change : null,
        onChange: () async {
          final d = await getDirectoryPath();
          if (d != null) setState(() => folder = '$d\\${p.name}');
        },
      ),
      const _Rule(),
      _CheckRow(key: const ValueKey('desktopShortcut'), value: desktop, onChanged: (v) => setState(() => desktop = v), title: s.desktopShortcut),
    ];
  }

  List<Widget> _uninstallOptions(ThemeData t) => [
        _Label(s.installedFolder),
        const SizedBox(height: 8),
        _PathField(path: folder),
        if (data != null) ...[
          const _Rule(),
          _CheckRow(key: const ValueKey('removeData'), value: removeData, onChanged: (v) => setState(() => removeData = v), title: s.removeData, path: data),
        ],
      ];

  List<Widget> _installed(ThemeData t) => [
        _Label(s.installedFolder),
        const SizedBox(height: 8),
        _PathField(path: folder),
        const _Rule(),
        _CheckRow(key: const ValueKey('launch'), value: launch, onChanged: (v) => setState(() => launch = v), title: s.launch(p.name)),
      ];

  List<Widget> _uninstalled(ThemeData t) => [
        if (data == null || removeData)
          _Line(icon: Icons.check_circle_outline_rounded, color: t.colorScheme.primary, text: data == null ? s.uninstalled(p.name) : s.dataRemoved)
        else ...[
          _Label(s.dataKept),
          const SizedBox(height: 8),
          _PathField(key: const ValueKey('dataKept'), path: data!),
        ],
      ];

  Widget _actions(ThemeData t) {
    final (IconData? icon, String? note) = switch ((installing, step, kind)) {
      (true, _Step.ready, InstallKind.fresh) => (Icons.verified_user_outlined, s.perUser),
      (true, _Step.ready, _) => (Icons.info_outline_rounded, s.closesRunning(p.name)),
      (false, _Step.ready, _) when data != null => (Icons.info_outline_rounded, s.dataKeptNote),
      _ => (null, null),
    };
    const big = EdgeInsets.symmetric(horizontal: 24, vertical: 10);
    const small = EdgeInsets.symmetric(horizontal: 20, vertical: 10);
    final List<Widget> buttons = switch (step) {
      _Step.ready => [
          TextButton(style: TextButton.styleFrom(padding: small), onPressed: () => exit(0), child: Text(s.cancel)),
          const SizedBox(width: 8),
          if (installing)
            FilledButton.icon(
              key: const ValueKey('go'),
              style: FilledButton.styleFrom(padding: big),
              onPressed: _run,
              icon: Icon(switch (kind) { InstallKind.fresh => Icons.download_rounded, InstallKind.upgrade => Icons.upgrade_rounded, _ => Icons.refresh_rounded }, size: 18),
              label: Text(switch (kind) { InstallKind.fresh => s.install, InstallKind.upgrade => s.upgrade, _ => s.overwrite }),
            )
          else
            FilledButton.icon(
              key: const ValueKey('go'),
              style: FilledButton.styleFrom(padding: big, backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
              onPressed: _run,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(s.uninstall),
            ),
        ],
      _Step.working => const [],
      _Step.done => [FilledButton(key: const ValueKey('finish'), style: FilledButton.styleFrom(padding: big), onPressed: _finish, child: Text(s.finish))],
      _Step.failed => [
          TextButton(style: TextButton.styleFrom(padding: small), onPressed: _finish, child: Text(s.close)),
          const SizedBox(width: 8),
          FilledButton(key: const ValueKey('retry'), style: FilledButton.styleFrom(padding: big), onPressed: _run, child: Text(s.retry)),
        ],
    };
    return SizedBox(
      height: 48,
      child: Row(children: [
        if (note != null) ...[
          Icon(icon, size: 16, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          const SizedBox(width: 12),
        ] else
          const Spacer(),
        ...buttons,
      ]),
    );
  }
}

/// The app's icon, the title with its version, and a line under them.
class _Header extends StatelessWidget {
  const _Header({required this.title, this.version, this.subtitle});
  final String title;
  final String? version, subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(children: [
      ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.asset('assets/app_icon.png', width: 48, height: 48, filterQuality: FilterQuality.medium)),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3))),
            if (version != null) ...[
              const SizedBox(width: 10),
              Container(
                key: const ValueKey('version'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                child: Text(version!, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
              ),
            ],
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
    ]);
  }
}

/// The one panel of a step. A Material, so that the hover of a row inside shows on it.
class _Panel extends StatelessWidget {
  const _Panel({required this.children, this.color});
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color ?? scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(text, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600));
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4)),
      );
}

/// A sentence with an icon, for what the person should know about this step.
class _Line extends StatelessWidget {
  const _Line({super.key, required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      ]);
}

/// A folder inset in the panel, in full over two lines when it has to be (its last part is what
/// tells folders apart), with a button to change it when it can be.
class _PathField extends StatelessWidget {
  const _PathField({super.key, required this.path, this.changeLabel, this.onChange});
  final String path;
  final String? changeLabel;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.only(left: 14, right: 6, top: 6, bottom: 6),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(Icons.folder_outlined, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(child: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'Consolas', color: scheme.onSurface))),
        if (changeLabel != null) ...[
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: onChange,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(changeLabel!),
          ),
        ],
      ]),
    );
  }
}

/// A choice without a frame of its own: the whole row clicks.
class _CheckRow extends StatelessWidget {
  const _CheckRow({super.key, required this.value, required this.onChanged, required this.title, this.path});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(value: value, onChanged: (v) => onChanged(v!), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              if (path != null) Text(path!, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Consolas', color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The window's top strip in place of the system title bar: drags move the window; minimize and
/// close at the end (close is off while files are being written).
class _Caption extends StatelessWidget {
  const _Caption({required this.brightness, required this.canClose});
  final Brightness brightness;
  final bool canClose;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: Row(children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          WindowCaptionButton.minimize(brightness: brightness, onPressed: () => windowManager.minimize()),
          if (canClose) WindowCaptionButton.close(brightness: brightness, onPressed: () => exit(0)) else const SizedBox(width: 46),
        ]),
      );
}
