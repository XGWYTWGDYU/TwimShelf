
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../l10n/l10n.dart';
import 'prefs.dart';
import '../platform/os.dart';

enum AppLockResult { passed, stayed, unavailable }

/// What the system answers (a fake in the tests).
abstract interface class AppLockSystem {
  /// The answer, with a reason when there is one to give.
  Future<(AppLockResult, String?)> ask();
  Future<bool> available();
  Future<String> methodName();
}

class LocalAuthSystem implements AppLockSystem {
  final _auth = LocalAuthentication();

  @override
  Future<(AppLockResult, String?)> ask() async {
    try {
      // not biometrics only: the device's passcode is the way in when a sensor fails
      final ok = await _auth.authenticate(localizedReason: L('applock.reason'), sensitiveTransaction: false);
      return ok ? (AppLockResult.passed, null) : (AppLockResult.stayed, L('applock.failed'));
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled || LocalAuthExceptionCode.systemCanceled || LocalAuthExceptionCode.timeout || LocalAuthExceptionCode.authInProgress => (AppLockResult.stayed, null),
        LocalAuthExceptionCode.noCredentialsSet || LocalAuthExceptionCode.noBiometricsEnrolled || LocalAuthExceptionCode.noBiometricHardware => (AppLockResult.unavailable, null),
        _ => (AppLockResult.stayed, e.description ?? e.code.name),
      };
    }
  }

  @override
  Future<bool> available() => _auth.isDeviceSupported();

  @override
  Future<String> methodName() async {
    if (OS.isWindows) return L('applock.method.hello');
    if (OS.isAndroid) return L('applock.method.android');
    final kinds = await _auth.getAvailableBiometrics();
    if (kinds.contains(BiometricType.face)) return L('applock.method.faceID');
    if (kinds.contains(BiometricType.fingerprint)) return L('applock.method.touchID');
    if (kinds.contains(BiometricType.iris)) return L('applock.method.opticID');
    return L('applock.method.passcode');
  }
}

/// 应用锁 (Face ID, Touch ID, Windows Hello, Android's biometrics): optional, off by default, not on
/// Linux. It stands in front of the app; it does not encrypt the library's files. Phones and tablets
/// lock again when the app goes to the background; desktops at each start.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({required this.system, required this.relocks});

  static bool get offered => !OS.isLinux;
  static final instance = AppLock(system: LocalAuthSystem(), relocks: OS.isIOS || OS.isAndroid);

  final AppLockSystem system;
  /// Going to the background locks again.
  final bool relocks;

  bool locked = false;
  /// Nothing of the app is built before the first unlock (its library is not even open).
  bool everUnlocked = false;
  bool busy = false;
  bool unavailable = false;
  String? message;
  /// Asked since it locked: a cancelled prompt does not come back by itself, the button does it.
  bool _asked = false;

  void start() {
    locked = offered && Prefs.instance.appLock;
    everUnlocked = !locked;
    WidgetsBinding.instance.addObserver(this);
  }

  void _lock() {
    locked = true;
    _asked = false;
    message = null;
    unavailable = false;
    notifyListeners();
    // frames have stopped by now: the lock is what is on screen when the app comes back
    WidgetsBinding.instance.scheduleForcedFrame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // while asking, a passcode screen of the system's may put the app in the background
    if (state == AppLifecycleState.paused && relocks && !busy && Prefs.instance.appLock) _lock();
    if (state == AppLifecycleState.resumed) askIfDue();
  }

  /// Asks when locked and not asked yet; on a phone only once the app is in front (the system
  /// refuses before that, and the app comes to the front right after a start).
  void askIfDue() {
    if (!locked || _asked) return;
    if (relocks && WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    ask();
  }

  Future<void> ask() async {
    if (busy) return;
    _asked = true;
    busy = true;
    message = null;
    notifyListeners();
    final (result, reason) = await system.ask();
    busy = false;
    switch (result) {
      case AppLockResult.passed:
        _open();
      case AppLockResult.stayed:
        message = reason;
      case AppLockResult.unavailable:
        unavailable = true;
    }
    notifyListeners();
  }

  void _open() {
    locked = false;
    everUnlocked = true;
    message = null;
    unavailable = false;
  }

  /// The device has no way to ask any more: open, and the lock is off.
  void openAnyway() {
    Prefs.instance.appLock = false;
    _open();
    notifyListeners();
  }

  /// The setting: both ways ask first, whoever turns it off has to be able to pass it. The reason
  /// when it stayed as it was.
  Future<String?> setEnabled(bool on) async {
    final (result, reason) = await system.ask();
    switch (result) {
      case AppLockResult.passed:
        Prefs.instance.appLock = on;
        return null;
      case AppLockResult.unavailable:
        Prefs.instance.appLock = false;
        return on ? L('applock.unavailable') : null;
      case AppLockResult.stayed:
        return reason;
    }
  }
}

/// Goes around everything the app shows (dialogs too): while locked only the lock is there, and the
/// app behind it neither draws nor takes the keyboard. It stays alive behind the lock, so coming
/// back from the background finds it as it was.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.lock, required this.child});
  final AppLock lock;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  @override
  void initState() {
    super.initState();
    widget.lock.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.lock.askIfDue());
  }

  @override
  void dispose() {
    widget.lock.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final lock = widget.lock;
    final screen = _AppLockScreen(lock: lock);
    if (!lock.everUnlocked) return screen;
    return Stack(fit: StackFit.expand, children: [
      TickerMode(
        enabled: !lock.locked,
        child: ExcludeFocus(excluding: lock.locked, child: Offstage(offstage: lock.locked, child: widget.child)),
      ),
      if (lock.locked) screen,
    ]);
  }
}

class _AppLockScreen extends StatelessWidget {
  const _AppLockScreen({required this.lock});
  final AppLock lock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('appLockScreen'),
      color: scheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock, size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(L('applock.title'), textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              if (lock.unavailable) ...[
                Text(L('applock.unavailable'), textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                FilledButton(key: const ValueKey('appLockOpenAnyway'), onPressed: lock.openAnyway, child: Text(L('applock.openAnyway'))),
              ] else ...[
                if (lock.message != null) ...[
                  Text(lock.message!, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                ],
                FilledButton(key: const ValueKey('appLockUnlock'), onPressed: lock.busy ? null : lock.ask, child: Text(L('applock.unlock'))),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 设置 → 隐私: the switch, named after what this device will ask for.
class AppLockSwitch extends StatefulWidget {
  const AppLockSwitch({super.key, required this.lock, required this.icon});
  final AppLock lock;
  final Widget icon;

  @override
  State<AppLockSwitch> createState() => _AppLockSwitchState();
}

class _AppLockSwitchState extends State<AppLockSwitch> {
  late final Future<(String, bool)> _device = _read();
  Future<(String, bool)> _read() async => (await widget.lock.system.methodName(), await widget.lock.system.available());
  String? _problem;
  bool _asking = false;

  @override
  Widget build(BuildContext context) => FutureBuilder<(String, bool)>(
        future: _device,
        builder: (context, snap) {
          final on = Prefs.instance.appLock;
          final (name, available) = snap.data ?? ('', false);
          return SwitchListTile(
            key: const ValueKey('appLock-switch'),
            secondary: widget.icon,
            title: Text(L('applock.toggle', [name])),
            subtitle: _problem == null ? null : Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            value: on,
            onChanged: _asking || (!available && !on)
                ? null
                : (v) async {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _asking = true;
                      _problem = null;
                    });
                    final problem = await widget.lock.setEnabled(v);
                    if (mounted) {
                      setState(() {
                        _asking = false;
                        _problem = problem;
                      });
                    }
                  },
          );
        },
      );
}
