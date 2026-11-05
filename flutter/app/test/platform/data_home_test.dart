import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/platform/data_home.dart';

void main() {
  test('an AppImage starts again from the AppImage, not its temporary mount', () {
    expect(DataHome.restartTarget({'APPIMAGE': '/home/a/App.AppImage'}, '/tmp/.mount_x/usr/bin/app'), '/home/a/App.AppImage');
    expect(DataHome.restartTarget({}, '/opt/app/app'), '/opt/app/app');
  });
}
