// C ABI declarations, in native/Shared/tl_core.h order.
import 'dart:ffi';
import 'package:ffi/ffi.dart';

final class TlGrid extends Opaque {}
final class TlPet extends Opaque {}

class CoreBindings {
  CoreBindings(this.library);
  final DynamicLibrary library;
  late final tl_fx_api_url = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_fx_api_url');
  late final tl_set_app_name = library.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('tl_set_app_name');
  late final tl_set_language = library.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('tl_set_language');
  late final tl_open = library.lookupFunction<Bool Function(Pointer<Utf8>),
      bool Function(Pointer<Utf8>)>('tl_open');
  late final tl_thumbnail_items = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_thumbnail_items');
  late final tl_feed = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_feed');
  late final tl_feed_packed = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_feed_packed');
  late final tl_import_legacy_dir = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_import_legacy_dir');
  late final tl_import_legacy_zip = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>)>('tl_import_legacy_zip');
  late final tl_import_pack = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_import_pack');
  late final tl_export_media = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_export_media');
  late final tl_parse_bookmarks = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_parse_bookmarks');
  late final tl_download_start = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_download_start');
  late final tl_download_status = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_download_status');
  late final tl_download_cancel = library
      .lookupFunction<Void Function(), void Function()>('tl_download_cancel');
  late final tl_set_cookies = library.lookupFunction<
      Void Function(Pointer<Utf8>, Pointer<Utf8>),
      void Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_set_cookies');
  late final tl_tag = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint8),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)>('tl_tag');
  late final tl_untag = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_untag');
  late final tl_all_tags = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_all_tags');
  late final tl_stats = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_stats');
  late final tl_update_check = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_update_check');
  late final tl_update_download = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_update_download');
  late final tl_storage_usage = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_storage_usage');
  late final tl_share_stage = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('tl_share_stage');
  late final tl_share_pack = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_share_pack');
  late final tl_import_cancel = library.lookupFunction<Void Function(), void Function()>('tl_import_cancel');
  late final tl_report_thumbnail_failed = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('tl_report_thumbnail_failed');
  late final tl_db_snapshot = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('tl_db_snapshot');
  late final tl_free_space = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_free_space');
  late final tl_wipe = library.lookupFunction<Pointer<Utf8> Function(Bool),
      Pointer<Utf8> Function(bool)>('tl_wipe');
  late final tl_string_free = library.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('tl_string_free');
  late final tl_labels_missing_vectors = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_labels_missing_vectors');
  late final tl_set_vectors = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_set_vectors');
  late final tl_sync_new_account = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_sync_new_account');
  late final tl_sync_start = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_sync_start');
  late final tl_sync_status = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_sync_status');
  late final tl_sync_restart_listener = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_sync_restart_listener');
  late final tl_sync_pair_begin = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_sync_pair_begin');
  late final tl_sync_pair_cancel = library
      .lookupFunction<Void Function(), void Function()>('tl_sync_pair_cancel');
  late final tl_sync_join = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint16, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, int, Pointer<Utf8>)>('tl_sync_join');
  late final tl_sync_with = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint16),
      Pointer<Utf8> Function(Pointer<Utf8>, int)>('tl_sync_with');
  late final tl_sync_reset =
      library.lookupFunction<Void Function(), void Function()>('tl_sync_reset');
  late final tl_set_models_dir = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_set_models_dir');
  late final tl_secret_key = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_secret_key');
  late final tl_secret_seal = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_secret_seal');
  late final tl_secret_open = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_secret_open');
  late final tl_model_catalog = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_model_catalog');
  late final tl_hub_device = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_hub_device');
  late final tl_hub_search = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_hub_search');
  late final tl_hub_repo = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_hub_repo');
  late final tl_hub_install = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_hub_install');
  late final tl_model_download_gguf = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_model_download_gguf');
  late final tl_model_download = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_model_download');
  late final tl_model_status = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_model_status');
  late final tl_model_cancel = library
      .lookupFunction<Void Function(), void Function()>('tl_model_cancel');
  late final tl_models_installed = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_models_installed');
  late final tl_models_interrupted = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_models_interrupted');
  late final tl_model_delete = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_model_delete');
  late final tl_model_export_zip = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>)>('tl_model_export_zip');
  late final tl_model_import = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_model_import');
  late final tl_ai_pending = library.lookupFunction<
      Pointer<Utf8> Function(Int64),
      Pointer<Utf8> Function(int)>('tl_ai_pending');
  late final tl_ai_pending_for = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Int64, Int64),
      Pointer<Utf8> Function(Pointer<Utf8>, int, int)>('tl_ai_pending_for');
  late final tl_ai_attempt = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_ai_attempt');
  late final tl_ai_failures = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_ai_failures');
  late final tl_ai_failures_clear = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_ai_failures_clear');
  late final tl_media_page = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Int64),
      Pointer<Utf8> Function(Pointer<Utf8>, int)>('tl_media_page');
  late final tl_setting = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_setting');
  late final tl_set_setting = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_set_setting');
  late final tl_ai_counts = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_ai_counts');
  late final tl_epoch = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_epoch');
  late final tl_ai_apply = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_ai_apply');
  late final tl_sync_peer_models = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint16),
      Pointer<Utf8> Function(Pointer<Utf8>, int)>('tl_sync_peer_models');
  late final tl_sync_pull_model = library.lookupFunction<
      Pointer<Utf8> Function(
          Pointer<Utf8>, Uint16, Pointer<Utf8>, Pointer<Utf8>, Uint64),
      Pointer<Utf8> Function(Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>,
          int)>('tl_sync_pull_model');
  late final tl_trash = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_trash');
  late final tl_trash_restore = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_trash_restore');
  late final tl_trash_purge = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_trash_purge');
  late final tl_trash_empty = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_trash_empty');
  late final tl_trash_list = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_trash_list');
  late final tl_trash_keep_days = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_trash_keep_days');
  late final tl_set_trash_keep_days = library.lookupFunction<
      Pointer<Utf8> Function(Uint32),
      Pointer<Utf8> Function(int)>('tl_set_trash_keep_days');
  late final tl_trash_expire = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_trash_expire');
  late final tl_verify_start = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_verify_start');
  late final tl_verify_status = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_verify_status');
  late final tl_verify_cancel = library
      .lookupFunction<Void Function(), void Function()>('tl_verify_cancel');
  late final tl_report_bad = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_report_bad');
  late final tl_repair = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_repair');
  late final tl_import_status = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_import_status');
  late final tl_import_reports = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_import_reports');
  late final tl_import_report = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_import_report');
  late final tl_import_export_issues = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>)>('tl_import_export_issues');
  late final tl_rename_tag = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_rename_tag');
  late final tl_media_tags = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_media_tags');
  late final tl_folders = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_folders');
  late final tl_delete_tag = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_delete_tag');
  late final tl_remove_ai_tags = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_remove_ai_tags');
  late final tl_folder_overview = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_folder_overview');
  late final tl_media_folders = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_media_folders');
  late final tl_create_folder = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_create_folder');
  late final tl_delete_folder = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_delete_folder');
  late final tl_rename_folder = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_rename_folder');
  late final tl_folder_add = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_folder_add');
  late final tl_folder_remove = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_folder_remove');
  late final tl_import_loose_zip = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>)>('tl_import_loose_zip');
  late final tl_export_backup = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_export_backup');
  late final tl_export_diagnostics = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>)>('tl_export_diagnostics');
  late final tl_tag_to_folder = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_tag_to_folder');
  late final tl_check_cookies = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('tl_check_cookies');
  late final tl_export_status = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_export_status');
  late final tl_export_cancel = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_export_cancel');
  late final tl_import_loose_dir = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_import_loose_dir');
  late final tl_delete_import_reports = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_delete_import_reports');
  late final tl_post_scope = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_post_scope');
  late final tl_bin_snapshot = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_bin_snapshot');
  late final tl_action = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_action');
  late final tl_action_undo = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_action_undo');
  late final tl_download_stop = library.lookupFunction<
      Pointer<Utf8> Function(Bool),
      Pointer<Utf8> Function(bool)>('tl_download_stop');
  late final tl_download_resume = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('tl_download_resume');
  late final tl_media_sizes_filling = library
      .lookupFunction<Bool Function(), bool Function()>('tl_media_sizes_filling');

  late final tl_integrity_summary = library.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('tl_integrity_summary');
  late final tl_grid_new = library.lookupFunction<
      Pointer<TlGrid> Function(Double, Double, Double, Double, Double, Uint64,
          Uint32, Int32, Double),
      Pointer<TlGrid> Function(double, double, double, double, double, int, int,
          int, double)>('tl_grid_new');
  late final tl_grid_free = library.lookupFunction<
      Void Function(Pointer<TlGrid>),
      void Function(Pointer<TlGrid>)>('tl_grid_free');
  late final tl_grid_configure = library.lookupFunction<
      Void Function(
          Pointer<TlGrid>, Double, Double, Double, Double, Double, Uint64),
      void Function(Pointer<TlGrid>, double, double, double, double, double,
          int)>('tl_grid_configure');
  late final tl_grid_rest = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Pointer<Double>),
      void Function(Pointer<TlGrid>, Pointer<Double>)>('tl_grid_rest');
  late final tl_grid_set_offset = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Double),
      void Function(Pointer<TlGrid>, double)>('tl_grid_set_offset');
  late final tl_pet_new = library.lookupFunction<Pointer<TlPet> Function(Uint64), Pointer<TlPet> Function(int)>('tl_pet_new');
  late final tl_pet_free = library.lookupFunction<Void Function(Pointer<TlPet>), void Function(Pointer<TlPet>)>('tl_pet_free');
  late final tl_pet_set_bounds = library.lookupFunction<Void Function(Pointer<TlPet>, Double, Double, Double, Double),
      void Function(Pointer<TlPet>, double, double, double, double)>('tl_pet_set_bounds');
  late final tl_pet_pointer = library.lookupFunction<Void Function(Pointer<TlPet>, Double, Double), void Function(Pointer<TlPet>, double, double)>('tl_pet_pointer');
  late final tl_pet_pointer_gone = library.lookupFunction<Void Function(Pointer<TlPet>), void Function(Pointer<TlPet>)>('tl_pet_pointer_gone');
  late final tl_pet_hit = library.lookupFunction<Bool Function(Pointer<TlPet>, Double, Double), bool Function(Pointer<TlPet>, double, double)>('tl_pet_hit');
  late final tl_pet_tap = library.lookupFunction<Bool Function(Pointer<TlPet>, Double, Double), bool Function(Pointer<TlPet>, double, double)>('tl_pet_tap');
  late final tl_pet_tick = library.lookupFunction<Uint64 Function(Pointer<TlPet>, Double, Pointer<Double>, Uint64),
      int Function(Pointer<TlPet>, double, Pointer<Double>, int)>('tl_pet_tick');
  late final tl_grid_levels = library.lookupFunction<
      Uint64 Function(Pointer<TlGrid>),
      int Function(Pointer<TlGrid>)>('tl_grid_levels');
  late final tl_grid_side = library.lookupFunction<
      Double Function(Pointer<TlGrid>, Uint64),
      double Function(Pointer<TlGrid>, int)>('tl_grid_side');
  late final tl_grid_max_offset = library.lookupFunction<
      Double Function(Pointer<TlGrid>),
      double Function(Pointer<TlGrid>)>('tl_grid_max_offset');
  late final tl_grid_begin_pinch = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Double, Double, Double),
      void Function(
          Pointer<TlGrid>, double, double, double)>('tl_grid_begin_pinch');
  late final tl_grid_pinch_changed = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Double, Double, Double),
      void Function(
          Pointer<TlGrid>, double, double, double)>('tl_grid_pinch_changed');
  late final tl_grid_release = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Double, Double),
      void Function(Pointer<TlGrid>, double, double)>('tl_grid_release');
  late final tl_grid_tick = library.lookupFunction<
      Int32 Function(Pointer<TlGrid>, Double),
      int Function(Pointer<TlGrid>, double)>('tl_grid_tick');
  late final tl_grid_finish_now = library.lookupFunction<
      Bool Function(Pointer<TlGrid>),
      bool Function(Pointer<TlGrid>)>('tl_grid_finish_now');
  late final tl_grid_realign_top = library.lookupFunction<
      Bool Function(Pointer<TlGrid>, Double),
      bool Function(Pointer<TlGrid>, double)>('tl_grid_realign_top');
  late final tl_grid_info = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Pointer<Double>),
      void Function(Pointer<TlGrid>, Pointer<Double>)>('tl_grid_info');
  late final tl_grid_tiles = library.lookupFunction<
      Uint64 Function(Pointer<TlGrid>, Pointer<Double>, Uint64),
      int Function(Pointer<TlGrid>, Pointer<Double>, int)>('tl_grid_tiles');
  late final tl_grid_index_at = library.lookupFunction<
      Int64 Function(Pointer<TlGrid>, Double, Double),
      int Function(Pointer<TlGrid>, double, double)>('tl_grid_index_at');
  late final tl_grid_frame = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Uint64, Pointer<Double>),
      void Function(Pointer<TlGrid>, int, Pointer<Double>)>('tl_grid_frame');
  late final tl_grid_set_hidden = library.lookupFunction<
      Void Function(Pointer<TlGrid>, Int64),
      void Function(Pointer<TlGrid>, int)>('tl_grid_set_hidden');
  late final tl_thumbnail = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint32, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, int, Pointer<Utf8>)>('tl_thumbnail');
  late final tl_display_image = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint32, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, int, Pointer<Utf8>)>('tl_display_image');
  late final tl_thumbnails_warm = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Uint32, Pointer<Utf8>),
      Pointer<Utf8> Function(
          Pointer<Utf8>, int, Pointer<Utf8>)>('tl_thumbnails_warm');
  late final tl_thumbnails_warm_cancel =
      library.lookupFunction<Void Function(), void Function()>(
          'tl_thumbnails_warm_cancel');
  late final tl_discovery_start = library.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('tl_discovery_start');
  late final tl_discovery_status = library.lookupFunction<
      Pointer<Utf8> Function(), Pointer<Utf8> Function()>('tl_discovery_status');
  late final tl_discovery_changed =
      library.lookupFunction<Void Function(), void Function()>('tl_discovery_changed');
  late final tl_discovery_sync_now =
      library.lookupFunction<Void Function(), void Function()>('tl_discovery_sync_now');
  late final tl_discovery_rediscover =
      library.lookupFunction<Void Function(), void Function()>('tl_discovery_rediscover');
  late final tl_discovery_stop =
      library.lookupFunction<Void Function(), void Function()>('tl_discovery_stop');
}
