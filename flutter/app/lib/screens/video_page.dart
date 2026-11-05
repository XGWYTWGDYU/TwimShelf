import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../app/prefs.dart';
import '../l10n/l10n.dart';
import '../platform/video.dart';

/// One video of the viewer, as the native player:
///  * double tap: play / pause · single tap: the controls (they hide after 3 s of playing)
///  * long press: 2.5× while held
///  * drags (unless 视频禁用手势): sideways seeks (a full width covers up to two minutes), up and
///    down set the brightness on the left half and the volume on the right half; while they are on,
///    a sideways swipe does not turn the page: the arrows on both sides do
///  * the bar: play, the time and progress, lock (everything else stops answering until it is
///    unlocked), rotate (phones and tablets), share, close
///  * the caption sits above the controls, under one shade from the caption to the bottom edge,
///    and comes and goes with them
/// It plays while it is the page on screen, starts muted (headphones only asks first) and loops.
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
    required this.canPrevious,
    required this.canNext,
    this.onControlsChanged,
    this.onTurn,
  });
  /// Turns the screen (true: landscape). The viewer owns it: leaving the viewer goes back to
  /// the orientation it opened in.
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
  final bool canPrevious, canNext;
  final ValueChanged<bool>? onControlsChanged;

  @override
  State<VideoPage> createState() => VideoPageState();
}

enum _Pan { none, seek, brightness, volume }

class VideoPageState extends State<VideoPage> {
  VideoPlayback? _video;
  bool _playing = false;
  bool _controls = true;
  bool _locked = false;
  bool _lockFlash = false;
  Object? _error;
  Timer? _hide;
  double _volume = 100;
  final _subs = <StreamSubscription<Duration>>[];

  // the readout pill in the middle (speed, seek target, brightness, volume)
  IconData? _hudIcon;
  String? _hudText;
  double? _hudLevel;
  Timer? _hudTimer;

  _Pan _pan = _Pan.none;
  double _panStart = 0;
  Offset _panOrigin = Offset.zero;
  bool _scrubbing = false;

  static bool get _mobile => !kIsWeb && (Platform.isIOS || Platform.isAndroid);
  bool get gestures => !Prefs.instance.playerGesturesOff;

  @override
  void initState() {
    super.initState();
    if (widget.active) _open();
  }

  @override
  void didUpdateWidget(VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.active && !old.active) {
      _video == null ? _open() : _setPlaying(true);
    } else if (!widget.active && old.active) {
      _setPlaying(false);
    }
  }

  Future<void> _open() async {
    final v = VideoPlayback();
    setState(() => _video = v);
    _subs.add(v.position.listen((_) {
      if (mounted && !_scrubbing) setState(() {});
    }));
    try {
      await v.setLoop(true);
      await v.open(widget.path, autoplay: widget.active);
      if (!mounted) return;
      setState(() => _playing = widget.active);
      _scheduleHide();
      _autoLandscape();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// 横屏视频自动横屏: a video wider than tall turns a phone or tablet sideways.
  void _autoLandscape() {
    if (!_mobile || !Prefs.instance.autoLandscape) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width >= size.height) return;
    // the video's own size is known once its first frame is decoded
    final c = _video?.surfaceController;
    final w = c?.player.state.width ?? 0, h = c?.player.state.height ?? 0;
    if (w > h && h > 0) _setLandscape(true);
  }

  void _setLandscape(bool on) => widget.onTurn?.call(on);

  /// The opposite of how the screen is now: portrait turns to landscape, landscape to portrait.
  void _rotate() {
    final size = MediaQuery.sizeOf(context);
    _setLandscape(size.width < size.height);
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

  /// ↑ ↓ on a desktop: the player's volume in tenths.
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
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing && !_scrubbing) _showControls(false);
    });
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

  /// The speed chosen in the menu (desktops); a long press boosts from it and returns to it.
  double _rate = 1;
  static String _speed(double r) => '${r == r.roundToDouble() ? r.toInt() : r}×'; // i18n-exempt: a speed

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
  /// nothing, on any platform — so a touch-screen Mac or Windows tablet has them, a desktop
  /// without one does not (it has the speed menu and the keys instead).
  bool _touch = false;

  /// Whether this device lets an app set the screen's brightness for the whole system: iOS and
  /// iPadOS do; Android once the person allowed changing system settings; Windows on screens
  /// with a brightness control. Never macOS (and Linux has no such API here).
  static bool? _canSetBrightness;
  static Future<bool> _systemBrightness() async {
    if (kIsWeb || Platform.isMacOS || Platform.isLinux) return false;
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
        // the system's brightness, where the system lets an app set it (not the app's own
        // window brightness); where it cannot, this half does nothing
        if (!await _systemBrightness()) return;
        _pan = _Pan.brightness;
        try {
          _panStart = await ScreenBrightness.instance.system;
        } catch (_) {
          _panStart = 0.5;
        }
      } else {
        // the system's volume (what the volume buttons change), not the player's own
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
        await v.seek(Duration(milliseconds: (target * 1000).round()));
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
    if (_pan == _Pan.seek) {
      _scrubbing = false;
      setState(() {});
    }
    _pan = _Pan.none;
    _hideHud(after: const Duration(milliseconds: 400));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hide?.cancel();
    _hudTimer?.cancel();
    unawaited(_video?.dispose());
    super.dispose();
  }

  static String _time(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (_error != null) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 56));
    if (v == null) return const Center(child: Icon(Icons.play_circle_outline, size: 72, color: Colors.white70));
    final total = v.currentDuration;
    final at = v.currentPosition;
    final pad = MediaQuery.paddingOf(context);
    final showBar = _controls && !_locked;
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
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
              child: VideoSurface(controller: v.surfaceController, controls: NoVideoControls, fill: Colors.black),
            ),
          ),
        ),
        // 没有连接耳机，已静音 · 开启声音
        ValueListenableBuilder<bool>(
          valueListenable: v.needsSpeakerConsent,
          builder: (context, ask, _) => !ask
              ? const SizedBox.shrink()
              : Align(
                  alignment: Alignment.topCenter,
                  child: SafeArea(
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
        if (_hudIcon != null) Center(child: _Hud(icon: _hudIcon!, text: _hudText, level: _hudLevel)),
        // the arrows, while the drags hold the sideways swipe
        if (gestures && showBar && widget.canPrevious)
          Positioned(left: 8 + pad.left, top: 0, bottom: 0, child: Center(child: _RoundButton(key: const ValueKey('videoPrevious'), icon: Icons.chevron_left, tooltip: L('viewer.previous'), onPressed: () => widget.onStep(-1)))),
        if (gestures && showBar && widget.canNext)
          Positioned(right: 8 + pad.right, top: 0, bottom: 0, child: Center(child: _RoundButton(key: const ValueKey('videoNext'), icon: Icons.chevron_right, tooltip: L('viewer.next'), onPressed: () => widget.onStep(1)))),
        // caption and controls under one shade from the caption to the bottom edge
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !showBar,
            child: AnimatedOpacity(
              opacity: showBar ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x8C000000), Color(0xB3000000)],
                    stops: [0, 0.35, 1],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16 + pad.left, 40, 16 + pad.right, 8 + pad.bottom),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ?widget.caption,
                    Row(children: [
                      _BarButton(key: const ValueKey('videoPlay'), icon: _playing ? Icons.pause : Icons.play_arrow, tooltip: _playing ? L('viewer.pause') : L('viewer.play'), onPressed: togglePlay),
                      Text(_time(at), style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
                      Expanded(
                        child: Slider(
                          value: total.inMilliseconds == 0 ? 0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                          onChangeStart: (_) => _scrubbing = true,
                          onChanged: total == Duration.zero ? null : (f) => v.seek(total * f),
                          onChangeEnd: (_) {
                            _scrubbing = false;
                            _scheduleHide();
                          },
                        ),
                      ),
                      Text(_time(total), style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
                      // the speed, on a desktop (a phone or tablet holds a finger for 2.5×)
                      if (!_mobile)
                        PopupMenuButton<double>(
                          key: const ValueKey('videoSpeed'),
                          tooltip: L('player.speed'),
                          initialValue: _rate,
                          color: const Color(0xEE202020),
                          onSelected: (r) {
                            setState(() => _rate = r);
                            v.setRate(r);
                            _scheduleHide();
                          },
                          itemBuilder: (_) => [
                            for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0])
                              PopupMenuItem(value: r, child: Text(_speed(r), style: TextStyle(color: Colors.white, fontWeight: r == _rate ? FontWeight.w700 : null))),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(_speed(_rate), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
                          ),
                        ),
                      ValueListenableBuilder<bool>(
                        valueListenable: v.muted,
                        builder: (context, muted, _) => _BarButton(
                          key: const ValueKey('videoMute'),
                          icon: muted ? Icons.volume_off : Icons.volume_up,
                          tooltip: muted ? L('audio.turnOn') : null,
                          onPressed: () => v.setMuted(!muted),
                        ),
                      ),
                    ]),
                    Row(children: [
                      Text(widget.counter, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (_mobile) _BarButton(key: const ValueKey('videoLock'), icon: Icons.lock_open, tooltip: L('viewer.lock'), onPressed: _toggleLock),
                      if (_mobile) _BarButton(key: const ValueKey('videoRotate'), icon: Icons.screen_rotation, tooltip: L('viewer.rotate'), onPressed: _rotate),
                      Builder(
                        builder: (button) => _BarButton(key: const ValueKey('videoShare'), icon: Icons.ios_share, tooltip: L('viewer.share'), onPressed: () {
                          final box = button.findRenderObject() as RenderBox?;
                          widget.onShare(box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                        }),
                      ),
                      _BarButton(key: const ValueKey('videoClose'), icon: Icons.close, tooltip: L('viewer.close'), onPressed: widget.onClose),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        ),
        // locked: only the lock, in the middle of the width at the bar's height
        if (_locked && (_lockFlash || _controls))
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + pad.bottom,
            child: Center(child: _RoundButton(key: const ValueKey('videoUnlock'), icon: Icons.lock, tooltip: L('viewer.unlock'), onPressed: _toggleLock)),
          ),
      ]);
    });
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.icon, this.tooltip, required this.onPressed});
  final IconData icon;
  final String? tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(color: Colors.white, tooltip: tooltip, icon: Icon(icon), onPressed: onPressed);
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
        icon: Icon(icon),
        onPressed: onPressed,
      );
}

/// The pill in the middle: what a gesture does (speed, seek target, brightness, volume).
class _Hud extends StatelessWidget {
  const _Hud({required this.icon, this.text, this.level});
  final IconData icon;
  final String? text;
  final double? level;
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('hud'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(22)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 20),
          if (text != null) ...[const SizedBox(width: 8), Text(text!, style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]))],
          if (level != null) ...[
            const SizedBox(width: 10),
            SizedBox(width: 120, child: LinearProgressIndicator(value: level, color: Colors.white, backgroundColor: Colors.white24, minHeight: 4)),
          ],
        ]),
      );
}
