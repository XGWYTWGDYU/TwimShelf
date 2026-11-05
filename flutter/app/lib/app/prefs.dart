import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This device's display preferences, under the native apps' `UserDefaults` names.
class Prefs extends ChangeNotifier {
  Prefs._(this._p);
  final SharedPreferences _p;
  static late Prefs instance;

  static Future<void> load() async {
    instance = Prefs._(await SharedPreferences.getInstance());
    await instance._removeRetired();
  }

  /// Settings of features that are gone (整理 mode), removed at every launch: the list only
  /// grows, so a device that skips versions is cleaned the same way.
  Future<void> _removeRetired() async {
    for (final k in const ['triage.mode', 'triage.filter', 'triage.recentFolders']) {
      if (_p.containsKey(k)) await _p.remove(k);
    }
  }

  /// 清除所有数据: every setting; with [keepAI], those of the AI models stay.
  Future<void> wipe({required bool keepAI}) async {
    for (final key in _p.getKeys().toList()) {
      if (keepAI && (key.startsWith('ai.') || key.startsWith('models.'))) continue;
      await _p.remove(key);
    }
    notifyListeners();
  }

  bool _bool(String key, bool fallback) => _p.getBool(key) ?? fallback;
  void _set(String key, Object? value) {
    switch (value) {
      case bool b:
        _p.setBool(key, b);
      case int i:
        _p.setInt(key, i);
      case null:
        _p.remove(key);
    }
    notifyListeners();
  }

  /// 浏览 by when things were added, newest first, instead of at random.
  bool get feedByAdded => _bool('feed.sortByAdded', false);
  set feedByAdded(bool v) => _set('feed.sortByAdded', v);

  /// 应用锁: every opening asks first (`AppLock`).
  bool get appLock => _bool('appLock.enabled', false);
  set appLock(bool v) => _set('appLock.enabled', v);

  /// 使用 Claude Code 吉祥物: its icons, and the little Clawd in wide windows.
  bool get mascot => _bool('mascot.enabled', false);
  set mascot(bool v) => _set('mascot.enabled', v);

  /// 只看损坏或缺失的媒体 (浏览 and the grids show only those).
  bool get badOnly => aboutExtras && _bool('filter.bad', false);
  set badOnly(bool v) => _set('filter.bad', v);

  /// 仅用耳机播放声音: this device's own choice, as in the native apps (not synced).
  bool get headphonesOnly => _bool('audio.headphonesOnly', false);
  set headphonesOnly(bool v) => _set('audio.headphonesOnly', v);

  /// What ten taps on the icon in 关于 bring out stays out until ten more put it away: the
  /// maintenance rows there, and 损坏或丢失 wherever it is offered.
  bool get aboutExtras => _bool('about.extras', false);
  set aboutExtras(bool v) {
    if (!v && _bool('filter.bad', false)) _set('filter.bad', false);
    _set('about.extras', v);
  }

  /// 按帖子分组 in 浏览.
  bool get feedGrouped => _bool('feed.grouped', true);
  set feedGrouped(bool v) => _set('feed.grouped', v);

  /// 视频禁用手势: no seek / volume / brightness drags (a sideways swipe turns the page).
  bool get playerGesturesOff => _bool('player.noGestures', false);
  set playerGesturesOff(bool v) => _set('player.noGestures', v);

  /// 横屏视频自动横屏 (phones and tablets).
  bool get autoLandscape => _bool('player.autoLandscape', false);
  set autoLandscape(bool v) => _set('player.autoLandscape', v);

  /// How many cards a row of 浏览 holds on a large screen, per orientation: 0 fewer, 1 medium,
  /// 2 more (the native apps' keys). The exact count follows the width.
  int get densityPortrait => _p.getInt('feed.density.portrait') ?? 1;
  set densityPortrait(int v) => _set('feed.density.portrait', v);
  int get densityLandscape => _p.getInt('feed.density.landscape') ?? 1;
  set densityLandscape(int v) => _set('feed.density.landscape', v);

  /// The columns of 浏览 for a width: one card per 400 at 适中, wider at 少, narrower at 多.
  int feedColumns(double width, double height) {
    final level = (width > height ? densityLandscape : densityPortrait).clamp(0, 2);
    final per = 400 * const [1.35, 1.0, 0.72][level];
    return (width / per).floor().clamp(1, 4 + (level == 2 ? 2 : 0));
  }

  /// The sidebar's width (drawn by its edge), between 200 and 420.
  double get sidebarWidth => (_p.getDouble('sidebar.width') ?? 264).clamp(200, 420).toDouble();
  set sidebarWidth(double v) {
    _p.setDouble('sidebar.width', v.clamp(200, 420).toDouble());
    notifyListeners();
  }

  /// 检查更新: when it last looked (ms), and a version the person chose to skip.
  int get updateLastCheck => _p.getInt('update.lastCheck') ?? 0;
  set updateLastCheck(int v) => _p.setInt('update.lastCheck', v);
  String? get updateSkipped => _p.getString('update.skipped');
  set updateSkipped(String? v) => v == null ? _p.remove('update.skipped') : _p.setString('update.skipped', v);

  /// The colour the scheme is made from; null: the default, or the system's on Android 12+.
  int? get seedColor => _p.getInt('appearance.seed');
  set seedColor(int? v) => _set('appearance.seed', v);

  /// Light, dark or the system's (0, 1, 2).
  int get brightness => _p.getInt('appearance.brightness') ?? 0;
  set brightness(int v) => _set('appearance.brightness', v);
}

/// The colours offered in 外观, by name (appearance.color.<name>).
const seedColors = {
  'pink': Color(0xFFE91E63),
  'red': Color(0xFFF44336),
  'orange': Color(0xFFFF9800),
  'amber': Color(0xFFFFC107),
  'yellow': Color(0xFFFFEB3B),
  'lime': Color(0xFFCDDC39),
  'lightGreen': Color(0xFF8BC34A),
  'green': Color(0xFF4CAF50),
  'teal': Color(0xFF009688),
  'cyan': Color(0xFF00BCD4),
  'lightBlue': Color(0xFF03A9F4),
  'blue': Color(0xFF2196F3),
  'indigo': Color(0xFF3F51B5),
  'purple': Color(0xFF9C27B0),
  'deepPurple': Color(0xFF673AB7),
  'blueGrey': Color(0xFF607D8B),
  'brown': Color(0xFF795548),
  'grey': Color(0xFF9E9E9E),
};

/// Where the system has no colour of its own and nothing was chosen.
const defaultSeed = Color(0xFF2196F3);

/// A theme colour's whole set of colours.
ColorScheme schemeOf(Color seed, Brightness b) => ColorScheme.fromSeed(seedColor: seed, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.vibrant);
