import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:tl_core/tl_core.dart';

import '../platform/secrets.dart';
import '../platform/apple_platform.dart';
import '../platform/multicast.dart';
import '../platform/os.dart';

/// LAN sync for the Flutter app: the account key (in the platform's secret store, as the native
/// apps keep it in the Keychain), the core's listener, and the core's discovery, which finds the
/// account's other devices — native or Flutter — and syncs with them by itself.
class SyncModel extends ChangeNotifier {
  /// Debug builds advertise another service type, as the native debug Mac build does: a test
  /// build never pairs with (or syncs into) the user's real devices.
  /// Test builds can be kept apart from every native device entirely with
  /// `--dart-define=TL_SYNC_SERVICE=_twlib-flutter._tcp` (they then never even see each other).
  static const serviceType = String.fromEnvironment('TL_SYNC_SERVICE', defaultValue: kDebugMode ? '_twlib-debug._tcp' : '_twlib._tcp');
  static const _keyName = 'sync.key';

  SyncStatus? status;
  DiscoveryStatus? discovery;
  String? accountKey;
  /// The result of the last 立即同步 or join (shown under the buttons).
  String? note;
  Timer? _poll;
  AppLifecycleListener? _lifecycle;
  /// Moves when another device's changes arrived (the core's `changes` counter grew): the
  /// library reloads, without telling the others about it again.
  final remoteChanges = ValueNotifier<int>(0);
  int? _changes;

  /// The name the others show; on Apple platforms the native apps' (the runner knows it).
  static String deviceName = _hostName();
  static String _hostName() {
    final h = OS.localHostname;
    return h.endsWith('.local') ? h.substring(0, h.length - 6) : h;
  }

  /// What this device is, announced with its name so the others show the right type.
  static String deviceKind = '';
  static Future<String> _kind() async {
    if (OS.isMacOS) return 'mac';
    if (OS.isWindows) return 'windows';
    if (OS.isLinux) return 'linux';
    if (OS.isIOS) return await ApplePlatform.instance.deviceKind() ?? 'iphone';
    if (OS.isAndroid) {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final shortest = view.physicalSize.shortestSide / view.devicePixelRatio;
      return shortest >= 600 ? 'android-tablet' : 'android-phone';
    }
    return '';
  }

  bool get joined => accountKey != null && accountKey!.isNotEmpty;

  /// Reads the stored key and starts listening, advertising and finding devices.
  Future<void> start() async {
    deviceName = await ApplePlatform.instance.deviceName() ?? deviceName;
    deviceKind = await _kind();
    // the web build: the device is the server (its name and kind, as it syncs on its own too)
    if (OS.isWeb) {
      deviceName = serverInfo.json['device_name'] as String? ?? 'TwimShelf Linux Server';
      deviceKind = 'linux';
    }
    await Multicast.acquire();
    final r = await Secrets.read(_keyName);
    accountKey = r is SecretValue<String?> ? r.value : null;
    _startCore();
    _poll ??= Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
    // back in the foreground: announce and look again (iOS withdraws a suspended app's
    // announcement and cuts its connection to the system's Bonjour)
    _lifecycle ??= AppLifecycleListener(onResume: () {
      unawaited(_foreground());
    });
    _refresh();
  }

  /// iOS kills a suspended app's listening socket while its port still looks open: others would
  /// find this device and not get in. A new listener first, then the announcement with its port.
  Future<void> _foreground() async {
    try {
      if (OS.isIOS) await Core.syncRestartListenerAsync();
      Core.discoveryRediscover();
    } catch (e) {
      note = '$e';
      notifyListeners();
    }
  }

  void _startCore() {
    try {
      Core.syncStart(accountKey ?? '', deviceName);
      Core.discoveryStart(OS.isWeb ? serverInfo.json['sync_service'] as String? ?? serviceType : serviceType, deviceName, deviceKind);
    } catch (e) {
      note = '$e';
    }
  }

  void _refresh() {
    try {
      final s = Core.syncStatus();
      final d = Core.discoveryStatus();
      final joinKey = s.join.account_key;
      if (joinKey != null && joinKey != accountKey) {
        // pairing succeeded: keep the key, start again in the account
        unawaited(_adopt(joinKey));
      }
      if (_changes != null && s.changes > _changes!) remoteChanges.value++;
      _changes = s.changes;
      status = s;
      discovery = d;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _adopt(String key) async {
    final w = await Secrets.write(_keyName, key);
    if (w is SecretsUnavailable) return;
    accountKey = key;
    Core.discoveryStop();
    _startCore();
  }

  /// The account's other devices found on the network.
  List<DiscoveredPeer> get accountPeers {
    final mine = status?.account_id;
    if (mine == null) return const [];
    return (discovery?.peers ?? const []).where((p) => p.account == mine).toList();
  }

  /// Devices that could be joined (other accounts, or none yet): the joining side picks one.
  List<DiscoveredPeer> get joinablePeers => (discovery?.peers ?? const []).where((p) => p.account != null && p.reachable).toList();

  /// The joinable devices, one group per account (devices that sync with each other are one
  /// account, shown together), largest group first.
  List<(String, List<DiscoveredPeer>)> get joinableAccounts {
    final groups = <String, List<DiscoveredPeer>>{};
    for (final p in joinablePeers) {
      (groups[p.account!] ??= []).add(p);
    }
    for (final g in groups.values) {
      g.sort((a, b) => a.name.compareTo(b.name));
    }
    return groups.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.length != a.$2.length ? b.$2.length - a.$2.length : a.$2.first.name.compareTo(b.$2.first.name));
  }

  Future<void> createAccount() async {
    final key = Core.syncNewAccount();
    if (await Secrets.write(_keyName, key) is SecretsUnavailable) return;
    accountKey = key;
    Core.discoveryStop();
    _startCore();
    _refresh();
  }

  /// 清除所有数据: the device leaves the account, or the next start would pull it all back.
  Future<bool> forgetAccount() async {
    final removed = await Secrets.delete(_keyName) is! SecretsUnavailable;
    accountKey = null;
    try {
      Core.discoveryStop();
      Core.syncReset();
    } catch (_) {}
    _startCore();
    _refresh();
    return removed;
  }

  Future<void> leave() async {
    if (await Secrets.delete(_keyName) is SecretsUnavailable) return;
    accountKey = null;
    Core.discoveryStop();
    _startCore();
    _refresh();
  }

  String beginPairing() => Core.syncPairBegin();
  void cancelPairing() => Core.syncPairCancel();

  /// Joins the account of [peer] with the code it shows; the key arrives through the status.
  void join(DiscoveredPeer peer, String code) => Core.syncJoin(peer.host!, peer.port!, code.trim());

  void syncNow() => Core.discoverySyncNow();

  /// The library changed here: the others hear of it in a few seconds.
  static void localChange() {
    try {
      Core.discoveryChanged();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(Multicast.release());
    _poll?.cancel();
    _lifecycle?.dispose();
    Core.discoveryStop();
    super.dispose();
  }
}
