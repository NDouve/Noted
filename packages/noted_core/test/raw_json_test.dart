// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  group('RawObject.parse', () {
    test('keeps each value as its exact source text', () {
      const src = '{ "a" : 1.0 , "b":[1e2, -0.5E-3],"c": "\\u00e9\\n", "d" : {"x":null} }';
      final o = RawObject.parse(src);
      expect(o.entries.map((e) => e.$1), ['a', 'b', 'c', 'd']);
      expect(o['a']!.text, '1.0');
      expect(o['b']!.text, '[1e2, -0.5E-3]');
      expect(o['c']!.text, '"\\u00e9\\n"');
      expect(o['d']!.text, '{"x":null}');
      expect(o.string('c'), 'é\n');
    });

    test('decodes escaped keys', () {
      final o = RawObject.parse(r'{"type":true}');
      expect(o['type']!.text, 'true');
    });

    test('rejects malformed input', () {
      for (final bad in [
        '',
        '[]',
        '{',
        '{"a":}',
        '{"a":1,}',
        '{"a":01}',
        '{"a":1} x',
        '{"a":"\u0001"}',
        '{"a":tru}',
        '{"a":"\\x"}',
      ]) {
        expect(() => RawObject.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('set keeps position and other values untouched', () {
      final o = RawObject.parse('{"a":1.50,"b":2,"c":[ 3 ]}');
      final n = o.set('b', RawJson.encode(9)).set('z', RawJson.encode('new'));
      expect(n.toRaw().text, '{"a":1.50,"b":9,"c":[ 3 ],"z":"new"}');
      expect(n.remove('a').toRaw().text, '{"b":9,"c":[ 3 ],"z":"new"}');
    });
  });

  group('readArray', () {
    test('splits items verbatim', () {
      final items = JsonSpanReader.readArray('[ {"a": 1} ,2.0, "x" ]');
      expect(items.map((e) => e.text), ['{"a": 1}', '2.0', '"x"']);
    });

    test('handles empty arrays', () {
      expect(JsonSpanReader.readArray(' [ ] '), isEmpty);
    });
  });

  test('RawJson.parse validates a single value', () {
    expect(RawJson.parse(' [1, {"a": [true]}] ').decode(), [
      1,
      {
        'a': [true],
      },
    ]);
    expect(() => RawJson.parse('1 2'), throwsFormatException);
  });
}
