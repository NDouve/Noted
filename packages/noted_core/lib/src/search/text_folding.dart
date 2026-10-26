// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// Text folded for searching: lower case, without diacritics, with every
/// kind of white space (other than a line break) as one space.
///
/// Folding can change the length (`ß` becomes `ss`, a combining accent is
/// dropped), so [origin] maps a position in [text] back to the position of
/// the original text it came from. It is null when the two have the same
/// length and every position is the same.
final class FoldedText {
  const FoldedText(this.text, this.origin);

  final String text;

  /// `origin[i]` is where folded character `i` starts in the original text;
  /// `origin[text.length]` is the original's length. Null: identity.
  final Int32List? origin;

  /// The position in the original text of the folded position [i].
  int originalIndex(int i) => origin == null ? i : origin![i];
}

/// Folds [input] for matching (see [FoldedText]).
///
/// What is folded: case (every script Dart knows), Latin diacritics
/// (Latin-1, Latin Extended-A and -B, Latin Extended Additional including
/// Vietnamese), the ligatures `ß æ œ þ ĳ ﬁ ﬂ ﬀ ﬃ ﬄ`, strokes (`ø đ ł ħ ŧ ð`),
/// Greek tonos and final sigma, Cyrillic `ё` and `й`, combining marks
/// (so decomposed text folds like composed text), typographic quotes and
/// dashes, and zero-width characters (dropped).
FoldedText foldText(String input) {
  final n = input.length;
  final out = StringBuffer();
  List<int>? origin;
  var outLen = 0;

  void emit(String s, int at) {
    if (origin == null && !(s.length == 1 && outLen == at)) {
      origin = List<int>.generate(outLen, (i) => i, growable: true);
    }
    final o = origin;
    if (o != null) {
      for (var k = 0; k < s.length; k++) {
        o.add(at);
      }
    }
    out.write(s);
    outLen += s.length;
  }

  for (var i = 0; i < n; i++) {
    final c = input.codeUnitAt(i);
    if (c < 0x80) {
      final String s;
      if (c >= 0x41 && c <= 0x5A) {
        s = String.fromCharCode(c + 32);
      } else if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0D ||
          c == 0x0B ||
          c == 0x0C) {
        s = ' ';
      } else {
        s = String.fromCharCode(c);
      }
      emit(s, i);
      continue;
    }
    final folded = _foldNonAscii(c);
    if (folded.isEmpty) {
      // Dropped: nothing is emitted, so later positions shift.
      origin ??= List<int>.generate(outLen, (i) => i, growable: true);
      continue;
    }
    emit(folded, i);
  }
  final o = origin;
  if (o == null) return FoldedText(out.toString(), null);
  o.add(n);
  return FoldedText(out.toString(), Int32List.fromList(o));
}

/// [foldText] without the position map, for a query.
String foldString(String input) => foldText(input).text;

/// Whether a (folded) character is part of a word: a letter or a digit.
/// Symbols, punctuation and white space separate words.
bool isWordUnit(int c) {
  if (c < 0x80) {
    return (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);
  }
  if (c >= 0xA0 && c <= 0xBF) return false;
  if (c == 0xD7 || c == 0xF7) return false;
  if (c >= 0x2000 && c <= 0x206F) return false;
  if (c >= 0x20A0 && c <= 0x20CF) return false;
  if (c >= 0x2190 && c <= 0x2BFF) return false;
  if (c >= 0x3000 && c <= 0x303F) return false;
  if (c == 0xFFFC || c == 0xFFFD) return false;
  return true;
}

String _foldNonAscii(int c) {
  final cached = _table[c];
  if (cached != null) return cached;
  final lower = String.fromCharCode(c).toLowerCase();
  if (lower.length == 1 && lower.codeUnitAt(0) == c) {
    return String.fromCharCode(c);
  }
  final b = StringBuffer();
  for (var k = 0; k < lower.length; k++) {
    final u = lower.codeUnitAt(k);
    b.write(u < 0x80 ? lower[k] : (_table[u] ?? lower[k]));
  }
  return b.toString();
}

final Map<int, String> _table = _buildTable();

Map<int, String> _buildTable() {
  final t = <int, String>{};
  void group(String target, String chars) {
    for (final r in chars.runes) {
      t[r] = target;
    }
  }

  group('a', 'àáâãäåāăąǎǟǡǻȁȃȧḁạảấầẩẫậắằẳẵặⱥ');
  group('b', 'ƀɓḃḅḇ');
  group('c', 'çćĉċčƈḉ');
  group('d', 'ďđɗḋḍḏḑḓð');
  group('e', 'èéêëēĕėęěȅȇȩḕḗḙḛḝẹẻẽếềểễệ');
  group('f', 'ƒḟ');
  group('g', 'ĝğġģǥǧǵḡ');
  group('h', 'ĥħḣḥḧḩḫẖ');
  group('i', 'ìíîïĩīĭįıǐȉȋḭḯỉị');
  group('j', 'ĵǰ');
  group('k', 'ķĸƙǩḱḳḵ');
  group('l', 'ĺļľŀłḷḹḻḽ');
  group('m', 'ḿṁṃ');
  group('n', 'ñńņňŉǹṅṇṉṋ');
  group('o', 'òóôõöōŏőơǒǫǭȍȏȫȭȯȱøǿṍṏṑṓọỏốồổỗộớờởỡợ');
  group('p', 'ƥṕṗ');
  group('r', 'ŕŗřȑȓṙṛṝṟ');
  group('s', 'śŝşšșſṡṣṥṧṩ');
  group('t', 'ţťŧțṫṭṯṱẗ');
  group('u', 'ùúûüũūŭůűųưǔǖǘǚǜȕȗṳṵṷṹṻụủứừửữự');
  group('v', 'ṽṿ');
  group('w', 'ŵẁẃẅẇẉẘ');
  group('x', 'ẋẍ');
  group('y', 'ýÿŷȳẏỳỵỷỹẙ');
  group('z', 'źżžƶẑẓẕ');
  t[0xDF] = 'ss'; // ß
  t[0x1E9E] = 'ss'; // ẞ
  t[0xE6] = 'ae'; // æ
  t[0x1FD] = 'ae'; // ǽ
  t[0x153] = 'oe'; // œ
  t[0xFE] = 'th'; // þ
  t[0x133] = 'ij'; // ĳ
  t[0xFB00] = 'ff';
  t[0xFB01] = 'fi';
  t[0xFB02] = 'fl';
  t[0xFB03] = 'ffi';
  t[0xFB04] = 'ffl';
  t[0xFB05] = 'st';
  t[0xFB06] = 'st';
  // Greek: tonos and dialytika off, final sigma as sigma.
  group('α', 'ά');
  group('ε', 'έ');
  group('η', 'ή');
  group('ι', 'ίϊΐ');
  group('ο', 'ό');
  group('υ', 'ύϋΰ');
  group('ω', 'ώ');
  group('σ', 'ς');
  // Cyrillic.
  group('е', 'ё');
  group('и', 'й');
  // Typographic punctuation to its plain form.
  group("'", '‘’‚‛ʼ');
  group('"', '“”„‟');
  group('-', '‐‑‒–—―−');
  // White space of every kind is one space; line separators are line breaks.
  group(
    ' ',
    '          '
        '     　',
  );
  group('\n', '\u0085  ');
  // Zero-width characters and the soft hyphen: dropped.
  group('', '­​‌‍⁠﻿');
  // Combining marks: dropped, so decomposed text folds like composed text.
  for (final range in const [
    (0x0300, 0x036F),
    (0x1AB0, 0x1AFF),
    (0x1DC0, 0x1DFF),
    (0x20D0, 0x20FF),
    (0xFE20, 0xFE2F),
  ]) {
    for (var c = range.$1; c <= range.$2; c++) {
      t[c] = '';
    }
  }
  return t;
}
