// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

/// Box data written in a style `jsonEncode` would change: float formatting,
/// exponents, unicode escapes, odd whitespace and key order.
const String oddData =
    '{ "z":1.0,"a" :[1e2,  -0.0, 1E+2],\n "s":"\\u00e9\\/", "n":{ } }';

final String oddNode =
    '{"id":"b1","type":"text","x":10,"y":20,"width":300,"height":80,'
    '"text":"caf\\u00e9","color":"4","futureField":{"k":[ 1 ]},'
    '"noted":{"type":"vendor.future","v":7,"rev":"r1","baseRev":"r0",'
    '"data":$oddData,"later":true}}';

final String foreignNode =
    '{ "id" : "f1", "type":"file", "file":"a.png", "x":0,"y":0,"width":5,"height":5 }';

final String source =
    '{"edges":[{"id":"e1","fromNode":"b1","toNode":"f1"}],'
    '"nodes":[$oddNode, $foreignNode],'
    '"noted":{"format":1,"pageId":"p1","parentId":null,"title":"T","order":0,"extra":1.50},'
    '"other":{"keep":  "me"}}';

void main() {
  test('reads geometry, header and snapshot', () {
    final page = readPage(source);
    expect(page.id, 'p1');
    expect(page.meta.title, 'T');
    final box = page.nodes.first as BoxRecord;
    expect(box.typeId, 'vendor.future');
    expect(box.dataVersion, 7);
    expect(box.rev, 'r1');
    expect(box.baseRev, 'r0');
    expect(box.snapshotText, 'café');
    expect(box.bounds, const Bounds(10, 20, 300, 80));
    expect(page.nodes[1], isA<ForeignNode>());
  });

  test('unchanged nodes and unknown fields round-trip byte-for-byte', () {
    final out = writePage(readPage(source));
    expect(out, contains(oddNode));
    expect(out, contains(foreignNode));
    expect(out, contains('"edges": [{"id":"e1","fromNode":"b1","toNode":"f1"}]'));
    expect(out, contains('"other": {"keep":  "me"}'));
    expect(out, contains('"extra":1.50'));
    // Writing what was read gives the same file again.
    expect(writePage(readPage(out)), out);
  });

  test('moving a box keeps its module data verbatim', () {
    final page = readPage(source);
    final box = page.nodes.first as BoxRecord;
    final moved = page.replaceNode(box.withBounds(const Bounds(15.4, 25.6, 300, 80)));
    final out = writePage(moved);
    expect(out, contains('"data":$oddData'));
    expect(out, contains('"futureField":{"k":[ 1 ]}'));
    expect(out, contains('"x":15,"y":26'));
    final reread = readPage(out).nodes.first as BoxRecord;
    expect(reread.data!.text, oddData);
    expect(reread.rev, 'r1');
  });

  test('committing content rolls the revision', () {
    final page = readPage(source);
    final box = page.nodes.first as BoxRecord;
    final next = box.withContent(
      data: RawJson.encode({'x': 1}),
      dataVersion: 7,
      snapshotText: 'new',
      newRev: 'r2',
    );
    expect(next.rev, 'r2');
    expect(next.baseRev, 'r1');
    final reread = readPage(writePage(page.replaceNode(next))).nodes.first as BoxRecord;
    expect(reread.rev, 'r2');
    expect(reread.baseRev, 'r1');
    expect(reread.snapshotText, 'new');
    expect(reread.noted['later']!.text, 'true');
  });

  test('a new page round-trips', () {
    final page = Page.create(PageMeta.create(id: 'p2', title: 'New', order: 3));
    final reread = readPage(writePage(page));
    expect(reread.id, 'p2');
    expect(reread.meta.title, 'New');
    expect(reread.meta.order, 3);
    expect(reread.meta.parentId, isNull);
    expect(reread.nodes, isEmpty);
  });

  test('duplicate node ids become read-only foreign nodes', () {
    final dup = source.replaceFirst(', $foreignNode', ', $oddNode');
    final page = readPage(dup);
    expect(page.nodes[0], isA<BoxRecord>());
    expect(page.nodes[1], isA<ForeignNode>());
    expect(page.nodes[1].id, isNot('b1'));
    expect(writePage(page), contains('$oddNode,\n    $oddNode'));
  });

  test('rejects files that are not Noted pages', () {
    expect(() => readPage('not json'), throwsA(isA<PageFormatException>()));
    expect(() => readPage('{"nodes":[]}'), throwsA(isA<PageFormatException>()));
    expect(
      () => readPage('{"noted":{"format":2,"pageId":"x"}}'),
      throwsA(isA<UnsupportedPageFormatException>()),
    );
  });

  test('accepts a byte order mark', () {
    expect(readPage('﻿$source').id, 'p1');
  });
}
