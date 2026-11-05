import 'dart:convert';
import 'package:test/test.dart';
import 'package:tl_core/tl_core.dart';

// Samples follow the Rust serde schemas: snake_case keys, enum strings, tuples
// as arrays, optional values as null. No native library is opened by these tests.
void main() {
  test('TagView wire round trip', () {
    final json = jsonDecode(
            r'''{"label": "sample", "origin": 7, "models": ["sample"]}''')
        as Map<String, dynamic>;
    expect(TagView.fromJson(json).toJson(), json);
  });
  test('FeedItem wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "post_id": "sample", "ordinal": 7, "kind": "photo", "path": "sample", "text": null, "author_name": null, "screen_name": null, "url": null, "tags": [{"label": "sample", "origin": 7, "models": ["sample"]}], "created_at": null, "bad": null, "recent": true, "album": true}''')
        as Map<String, dynamic>;
    expect(FeedItem.fromJson(json).toJson(), json);
  });
  test('Folder wire round trip', () {
    final json = jsonDecode(
            r'''{"name": "sample", "count": 7, "videos": 7, "cover_id": null, "cover_path": null, "cover_video": true}''')
        as Map<String, dynamic>;
    expect(Folder.fromJson(json).toJson(), json);
  });
  test('FolderOverview wire round trip', () {
    final json = jsonDecode(
            r'''{"folders": [{"name": "sample", "count": 7, "videos": 7, "cover_id": null, "cover_path": null, "cover_video": true}], "photos": 7, "videos": 7}''')
        as Map<String, dynamic>;
    expect(FolderOverview.fromJson(json).toJson(), json);
  });
  test('SearchFields wire round trip', () {
    final json = jsonDecode(r'''{"tags": true, "text": true, "author": true}''')
        as Map<String, dynamic>;
    expect(SearchFields.fromJson(json).toJson(), json);
  });
  test('FeedFilter wire round trip', () {
    final json = jsonDecode(
            r'''{"author": null, "labels": ["sample"], "review": "any", "bad_only": true, "folder": null, "loose_only": true, "album_only": true, "recent_only": true, "kind": null, "exclude_terms": ["sample"], "origins": null, "exclude_folders": ["sample"], "exclude_recent": true, "exclude_loose": true}''')
        as Map<String, dynamic>;
    expect(FeedFilter.fromJson(json).toJson(), json);
  });
  test('FeedRequest wire round trip', () {
    final json = jsonDecode(
            r'''{"terms": ["sample"], "scope": "mine", "seed": null, "newest_first": true, "fuzzy": true, "term_vectors": [null], "embed_model": null, "threshold": 0.55, "fields": {"tags": true, "text": true, "author": true}, "filter": {"author": null, "labels": ["sample"], "review": "any", "bad_only": true, "folder": null, "loose_only": true, "album_only": true, "recent_only": true, "kind": null, "exclude_terms": ["sample"], "origins": null, "exclude_folders": ["sample"], "exclude_recent": true, "exclude_loose": true}}''')
        as Map<String, dynamic>;
    expect(FeedRequest.fromJson(json).toJson(), json);
  });
  test('ImportIssue wire round trip', () {
    final json = jsonDecode(
            r'''{"category": "sample", "path": "sample", "reason": "sample", "same_as": null}''')
        as Map<String, dynamic>;
    expect(ImportIssue.fromJson(json).toJson(), json);
  });
  test('ImportReport wire round trip', () {
    final json = jsonDecode(
            r'''{"posts": 7, "media": 7, "skipped": ["sample"], "deleted": 7, "duplicate_media": 7, "merged_posts": 7, "posts_without_media": 7, "entries": 7, "system_files": 7, "sidecars": 7, "new_media": 7, "folders": 7, "issues": [{"category": "sample", "path": "sample", "reason": "sample", "same_as": null}], "report_file": null, "source": null, "folder": null, "folder_added": 7, "to_bin": 7, "renames_restored": 7, "folders_restored": 7}''')
        as Map<String, dynamic>;
    expect(ImportReport.fromJson(json).toJson(), json);
  });
  test('ImportProgress wire round trip', () {
    final json = jsonDecode(
            r'''{"outcome": "sample", "running": true, "kind": "sample", "folders_done": 7, "folders_total": 7, "files_done": 7, "issues": 7, "current": null, "waiting": true}''')
        as Map<String, dynamic>;
    expect(ImportProgress.fromJson(json).toJson(), json);
  });
  test('ExportOptions wire round trip', () {
    final json =
        jsonDecode(r'''{"tags": true, "folders": true, "media_only": true}''')
            as Map<String, dynamic>;
    expect(ExportOptions.fromJson(json).toJson(), json);
  });
  test('ExportSkip wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "post_id": "sample", "reason": "sample"}''')
        as Map<String, dynamic>;
    expect(ExportSkip.fromJson(json).toJson(), json);
  });
  test('ExportReport wire round trip', () {
    final json = jsonDecode(
            r'''{"posts": 7, "media": 7, "bytes": 7, "trashed": 7, "skipped": [{"media_id": "sample", "post_id": "sample", "reason": "sample"}]}''')
        as Map<String, dynamic>;
    expect(ExportReport.fromJson(json).toJson(), json);
  });
  test('ExportProgress wire round trip', () {
    final json =
        jsonDecode(r'''{"running": true, "done": 7, "total": 7, "bytes": 7}''')
            as Map<String, dynamic>;
    expect(ExportProgress.fromJson(json).toJson(), json);
  });
  test('TagCount wire round trip', () {
    final json =
        jsonDecode(r'''{"label": "sample", "count": 7, "user": 7, "ai": 7}''')
            as Map<String, dynamic>;
    expect(TagCount.fromJson(json).toJson(), json);
  });
  test('LibraryStats wire round trip', () {
    final json = jsonDecode(
            r'''{"posts": 7, "photos": 7, "videos": 7, "tags": 7, "pending_jobs": 7, "failed_jobs": 7, "trashed": 7, "bad": 7, "newer_ops": 7}''')
        as Map<String, dynamic>;
    expect(LibraryStats.fromJson(json).toJson(), json);
  });
  test('TrashItem wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "post_id": "sample", "ordinal": 7, "kind": "photo", "path": "sample", "text": null, "author_name": null, "screen_name": null, "url": null, "tags": [{"label": "sample", "origin": 7, "models": ["sample"]}], "trashed_at_ms": 7}''')
        as Map<String, dynamic>;
    expect(TrashItem.fromJson(json).toJson(), json);
  });
  test('VerifyStatus wire round trip', () {
    final json = jsonDecode(
            r'''{"outcome": "sample", "completed_at": 7, "running": true, "checked": 7, "total": 7, "bytes": 7, "bad": 7, "fixed": 7, "finished": true, "current": null}''')
        as Map<String, dynamic>;
    expect(VerifyStatus.fromJson(json).toJson(), json);
  });
  test('IntegritySummary wire round trip', () {
    final json =
        jsonDecode(r'''{"total": 7, "unchecked": 7, "bad": 7, "last": null}''')
            as Map<String, dynamic>;
    expect(IntegritySummary.fromJson(json).toJson(), json);
  });
  test('DownloadRequest wire round trip', () {
    final json = jsonDecode(
            r'''{"urls": ["sample"], "concurrency": 7, "interval_ms": 7, "route": "auto", "revive": true, "folder": null, "mark_recent": true}''')
        as Map<String, dynamic>;
    expect(DownloadRequest.fromJson(json).toJson(), json);
  });
  test('DownloadStatus wire round trip', () {
    final json = jsonDecode(
            r'''{"outcome": "sample", "paused": 7, "running": true, "total": 7, "done": 7, "skipped": 7, "failed": 7, "active": ["sample"], "errors": [["sample"]], "generation": 7, "recent": ["sample"]}''')
        as Map<String, dynamic>;
    expect(DownloadStatus.fromJson(json).toJson(), json);
  });
  test('DeletedReports wire round trip', () {
    final json = jsonDecode(r'''{"reports": 7, "sources": 7, "bytes": 7}''')
        as Map<String, dynamic>;
    expect(DeletedReports.fromJson(json).toJson(), json);
  });
  test('ActionStamp wire round trip', () {
    final json =
        jsonDecode(r'''{"id": "sample", "hlc": 7, "inc": 7, "state": 7}''')
            as Map<String, dynamic>;
    expect(ActionStamp.fromJson(json).toJson(), json);
  });
  test('ActionReceipt wire round trip', () {
    final json = jsonDecode(
            r'''{"kind": "trash", "folder": null, "folder_hlc": null, "epoch": 7, "changes": [{"id": "sample", "hlc": 7, "inc": 7, "state": 7}]}''')
        as Map<String, dynamic>;
    expect(ActionReceipt.fromJson(json).toJson(), json);
  });
  test('BinSnapshot wire round trip', () {
    final json = jsonDecode(
            r'''{"entries": [{"id": "sample", "hlc": 7, "inc": 7, "state": 7}], "pending_count": 7, "epoch": 7}''')
        as Map<String, dynamic>;
    expect(BinSnapshot.fromJson(json).toJson(), json);
  });
  test('MediaScope wire round trip', () {
    final json = jsonDecode(
            r'''{"ids": ["sample"], "pending_count": 7, "user_tags": {"sample": ["sample"]}}''')
        as Map<String, dynamic>;
    expect(MediaScope.fromJson(json).toJson(), json);
  });
  test('ModelInfo wire round trip', () {
    final json = jsonDecode(
            r'''{"id": "sample", "repo": null, "model_type": null, "vision": true, "bytes": 7, "path": "sample", "format": "gguf", "weights": "w.gguf", "projector": null}''')
        as Map<String, dynamic>;
    expect(ModelInfo.fromJson(json).toJson(), json);
  });
  test('ModelDownloadStatus wire round trip', () {
    final json = jsonDecode(
            r'''{"repo": "sample", "running": true, "total_bytes": 7, "done_bytes": 7, "file": "sample", "error": null, "finished": true}''')
        as Map<String, dynamic>;
    expect(ModelDownloadStatus.fromJson(json).toJson(), json);
  });
  test('MediaRef wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "path": "sample", "kind": "sample", "text": null}''')
        as Map<String, dynamic>;
    expect(MediaRef.fromJson(json).toJson(), json);
  });
  test('InterruptedModel wire round trip', () {
    final json = jsonDecode(r'''{"repo": "sample", "bytes": 7}''')
        as Map<String, dynamic>;
    expect(InterruptedModel.fromJson(json).toJson(), json);
  });
  test('AiFailure wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "model": "sample", "attempts": 7, "reason": "sample", "at": 7}''')
        as Map<String, dynamic>;
    expect(AiFailure.fromJson(json).toJson(), json);
  });
  test('CookieCheck wire round trip', () {
    final json = jsonDecode(
            r'''{"screen_name": null, "name": null, "error": null}''')
        as Map<String, dynamic>;
    expect(CookieCheck.fromJson(json).toJson(), json);
  });
  test('PeerInfo wire round trip', () {
    final json = jsonDecode(
            r'''{"device": "sample", "name": "sample", "last_sync": 7, "last_error": null, "addr": "sample", "clock_skew_ms": null, "clock_warning": true}''')
        as Map<String, dynamic>;
    expect(PeerInfo.fromJson(json).toJson(), json);
  });
  test('JoinState wire round trip', () {
    final json =
        jsonDecode(r'''{"running": true, "account_key": null, "error": null}''')
            as Map<String, dynamic>;
    expect(JoinState.fromJson(json).toJson(), json);
  });
  test('Transfer wire round trip', () {
    final json = jsonDecode(
            r'''{"received": 7, "total": 7, "total_bytes": 7, "bytes": 7, "current_size": 7, "current_done": 7, "last_path": null}''')
        as Map<String, dynamic>;
    expect(Transfer.fromJson(json).toJson(), json);
  });
  test('SyncStatus wire round trip', () {
    final json = jsonDecode(
            r'''{"account_id": null, "device_id": "sample", "device_name": "sample", "port": null, "pairing_code": null, "pairing_seconds_left": null, "peers": [{"device": "sample", "name": "sample", "last_sync": 7, "last_error": null, "addr": "sample", "clock_skew_ms": null, "clock_warning": true}], "syncing": 7, "changes": 7, "join": {"running": true, "account_key": null, "error": null}, "receiving": null, "failed": {"sample": "sample"}}''')
        as Map<String, dynamic>;
    expect(SyncStatus.fromJson(json).toJson(), json);
  });
  test('ThumbnailItem wire round trip', () {
    final json = jsonDecode(
            r'''{"media_id": "sample", "path": "sample", "kind": "photo"}''')
        as Map<String, dynamic>;
    expect(ThumbnailItem.fromJson(json).toJson(), json);
  });

  test('FeedRequest defaults match the Swift request and Rust wire keys', () {
    final json = FeedRequest().toJson();
    expect(json['scope'], 'both');
    expect(json['threshold'], 0.55);
    expect(json['fuzzy'], true);
    expect(json['term_vectors'], isEmpty);
    expect(json['fields'], {'tags': true, 'text': false, 'author': false});
    expect((json['filter'] as Map)['review'], 'any');
  });
  test('nullable vectors and floating point values survive JSON', () {
    final request = FeedRequest(term_vectors: [
      null,
      [1, 0.5]
    ]);
    expect(
        FeedRequest.fromJson(jsonDecode(jsonEncode(request.toJson())))
            .term_vectors,
        [
          null,
          [1.0, 0.5]
        ]);
  });
  test('model collections take immutable defensive copies', () {
    final labels = ['a'];
    final filter = FeedFilter(labels: labels);
    labels.add('b');
    expect(filter.labels, ['a']);
    expect(() => filter.labels.add('c'), throwsUnsupportedError);
    final vector = [1.0];
    final request = FeedRequest(term_vectors: [vector]);
    vector.add(2);
    expect(request.term_vectors.single, [1.0]);
    expect(() => request.term_vectors.single!.add(2), throwsUnsupportedError);
  });
}
