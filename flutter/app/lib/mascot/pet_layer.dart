import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tl_core/tl_core.dart';

import '../app/prefs.dart';
import '../platform/system_random.dart';

/// [child] with the mascot's little Clawd over it, in wide windows while the mode is on: at home
/// in the bottom-right corner, wandering over the content without being in its way (only the
/// crab itself takes taps). All it does comes from the core (core/src/pet.rs).
class MascotPetLayer extends StatelessWidget {
  const MascotPetLayer({super.key, required this.child});
  final Widget child;

  /// A window big enough to have room for it: not a phone, not a narrowed window.
  static bool fits(Size s) => s.width >= 700 && s.height >= 500;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Prefs.instance,
        builder: (context, content) => Stack(children: [
          content!,
          if (Prefs.instance.mascot && fits(MediaQuery.sizeOf(context))) const Positioned.fill(child: _Pet()),
        ]),
        child: child,
      );
}

class _Pet extends StatefulWidget {
  const _Pet();
  @override
  State<_Pet> createState() => _PetState();
}

class _PetState extends State<_Pet> with WidgetsBindingObserver {
  final _engine = PetEngine(const SystemRandom().nextInt(1 << 31) + 1);
  final _picture = ValueNotifier<List<double>>(const []);
  final _clock = Stopwatch()..start();
  Timer? _timer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    _start();
  }

  // Thirty pictures a second are plenty for pixel art; nothing is painted when nothing changed.
  void _start() => _timer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());

  void _tick() {
    final dt = _clock.elapsedMicroseconds / 1e6;
    _clock.reset();
    final next = _engine.tick(dt);
    final old = _picture.value;
    var same = old.length == next.length;
    for (var i = 0; same && i < next.length; i++) {
      same = old[i] == next[i];
    }
    if (!same) _picture.value = next;
  }

  /// The pointer anywhere in the window, over whatever is there (hover events only reach the
  /// widgets under the pointer): only a mouse or trackpad, only in the foreground.
  void _pointer(PointerEvent e) {
    if (!_foreground || !mounted || e.kind == PointerDeviceKind.touch) return;
    if (e is PointerRemovedEvent) return _engine.pointerGone();
    if (e is PointerHoverEvent || e is PointerMoveEvent) {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final at = box.globalToLocal(e.position);
      if (box.paintBounds.contains(at)) {
        _engine.pointer(at.dx, at.dy);
      } else {
        _engine.pointerGone();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _engine.pointerGone();
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    } else {
      _clock.reset();
      _start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    WidgetsBinding.instance.removeObserver(this);
    _engine.dispose();
    _picture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: _PetPicture(engine: _engine, picture: _picture));
}

class _PetPicture extends LeafRenderObjectWidget {
  const _PetPicture({required this.engine, required this.picture});
  final PetEngine engine;
  final ValueNotifier<List<double>> picture;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPet(engine, picture);
}

/// Paints the rectangles; takes a press only on the crab, everything else goes to what is below.
class _RenderPet extends RenderBox {
  _RenderPet(this.engine, this.picture);
  final PetEngine engine;
  final ValueNotifier<List<double>> picture;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    picture.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    picture.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;
  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;
  @override
  void performResize() {
    super.performResize();
    engine.setBounds(size.width, size.height, 18, 18);
  }

  @override
  bool hitTestSelf(Offset position) => engine.hit(position.dx, position.dy);

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent) engine.tap(event.localPosition.dx, event.localPosition.dy);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final paint = Paint();
    final p = picture.value;
    for (var i = 0; i + 4 < p.length; i += 5) {
      paint.color = Color(p[i + 4].toInt());
      canvas.drawRect(Rect.fromLTWH(offset.dx + p[i], offset.dy + p[i + 1], p[i + 2], p[i + 3]), paint);
    }
  }
}
