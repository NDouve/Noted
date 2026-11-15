// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Run 2026-11-14-02, task 3. Every merge in the app takes its registry from
// `_mergeCodecs`, built from the versions the merge reads, so a type a page
// disallows is never decoded by a merge (0111).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every mergePage and mergeConflictCopy call in app/lib passes _mergeCodecs(...) with its versions', () {
    final files = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f,
    ];
    var calls = 0;
    for (final f in files) {
      final src = f.readAsStringSync();
      expect(src, isNot(contains('_pageCodecs')), reason: f.path);
      for (final name in ['mergePage', 'mergeConflictCopy']) {
        for (final m in RegExp('\\b$name\\(').allMatches(src)) {
          final args = _topLevelArguments(src, m.end);
          // The registry is the 4th positional argument of mergePage and the
          // 3rd of mergeConflictCopy.
          final at = name == 'mergePage' ? 3 : 2;
          final where = '${f.path}: $name(${args.join(', ')})';
          expect(args.length, greaterThan(at), reason: where);
          final registry = args[at].trim();
          expect(registry, startsWith('_mergeCodecs('), reason: where);
          final list = RegExp(r'_mergeCodecs\([^,]+,\s*\[([^\]]*)\]').firstMatch(registry);
          expect(list, isNotNull, reason: 'a list of versions: $where');
          expect(list!.group(1)!.trim(), isNotEmpty, reason: where);
          calls++;
        }
      }
    }
    expect(calls, greaterThanOrEqualTo(10), reason: 'the calls were found');
  });

  test('the argument splitter ignores commas in nested brackets and strings', () {
    expect(_topLevelArguments("f(a, g(b, c), [d, e], {'k': 1}, 'x, y', \"p, q\")", 2), [
      'a',
      ' g(b, c)',
      ' [d, e]',
      " {'k': 1}",
      " 'x, y'",
      '"p, q"',
    ]);
  });
}

/// The top-level arguments of the call whose text starts at [from] (just past
/// the opening parenthesis), split on commas outside nested parentheses,
/// brackets, braces and strings.
List<String> _topLevelArguments(String src, int from) {
  final out = <String>[];
  var depth = 0;
  var start = from;
  String? quote;
  for (var i = from; i < src.length; i++) {
    final ch = src[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    switch (ch) {
      case "'" || '"':
        quote = ch;
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        if (depth == 0) {
          final last = src.substring(start, i).trim();
          if (last.isNotEmpty) out.add(last);
          return out;
        }
        depth--;
      case ',':
        if (depth == 0) {
          out.add(src.substring(start, i));
          start = i + 1;
        }
    }
  }
  return out;
}
