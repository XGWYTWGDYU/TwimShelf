import 'dart:async';

import 'package:flutter/material.dart';

import '../app/prefs.dart';
import '../l10n/l10n.dart';
import 'clawd_icons.g.dart';
import '../widgets/text_menu.dart';

/// One of the mascot's icons (scripts/gen_icons.py), drawn from its vector data: the crab in
/// its own colours, the object it holds in the foreground colour.
class ClawdIcon extends StatelessWidget {
  const ClawdIcon(this.name, {super.key, this.size, this.color});
  final String name;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    return SizedBox.square(
      dimension: side,
      child: CustomPaint(painter: _ClawdPainter(name, color ?? theme.color ?? Theme.of(context).colorScheme.onSurface)),
    );
  }
}

class _ClawdPainter extends CustomPainter {
  _ClawdPainter(this.name, this.color);
  final String name;
  final Color color;

  static final Map<String, List<(ClawdOp, Path)>> _parsed = {};
  static List<(ClawdOp, Path)> _ops(String name) => _parsed[name] ??= [
        for (final op in clawdIcons[name] ?? const <ClawdOp>[]) (op, _path(op.d)),
      ];

  static Path _path(String d) {
    final t = d.split(' ');
    final p = Path();
    double n(int i) => double.parse(t[i]);
    for (var i = 0; i < t.length;) {
      switch (t[i]) {
        case 'M':
          p.moveTo(n(i + 1), n(i + 2));
          i += 3;
        case 'L':
          p.lineTo(n(i + 1), n(i + 2));
          i += 3;
        case 'C':
          p.cubicTo(n(i + 1), n(i + 2), n(i + 3), n(i + 4), n(i + 5), n(i + 6));
          i += 7;
        default:
          p.close();
          i += 1;
      }
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    for (final (op, path) in _ops(name)) {
      if (op.stroke) {
        canvas.drawPath(path, stroke);
      } else {
        fill.color = op.fill == null ? color : Color(0xFF000000 | op.fill!);
        canvas.drawPath(path, fill);
      }
    }
  }

  @override
  bool shouldRepaint(_ClawdPainter old) => old.name != name || old.color != color;
}

/// The mascot's icon while the mode is on ([name] null: never), otherwise [fallback]. Follows the
/// switch by itself, wherever it is on screen.
class MascotIcon extends StatelessWidget {
  const MascotIcon(this.name, {super.key, required this.fallback, this.size});
  final String? name;
  final Widget fallback;
  final double? size;

  // Clawd pops up with a little overshoot and tilt; what it replaces shrinks away.
  static Widget _pop(Widget child, Animation<double> animation) => FadeTransition(
        opacity: animation.drive(CurveTween(curve: const Interval(0, 0.4))),
        child: RotationTransition(
          turns: animation.drive(Tween<double>(begin: -0.04, end: 0).chain(CurveTween(curve: Curves.easeOutCubic))),
          child: ScaleTransition(
            scale: animation.drive(Tween<double>(begin: 0.45, end: 1).chain(CurveTween(curve: Curves.easeOutBack))),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Prefs.instance,
        builder: (_, _) {
          final mascot = Prefs.instance.mascot ? name : null;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            reverseDuration: const Duration(milliseconds: 140),
            transitionBuilder: _pop,
            child: KeyedSubtree(
              key: ValueKey<String?>(mascot),
              child: mascot != null ? ClawdIcon(mascot, size: size) : fallback,
            ),
          );
        },
      );
}

/// Shows the mascot during an activation without delaying navigation.
class MascotPress extends StatefulWidget {
  const MascotPress(this.name, {super.key, required this.onPressed, required this.builder});
  final String? name;
  final VoidCallback onPressed;
  final Widget Function(BuildContext context, String? activeMascot, VoidCallback press) builder;

  @override
  State<MascotPress> createState() => _MascotPressState();
}

class _MascotPressState extends State<MascotPress> {
  Timer? _reset;

  void _press() {
    if (widget.name != null && Prefs.instance.mascot) {
      _reset?.cancel();
      setState(() {
        _reset = Timer(const Duration(milliseconds: 700), () => setState(() => _reset = null));
      });
    }
    widget.onPressed();
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _reset == null ? null : widget.name, _press);
}

/// The switch's notice and the license texts it refers to.
abstract final class MascotCredits {
  static void showLicenses(BuildContext context) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(L('mascot.licenses')),
          content: const SingleChildScrollView(child: SelectableText(contextMenuBuilder: appTextMenu, _license)),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))],
        ),
      );

  static const _license = '''Clawd Icons
https://github.com/TangfanOVO/clawd-icons

MIT License

Copyright (c) 2026 唐幡 (TangfanOVO)
Copyright (c) 2026 Marcio Granzotto Rodrigues (Clawd base artwork)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'''; // i18n-exempt: the license is quoted as written
}
