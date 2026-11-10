// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord box(String id, Bounds at) => BoxRecord.create(
  id: id,
  typeId: 'unknown.type',
  dataVersion: 9,
  bounds: at,
  data: RawJson.trusted('{"z":[1, 2]}'),
  snapshotText: 'snap $id',
  rev: 'r',
);

ForeignNode foreign(String id, {Bounds? at}) => ForeignNode.read(
  RawJson.trusted(
    at == null
        ? '{"id":"$id","type":"group","label":"$id"}'
        : '{"id":"$id","type":"group","x":${at.x},"y":${at.y},"width":${at.width},"height":${at.height}}',
  ),
  fallbackId: id,
);

NotedPage pageOf(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

List<String> ids(NotedPage p) => [for (final n in p.nodes) n.id];

void main() {
  const r0 = Bounds(0, 0, 100, 100);
  const r1 = Bounds(50, 50, 100, 100);
  const r2 = Bounds(90, 90, 100, 100);
  const far = Bounds(500, 500, 10, 10);

  group('stackTarget', () {
    final p = pageOf([box('a', r0), box('b', far), box('c', r1), box('d', r2)]);

    test('front and back', () {
      expect(stackTarget(p, 'a', StackMove.front), 3);
      expect(stackTarget(p, 'd', StackMove.front), isNull);
      expect(stackTarget(p, 'd', StackMove.back), 0);
      expect(stackTarget(p, 'a', StackMove.back), isNull);
    });

    test('forward and backward skip nodes that do not overlap', () {
      // a overlaps c (not b); c overlaps d.
      expect(stackTarget(p, 'a', StackMove.forward), 2);
      expect(p.moveNode('a', 2).nodes.map((n) => n.id), ['b', 'c', 'a', 'd']);
      expect(stackTarget(p, 'c', StackMove.forward), 3);
      expect(stackTarget(p, 'd', StackMove.backward), 2);
      expect(stackTarget(p, 'c', StackMove.backward), 0);
      expect(p.moveNode('d', 2).nodes.map((n) => n.id), ['a', 'b', 'd', 'c']);
    });

    test('disabled at the ends, with no overlap, for missing ids', () {
      expect(stackTarget(p, 'b', StackMove.forward), isNull);
      expect(stackTarget(p, 'b', StackMove.backward), isNull);
      expect(stackTarget(p, 'd', StackMove.forward), isNull);
      expect(stackTarget(p, 'a', StackMove.backward), isNull);
      expect(stackTarget(p, 'zz', StackMove.front), isNull);
    });

    test('nodes without bounds never count and cannot step', () {
      final q = pageOf([box('a', r0), foreign('g'), box('c', r1)]);
      expect(stackTarget(q, 'a', StackMove.forward), 2);
      expect(stackTarget(q, 'g', StackMove.forward), isNull);
      expect(stackTarget(q, 'g', StackMove.backward), isNull);
      expect(stackTarget(q, 'g', StackMove.front), 2);
      expect(stackTarget(q, 'c', StackMove.backward), 0);
    });

    test('a node without an id of its own is not restacked', () {
      final q = readPage(
        '{"nodes":[{"type":"group","x":0,"y":0,"width":9,"height":9},'
        '{"id":"a","type":"group","x":0,"y":0,"width":9,"height":9}],'
        '"edges":[],"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
      );
      expect(q.nodes.first.id, startsWith('#node'));
      expect(hasOwnId(q.nodes.first), isFalse);
      expect(hasOwnId(q.nodes.last), isTrue);
      expect(stackTarget(q, q.nodes.first.id, StackMove.front), isNull);
      expect(stackTarget(q, 'a', StackMove.back), 0);
    });

    test('foreign and unknown-type nodes are moved byte for byte', () {
      final f = foreign('f', at: r1);
      final u = box('u', r0);
      final q = pageOf([u, f, box('c', far)]);
      final moved = q.moveNode('u', stackTarget(q, 'u', StackMove.front)!);
      expect(ids(moved), ['f', 'c', 'u']);
      expect(moved.node('u')!.toRaw().text, u.toRaw().text);
      expect(moved.node('f')!.toRaw().text, f.toRaw().text);
      final back = moved.moveNode(
        'f',
        stackTarget(moved, 'f', StackMove.back) ?? 0,
      );
      expect(identical(back, moved), isTrue);
    });
  });

  group('NotedPage.moveNode', () {
    final p = pageOf([box('a', r0), box('b', r1), box('c', r2)]);
    test('index counts after the node is removed and is clamped', () {
      expect(ids(p.moveNode('a', 1)), ['b', 'a', 'c']);
      expect(ids(p.moveNode('a', 99)), ['b', 'c', 'a']);
      expect(ids(p.moveNode('c', -5)), ['c', 'a', 'b']);
    });
    test('a missing id or the same place returns the page', () {
      expect(identical(p.moveNode('zz', 0), p), isTrue);
      expect(identical(p.moveNode('b', 1), p), isTrue);
    });
  });
}
