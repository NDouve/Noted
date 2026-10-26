// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'text_folding.dart';

/// A span of text, in UTF-16 code units: [start] up to, not including, [end].
final class SearchRange {
  const SearchRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is SearchRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start, $end)';
}

/// One word or one quoted phrase of a query, folded.
final class SearchTerm {
  SearchTerm._(this.text, this.tokens, this.isPhrase)
    : _pattern = tokens.length > 1
          ? RegExp(tokens.map(RegExp.escape).join(' +'))
          : null,
      _wordStart = isWordUnit(text.codeUnitAt(0)),
      _wordEnd = isWordUnit(text.codeUnitAt(text.length - 1));

  /// The folded text of the term (a phrase has its words separated by one
  /// space).
  final String text;

  /// The words of the term; a phrase has several.
  final List<String> tokens;

  /// The term was written in double quotes.
  final bool isPhrase;

  final RegExp? _pattern;
  final bool _wordStart;
  final bool _wordEnd;

  /// Every occurrence of the term in [folded] as a whole word (or phrase),
  /// in order. A phrase's words are separated by spaces only, so it does not
  /// run over a line break.
  List<SearchRange> findIn(String folded) {
    final found = <SearchRange>[];
    final p = _pattern;
    if (p == null) {
      var from = 0;
      while (true) {
        final at = folded.indexOf(text, from);
        if (at < 0) break;
        final end = at + text.length;
        if (_bounded(folded, at, end)) found.add(SearchRange(at, end));
        from = at + 1;
      }
    } else {
      for (final m in p.allMatches(folded)) {
        if (_bounded(folded, m.start, m.end)) {
          found.add(SearchRange(m.start, m.end));
        }
      }
    }
    return found;
  }

  /// Whether [folded] contains the term, without listing where.
  bool occursIn(String folded) {
    final p = _pattern;
    if (p == null) {
      var from = 0;
      while (true) {
        final at = folded.indexOf(text, from);
        if (at < 0) return false;
        if (_bounded(folded, at, at + text.length)) return true;
        from = at + 1;
      }
    }
    for (final m in p.allMatches(folded)) {
      if (_bounded(folded, m.start, m.end)) return true;
    }
    return false;
  }

  bool _bounded(String s, int start, int end) {
    if (_wordStart && start > 0 && isWordUnit(s.codeUnitAt(start - 1))) {
      return false;
    }
    if (_wordEnd && end < s.length && isWordUnit(s.codeUnitAt(end))) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is SearchTerm && other.text == text && other.isPhrase == isPhrase;

  @override
  int get hashCode => Object.hash(text, isPhrase);
}

/// What the user typed to search for.
///
/// Matching rules:
/// - case and accents are ignored (see [foldText]);
/// - several words must all appear in a box (AND), in any order, each as a
///   whole word: `cat` does not match `category`;
/// - a phrase in double quotes matches its words next to each other, as
///   whole words, separated by white space only.
///
/// The query only ever sees the text a box module hands over as its
/// snapshot; it never looks at a box's data.
final class SearchQuery {
  SearchQuery._(this.terms);

  /// Reads [input]. An empty or blank input gives an empty query that
  /// matches nothing.
  factory SearchQuery.parse(String input) {
    final terms = <SearchTerm>[];
    void add(String raw, {required bool phrase}) {
      final folded = foldString(raw).trim();
      if (folded.isEmpty) return;
      final tokens = folded.split(RegExp(r'\s+'));
      final term = SearchTerm._(tokens.join(' '), tokens, phrase);
      if (!terms.contains(term)) terms.add(term);
    }

    final buffer = StringBuffer();
    var quoted = false;
    void flush() {
      add(buffer.toString(), phrase: quoted);
      buffer.clear();
    }

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '"' || ch == '“' || ch == '”') {
        flush();
        quoted = !quoted;
      } else if (!quoted && ch.trim().isEmpty) {
        flush();
      } else {
        buffer.write(ch);
      }
    }
    flush();
    return SearchQuery._(List.unmodifiable(terms));
  }

  /// The words and phrases, all of which must appear.
  final List<SearchTerm> terms;

  bool get isEmpty => terms.isEmpty;

  /// Whether two queries match the same way.
  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      other.terms.length == terms.length &&
      terms.every(other.terms.contains);

  @override
  int get hashCode => Object.hashAllUnordered(terms);

  /// Whether the folded [text] holds every term.
  bool matchesFolded(String text) {
    if (terms.isEmpty) return false;
    for (final t in terms) {
      if (!t.occursIn(text)) return false;
    }
    return true;
  }

  /// Where the terms are in [text] (ascending, overlaps merged, in
  /// [text]'s own positions), or null if some term is missing.
  List<SearchRange>? rangesIn(String text) => rangesInFolded(foldText(text));

  /// [rangesIn] for text that is already folded.
  List<SearchRange>? rangesInFolded(FoldedText folded) {
    if (terms.isEmpty) return null;
    final all = <SearchRange>[];
    for (final t in terms) {
      final found = t.findIn(folded.text);
      if (found.isEmpty) return null;
      all.addAll(found);
    }
    return _toOriginal(_merge(all), folded);
  }

  /// Where any term occurs in [text], whether or not the other terms do.
  /// For highlighting inside a fragment of a box that matched as a whole.
  List<SearchRange> termRangesIn(String text) {
    if (terms.isEmpty) return const [];
    final folded = foldText(text);
    final all = <SearchRange>[];
    for (final t in terms) {
      all.addAll(t.findIn(folded.text));
    }
    return _toOriginal(_merge(all), folded);
  }

  static List<SearchRange> _merge(List<SearchRange> ranges) {
    if (ranges.length < 2) return ranges;
    ranges.sort((a, b) => a.start != b.start ? a.start - b.start : b.end - a.end);
    final merged = <SearchRange>[ranges.first];
    for (var i = 1; i < ranges.length; i++) {
      final last = merged.last;
      final r = ranges[i];
      if (r.start < last.end) {
        if (r.end > last.end) merged[merged.length - 1] = SearchRange(last.start, r.end);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }

  static List<SearchRange> _toOriginal(
    List<SearchRange> ranges,
    FoldedText folded,
  ) {
    if (folded.origin == null) return ranges;
    return [
      for (final r in ranges)
        SearchRange(folded.originalIndex(r.start), folded.originalIndex(r.end)),
    ];
  }
}

/// A short excerpt of a box's text around a match, with the matches in it.
final class SearchSnippet {
  const SearchSnippet(this.text, this.highlights);

  /// The excerpt, on one line, with `…` where the text was cut.
  final String text;

  /// Where the matches are in [text].
  final List<SearchRange> highlights;
}

/// Cuts about [radius] characters before and after the first of [ranges]
/// out of [text], at word breaks where possible. Line breaks become spaces
/// (the length does not change, so [ranges] stay valid inside the excerpt).
SearchSnippet snippetOf(
  String text,
  List<SearchRange> ranges, {
  int radius = 40,
}) {
  if (ranges.isEmpty) {
    final cut = text.length > radius * 2 ? '${text.substring(0, radius * 2)}…' : text;
    return SearchSnippet(cut.replaceAll(RegExp(r'\s'), ' '), const []);
  }
  final first = ranges.first;
  var start = first.start - radius;
  var end = first.end + radius;
  if (start <= 0) {
    start = 0;
  } else {
    final space = text.indexOf(RegExp(r'\s'), start);
    if (space >= 0 && space < first.start) start = space + 1;
  }
  if (end >= text.length) {
    end = text.length;
  } else {
    final space = text.lastIndexOf(RegExp(r'\s'), end);
    if (space > first.end) end = space;
  }
  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  final body = text.substring(start, end).replaceAll(RegExp(r'\s'), ' ');
  final shift = prefix.length - start;
  return SearchSnippet('$prefix$body$suffix', [
    for (final r in ranges)
      if (r.start >= start && r.end <= end)
        SearchRange(r.start + shift, r.end + shift),
  ]);
}
