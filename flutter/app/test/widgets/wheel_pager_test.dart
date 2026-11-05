import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/widgets/wheel_pager.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  late List<int> steps;

  Future<void> open(WidgetTester tester, {bool enabled = true, bool Function(int)? canStep}) async {
    steps = [];
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: WheelPager(enabled: enabled, canStep: canStep, onStep: steps.add, child: const SizedBox.expand(child: ColoredBox(color: Color(0xFF000000)))),
    ));
  }

  Future<void> wheel(WidgetTester tester, Offset by, int ms) => tester.sendEventToBinding(
      PointerScrollEvent(position: const Offset(100, 100), scrollDelta: by, timeStamp: Duration(milliseconds: ms)));

  testWidgets('one scroll, one page, each way', (tester) async {
    await open(tester);
    await wheel(tester, const Offset(0, 100), 1000);
    await wheel(tester, const Offset(0, -100), 2000);
    await wheel(tester, const Offset(30, 0), 3000);
    await wheel(tester, const Offset(-30, 0), 4000);
    expect(steps, [1, -1, 1, -1]);
  }, variant: _windows);

  testWidgets('a run of events and its inertia turn one page; after a pause the next scroll turns', (tester) async {
    await open(tester);
    var at = 1000;
    for (final dy in <double>[12, 30, 50, 45, 30, 20, 12, 7, 4, 2, 1]) {
      await wheel(tester, Offset(0, dy), at += 16);
    }
    expect(steps, [1]);
    await wheel(tester, const Offset(0, 20), at += 200);
    expect(steps, [1, 1]);
  }, variant: _windows);

  testWidgets('a trackpad the app sees as one is a wheel too', (tester) async {
    await open(tester);
    final p = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(p.panZoomStart(const Offset(100, 100), timeStamp: Duration.zero));
    await tester.sendEventToBinding(p.panZoomUpdate(const Offset(100, 100), pan: const Offset(-10, 0), timeStamp: const Duration(milliseconds: 16)));
    await tester.sendEventToBinding(p.panZoomUpdate(const Offset(100, 100), pan: const Offset(-40, 0), timeStamp: const Duration(milliseconds: 32)));
    expect(steps, [1]);
  }, variant: _windows);

  testWidgets('at the last page the scroll is left to what is around; a zoomed photo keeps the wheel', (tester) async {
    await open(tester, canStep: (by) => by < 0);
    await wheel(tester, const Offset(0, 100), 1000);
    expect(steps, isEmpty);
    await wheel(tester, const Offset(0, -100), 2000);
    expect(steps, [-1]);
    await open(tester, enabled: false);
    await wheel(tester, const Offset(0, 100), 1000);
    expect(steps, isEmpty);
  }, variant: _windows);

  testWidgets('a card under the mouse scrolls by the wheel, and the list only past its ends', (tester) async {
    final list = ScrollController();
    final pages = PageController();
    var page = 0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, set) => ListView(controller: list, children: [
          SizedBox(
            height: 400,
            child: WheelPager(
              canStep: (by) => page + by >= 0 && page + by < 2,
              onStep: (by) => set(() {
                page += by;
                pages.jumpToPage(page);
              }),
              child: PageView(controller: pages, children: const [WheelGuard(child: SizedBox.expand()), WheelGuard(child: SizedBox.expand())]),
            ),
          ),
          const SizedBox(height: 4000),
        ]),
      ),
    ));
    await wheel(tester, const Offset(0, 100), 1000);
    await tester.pump();
    expect((page, list.offset), (1, 0));
    await wheel(tester, const Offset(0, 100), 2000);
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(list.offset, greaterThan(0), reason: 'past the last page, the list scrolls');
  }, variant: _windows);

  testWidgets('a scroll of the list that reaches a card goes on being the list', (tester) async {
    final list = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: ListView(controller: list, children: [
        const SizedBox(height: 300),
        SizedBox(height: 300, child: WheelPager(onStep: (_) => fail('the card must not turn'), child: const WheelGuard(child: SizedBox.expand()))),
        const SizedBox(height: 4000),
      ]),
    ));
    await tester.sendEventToBinding(const PointerScrollEvent(position: Offset(100, 100), scrollDelta: Offset(0, 100), timeStamp: Duration(milliseconds: 1000)));
    await tester.pump();
    await tester.sendEventToBinding(const PointerScrollEvent(position: Offset(100, 400), scrollDelta: Offset(0, 100), timeStamp: Duration(milliseconds: 1016)));
    await tester.pumpAndSettle();
    expect(list.offset, greaterThan(100));
  }, variant: _windows);

  testWidgets('the PageView itself never moves part of the way', (tester) async {
    final pages = PageController();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: WheelPager(
          onStep: (by) => pages.jumpToPage(pages.page!.round() + by),
          child: PageView.builder(controller: pages, itemCount: 5, itemBuilder: (_, i) => WheelGuard(child: SizedBox.expand(child: Text('$i')))),
        ),
      ),
    ));
    await tester.sendEventToBinding(const PointerScrollEvent(position: Offset(100, 100), scrollDelta: Offset(20, 0), timeStamp: Duration(seconds: 1)));
    await tester.pump();
    expect(pages.page, 1);
  }, variant: _windows);

  testWidgets('a wheel going up does not zoom a photo; Ctrl or a zoomed photo does', (tester) async {
    Future<double> afterWheel({required bool zoomed, required bool ctrl}) async {
      final t = TransformationController();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: InteractiveViewer(key: UniqueKey(), transformationController: t, maxScale: 6, scaleFactor: photoScaleFactor(zoomed: zoomed, ctrl: ctrl), child: const SizedBox.expand()),
      ));
      await wheel(tester, const Offset(0, -120), 1000);
      return t.value.getMaxScaleOnAxis();
    }

    expect(await afterWheel(zoomed: false, ctrl: false), closeTo(1, 0.001));
    expect(await afterWheel(zoomed: false, ctrl: true), greaterThan(1.5));
    expect(await afterWheel(zoomed: true, ctrl: false), greaterThan(1.5));
  }, variant: _windows);

  /// Real input through Remote Desktop from a Mac, as received by the app: ms:amount.
  const recorded = <(String, List<int>, String)>[
    ('a slow swipe and its long inertia', [1], '0:4.16667 12:49.1667 30:174.167 56:213.333 58:213.333 75:213.333 90:213.333 105:199.167 122:186.667 138:175.833 157:154.167 172:145 189:140.833 213:136.667 226:131.667 239:127.5 256:122.5 273:119.167 290:114.167 306:110 322:105.833 339:102.5 356:97.5 373:93.3333 466:90 466:322.5 472:70.8333 490:67.5 505:63.3333 522:58.3333 539:55 555:51.6667 573:47.5 589:44.1667 606:40.8333 623:39.1667 639:35.8333 655:32.5 672:30 689:27.5 705:25.8333 722:23.3333 739:21.6667 756:20 772:17.5 790:15.8333 806:14.1667 822:13.3333 839:11.6667 856:11.6667 872:10.8333 889:10 990:15.8333'),
    ('five fast swipes, each into the inertia of the one before', [1,1,1,1,1], '0:2.5 17:20 34:44.1667 50:85.8333 67:112.5 84:110.833 86:147.5 101:149.167 117:141.667 134:134.167 152:127.5 167:120.833 183:109.167 200:103.333 217:99.1667 233:94.1667 250:90.8333 267:87.5 283:83.3333 300:80 445:6.66667 451:804.167 467:163.333 483:153.333 502:144.167 518:129.167 534:121.667 551:118.333 567:113.333 583:109.167 600:105.833 617:101.667 634:97.5 651:94.1667 667:90 717:12.5 734:9.16667 750:31.6667 769:65.8333 783:111.667 811:160 821:160.833 834:153.333 850:145.833 867:137.5 970:130.833 971:423.333 983:95.8333 1006:90.8333 1019:86.6667 1034:83.3333 1058:78.3333 1093:8.33333 1111:25.8333 1125:45 1141:102.5 1159:133.333 1184:177.5 1200:178.333 1216:170 1234:161.667 1250:152.5 1267:145 1284:131.667 1300:125.833 1317:119.167 1334:114.167 1350:110 1367:105.833 1383:100.833 1401:95.8333 1493:91.6667 1494:37.5 1501:57.5 1517:98.3333 1536:146.667 1551:193.333 1567:194.167 1584:185.833 1600:176.667 1617:166.667 1635:157.5 1651:143.333 1667:136.667 1695:130 1700:124.167 1722:213.333 1753:110 1761:105 1779:100 1818:95 1820:90 1826:85 1843:78.3333 1859:73.3333'),
    ('four swipes, the third the other way', [1,1,-1,1], '0:0.833333 16:6.66667 36:11.6667 51:22.5 188:33.3333 194:306.667 208:54.1667 225:55.8333 242:53.3333 258:49.1667 275:45.8333 292:42.5 312:39.1667 327:37.5 342:34.1667 359:30.8333 375:29.1667 391:26.6667 408:24.1667 431:21.6667 442:20 460:18.3333 478:16.6667 492:15.8333 508:14.1667 526:13.3333 542:11.6667 559:10.8333 577:10 592:9.16667 610:8.33333 711:7.5 712:23.3333 726:4.16667 742:4.16667 758:4.16667 779:4.16667 792:3.33333 808:3.33333 829:3.33333 845:2.5 860:2.5 880:2.5 892:1.66667 911:1.66667 927:1.66667 998:5 1015:5.83333 1031:20 1048:30.8333 1064:32.5 1093:45 1110:50.8333 1129:52.5 1142:52.5 1236:50.8333 1236:145 1242:42.5 1258:39.1667 1275:35.8333 1292:33.3333 1308:30.8333 1325:28.3333 1342:25.8333 1358:23.3333 1375:21.6667 1392:20 1408:18.3333 1425:16.6667 1442:15.8333 1460:14.1667 1475:13.3333 1492:11.6667 1508:10.8333 1525:10 1542:9.16667 1558:8.33333 1575:7.5 1592:6.66667 1608:6.66667 1625:5.83333 1643:5 1658:5 1759:4.16667 1759:4.16667 1773:-0.833333 1778:-0.833333 1784:-8.33333 1800:-13.3333 1816:-28.3333 1833:-34.1667 1850:-32.5 1860:-49.1667 1875:-57.5 1897:-58.3333 1912:-57.5 1925:-55.8333 1942:-54.1667 1973:-55.8333 1977:-53.3333 1995:-49.1667 2014:-45.8333 2028:-42.5 2046:-39.1667 2064:-37.5 2075:-34.1667 2095:-30.8333 2109:-29.1667 2125:-26.6667 2147:-24.1667 2159:-21.6667 2176:-20 2191:-18.3333 2285:-16.6667 2285:-39.1667 2292:-10.8333 2311:-10 2328:-9.16667 2342:-8.33333 2358:-7.5 2375:-6.66667 2391:-6.66667 2408:-5.83333 2425:-5.83333 2442:-5 2459:-4.16667 2475:-4.16667 2492:-4.16667 2509:-4.16667 2525:-3.33333 2544:-3.33333 2558:-3.33333 2576:-2.5 2592:-2.5 2609:-2.5 2625:-1.66667 2694:0.833333 2709:4.16667 2808:12.5 2808:97.5 2813:31.6667 2828:20.8333 2834:40.8333 2842:47.5 2858:50 2876:49.1667 2891:47.5 2911:45.8333 2925:49.1667 2942:46.6667 2958:44.1667 2975:40.8333 2991:37.5 3009:34.1667 3025:31.6667 3042:29.1667 3059:26.6667 3075:25 3092:22.5 3108:20 3125:18.3333 3144:16.6667 3161:15.8333 3176:14.1667 3194:13.3333 3212:11.6667 3225:10.8333 3241:10 3334:9.16667 3335:8.33333'),
    ('a swipe that stalls while speeding up', [1], '0:0.833333 21:4.16667 33:11.6667 136:20 136:193.333 142:61.6667 152:62.5 166:61.6667 184:60 199:58.3333 228:60 255:56.6667 256:53.3333 266:50 283:46.6667 299:44.1667 316:40.8333 342:37.5 349:34.1667 366:31.6667 383:29.1667 399:26.6667 416:25 433:22.5 449:20 466:18.3333 482:16.6667 499:15.8333 518:14.1667 533:13.3333 550:11.6667 569:10.8333 659:10 659:14.1667 666:6.66667 683:5.83333 699:5.83333 716:5 733:5 750:4.16667 766:4.16667 783:4.16667 799:3.33333 816:3.33333 833:3.33333 849:2.5 866:2.5 883:2.5 899:1.66667 916:1.66667 933:1.66667 949:1.66667 966:1.66667 982:0.833333 999:0.833333 1016:0.833333 1032:0.833333 1050:0.833333 1083:0.833333 1183:0.833333'),
    ('a mouse spun fast: a cluster of notches for each flick', [-1,-1,-1,-1,1,1,1,1,1,1,1,1,1,1], '0:-100 6:-200 272:-100 287:-100 303:-100 318:-100 573:-100 587:-100 602:-100 618:-100 636:-100 885:-100 901:-100 911:-100 926:-100 944:-100 1049:-100 1220:100 1235:100 1251:100 1267:100 1277:100 1354:100 1573:100 1579:300 1594:100 1787:100 1802:100 1827:100 1846:100 1860:100 2097:100 2104:200 2110:100 2127:100 2152:100 2356:100 2373:100 2386:100 2394:100 2410:100 2433:100 2637:100 2658:100 2669:100 2677:100 2693:100 2711:100 2937:100 2970:100 2980:100 2994:100 3055:100 3221:100 3237:100 3255:100 3262:100 3277:100 3293:100 3313:100 3505:100 3520:100 3539:100 3543:100 3560:100 3670:100 3805:100 3821:100 3838:100 3857:100 3872:100'),
  ];
  for (final (name, expected, events) in recorded) {
    testWidgets('recorded: $name', (tester) async {
      await open(tester);
      for (final e in events.split(' ')) {
        final [ms, amount] = e.split(':');
        await wheel(tester, Offset(0, double.parse(amount)), 100000 + int.parse(ms));
      }
      expect(steps, expected);
    }, variant: _windows);
  }

  testWidgets('macOS keeps its own scrolling', (tester) async {
    await open(tester);
    await wheel(tester, const Offset(0, 100), 1000);
    expect(steps, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
