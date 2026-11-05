import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sidebar layout's shape: its page area gets a copy of the MediaQuery from above the
/// Scaffold, keyboard included, and the page has a Scaffold of its own. With an iPad's keyboard up.
Future<double> _pageHeight(WidgetTester t, {required bool outerResizes}) async {
  final view = t.view;
  view.physicalSize = const Size(1000, 695);
  view.devicePixelRatio = 1;
  view.viewInsets = const FakeViewPadding(bottom: 350);
  addTearDown(view.reset);
  const body = Key('page');
  await t.pumpWidget(MaterialApp(
    home: Builder(builder: (context) {
      final mq = MediaQuery.of(context);
      return Scaffold(
        resizeToAvoidBottomInset: outerResizes,
        body: MediaQuery(data: mq, child: const Scaffold(body: SizedBox.expand(key: body))),
      );
    }),
  ));
  return t.getSize(find.byKey(body)).height;
}

void main() {
  testWidgets('the keyboard is made room for once: twice leaves a page no height at all', (t) async {
    expect(await _pageHeight(t, outerResizes: true), 0);
    expect(await _pageHeight(t, outerResizes: false), 345);
  });

  test('the sidebar layout leaves the room to the page', () {
    final source = File('lib/app/shell.dart').readAsStringSync();
    final layout = source.substring(source.indexOf('Widget _sidebarLayout()'));
    expect(layout.substring(layout.indexOf('return Scaffold(')), contains('resizeToAvoidBottomInset: false'));
  });
}
