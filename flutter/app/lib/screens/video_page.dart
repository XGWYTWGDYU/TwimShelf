import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../app/prefs.dart';
import '../l10n/l10n.dart';
import '../platform/os.dart';
import '../platform/pip.dart';
import '../platform/video.dart';

/// One video of the viewer, backed by the same [VideoSession] as its feed card:
///  * double tap: play / pause · single tap: the controls (they hide after 3 s of playing)
///  * long press: 2.5× while held
///  * drags (unless 视频禁用手势): sideways seeks (a full width covers up to two minutes), up and
///    down set the brightness on the left half and the volume on the right half; while they are on,
///    a sideways swipe does not turn the page: the arrows on both sides do
///  * the bar: play, the time and progress, lock (everything else stops answering until it is
///    unlocked), rotate (phones and tablets), share, close
///  * the caption sits above the controls, under one shade from the caption to the bottom edge,
///    and comes and goes with them
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.path,
    required this.active,
    required this.caption,
    required this.counter,
    required this.onClose,
    required this.onStep,
    required this.onShare,
    this.isFavorited = false,
    this.onToggleFavorite,
    required this.canPrevious,
    required this.canNext,
    this.onControlsChanged,
    this.onTurn,
    this.fallbackPreview,
    this.routeAnimation,
    this.dismissProgress,
  });
  /// The video was turned on its own, or back (the viewer stops paging while it is). Only the
  /// video turns: the app's orientation is never changed, so nothing behind it ever turns.
  final ValueChanged<bool>? onTurn;
  final String path;
  final bool active;
  /// The post's caption (null for none): shown above the controls.
  final Widget? caption;
  final String counter;
  final VoidCallback onClose;
  final void Function(int delta) onStep;
  /// With where the button is, for the menu.
  final ValueChanged<Rect?> onShare;
  final bool isFavorited;
  final VoidCallback? onToggleFavorite;
  final bool canPrevious, canNext;
  final ValueChanged<bool>? onControlsChanged;
  /// Optional fallback image (e.g. the grid's decoded thumbnail) shown while opening.
  final Widget? fallbackPreview;
  final Animation<double>? routeAnimation;
  /// Interactive dismiss drag progress (0..1) so player overlays fade out as the video shrinks.
  final ValueListenable<double>? dismissProgress;

  @override
  State<VideoPage> createState() => VideoPageState();
}

enum _Pan { none, seek, brightness, volume }

class VideoPageState extends State<VideoPage> {
  late final VideoSession _session = VideoSession.of(widget.path);
  VideoPlayback? _boundPlayback;
  bool _playing = false;
  bool _controls = true;
  bool _locked = false;
  bool _lockFlash = false;
  bool _pipSupported = false;
  bool _inPip = false;
  Timer? _hide;
  Timer? _stallWatch;
  Duration? _lastWatchPos;
  DateTime? _lastProgressAt;
  DateTime? _lastRecoverAt;
  bool _recovering = false;
  double _volume = 100;
  double _rate = 1.0;
  final _subs = <StreamSubscription<dynamic>>[];

  // the readout pill in the middle (speed, seek target, brightness, volume)
  IconData? _hudIcon;
  String? _hudText;
  double? _hudLevel;
  Timer? _hudTimer;

  /// Quarter turns of the whole page (video, controls, gestures) inside the screen: 0 or 1.
  int _turns = 0;
  Orientation? _orientation;

  _Pan _pan = _Pan.none;
  double _panStart = 0;
  Offset _panOrigin = Offset.zero;
  bool _scrubbing = false;
  Duration? _scrubPosition;
  Duration? _pendingSeek;
  Future<void>? _seekWork;

  VideoPlayback? get _video => _session.playback;

  // Keep one decoder seek in flight; newer pointer positions replace stale work.
  Future<void> _seek(Duration target) {
    _pendingSeek = target;
    return _seekWork ??= _drainSeeks().whenComplete(() => _seekWork = null);
  }

  Future<void> _drainSeeks() async {
    while (mounted && _pendingSeek != null) {
      final next = _pendingSeek!;
      _pendingSeek = null;
      await _video?.seek(next);
    }
  }

  void _previewSeek(Duration target) {
    setState(() => _scrubPosition = target);
    unawaited(_seek(target));
  }

  Future<void> _finishSeek(Duration target) async {
    await _seek(target);
    if (!mounted) return;
    setState(() {
      _scrubbing = false;
      _scrubPosition = null;
    });
    _scheduleHide();
  }

  bool get gestures => !Prefs.instance.playerGesturesOff;

  /// Locked (the lock button): the viewer's dismiss swipes wait too.
  bool get locked => _locked;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    if (OS.isAndroid) {
      _inPip = AndroidPip.inPip.value;
      AndroidPip.inPip.addListener(_onPipChanged);
      unawaited(AndroidPip.isSupported().then((ok) {
        if (mounted && ok != _pipSupported) setState(() => _pipSupported = ok);
      }));
    }
    if (widget.active) _activate();
  }

  void _onPipChanged() {
    if (!mounted) return;
    final inPip = AndroidPip.inPip.value;
    if (inPip != _inPip) setState(() => _inPip = inPip);
  }

  Future<void> _enterPip() async {
    final st = _video?.surfaceController.player.state;
    final dw = st?.videoParams.dw ?? 0, dh = st?.videoParams.dh ?? 0;
    final sw = st?.width ?? 0, sh = st?.height ?? 0;
    final w = dw > 0 && dh > 0 ? dw : (sw > 0 && sh > 0 ? sw : 16);
    final h = dw > 0 && dh > 0 ? dh : (sw > 0 && sh > 0 ? sh : 9);
    final ok = await AndroidPip.enter(width: w, height: h);
    if (!ok && mounted) {
      _showHud(Icons.picture_in_picture_alt, text: L('viewer.pipFailed'));
    }
  }

  void _onSessionChanged() {
    final v = _session.playback;
    if (v != null && v != _boundPlayback) {
      _bindPlayback(v);
    } else if (v == null && _boundPlayback != null) {
      _clearPlaybackSubs();
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the screen itself turned (the device was turned): it fits by itself now
    final o = MediaQuery.orientationOf(context);
    if (_orientation != null && o != _orientation && _turns != 0) {
      _turns = 0;   // (a build follows anyway)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onTurn?.call(false);
      });
    }
    _orientation = o;
  }

  @override
  void didUpdateWidget(VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.active && !old.active) {
      _activate();
    } else if (!widget.active && old.active) {
      _deactivate();
      // a page left behind comes back upright (the viewer has already resumed paging)
      _turns = 0;
    }
  }

  Future<void> _activate() async {
    final existing = _session.playback;
    if (existing != null) {
      _bindPlayback(existing);
    }
    final v = await _session.attachViewer(this);
    if (!mounted || v == null || !widget.active) return;
    if (v != _boundPlayback) _bindPlayback(v);
    await _setPlaying(true);
    _startStallWatch();
    _scheduleHide();
    _autoLandscape();
  }

  void _deactivate() {
    _stopStallWatch();
    _clearPlaybackSubs();
    _session.detachViewer(this);
    if (mounted) setState(() => _playing = false);
  }

  void _startStallWatch() {
    _stallWatch?.cancel();
    _lastWatchPos = _video?.currentPosition;
    _lastProgressAt = DateTime.now();
    _stallWatch = Timer.periodic(const Duration(milliseconds: 400), (_) => _checkStall());
  }

  void _stopStallWatch() {
    _stallWatch?.cancel();
    _stallWatch = null;
    _lastWatchPos = null;
    _lastProgressAt = null;
  }

  Future<void> _checkStall() async {
    if (!mounted || !widget.active || !_playing || _scrubbing || _recovering) return;
    final v = _video;
    if (v == null || v.isClosed) return;
    final st = v.surfaceController.player.state;
    if (!st.playing) return;
    final dur = v.currentDuration;
    if (dur <= Duration.zero) return;
    final pos = v.currentPosition;
    final now = DateTime.now();
    if (_lastWatchPos == null || pos != _lastWatchPos) {
      _lastWatchPos = pos;
      _lastProgressAt = now;
      return;
    }
    final stalled = now.difference(_lastProgressAt ?? now);
    if (stalled < const Duration(milliseconds: 850)) return;
    if (_lastRecoverAt != null && now.difference(_lastRecoverAt!) < const Duration(milliseconds: 2500)) return;
    _recovering = true;
    _lastRecoverAt = now;
    try {
      if (dur - pos < const Duration(milliseconds: 400)) {
        await v.seek(Duration.zero);
        await v.play();
      } else {
        // Recover from iOS libmpv audiounit / decoder clock stalls without flipping UI state.
        await v.pause();
        if (mounted && widget.active && _playing && !v.isClosed) {
          await v.play();
        }
      }
      _lastProgressAt = DateTime.now();
    } catch (_) {
    } finally {
      _recovering = false;
    }
  }

  void _bindPlayback(VideoPlayback v) {
    _clearPlaybackSubs();
    _boundPlayback = v;
    _playing = v.surfaceController.player.state.playing;
    _subs.add(v.position.listen((p) {
      if (mounted && !_scrubbing) setState(() {});
    }));
    _subs.add(v.surfaceController.player.stream.playing.listen((playing) {
      if (mounted && !_recovering) setState(() => _playing = playing);
    }));
  }

  void _clearPlaybackSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _boundPlayback = null;
  }

  /// 横屏视频自动横屏: a video wider than tall, opened on a portrait screen, is turned.
  void _autoLandscape() {
    if (!Prefs.instance.autoLandscape || _turns != 0 || !widget.active) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width >= size.height) return;
    // the video's own size is known once its first frame is decoded
    final c = _video?.surfaceController;
    final w = c?.player.state.width ?? 0, h = c?.player.state.height ?? 0;
    if (w > h && h > 0) _setTurned(true);
  }

  /// Portrait ⇄ landscape for the video alone: whatever the screen is, the page turns a quarter
  /// (clockwise) or back. Works where the system will not turn the app (an iPad that can
  /// multitask, Android's split screen, the orientation lock).
  void _rotate() {
    if (_locked) return;
    _setTurned(_turns == 0);
  }

  void _setTurned(bool on) {
    final turns = on ? 1 : 0;
    if (turns == _turns || !mounted) return;
    setState(() => _turns = turns);
    widget.onTurn?.call(on);
    _showControls(true);
    _scheduleHide();
  }

  Future<void> _setPlaying(bool play) async {
    final v = _video;
    if (v == null) return;
    play ? await v.play() : await v.pause();
    if (!mounted) return;
    setState(() => _playing = play);
    if (play) {
      _scheduleHide();
    } else {
      _showControls(true);
    }
  }

  Future<void> togglePlay() => _setPlaying(!_playing);

  /// ↑ ↓ on a keyboard: the player's volume in tenths.
  void stepVolume(int delta) {
    _volume = (_volume + delta * 10).clamp(0, 100);
    _video?.setMuted(_volume == 0);
    _video?.setVolume(_volume);
    _showHud(_volume == 0 ? Icons.volume_off : Icons.volume_up, level: _volume / 100);
  }

  void _showControls(bool on) {
    if (_controls == on) return;
    setState(() => _controls = on);
    widget.onControlsChanged?.call(on);
    if (on) _scheduleHide();
  }

  void _scheduleHide() {
    // Bottom controls stay visible on inactivity across all versions; tap toggles manually.
    _hide?.cancel();
  }

  String _formatRate(double r) => r == r.truncateToDouble() ? '${r.toInt()}×' : '$r×';

  void _setRate(double r) {
    setState(() => _rate = r);
    _video?.setRate(r);
  }

  Future<void> _showSpeedMenu(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final chosen = await showMenu<double>(
      context: buttonContext,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy - 260, pos.dx + box.size.width, pos.dy),
      items: [
        for (final r in rates)
          CheckedPopupMenuItem<double>(
            value: r,
            checked: (r - _rate).abs() < 0.01,
            child: Text(_formatRate(r)),
          ),
      ],
    );
    if (chosen != null && mounted) _setRate(chosen);
  }

  void _showHud(IconData icon, {String? text, double? level, bool sticky = false}) {
    _hudTimer?.cancel();
    setState(() {
      _hudIcon = icon;
      _hudText = text;
      _hudLevel = level;
    });
    if (!sticky) _hudTimer = Timer(const Duration(milliseconds: 900), _hideHud);
  }

  void _hideHud({Duration after = Duration.zero}) {
    _hudTimer?.cancel();
    _hudTimer = Timer(after, () {
      if (mounted) setState(() => _hudIcon = null);
    });
  }

  void _toggleLock() {
    setState(() => _locked = !_locked);
    _showHud(_locked ? Icons.lock : Icons.lock_open, text: _locked ? L('viewer.locked') : L('viewer.unlocked'));
    if (!_locked) _scheduleHide();
  }

  /// While locked, a tap shows only the lock for a moment.
  void _flashLock() {
    setState(() => _lockFlash = true);
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _lockFlash = false);
    });
  }

  // ---- gestures

  void _tap() => _locked ? _flashLock() : _showControls(!_controls);

  /// A long press boosts to 2.5× and returns to normal speed.
  double _boostFrom = 1;
  void _longPressStart() {
    if (_locked) return;
    _boostFrom = _rate;
    _video?.setRate(2.5);
    _showHud(Icons.fast_forward, text: '2.5×', sticky: true); // i18n-exempt: a speed, not words
  }

  void _longPressEnd() {
    _video?.setRate(_boostFrom);
    _hideHud();
  }

  /// The drags belong to a touch screen (a finger or a pen): with a mouse or a trackpad they do
  /// nothing, on any platform.
  bool _touch = false;

  /// Whether this device lets an app set the screen's brightness for the whole system: iOS and
  /// iPadOS do; Android once the person allowed changing system settings.
  static bool? _canSetBrightness;
  static Future<bool> _systemBrightness() async {
    try {
      return _canSetBrightness ??= await ScreenBrightness.instance.canChangeSystemBrightness;
    } catch (_) {
      return _canSetBrightness = false;
    }
  }

  Future<void> _panStartAt(DragStartDetails d, Size size) async {
    _touch = d.kind == PointerDeviceKind.touch || d.kind == PointerDeviceKind.stylus || d.kind == PointerDeviceKind.invertedStylus;
    if (_locked || !gestures || !_touch) return;
    _panOrigin = d.localPosition;
    _pan = _Pan.none;
  }

  Future<void> _panUpdate(DragUpdateDetails d, Size size) async {
    if (_locked || !gestures || !_touch) return;
    final v = _video;
    if (v == null) return;
    final moved = d.localPosition - _panOrigin;
    if (_pan == _Pan.none) {
      if (moved.distance < 8) return;
      if (moved.dx.abs() > moved.dy.abs()) {
        _pan = _Pan.seek;
        _panStart = v.currentPosition.inMilliseconds / 1000;
        _scrubbing = true;
      } else if (_panOrigin.dx < size.width / 2) {
        if (!await _systemBrightness()) return;
        _pan = _Pan.brightness;
        try {
          _panStart = await ScreenBrightness.instance.system;
        } catch (_) {
          _panStart = 0.5;
        }
      } else {
        _pan = _Pan.volume;
        try {
          await FlutterVolumeController.updateShowSystemUI(false);
          _panStart = await FlutterVolumeController.getVolume() ?? 0.5;
        } catch (_) {
          _pan = _Pan.none;
          return;
        }
      }
    }
    final duration = v.currentDuration.inMilliseconds / 1000;
    switch (_pan) {
      case _Pan.seek:
        // a full width covers min(duration, 120 s): precise on short clips, still quick on long ones
        final span = duration.clamp(1, 120).toDouble();
        final target = (_panStart + moved.dx / size.width * span).clamp(0, duration).toDouble();
        _previewSeek(Duration(milliseconds: (target * 1000).round()));
        _showHud(target >= _panStart ? Icons.fast_forward : Icons.fast_rewind,
            text: '${_time(Duration(milliseconds: (target * 1000).round()))} / ${_time(v.currentDuration)}', sticky: true);
      case _Pan.brightness:
        final b = (_panStart - moved.dy / (size.height * 0.7)).clamp(0.0, 1.0);
        try {
          await ScreenBrightness.instance.setSystemScreenBrightness(b);
        } catch (_) {}
        _showHud(Icons.brightness_6, level: b, sticky: true);
      case _Pan.volume:
        final level = (_panStart - moved.dy / (size.height * 0.7)).clamp(0.0, 1.0);
        try {
          await FlutterVolumeController.setVolume(level);
        } catch (_) {}
        _showHud(level == 0 ? Icons.volume_off : Icons.volume_up, level: level, sticky: true);
      case _Pan.none:
        break;
    }
  }

  void _panEnd() {
    if (_pan == _Pan.seek && _video != null) {
      unawaited(_finishSeek(_scrubPosition ?? _video!.currentPosition));
    }
    _pan = _Pan.none;
    _hideHud(after: const Duration(milliseconds: 400));
  }

  /// Called as the viewer begins its close animation: mutes and hides controls while the shared
  /// [VideoSession] keeps playing inside the shrinking zoom rectangle.
  void leaveForCard() {
    _stopStallWatch();
    _hide?.cancel();
    if (mounted && _controls) setState(() => _controls = false);
    _session.prepareLeaveViewer();
  }

  @override
  void dispose() {
    _stopStallWatch();
    _session.removeListener(_onSessionChanged);
    if (OS.isAndroid) AndroidPip.inPip.removeListener(_onPipChanged);
    _clearPlaybackSubs();
    _hide?.cancel();
    _hudTimer?.cancel();
    _session.detachViewer(this);
    super.dispose();
  }

  static String _time(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_session.error != null) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 56));
    final v = _video;
    final total = v?.currentDuration ?? Duration.zero;
    final at = _scrubPosition ?? (v?.currentPosition ?? _session.position);
    final showBar = !_inPip && _controls && !_locked && v != null;
    final page = LayoutBuilder(builder: (context, box) {
      // below the turn: the turned screen's safe area
      final pad = MediaQuery.paddingOf(context);
      final size = box.biggest;
      Widget fadeWithRoute(Widget overlay) {
        final anim = widget.routeAnimation;
        final dismiss = widget.dismissProgress;
        if (anim == null && dismiss == null) return overlay;
        return AnimatedBuilder(
          animation: Listenable.merge([?anim, ?dismiss]),
          child: overlay,
          builder: (context, child) {
            final routeOp = anim == null
                ? 1.0
                : Curves.easeIn.transform(((anim.value - 0.30) / 0.70).clamp(0.0, 1.0));
            final dismissOp = dismiss == null
                ? 1.0
                : (1 - dismiss.value * 4).clamp(0.0, 1.0);
            return Opacity(opacity: routeOp * dismissOp, child: child);
          },
        );
      }

      final compactLandscape = size.width > size.height && size.shortestSide < 600;
      return Stack(children: [
        Positioned.fill(
          // the long press (2.5×) answers after a quarter second, as native
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 250)),
                (r) => r
                  ..onLongPressStart = ((_) => _longPressStart())
                  ..onLongPressEnd = ((_) => _longPressEnd()),
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tap,
              onDoubleTap: _locked ? null : togglePlay,
              onPanStart: gestures ? (d) => _panStartAt(d, size) : null,
              onPanUpdate: gestures ? (d) => _panUpdate(d, size) : null,
              onPanEnd: gestures ? (_) => _panEnd() : null,
              child: VideoSessionView(
                session: _session,
                fill: Colors.transparent,
                showPlayBadgeWhenStopped: widget.fallbackPreview == null,
                fallback: widget.fallbackPreview,
              ),
            ),
          ),
        ),
        // 没有连接耳机，已静音 · 开启声音
        if (v != null && !_inPip)
          ValueListenableBuilder<bool>(
            valueListenable: v.needsSpeakerConsent,
            builder: (context, ask, _) => !ask
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.topCenter,
                    child: fadeWithRoute(
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(L('audio.prompt')),
                                TextButton(key: const ValueKey('soundOn'), onPressed: () => v.allowSpeakerForCurrentVideo(), child: Text(L('audio.turnOn'))),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        if (_hudIcon != null && !_inPip)
          Positioned(
            top: pad.top + 40,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: fadeWithRoute(_Hud(icon: _hudIcon!, text: _hudText, level: _hudLevel)),
              ),
            ),
          ),
        // the arrows, while the drags hold the sideways swipe
        if (gestures && showBar && widget.canPrevious)
          Positioned(left: 8 + pad.left, top: 0, bottom: 0, child: Center(child: fadeWithRoute(_RoundButton(key: const ValueKey('videoPrevious'), icon: Icons.chevron_left, tooltip: L('viewer.previous'), onPressed: () => widget.onStep(-1))))),
        if (gestures && showBar && widget.canNext)
          Positioned(right: 8 + pad.right, top: 0, bottom: 0, child: Center(child: fadeWithRoute(_RoundButton(key: const ValueKey('videoNext'), icon: Icons.chevron_right, tooltip: L('viewer.next'), onPressed: () => widget.onStep(1))))),
        // Compact-screen landscape (p3 design): top-left back button, bottom dark scrim with
        // frosted caption on the left, our real controls pill on the right, and play + scrubber +
        // time on the bottom row. Portrait phones & tablets keep the solid black bottom dock.
        if (v != null && compactLandscape) ...[
          Positioned(
            top: 12 + pad.top,
            left: 12 + pad.left,
            child: IgnorePointer(
              ignoring: !showBar,
              child: fadeWithRoute(
                AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                    ),
                    child: IconButton(
                      key: const ValueKey('videoClose'),
                      color: Colors.white,
                      iconSize: 20,
                      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                      padding: EdgeInsets.zero,
                      tooltip: L('viewer.close'),
                      icon: const Icon(Icons.arrow_back),
                      onPressed: widget.onClose,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !showBar,
              child: fadeWithRoute(
                AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(14 + pad.left, 24, 14 + pad.right, 6 + pad.bottom),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: widget.caption == null
                                    ? const SizedBox.shrink()
                                    : Theme(
                                        data: Theme.of(context).copyWith(
                                          brightness: Brightness.dark,
                                          colorScheme: ColorScheme.fromSeed(
                                            seedColor: Theme.of(context).colorScheme.primary,
                                            brightness: Brightness.dark,
                                          ),
                                        ),
                                        child: widget.caption!,
                                      ),
                              ),
                              const SizedBox(width: 12),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.48),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    if (widget.onToggleFavorite != null)
                                      _BarButton(
                                        key: const ValueKey('videoFavorite'),
                                        icon: widget.isFavorited ? Icons.star : Icons.star_border,
                                        color: widget.isFavorited ? const Color(0xFFF5B800) : Colors.white,
                                        tooltip: widget.isFavorited ? L('common.unfavorite') : L('common.favorite'),
                                        onPressed: widget.onToggleFavorite!,
                                      ),
                                    Builder(
                                      builder: (button) => _BarButton(
                                        key: const ValueKey('videoShare'),
                                        icon: Icons.ios_share,
                                        tooltip: L('viewer.share'),
                                        onPressed: () {
                                          final box = button.findRenderObject() as RenderBox?;
                                          widget.onShare(box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                                        },
                                      ),
                                    ),
                                    _BarButton(key: const ValueKey('videoLock'), icon: Icons.lock_open, tooltip: L('viewer.lock'), onPressed: _toggleLock),
                                    _BarButton(key: const ValueKey('videoRotate'), icon: Icons.screen_rotation_alt_rounded, tooltip: L('viewer.rotate'), onPressed: _rotate),
                                    if (_pipSupported)
                                      _BarButton(key: const ValueKey('videoPip'), icon: Icons.picture_in_picture_alt, tooltip: L('viewer.pip'), onPressed: _enterPip),
                                    ValueListenableBuilder<bool>(
                                      valueListenable: v.muted,
                                      builder: (context, muted, _) => _BarButton(
                                        key: const ValueKey('videoMute'),
                                        icon: muted ? Icons.volume_off : Icons.volume_up,
                                        tooltip: muted ? L('audio.turnOn') : null,
                                        onPressed: () => v.setMuted(!muted),
                                      ),
                                    ),
                                    Builder(
                                      builder: (btnCtx) => TextButton(
                                        key: const ValueKey('videoSpeed'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size(36, 40),
                                          padding: const EdgeInsets.symmetric(horizontal: 6),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => _showSpeedMenu(btnCtx),
                                        child: Text(
                                          _formatRate(_rate),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(children: [
                            _BarButton(
                              key: const ValueKey('videoPlay'),
                              icon: _playing ? Icons.pause : Icons.play_arrow,
                              tooltip: _playing ? L('viewer.pause') : L('viewer.play'),
                              onPressed: togglePlay,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: SizedBox(
                                height: 28,
                                child: _TopEdgeScrubBar(
                                  value: total.inMilliseconds == 0 ? 0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                                  enabled: total != Duration.zero,
                                  onStart: () {
                                    _hide?.cancel();
                                    setState(() {
                                      _scrubbing = true;
                                      _scrubPosition = v.currentPosition;
                                    });
                                  },
                                  onChanged: (f) => _previewSeek(total * f),
                                  onEnd: (f) => _finishSeek(total * f),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '${_time(at)} / ${_time(total)}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 12,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        // Portrait phones & tablets/desktops: solid black bottom dock with top-edge scrubber.
        if (v != null && !compactLandscape)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !showBar,
              child: fadeWithRoute(
                AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.caption != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(16 + pad.left, 0, 16 + pad.right, 10),
                          child: widget.caption!,
                        ),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ColoredBox(
                            color: Colors.black,
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(8 + pad.left, 6, 8 + pad.right, 4 + pad.bottom),
                              child: Row(children: [
                                _BarButton(key: const ValueKey('videoPlay'), icon: _playing ? Icons.pause : Icons.play_arrow, tooltip: _playing ? L('viewer.pause') : L('viewer.play'), onPressed: togglePlay),
                                Text(
                                  '${_time(at)} / ${_time(total)}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 12,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                                const Spacer(),
                                ValueListenableBuilder<bool>(
                                  valueListenable: v.muted,
                                  builder: (context, muted, _) => _BarButton(
                                    key: const ValueKey('videoMute'),
                                    icon: muted ? Icons.volume_off : Icons.volume_up,
                                    tooltip: muted ? L('audio.turnOn') : null,
                                    onPressed: () => v.setMuted(!muted),
                                  ),
                                ),
                                _BarButton(key: const ValueKey('videoLock'), icon: Icons.lock_open, tooltip: L('viewer.lock'), onPressed: _toggleLock),
                                _BarButton(key: const ValueKey('videoRotate'), icon: Icons.screen_rotation_alt_rounded, tooltip: L('viewer.rotate'), onPressed: _rotate),
                                if (_pipSupported)
                                  _BarButton(key: const ValueKey('videoPip'), icon: Icons.picture_in_picture_alt, tooltip: L('viewer.pip'), onPressed: _enterPip),
                                if (widget.onToggleFavorite != null)
                                  _BarButton(
                                    key: const ValueKey('videoFavorite'),
                                    icon: widget.isFavorited ? Icons.star : Icons.star_border,
                                    color: widget.isFavorited ? const Color(0xFFF5B800) : Colors.white,
                                    tooltip: widget.isFavorited ? L('common.unfavorite') : L('common.favorite'),
                                    onPressed: widget.onToggleFavorite!,
                                  ),
                                Builder(
                                  builder: (button) => _BarButton(key: const ValueKey('videoShare'), icon: Icons.ios_share, tooltip: L('viewer.share'), onPressed: () {
                                    final box = button.findRenderObject() as RenderBox?;
                                    widget.onShare(box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                                  }),
                                ),
                                _BarButton(key: const ValueKey('videoClose'), icon: Icons.close, tooltip: L('viewer.close'), onPressed: widget.onClose),
                              ]),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: -12,
                            height: 24,
                            child: _TopEdgeScrubBar(
                              value: total.inMilliseconds == 0 ? 0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                              enabled: total != Duration.zero,
                              onStart: () {
                                _hide?.cancel();
                                setState(() {
                                  _scrubbing = true;
                                  _scrubPosition = v.currentPosition;
                                });
                              },
                              onChanged: (f) => _previewSeek(total * f),
                              onEnd: (f) => _finishSeek(total * f),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // locked: only the lock, in the middle of the width at the bar's height
        if (!_inPip && _locked && (_lockFlash || _controls))
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + pad.bottom,
            child: Center(child: _RoundButton(key: const ValueKey('videoUnlock'), icon: Icons.lock, tooltip: L('viewer.unlock'), onPressed: _toggleLock)),
          ),
      ]);
    });
    if (_turns == 0) return page;
    // a quarter turn clockwise: the page's top is the screen's right edge, its left the top…
    final mq = MediaQuery.of(context);
    EdgeInsets turned(EdgeInsets e) => EdgeInsets.fromLTRB(e.top, e.right, e.bottom, e.left);
    return RotatedBox(
      key: const ValueKey('videoTurned'),
      quarterTurns: _turns,
      child: MediaQuery(
        data: mq.copyWith(size: mq.size.flipped, padding: turned(mq.padding), viewPadding: turned(mq.viewPadding), viewInsets: EdgeInsets.zero),
        child: page,
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.icon, this.color, this.tooltip, required this.onPressed});
  final IconData icon;
  final Color? color;
  final String? tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
        color: color ?? Colors.white,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      );
}

class _TopEdgeScrubBar extends StatefulWidget {
  const _TopEdgeScrubBar({
    required this.value,
    required this.enabled,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });
  final double value;
  final bool enabled;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;

  @override
  State<_TopEdgeScrubBar> createState() => _TopEdgeScrubBarState();
}

class _TopEdgeScrubBarState extends State<_TopEdgeScrubBar> {
  bool _dragging = false;
  double _last = 0;

  double _frac(BuildContext context, double dx) {
    final box = context.findRenderObject() as RenderBox?;
    final w = box?.size.width ?? 0;
    return w > 0 ? (dx / w).clamp(0.0, 1.0) : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragDown: widget.enabled
          ? (d) {
              setState(() => _dragging = true);
              widget.onStart();
              _last = _frac(context, d.localPosition.dx);
              widget.onChanged(_last);
            }
          : null,
      onHorizontalDragUpdate: widget.enabled
          ? (d) {
              _last = _frac(context, d.localPosition.dx);
              widget.onChanged(_last);
            }
          : null,
      onHorizontalDragEnd: widget.enabled
          ? (_) {
              setState(() => _dragging = false);
              widget.onEnd(_last);
            }
          : null,
      onHorizontalDragCancel: widget.enabled
          ? () {
              setState(() => _dragging = false);
              widget.onEnd(_last);
            }
          : null,
      onTapUp: widget.enabled
          ? (d) {
              widget.onStart();
              final f = _frac(context, d.localPosition.dx);
              widget.onChanged(f);
              widget.onEnd(f);
            }
          : null,
      child: CustomPaint(
        painter: _TopEdgeScrubPainter(value: widget.value, dragging: _dragging),
      ),
    );
  }
}

class _TopEdgeScrubPainter extends CustomPainter {
  const _TopEdgeScrubPainter({required this.value, required this.dragging});
  final double value;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final trackH = dragging ? 4.5 : 2.5;
    final top = (size.height - trackH) / 2;
    final fillW = (size.width * value).clamp(0.0, size.width);
    canvas.drawRect(Rect.fromLTWH(0, top, size.width, trackH), Paint()..color = Colors.white.withValues(alpha: 0.28));
    canvas.drawRect(Rect.fromLTWH(0, top, fillW, trackH), Paint()..color = Colors.white);
    final radius = dragging ? 7.0 : 4.0;
    final cx = fillW.clamp(radius, (size.width - radius).clamp(radius, double.infinity));
    canvas.drawCircle(Offset(cx, size.height / 2), radius, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_TopEdgeScrubPainter old) => old.value != value || old.dragging != dragging;
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.88),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// Top-centered Material 3 Expressive HUD reporting gesture feedback (speed, seek, brightness, volume, lock).
class _Hud extends StatelessWidget {
  const _Hud({required this.icon, this.text, this.level});
  final IconData icon;
  final String? text;
  final double? level;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme;
    final scheme = base.brightness == Brightness.dark
        ? base
        : ColorScheme.fromSeed(seedColor: base.primary, brightness: Brightness.dark);
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    return Material(
      key: const ValueKey('hud'),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: scheme.onSurface, size: 18),
          if (text != null) ...[const SizedBox(width: 8), Text(text!, style: labelStyle)],
          if (level != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: level,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
                minHeight: 6,
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
