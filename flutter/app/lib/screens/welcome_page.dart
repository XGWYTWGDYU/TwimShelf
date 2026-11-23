import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/prefs.dart';
import '../l10n/l10n.dart';

/// 欢迎: eight pages on what the app does, as the native apps' welcome (the same pages and
/// words), in Material 3: on a phone a page of its own, on a tablet a large dialog. Shown on the
/// first launch; 关于 opens it again any time.
class Welcome {
  /// The first launch: the welcome, once.
  static Future<void> showIfDue(BuildContext context) async {
    if (Prefs.instance.welcomeSeen) return;
    await show(context);
  }

  static Future<void> show(BuildContext context) async {
    final tablet = Prefs.largeScreen(context);
    if (tablet) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(32),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720, maxHeight: 700), child: const WelcomePage()),
        ),
      );
    } else {
      await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const WelcomePage()));
    }
    Prefs.instance.welcomeSeen = true;
  }
}

class _PageSpec {
  const _PageSpec(this.n, this.icon, this.color, {this.body});
  final int n;
  final IconData icon;
  final Color color;
  final String? body;
  String get badge => L('welcome.p$n.badge');
  String get title => L('welcome.p$n.title');
  String get text => L(body ?? 'welcome.p$n.body');
}

const _pages = [
  _PageSpec(1, Icons.shuffle, Color(0xFFFF9500), body: 'welcome.p1.body.mobile'),
  _PageSpec(2, Icons.grid_view, Color(0xFF0A84FF)),
  _PageSpec(3, Icons.download, Color(0xFF00B4D8)),
  _PageSpec(4, Icons.auto_awesome, Color(0xFFAF52DE)),
  _PageSpec(5, Icons.sell, Color(0xFF34C759)),
  _PageSpec(6, Icons.search, Color(0xFF5856D6)),
  _PageSpec(7, Icons.hub, Color(0xFF30B0C7)),
  _PageSpec(8, Icons.swap_horiz, Color(0xFFFF2D55)),
];

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _pager = PageController();
  int _page = 0;

  bool get _last => _page == _pages.length - 1;

  void _close() => Navigator.of(context).pop();

  void _next() {
    if (_last) return _close();
    _pager.nextPage(duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = _pages[_page];
    final accent = Color.lerp(p.color, scheme.primary, 0.15)!;
    return Material(
      key: const ValueKey('welcome'),
      color: scheme.surface,
      child: SafeArea(
        child: Column(children: [
          // Skip at the start, the step at the end
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
            child: Row(children: [
              AnimatedOpacity(
                opacity: _last ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: TextButton(key: const ValueKey('welcomeSkip'), onPressed: _last ? null : _close, child: Text(L('welcome.skip'))),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: Text(L('welcome.step', [_page + 1, _pages.length]), style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => _PageBody(spec: _pages[i], active: i == _page),
            ),
          ),
          // the dots, then the one button
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < _pages.length; i++)
              GestureDetector(
                onTap: () => _pager.animateToPage(i, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  margin: const EdgeInsets.symmetric(horizontal: 3.5),
                  width: i == _page ? 22 : 7,
                  height: 7,
                  decoration: BoxDecoration(color: i == _page ? accent : scheme.outlineVariant, borderRadius: BorderRadius.circular(4)),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('welcomeNext'),
                style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _next,
                iconAlignment: IconAlignment.end,
                icon: Icon(_last ? Icons.check : Icons.arrow_forward, size: 18),
                label: Text(_last ? L('welcome.done') : L('welcome.next'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// One page: its picture on a card, the badge, the title and the words.
class _PageBody extends StatelessWidget {
  const _PageBody({required this.spec, required this.active});
  final _PageSpec spec;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final stage = math.min(380.0, c.maxHeight * 0.55);
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(children: [
          const SizedBox(height: 8),
          Container(
            height: stage,
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _Stage(spec: spec, active: active),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(color: spec.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(spec.icon, size: 14, color: spec.color),
              const SizedBox(width: 5),
              Text(spec.badge, style: theme.textTheme.labelLarge?.copyWith(color: spec.color, fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(height: 10),
          Text(spec.title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(spec.text, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45)),
          ),
          const SizedBox(height: 12),
        ]),
      );
    });
  }
}

/// The picture of a page: a small phone showing that part of the app, animated while the page is
/// the one shown.
class _Stage extends StatefulWidget {
  const _Stage({required this.spec, required this.active});
  final _PageSpec spec;
  final bool active;
  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void initState() {
    super.initState();
    if (widget.active) _t.repeat();
  }

  @override
  void didUpdateWidget(_Stage old) {
    super.didUpdateWidget(old);
    if (widget.active && !_t.isAnimating) _t.repeat();
    if (!widget.active && _t.isAnimating) _t.stop();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.spec.color;
    return Center(
      child: AspectRatio(
        aspectRatio: 0.52,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: scheme.outlineVariant, width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 16, offset: const Offset(0, 6))],
            ),
            clipBehavior: Clip.antiAlias,
            child: AnimatedBuilder(animation: _t, builder: (context, _) => _screen(context, _t.value, c)),
          ),
        ),
      ),
    );
  }

  /// A grey line of placeholder text.
  Widget _line(ColorScheme s, double w, {double h = 5, Color? color}) =>
      Container(width: w, height: h, decoration: BoxDecoration(color: color ?? s.onSurface.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(3)));

  /// A small card: media, two lines, a few tag chips with dots.
  Widget _card(ColorScheme s, Color tint, double media, {List<Color> dots = const []}) => Container(
        decoration: BoxDecoration(color: s.surfaceContainerLowest, borderRadius: BorderRadius.circular(10), border: Border.all(color: s.outlineVariant.withValues(alpha: 0.5))),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Container(height: media, color: tint.withValues(alpha: 0.35)),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _line(s, 40),
              const SizedBox(height: 4),
              Wrap(spacing: 3, runSpacing: 3, children: [for (final d in dots) _chip(s, d)]),
            ]),
          ),
        ]),
      );

  Widget _chip(ColorScheme s, Color dot, [String? text]) => Container(
        padding: EdgeInsets.symmetric(horizontal: text == null ? 4 : 6, vertical: text == null ? 3 : 3),
        decoration: BoxDecoration(color: s.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(4), border: Border.all(color: s.onSurface.withValues(alpha: 0.12), width: 0.6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 4, height: 4, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          SizedBox(width: text == null ? 8 : 4),
          if (text != null) Text(text, style: TextStyle(fontSize: 7, color: s.onSurface, fontWeight: FontWeight.w500)),
        ]),
      );

  /// The floating buttons at the top right (no title, nothing frosted: as the app).
  Widget _topButtons(ColorScheme s, {bool highlight = false, Color? accent}) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.download, size: 10, color: highlight ? accent : s.onSurface),
                const SizedBox(width: 6),
                Icon(Icons.schedule, size: 10, color: s.onSurfaceVariant),
              ]),
            ),
            const SizedBox(width: 4),
            CircleAvatar(radius: 9, backgroundColor: s.surfaceContainerHighest, child: Icon(Icons.search, size: 10, color: s.onSurface)),
          ]),
        ),
      );

  Widget _screen(BuildContext context, double t, Color c) {
    final s = Theme.of(context).colorScheme;
    const mine = Color(0xFF0A84FF), ai = Color(0xFFAF52DE), both = Color(0xFF34C759);
    switch (widget.spec.n) {
      case 1: // a fresh order: the cards trade places
        final swap = Curves.easeInOutCubic.transform(((t * 2) % 1).clamp(0, 1));
        final tints = [const Color(0xFFFF9500), const Color(0xFFFF2D55), const Color(0xFF30B0C7), const Color(0xFF5856D6)];
        final order = (t * 2).floor().isEven ? [0, 1, 2, 3] : [2, 3, 0, 1];
        return Stack(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 34, 8, 8),
            child: Opacity(
              opacity: 1 - (math.sin(swap * math.pi) * 0.5),
              child: GridView.count(crossAxisCount: 2, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 0.72, physics: const NeverScrollableScrollPhysics(),
                  children: [for (final i in order) _card(s, tints[i], 46, dots: const [mine, ai])]),
            ),
          ),
          _topButtons(s),
          Align(alignment: Alignment.topCenter, child: Padding(padding: const EdgeInsets.only(top: 12), child: Icon(Icons.refresh, size: 14, color: c.withValues(alpha: math.sin(swap * math.pi))))),
        ]);
      case 2: // pinch: the grid zooms between more and fewer columns
        final cols = 3 + (math.sin(t * math.pi * 2) > 0 ? 1 : 0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 26, 6, 6),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: GridView.count(key: ValueKey(cols), crossAxisCount: cols, mainAxisSpacing: 2, crossAxisSpacing: 2, physics: const NeverScrollableScrollPhysics(),
                children: [for (var i = 0; i < 24; i++) Container(color: Color.lerp(c, const Color(0xFF34C759), (i % 7) / 7)!.withValues(alpha: 0.30 + (i % 3) * 0.12))]),
          ),
        );
      case 3: // quick download: links into the card, progress bars fill
        return Stack(children: [
          _topButtons(s, highlight: true, accent: c),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 40, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withValues(alpha: 0.5))),
                child: Row(children: [Icon(Icons.description, size: 12, color: c), const SizedBox(width: 6), Text('bookmarks.json', style: TextStyle(fontSize: 8, fontFamily: 'monospace', color: s.onSurface))]),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(children: [
                    Icon(Icons.download_done, size: 10, color: ((t * 1.4 - i * 0.2).clamp(0, 1)) >= 1 ? c : s.outline),
                    const SizedBox(width: 6),
                    Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: (t * 1.4 - i * 0.2).clamp(0, 1), minHeight: 4, color: c, backgroundColor: s.surfaceContainerHighest))),
                  ]),
                ),
            ]),
          ),
        ]);
      case 4: // AI models: a model tagging, sparkles turning into tags
        final n = (t * 5).floor().clamp(0, 4);
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 24, 10, 10),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: s.surfaceContainerLow, borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                RotationTransition(turns: AlwaysStoppedAnimation(t), child: Icon(Icons.auto_awesome, size: 16, color: c)),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_line(s, 60), const SizedBox(height: 4), _line(s, 36, color: c.withValues(alpha: 0.5))])),
                Switch(value: true, onChanged: null, activeTrackColor: c),
              ]),
            ),
            const SizedBox(height: 12),
            _card(s, c, 70, dots: [for (var i = 0; i < n; i++) ai]),
          ]),
        );
      case 5: // where a tag comes from: the three dots
        final phase = (t * 3).floor() % 3;
        final labels = [L('welcome.p5.chip.mine'), L('welcome.p5.chip.ai'), L('welcome.p5.chip.common')];
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            _card(s, both, 90),
            const SizedBox(height: 14),
            for (var i = 0; i < 3; i++)
              AnimatedScale(
                scale: phase == i ? 1.12 : 1,
                duration: const Duration(milliseconds: 300),
                child: Padding(padding: const EdgeInsets.only(bottom: 6), child: _chip(s, [mine, ai, both][i], labels[i])),
              ),
          ]),
        );
      case 6: // search: capsules in the field, matching cards light up
        final k = (t * 3).floor().clamp(0, 2);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
          child: Column(children: [
            Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(11)),
              child: Row(children: [
                Icon(Icons.search, size: 10, color: s.onSurfaceVariant),
                const SizedBox(width: 4),
                for (var i = 0; i <= k; i++)
                  Container(margin: const EdgeInsets.only(right: 3), padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)), child: _line(s, 14, h: 4, color: Colors.white70)),
              ]),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.count(crossAxisCount: 2, mainAxisSpacing: 5, crossAxisSpacing: 5, physics: const NeverScrollableScrollPhysics(), children: [
                for (var i = 0; i < 6; i++) AnimatedOpacity(opacity: i % (k + 2) == 0 ? 1 : 0.25, duration: const Duration(milliseconds: 300), child: Container(decoration: BoxDecoration(color: c.withValues(alpha: 0.30), borderRadius: BorderRadius.circular(8)))),
              ]),
            ),
          ]),
        );
      case 7: // LAN sync: two devices and ripples between them
        return Stack(alignment: Alignment.center, children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 40 + ((t + i / 3) % 1) * 150,
              height: 40 + ((t + i / 3) % 1) * 150,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.withValues(alpha: 1 - ((t + i / 3) % 1)), width: 1.5)),
            ),
          Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            Icon(Icons.laptop_mac, size: 34, color: c),
            Icon(Icons.sync, size: 18, color: s.onSurfaceVariant),
            Icon(Icons.phone_android, size: 34, color: c),
          ]),
        ]);
      default: // import and export: a file going in and out
        final x = math.sin(t * math.pi * 2);
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Transform.translate(offset: Offset(x * 30, 0), child: Icon(Icons.folder_zip, size: 46, color: c)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.file_download, size: 22, color: x < 0 ? c : s.outline),
            const SizedBox(width: 28),
            Icon(Icons.file_upload, size: 22, color: x > 0 ? c : s.outline),
          ]),
        ]);
    }
  }
}
