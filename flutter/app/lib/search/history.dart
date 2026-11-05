import 'package:shared_preferences/shared_preferences.dart';

/// Device-local history, using the native key and its exact 12-item MRU rules.
class SearchHistory {
  SearchHistory(this.preferences);
  final SharedPreferences preferences;
  static const key = 'search.history';
  Future<void> _tail = Future.value();
  List<String> get items =>
      List.unmodifiable(preferences.getStringList(key) ?? const []);
  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> add(String value) => _serialize(() async {
    final text = value.trim();
    if (text.isEmpty) return;
    final next = [text, ...items.where((s) => s != text)].take(12).toList();
    if (!await preferences.setStringList(key, next)) {
      throw StateError('search.history.writeFailed');
    }
  });
  Future<void> clear() => _serialize(() async {
    if (!await preferences.remove(key)) {
      throw StateError('search.history.writeFailed');
    }
  });
}
