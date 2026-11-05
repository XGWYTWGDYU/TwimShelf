import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/services/updates.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tl-update'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a new AppImage takes the place of the old one, runnable, and leaves nothing behind', () async {
    final download = File('${dir.path}/download')..writeAsStringSync('new');
    final self = File('${dir.path}/App.AppImage')..writeAsStringSync('old');
    await Updates.replaceAppImage(download.path, self.path);
    expect(self.readAsStringSync(), 'new');
    expect(self.statSync().mode & 0x40, isNonZero, reason: 'owner may run it');
    expect(download.existsSync(), isFalse);
    expect(File('${self.path}.update').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('when the copy fails the old program stays as it was', () async {
    final self = File('${dir.path}/App.AppImage')..writeAsStringSync('old');
    await expectLater(Updates.replaceAppImage('${dir.path}/missing', self.path), throwsA(isA<FileSystemException>()));
    expect(self.readAsStringSync(), 'old');
    expect(File('${self.path}.update').existsSync(), isFalse);
  });
}
