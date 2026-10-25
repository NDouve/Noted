// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// A single JSON value held as the exact text it was read from or written as.
///
/// The core keeps every value it doesn't need to change as [RawJson] and
/// writes it back unchanged. This is how data from box types the core doesn't
/// support passes through load and save byte-for-byte (invariant 2).
final class RawJson {
  /// Wraps [text] without checking it. Only for text that [JsonSpanReader]
  /// produced or that was just encoded.
  const RawJson.trusted(this.text);

  /// Wraps [text] after checking that it is exactly one JSON value.
  factory RawJson.parse(String text) {
    JsonSpanReader._validate(text);
    return RawJson.trusted(text);
  }

  /// Encodes [value] with `jsonEncode`.
  factory RawJson.encode(Object? value) => RawJson.trusted(jsonEncode(value));

  static const RawJson nullValue = RawJson.trusted('null');

  final String text;

  /// Decodes the value. Each call returns a fresh object.
  Object? decode() => jsonDecode(text);

  bool get isObject => text.startsWith('{');
  bool get isArray => text.startsWith('[');

  @override
  bool operator ==(Object other) => other is RawJson && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

/// A JSON object as an ordered list of keys and raw values.
///
/// Changing one value leaves every other value's text untouched.
final class RawObject {
  const RawObject(this.entries);

  static const RawObject empty = RawObject([]);

  /// Parses [text], which must be a JSON object.
  factory RawObject.parse(String text) => JsonSpanReader.readObject(text);

  final List<(String, RawJson)> entries;

  RawJson? operator [](String key) {
    for (final (k, v) in entries) {
      if (k == key) return v;
    }
    return null;
  }

  bool containsKey(String key) => this[key] != null;

  /// Returns a copy with [key] set to [value]. An existing key keeps its
  /// position; a new key is appended.
  RawObject set(String key, RawJson value) {
    var found = false;
    final next = <(String, RawJson)>[];
    for (final (k, v) in entries) {
      if (!found && k == key) {
        next.add((k, value));
        found = true;
      } else {
        next.add((k, v));
      }
    }
    if (!found) next.add((key, value));
    return RawObject(List.unmodifiable(next));
  }

  /// Returns a copy without [key].
  RawObject remove(String key) =>
      RawObject(List.unmodifiable(entries.where((e) => e.$1 != key)));

  String? string(String key) {
    final v = this[key]?.decode();
    return v is String ? v : null;
  }

  num? number(String key) {
    final v = this[key]?.decode();
    return v is num ? v : null;
  }

  int? integer(String key) {
    final v = this[key]?.decode();
    return v is int ? v : null;
  }

  /// Writes the object on one line. Values are emitted verbatim.
  RawJson toRaw() {
    final b = StringBuffer('{');
    var first = true;
    for (final (k, v) in entries) {
      if (!first) b.write(',');
      first = false;
      b
        ..write(jsonEncode(k))
        ..write(':')
        ..write(v.text);
    }
    b.write('}');
    return RawJson.trusted(b.toString());
  }
}

/// Reads JSON while keeping the source text of each value.
///
/// Only the levels the caller asks for are split into entries. Everything
/// below them stays as one verbatim span.
final class JsonSpanReader {
  JsonSpanReader._(this._s);

  static const int _maxDepth = 512;

  final String _s;
  int _i = 0;

  /// Parses [source], which must be a single JSON object.
  static RawObject readObject(String source) {
    final r = JsonSpanReader._(source);
    r._ws();
    if (r._peek() != 0x7B) r._fail('Expected an object');
    final obj = r._object();
    r._end();
    return obj;
  }

  /// Parses [source], which must be a single JSON array, into its items.
  static List<RawJson> readArray(String source) {
    final r = JsonSpanReader._(source);
    r._ws();
    if (r._peek() != 0x5B) r._fail('Expected an array');
    r._i++;
    final items = <RawJson>[];
    r._ws();
    if (r._peek() == 0x5D) {
      r._i++;
    } else {
      while (true) {
        r._ws();
        final start = r._i;
        r._skipValue(1);
        items.add(RawJson.trusted(source.substring(start, r._i)));
        r._ws();
        if (r._take(0x2C)) continue;
        if (r._take(0x5D)) break;
        r._fail("Expected ',' or ']'");
      }
    }
    r._end();
    return items;
  }

  static void _validate(String source) {
    final r = JsonSpanReader._(source);
    r._ws();
    r._skipValue(0);
    r._end();
  }

  RawObject _object() {
    _i++; // '{'
    final entries = <(String, RawJson)>[];
    _ws();
    if (_take(0x7D)) return RawObject(List.unmodifiable(entries));
    while (true) {
      _ws();
      if (_peek() != 0x22) _fail('Expected a string key');
      final key = _string();
      _ws();
      if (!_take(0x3A)) _fail("Expected ':'");
      _ws();
      final start = _i;
      _skipValue(1);
      entries.add((key, RawJson.trusted(_s.substring(start, _i))));
      _ws();
      if (_take(0x2C)) continue;
      if (_take(0x7D)) break;
      _fail("Expected ',' or '}'");
    }
    return RawObject(List.unmodifiable(entries));
  }

  void _skipValue(int depth) {
    if (depth > _maxDepth) _fail('Nesting too deep');
    switch (_peek()) {
      case 0x7B: // {
        _i++;
        _ws();
        if (_take(0x7D)) return;
        while (true) {
          _ws();
          if (_peek() != 0x22) _fail('Expected a string key');
          _string();
          _ws();
          if (!_take(0x3A)) _fail("Expected ':'");
          _ws();
          _skipValue(depth + 1);
          _ws();
          if (_take(0x2C)) continue;
          if (_take(0x7D)) return;
          _fail("Expected ',' or '}'");
        }
      case 0x5B: // [
        _i++;
        _ws();
        if (_take(0x5D)) return;
        while (true) {
          _ws();
          _skipValue(depth + 1);
          _ws();
          if (_take(0x2C)) continue;
          if (_take(0x5D)) return;
          _fail("Expected ',' or ']'");
        }
      case 0x22:
        _string();
      case 0x74:
        _literal('true');
      case 0x66:
        _literal('false');
      case 0x6E:
        _literal('null');
      default:
        _number();
    }
  }

  String _string() {
    _i++; // opening quote
    final b = StringBuffer();
    var runStart = _i;
    while (true) {
      if (_i >= _s.length) _fail('Unterminated string');
      final c = _s.codeUnitAt(_i);
      if (c == 0x22) {
        b.write(_s.substring(runStart, _i));
        _i++;
        return b.toString();
      }
      if (c < 0x20) _fail('Control character in string');
      if (c != 0x5C) {
        _i++;
        continue;
      }
      b.write(_s.substring(runStart, _i));
      _i++;
      if (_i >= _s.length) _fail('Unterminated escape');
      final e = _s.codeUnitAt(_i++);
      switch (e) {
        case 0x22:
          b.writeCharCode(0x22);
        case 0x5C:
          b.writeCharCode(0x5C);
        case 0x2F:
          b.writeCharCode(0x2F);
        case 0x62:
          b.writeCharCode(0x08);
        case 0x66:
          b.writeCharCode(0x0C);
        case 0x6E:
          b.writeCharCode(0x0A);
        case 0x72:
          b.writeCharCode(0x0D);
        case 0x74:
          b.writeCharCode(0x09);
        case 0x75:
          if (_i + 4 > _s.length) _fail('Bad unicode escape');
          final hex = int.tryParse(_s.substring(_i, _i + 4), radix: 16);
          if (hex == null) _fail('Bad unicode escape');
          b.writeCharCode(hex);
          _i += 4;
        default:
          _i--;
          _fail('Bad escape');
      }
      runStart = _i;
    }
  }

  void _number() {
    final start = _i;
    _take(0x2D);
    if (_take(0x30)) {
      // a leading zero stands alone
    } else if (_digit()) {
      while (_digit()) {}
    } else {
      _i = start;
      _fail('Unexpected character');
    }
    if (_take(0x2E)) {
      if (!_digit()) _fail('Expected a digit');
      while (_digit()) {}
    }
    if (_peek() == 0x65 || _peek() == 0x45) {
      _i++;
      if (!_take(0x2B)) _take(0x2D);
      if (!_digit()) _fail('Expected a digit');
      while (_digit()) {}
    }
  }

  bool _digit() {
    final c = _peek();
    if (c >= 0x30 && c <= 0x39) {
      _i++;
      return true;
    }
    return false;
  }

  void _literal(String word) {
    if (!_s.startsWith(word, _i)) _fail('Unexpected character');
    _i += word.length;
  }

  void _ws() {
    while (_i < _s.length) {
      final c = _s.codeUnitAt(_i);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) return;
      _i++;
    }
  }

  void _end() {
    _ws();
    if (_i != _s.length) _fail('Unexpected text after the JSON value');
  }

  int _peek() => _i < _s.length ? _s.codeUnitAt(_i) : -1;

  bool _take(int c) {
    if (_peek() == c) {
      _i++;
      return true;
    }
    return false;
  }

  Never _fail(String message) => throw FormatException(message, _s, _i);
}
