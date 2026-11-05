# Platform integration hooks

These helpers deliberately do not edit main.dart or any UI-owned file.

## Secrets (F6)

After WidgetsFlutterBinding.ensureInitialized and successful Core.open, call:

```dart
final result = await Session.applyStoredCookies();
if (result is SecretsUnavailable<void>) {
  // Show the UI's localized secrets-unavailable state.
}
```

Import platform/secrets.dart (use an import prefix if your UI also has a Session type). Secrets.read/write/delete return typed results; they never expose backend exception text. Cookie keys are auth_token and ct0. Empty writes delete a key. Reapply both cookies after edits. No plaintext fallback exists, including debug.On Windows and Linux secrets live in the data folder (`DataFolderSecretBackend`), so they move with it.

## Android shares (F5a)

Create one ShareInbox after the core library is opened, subscribe first, then await inbox.start(). It observes resume automatically. Dispose the subscription and inbox at shutdown.

```dart
final inbox = ShareInbox();
final subscription = inbox.events.listen((event) async {
  if (event is ShareLinksReady) {
    // Pass event.links to the download flow; persist/enqueue successfully first.
    // Use event.id as an idempotency key, since delivery is at least once.
    await enqueueLinks(event.id, event.links);
    await inbox.acknowledgeLinks(event.id);
  } else if (event is ShareFilesImported) {
    // Refresh stats/feed and show the catalog-based import summary.
    refreshLibrary(event.report);
  } else if (event is ShareInboxFailure) {
    // Localized failure state. The source remains queued for the next resume.
  }
});
await inbox.start();
```

No automatic downloads happen in the receiver/helper: the UI owns queue policy and cookie prompts. Files import through Core.importLooseDirAsync(consume:true,keepTo:...). Handle callback failures without acknowledging the links. Do not acknowledge merely because a dialog opened. A restart/resume can redeliver an unacknowledged event; the UI/download queue must deduplicate by event.id.

Native Android storage is filesDir/Shares-Debug for debug, filesDir/Shares otherwise. It follows Shares/Inbox/<id>.partial -> <id> atomic publication and Shares/Kept/<id> problem-file retention. Content resolver streams are copied to regular local files while URI grants are active. Text shares ignore Chrome preview-image URIs; only image/video MIME intents may copy media attachments. No retained content URI, storage permission or network work is used. Published text links use an additive _links.json sidecar (native Apple inbox defines only files); Dart moves it to Shares/Links/<id>.json before importing the flat media folder. That file is deleted only by acknowledgeLinks. Include the selected Shares root among owned source roots when deleting import-history records, as in the native app.

Only post links on x.com/twitter.com and the core's fx/vx mirror hosts are accepted. They normalize to https://x.com/<user>/status/<id> and discard tracking queries. Profile/unrelated/spoofed links and non-content attachments are rejected. Unfinished partial shares are ignored; abandoned ones older than a day are removed. Failed imports stay queued and are retried on a future resume. Symlinks are never imported.

Chooser labels are generated from assets/l10n catalogs by generateShareCatalog; the cold-start activity reads the same bundled catalog for its confirmation. No translation duplicates are maintained. Debug entry lib/dev/share_smoke.dart logs only event counts, acknowledges synthetic links without downloading, and imports synthetic file shares.
