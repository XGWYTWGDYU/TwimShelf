import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/widgets/text_menu.dart';

Future<void> _openOn(WidgetTester tester, Widget text, {int selected = 5}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: text))));
  final state = tester.state<EditableTextState>(find.byType(EditableText));
  state.userUpdateTextEditingValue(state.textEditingValue.copyWith(selection: TextSelection(baseOffset: 0, extentOffset: selected)), SelectionChangedCause.longPress);
  await tester.pump();
  state.showToolbar();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selected text on Windows gets the app menu, and copy copies and closes it', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _openOn(tester, const SelectableText('hello', contextMenuBuilder: appTextMenu));
    expect(find.byType(TextMenu), findsOneWidget);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pumpAndSettle();
    expect(copied, ['hello']);
    expect(find.byType(TextMenu), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a field offers what a field can do', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    await _openOn(tester, TextField(controller: TextEditingController(text: 'hello'), autofocus: true, contextMenuBuilder: appTextMenu), selected: 3);
    expect(find.byIcon(Icons.content_cut), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(find.byIcon(Icons.select_all), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('elsewhere the platform menu stays', (tester) async {
    await _openOn(tester, const SelectableText('hello', contextMenuBuilder: appTextMenu));
    expect(find.byType(TextMenu), findsNothing);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('every text widget in the app uses it', () {
    final widget = RegExp(r'\b(SelectableText(\.rich)?|TextField|TextFormField)\(');
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final s = f.readAsStringSync();
      for (final m in widget.allMatches(s)) {
        if (!s.startsWith('contextMenuBuilder: appTextMenu', m.end)) missing.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(missing, isEmpty);
  });
}
