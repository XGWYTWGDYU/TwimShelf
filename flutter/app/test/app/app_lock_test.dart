import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/app/app_lock.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';

class _System implements AppLockSystem {
  (AppLockResult, String?) answer = (AppLockResult.passed, null);
  int asked = 0;
  @override
  Future<(AppLockResult, String?)> ask() async {
    asked++;
    return answer;
  }

  @override
  Future<bool> available() async => true;
  @override
  Future<String> methodName() async => 'Face ID';
}

const _content = ValueKey('content');
const _screen = ValueKey('appLockScreen');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
    await L10n.load(locale: const Locale('zh', 'CN'));
  });
  late _System system;
  late AppLock lock;

  Future<void> pump(WidgetTester t, {bool on = true, bool relocks = false}) async {
    Prefs.instance.appLock = on;
    system = _System();
    lock = AppLock(system: system, relocks: relocks)..start();
    addTearDown(() => WidgetsBinding.instance.removeObserver(lock));
  }

  Widget app() => MaterialApp(builder: (_, child) => AppLockGate(lock: lock, child: child!), home: const Scaffold(body: Text('library', key: _content)));

  testWidgets('off: nothing asks and the app shows', (t) async {
    await pump(t, on: false);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(system.asked, 0);
    expect(find.byKey(_screen), findsNothing);
    expect(find.byKey(_content), findsOneWidget);
  });

  testWidgets('on: nothing of the app is built until it passes', (t) async {
    await pump(t);
    system.answer = (AppLockResult.stayed, null);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(system.asked, 1);
    expect(find.byKey(_screen), findsOneWidget);
    expect(find.byKey(_content, skipOffstage: false), findsNothing);
    // a cancel: it does not come back by itself; the button asks again
    await t.pumpAndSettle();
    expect(system.asked, 1);
    system.answer = (AppLockResult.passed, null);
    await t.tap(find.byKey(const ValueKey('appLockUnlock')));
    await t.pumpAndSettle();
    expect(system.asked, 2);
    expect(find.byKey(_screen), findsNothing);
    expect(find.byKey(_content), findsOneWidget);
  });

  testWidgets('a failure says why and stays locked', (t) async {
    await pump(t);
    system.answer = (AppLockResult.stayed, 'synthetic reason');
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.text('synthetic reason'), findsOneWidget);
    expect(find.byKey(_content, skipOffstage: false), findsNothing);
  });

  testWidgets('no way to ask any more: it says so, and opening turns the lock off', (t) async {
    await pump(t);
    system.answer = (AppLockResult.unavailable, null);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byKey(_content, skipOffstage: false), findsNothing);
    await t.tap(find.byKey(const ValueKey('appLockOpenAnyway')));
    await t.pumpAndSettle();
    expect(find.byKey(_content), findsOneWidget);
    expect(Prefs.instance.appLock, isFalse);
  });

  testWidgets('a phone locks again in the background, keeps the app alive, and asks on return', (t) async {
    await pump(t, relocks: true);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byKey(_content), findsOneWidget);
    final state = t.element(find.byKey(_content));

    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(find.byKey(_screen), findsOneWidget);
    expect(find.byKey(_content), findsNothing, reason: 'offstage');
    expect(find.byKey(_content, skipOffstage: false), findsOneWidget);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle();
    expect(system.asked, 2);
    expect(find.byKey(_content), findsOneWidget);
    expect(t.element(find.byKey(_content)), same(state));
  });

  testWidgets('a desktop does not lock again in the background', (t) async {
    await pump(t, relocks: false);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
    await t.pump();
    expect(find.byKey(_screen), findsNothing);
  });

  testWidgets('the setting asks both ways; a cancel changes nothing', (t) async {
    await pump(t, on: false);
    system.answer = (AppLockResult.stayed, null);
    expect(await lock.setEnabled(true), isNull);
    expect(Prefs.instance.appLock, isFalse);
    system.answer = (AppLockResult.passed, null);
    await lock.setEnabled(true);
    expect(Prefs.instance.appLock, isTrue);
    system.answer = (AppLockResult.stayed, 'no');
    expect(await lock.setEnabled(false), 'no');
    expect(Prefs.instance.appLock, isTrue);
    system.answer = (AppLockResult.passed, null);
    await lock.setEnabled(false);
    expect(Prefs.instance.appLock, isFalse);
    expect(system.asked, 4);
  });
}
