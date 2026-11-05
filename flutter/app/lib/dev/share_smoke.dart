import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import '../platform/share_inbox.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode) return;
  await L10n.load();
  final path = (await getApplicationSupportDirectory()).path;
  Core.setLanguage(L10n.languageTag);
  if (!Core.open(path)) throw const CoreError('app.openFailed');
  final inbox = ShareInbox();
  inbox.events.listen((event) async {
    if (event is ShareLinksReady) {
      // No downloads in the smoke host. Acknowledge only this synthetic test event.
      debugPrint('share-smoke links=${event.links.length}');
      await inbox.acknowledgeLinks(event.id);
    } else if (event is ShareFilesImported) {
      debugPrint(
        'share-smoke media=${event.report.media} new=${event.report.new_media}',
      );
    } else if (event is ShareInboxFailure) {
      debugPrint('share-smoke failure pending=${event.pending}');
    }
  });
  await inbox.start();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text(L('share.title'))),
    ),
  );
}
