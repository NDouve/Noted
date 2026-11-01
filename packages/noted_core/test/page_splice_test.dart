// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

// A page file in a hand-made layout: odd whitespace, odd number formats,
// a key order jsonEncode wouldn't keep, unknown fields.
const String box1 =
    '{ "id":"b1","type":"text","x":10,"y":20.0,"width":300,"height":80,"text":"old text",\n'
    '      "color":"4","futureField":{"k":[ 1 ]},\n'
    '      "noted":{"type":"noted.ai","v":1,"rev":"r1","data":{"document":{ "type":"page","children":[]},"owner":"c"},'
    '"later":true,"device":"old-dev","at":5}}';
const String box2 =
    '{"id":"b2","type":"text","x":0,"y":0,"width":5,"height":5,"text":"two","noted":{"type":"vendor.x","v":3,"rev":"q1","data":{ "z":1.0 }}}';
const String foreign = '{ "id" : "f1", "type":"file", "file":"a.png", "x":0,"y":0,"width":5,"height":5 }';

String page({String between = ',\n    '}) =>
    '{\r\n  "edges" :[ {"id":"e1","fromNode":"b1","toNode":"f1"} ],\r\n'
    '  "nodes":[\r\n    $box1$between$foreign$between$box2\r\n  ],\r\n'
    '  "noted":{"format":1,"pageId":"p1","parentId":null,"title":"T","order":0,"extra":1.50},\r\n'
    '  "other":{"keep":  "me"}\r\n}\r\n';

void main() {
  const data = RawJson.trusted('{"document":{"type":"page","children":[{"type":"paragraph"}]},"owner":"c"}');

  test('only the one box record changes; every other byte stays', () {
    final source = page();
    final out = spliceBoxContent(
      source,
      'b1',
      data: data,
      dataVersion: 2,
      snapshotText: 'new text',
      newRev: 'r2',
      device: 'new-dev',
      at: 99,
    )!;
    final start = source.indexOf(box1);
    final newRecord = (readPage(out).nodes.first as BoxRecord).toRaw().text;
    expect(newRecord, isNot(box1));
    // Taking the record out of both texts leaves identical text.
    expect(out.replaceRange(start, start + newRecord.length, ''), source.replaceRange(start, start + box1.length, ''));
    expect(out.substring(0, start), source.substring(0, start));
  });

  test('the record changes the way commitBox changes it', () {
    final out = spliceBoxContent(
      page(),
      'b1',
      data: data,
      dataVersion: 2,
      snapshotText: 'new text',
      newRev: 'r2',
      device: 'new-dev',
      at: 99,
    )!;
    final nb = readPage(out).nodes.first as BoxRecord;
    expect(nb.rev, 'r2');
    expect(nb.baseRev, 'r1');
    expect(nb.dataVersion, 2);
    expect(nb.snapshotText, 'new text');
    expect(nb.noted['data'], data);
    expect(nb.noted.string('device'), 'new-dev');
    expect(nb.noted.integer('at'), 99);
    // Geometry, the unknown fields and the unknown header field are kept.
    expect(nb.bounds, const Bounds(10, 20, 300, 80));
    expect(nb.fields['futureField']!.text, '{"k":[ 1 ]}');
    expect(nb.fields['color']!.text, '"4"');
    expect(nb.noted['later']!.text, 'true');
    // The same result as the model's own commit.
    final original = (readPage(page()).nodes.first as BoxRecord).withContent(
      data: data,
      dataVersion: 2,
      snapshotText: 'new text',
      newRev: 'r2',
      device: 'new-dev',
      at: 99,
    );
    expect(nb.toRaw().text, original.toRaw().text);
  });

  test('a null device and at remove the stamps, like commitBox', () {
    final out = spliceBoxContent(
      page(),
      'b1',
      data: data,
      dataVersion: 1,
      snapshotText: 's',
      newRev: 'r2',
    )!;
    final nb = readPage(out).nodes.first as BoxRecord;
    expect(nb.noted.containsKey('device'), isFalse);
    expect(nb.noted.containsKey('at'), isFalse);
  });

  test('the other boxes, the foreign node, the edges and the header read back unchanged', () {
    final before = readPage(page());
    final out = spliceBoxContent(page(), 'b2', data: const RawJson.trusted('{"z":2}'), dataVersion: 3, snapshotText: 'x', newRev: 'q2')!;
    final after = readPage(out);
    expect((after.nodes[0] as BoxRecord).toRaw().text, (before.nodes[0] as BoxRecord).toRaw().text);
    expect(after.nodes[1].toRaw().text, before.nodes[1].toRaw().text);
    expect(out, contains(box1));
    expect(out, contains(foreign));
    expect(out, contains('"edges" :[ {"id":"e1","fromNode":"b1","toNode":"f1"} ]'));
    expect(out, contains('"extra":1.50'));
    expect(out, contains('"other":{"keep":  "me"}'));
    expect(out, isNot(contains('"two"')));
    expect((after.nodes[2] as BoxRecord).rev, 'q2');
    expect((after.nodes[2] as BoxRecord).baseRev, 'q1');
  });

  test('a byte order mark is kept and the offsets still hold', () {
    final source = '﻿${page()}';
    final out = spliceBoxContent(source, 'b2', data: const RawJson.trusted('{"z":2}'), dataVersion: 3, snapshotText: 'x', newRev: 'q2')!;
    expect(out.codeUnitAt(0), 0xFEFF);
    expect(out, contains(box1));
    expect((readPage(out).nodes[2] as BoxRecord).rev, 'q2');
  });

  test('different layouts: compact nodes and one per line', () {
    for (final between in [',', ' , ', ',\r\n']) {
      final out = spliceBoxContent(page(between: between), 'b1', data: data, dataVersion: 2, snapshotText: 's', newRev: 'r2')!;
      expect((readPage(out).nodes.first as BoxRecord).rev, 'r2');
      expect(out, contains(box2));
      expect(out, contains(foreign));
    }
  });

  test('null for a missing box, a foreign node id, and text that cannot be read', () {
    String? splice(String text, String id) =>
        spliceBoxContent(text, id, data: data, dataVersion: 1, snapshotText: 's', newRev: 'r');
    expect(splice(page(), 'nope'), isNull);
    expect(splice(page(), 'f1'), isNull);
    expect(splice('not json', 'b1'), isNull);
    expect(splice('{"nodes":[]}', 'b1'), isNull);
    expect(splice('', 'b1'), isNull);
    expect(splice('{"nodes":[],"noted":{"format":99,"pageId":"p"}}', 'b1'), isNull);
    expect(splice(page().replaceFirst('"nodes":[', '"nodes":{'), 'b1'), isNull);
    expect(splice(page().replaceFirst(']', ''), 'b1'), isNull);
  });

  test('the first node with the id decides: a foreign node first means null, not the later box', () {
    const dup = '{"id":"b1","type":"file","file":"a.png","x":0,"y":0,"width":5,"height":5}';
    final text = '{"nodes":[$dup,$box1],"noted":{"format":1,"pageId":"p1","title":"T","order":0}}';
    String? splice(String t) =>
        spliceBoxContent(t, 'b1', data: data, dataVersion: 1, snapshotText: 's', newRev: 'r');
    expect(splice(text), isNull);
    // A readable box first wins; the duplicate after it is left alone.
    final other = '{"nodes":[$box1,$dup],"noted":{"format":1,"pageId":"p1","title":"T","order":0}}';
    final out = splice(other)!;
    expect(out, endsWith(',$dup],"noted":{"format":1,"pageId":"p1","title":"T","order":0}}'));
    expect((readPage(out).nodes.first as BoxRecord).rev, 'r');
  });

  test('the span readers give exact ranges', () {
    const s = '{ "a" : [1, {"b":2}] , "c":"x" }';
    final spans = JsonSpanReader.objectEntrySpans(s);
    expect(spans.map((e) => e.$1), ['a', 'c']);
    expect(s.substring(spans[0].$2, spans[0].$3), '[1, {"b":2}]');
    expect(s.substring(spans[1].$2, spans[1].$3), '"x"');
    const arr = ' [ 1 , "two",{"k":[ ]} ] ';
    final items = JsonSpanReader.arrayItemSpans(arr);
    expect(items.map((e) => arr.substring(e.$1, e.$2)), ['1', '"two"', '{"k":[ ]}']);
    expect(JsonSpanReader.arrayItemSpans('[]'), isEmpty);
    expect(JsonSpanReader.objectEntrySpans('{}'), isEmpty);
    expect(() => JsonSpanReader.arrayItemSpans('{}'), throwsFormatException);
    expect(() => JsonSpanReader.objectEntrySpans('[1] x'), throwsFormatException);
  });
}
