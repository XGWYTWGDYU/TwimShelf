import 'package:characters/characters.dart';
import 'package:tl_core/tl_core.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

class SearchMarks {
  SearchMarks({List<String> terms = const [], SearchFields? fields})
    : terms = List.unmodifiable(terms),
      fields = fields ?? SearchFields(tags: true, text: true, author: true);
  final List<String> terms;
  final SearchFields fields;
  static final none = SearchMarks();
  List<String> get tags =>
      fields.tags || (!fields.text && !fields.author) ? terms : const [];
  List<String> get text => fields.text ? terms : const [];
  List<String> get author => fields.author ? terms : const [];
}

/// UTF-16 offsets, suitable for Dart substring/TextSpan and native NSRange.
class HighlightRange {
  const HighlightRange(this.start, this.end);
  final int start, end;
  int get length => end - start;
  @override
  bool operator ==(Object other) =>
      other is HighlightRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
}

String _fold(String value) {
  // Foundation width folding keeps halfwidth voiced marks distinct from a
  // composed fullwidth kana. Preserve that distinction while folding its base.
  final source = value
      .replaceAll('\uff9e', '\u309b')
      .replaceAll('\uff9f', '\u309c');
  return unicode
      .nfkd(source)
      .toLowerCase()
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
      .replaceAll('ß', 'ss')
      .replaceAll('ς', 'σ');
}

/// Case/width/diacritic insensitive matches mapped back to original graphemes.
/// Each term advances past its previous match, like NSString.range(of:).
List<HighlightRange> highlightRanges(List<String> terms, String text) {
  final buffer = StringBuffer();
  final starts = <int>[], ends = <int>[];
  var offset = 0;
  for (final grapheme in text.characters) {
    final pieces = grapheme.contains('\uff9e') || grapheme.contains('\uff9f')
        ? grapheme.runes.map(String.fromCharCode)
        : [grapheme];
    for (final piece in pieces) {
      final folded = _fold(piece);
      buffer.write(folded);
      for (var i = 0; i < folded.length; i++) {
        starts.add(offset);
        ends.add(offset + piece.length);
      }
      offset += piece.length;
    }
  }
  final haystack = buffer.toString();
  final ranges = <HighlightRange>[];
  for (final term
      in terms.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet()) {
    final needle = _fold(term);
    if (needle.isEmpty) continue;
    var from = 0;
    while (from < haystack.length) {
      final found = haystack.indexOf(needle, from);
      if (found < 0) break;
      final end = found + needle.length;
      // A base kana must not match the first half of a voiced kana.
      if (end < haystack.length &&
          const [0x3099, 0x309a].contains(haystack.codeUnitAt(end))) {
        from = end;
        continue;
      }
      ranges.add(
        HighlightRange(starts[found], ends[found + needle.length - 1]),
      );
      from = found + needle.length;
    }
  }
  ranges.sort(
    (a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : a.end.compareTo(b.end),
  );
  final merged = <HighlightRange>[];
  for (final range in ranges) {
    if (merged.isNotEmpty && range.start < merged.last.end) {
      final last = merged.removeLast();
      merged.add(
        HighlightRange(last.start, range.end > last.end ? range.end : last.end),
      );
    } else {
      merged.add(range);
    }
  }
  return List.unmodifiable(merged);
}
