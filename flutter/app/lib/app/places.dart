import 'package:flutter/material.dart';
import 'prefs.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';

/// A place of the library, the same set (and ids) as the native apps' `LibraryPlace`: the
/// browse, the media kinds, the folders, the special collections and 设置.
@immutable
class Place {
  const Place._(this.id, [this.folder]);

  static const browse = Place._('browse');
  static const photos = Place._('photos');
  static const videos = Place._('videos');
  static const allFolders = Place._('folders');
  static const loose = Place._('loose');
  static const album = Place._('album');
  static const unreviewed = Place._('unreviewed');
  static const reviewed = Place._('reviewed');
  static const bad = Place._('bad');
  static const trash = Place._('trash');
  static const settings = Place._('settings');
  factory Place.folder(String name) => Place._('folder:$name', name);

  /// Stable name (restoring the selection, test keys).
  final String id;
  final String? folder;

  String get title => folder ?? L('place.$id'); // i18n-exempt: keys place.<id>, checked by test/places_test.dart

  IconData get icon => switch (id) {
        'browse' => Icons.photo_library_outlined,
        'photos' => Icons.image_outlined,
        'videos' => Icons.videocam_outlined,
        'folders' => Icons.folder_copy_outlined,
        'loose' => Icons.crop_free,
        'album' => Icons.photo_album_outlined,
        'unreviewed' => Icons.new_releases_outlined,
        'reviewed' => Icons.verified_outlined,
        'bad' => Icons.warning_amber_outlined,
        'trash' => Icons.delete_outline,
        'settings' => Icons.settings_outlined,
        _ => Icons.folder_outlined,
      };

  /// The mascot mode's icon of this place, if it has one.
  String? get mascotIcon => switch (id) {
        'browse' => 'home',
        'photos' => 'image',
        'videos' => 'video',
        'folders' => 'folder',
        'settings' => 'settings',
        _ => folder != null ? 'folder' : null,
      };

  IconData get selectedIcon => switch (id) {
        'browse' => Icons.photo_library,
        'folders' => Icons.folder_copy,
        'settings' => Icons.settings,
        _ => icon,
      };

  /// The media a grid of this place shows; null for places that are not a grid.
  FeedFilter? get filter => switch (id) {
        'photos' => FeedFilter(kind: MediaKind.photo),
        'videos' => FeedFilter(kind: MediaKind.video),
        'loose' => FeedFilter(loose_only: true),
        'album' => FeedFilter(album_only: true),
        'unreviewed' => FeedFilter(review: ReviewFilter.unreviewed),
        'reviewed' => FeedFilter(review: ReviewFilter.reviewed),
        'bad' => FeedFilter(bad_only: true),
        _ => folder != null ? FeedFilter(folder: folder) : null,
      };

  bool get isGrid => filter != null || id == 'trash';

  /// The places of the bar, in the native order.
  static const primary = [browse, allFolders, settings];
  static const mediaKinds = [photos, videos];
  static const others = [loose, album, unreviewed, reviewed, bad, trash];
  /// 损坏或丢失 is offered while the maintenance rows of 关于 are out.
  static List<Place> get offered => [for (final p in others) if (p != bad || Prefs.instance.aboutExtras) p];

  @override
  bool operator ==(Object other) => other is Place && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
