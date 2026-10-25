// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId, {this.merges = false});

  @override
  final String typeId;
  final bool merges;

  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => 'snap:$data';
  @override
  AiExposure aiExposure(String data) => AiText(data);
  @override
  MergeResult<String> merge(String base, String mine, String theirs) =>
      merges ? Merged('$mine+$theirs') : const Conflicted();
}

const _merging = _Codec('test.merge', merges: true);
const _plain = _Codec('test.plain');

CodecRegistry registry() => CodecRegistry()
  ..register(_merging)
  ..register(_plain);

BoxRecord box(String id, String type, String data, {Bounds? at, String? rev}) =>
    BoxRecord.create(
      id: id,
      typeId: type,
      dataVersion: 1,
      bounds: at ?? const Bounds(0, 0, 100, 50),
      data: RawJson.encode(data),
      snapshotText: 'snap:$data',
      rev: rev ?? 'r-$id',
    );

BoxRecord edit(BoxRecord b, String data) => commitBox(
  b,
  b.typeId == 'test.merge' ? _merging : _plain,
  data,
);

NotedPage pageOf(List<CanvasNode> nodes, {String title = 'T', int order = 0}) {
  var p = NotedPage.create(
    PageMeta.create(id: 'p', title: title, order: order),
  );
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

String dataOf(CanvasNode? n) => (n as BoxRecord).data!.decode()! as String;

PageMerge merge(NotedPage base, NotedPage mine, NotedPage theirs, {int time = 1000}) =>
    mergePage(base, mine, theirs, registry(), theirsTime: time);

void main() {
  final a = box('a', 'test.merge', 'one');
  final b = box('b', 'test.plain', 'two');
  final base = pageOf([a, b]);

  test('nothing changed: the same nodes, written back verbatim', () {
    final r = merge(base, base, base);
    expect(r.conflictedIds, isEmpty);
    expect(writePage(r.page), writePage(base));
  });

  test('theirs-only content change is taken', () {
    final theirs = base.replaceNode(edit(a, 'their'));
    final r = merge(base, base, theirs);
    expect(dataOf(r.page.node('a')), 'their');
    expect(r.page.node('a')!.toRaw(), theirs.node('a')!.toRaw());
    expect(r.page.node('b')!.toRaw(), b.toRaw());
    expect(r.conflictedIds, isEmpty);
  });

  test('mine-only content change is kept', () {
    final mine = base.replaceNode(edit(b, 'mine'));
    final r = merge(base, mine, base);
    expect(dataOf(r.page.node('b')), 'mine');
    expect(r.conflictedIds, isEmpty);
  });

  test('both changed with a merging codec: merged through the codec', () {
    final mine = base.replaceNode(edit(a, 'mine'));
    final theirs = base.replaceNode(edit(a, 'their'));
    final r = merge(base, mine, theirs);
    final m = r.page.node('a')! as BoxRecord;
    expect(dataOf(m), 'mine+their');
    expect(m.snapshotText, 'snap:mine+their');
    expect(m.rev, isNot((mine.node('a')! as BoxRecord).rev));
    expect(m.isConflicted, isFalse);
    expect(r.conflictedIds, isEmpty);
  });

  test('both changed with the default codec: conflicted, theirs stored verbatim', () {
    final mine = base.replaceNode(edit(b, 'mine'));
    final theirs = base.replaceNode(edit(b, 'their'));
    final r = merge(base, mine, theirs, time: 4242);
    final m = r.page.node('b')! as BoxRecord;
    expect(dataOf(m), 'mine');
    expect(r.conflictedIds, {'b'});
    expect(m.conflicts, hasLength(1));
    expect(m.conflicts.single.at, 4242);
    expect(m.conflicts.single.deleted, isFalse);
    expect(m.conflicts.single.node, theirs.node('b')!.toRaw());
    // It survives a write and read.
    final back = readPage(writePage(r.page)).node('b')! as BoxRecord;
    expect(back.conflicts.single.node, theirs.node('b')!.toRaw());
    expect(back.toRaw(), m.toRaw());
  });

  test('merging the same theirs again does not duplicate the conflict', () {
    final mine = base.replaceNode(edit(b, 'mine'));
    final theirs = base.replaceNode(edit(b, 'their'));
    final once = merge(base, mine, theirs).page;
    final twice = merge(base, once, theirs).page;
    expect((twice.node('b')! as BoxRecord).conflicts, hasLength(1));
  });

  test('a box this device cannot run, changed on both sides: conflicted', () {
    final u = box('u', 'x.unknown', 'zzz');
    final b0 = pageOf([u]);
    final mine = b0.replaceNode(u.withContent(
      data: RawJson.encode('m'),
      dataVersion: 1,
      snapshotText: 'm',
      newRev: 'm1',
    ));
    final theirs = b0.replaceNode(u.withContent(
      data: RawJson.encode('t'),
      dataVersion: 1,
      snapshotText: 't',
      newRev: 't1',
    ));
    final r = merge(b0, mine, theirs);
    expect(r.conflictedIds, {'u'});
    expect(r.page.node('u')!.toRaw().text, contains('"m1"'));
    // One side only: taken without decoding.
    final r2 = merge(b0, b0, theirs);
    expect(r2.conflictedIds, isEmpty);
    expect(r2.page.node('u')!.toRaw(), theirs.node('u')!.toRaw());
  });

  group('geometry', () {
    const moved = Bounds(10, 20, 100, 50);
    const other = Bounds(300, 5, 120, 60);

    test('theirs moved, mine did not: theirs', () {
      final r = merge(base, base, base.replaceNode(a.withBounds(moved)));
      expect((r.page.node('a')! as BoxRecord).bounds, moved);
    });

    test('mine moved, theirs did not: mine', () {
      final r = merge(base, base.replaceNode(a.withBounds(moved)), base);
      expect((r.page.node('a')! as BoxRecord).bounds, moved);
    });

    test('both moved: mine', () {
      final r = merge(
        base,
        base.replaceNode(a.withBounds(moved)),
        base.replaceNode(a.withBounds(other)),
      );
      expect((r.page.node('a')! as BoxRecord).bounds, moved);
      expect(r.conflictedIds, isEmpty);
    });

    test('content from theirs, geometry from mine', () {
      final r = merge(
        base,
        base.replaceNode(a.withBounds(moved)),
        base.replaceNode(edit(a, 'their')),
      );
      final n = r.page.node('a')! as BoxRecord;
      expect(n.bounds, moved);
      expect(dataOf(n), 'their');
    });

    test('fixedHeight follows the same rule', () {
      final r = merge(base, base, base.replaceNode(a.withFixedHeight(true)));
      expect((r.page.node('a')! as BoxRecord).fixedHeight, isTrue);
      final r2 = merge(
        base,
        base.replaceNode(a.withFixedHeight(true)),
        base.replaceNode(a.withBounds(moved)),
      );
      final n = r2.page.node('a')! as BoxRecord;
      expect(n.fixedHeight, isTrue);
      expect(n.bounds, moved);
    });
  });

  group('added and removed', () {
    final c = box('c', 'test.plain', 'new');

    test('added in theirs: added after the node that precedes it', () {
      final theirs = base.insertNode(c, 1); // a, c, b
      final r = merge(base, base, theirs);
      expect(r.page.nodes.map((n) => n.id), ['a', 'c', 'b']);
    });

    test('added in mine: kept', () {
      final r = merge(base, base.insertNode(c), base);
      expect(r.page.nodes.map((n) => n.id), ['a', 'b', 'c']);
    });

    test('removed in theirs, unchanged in mine: removed', () {
      final r = merge(base, base, base.removeNode('a'));
      expect(r.page.nodes.map((n) => n.id), ['b']);
    });

    test('removed in mine, unchanged in theirs: stays removed', () {
      final r = merge(base, base.removeNode('a'), base);
      expect(r.page.nodes.map((n) => n.id), ['b']);
    });

    test('removed in theirs, edited in mine: kept and flagged deleted', () {
      final mine = base.replaceNode(edit(a, 'mine'));
      final r = merge(base, mine, base.removeNode('a'), time: 77);
      final n = r.page.node('a')! as BoxRecord;
      expect(dataOf(n), 'mine');
      expect(n.conflicts.single.deleted, isTrue);
      expect(n.conflicts.single.at, 77);
      expect(r.conflictedIds, {'a'});
    });

    test('removed in mine, edited in theirs: brought back flagged', () {
      final theirs = base.replaceNode(edit(a, 'their'));
      final r = merge(base, base.removeNode('a'), theirs);
      final n = r.page.node('a')! as BoxRecord;
      expect(dataOf(n), 'their');
      expect(n.conflicts.single.deleted, isTrue);
      expect(r.page.nodes.first.id, 'a');
      expect(r.conflictedIds, {'a'});
    });

    test('removed on both sides: gone', () {
      final r = merge(base, base.removeNode('a'), base.removeNode('a'));
      expect(r.page.nodes.map((n) => n.id), ['b']);
    });
  });

  group('page header', () {
    test('per field: theirs when mine is unchanged, else mine', () {
      final mine = base.withMeta(base.meta.withTitle('Mine'));
      final theirs = base.withMeta(base.meta.withTitle('Theirs').withOrder(5));
      final r = merge(base, mine, theirs);
      expect(r.page.meta.title, 'Mine');
      expect(r.page.meta.order, 5);
    });

    test('a parent change from theirs is taken', () {
      final theirs = base.withMeta(base.meta.withParent('q'));
      final r = merge(base, base, theirs);
      expect(r.page.meta.parentId, 'q');
    });
  });

  group('foreign nodes', () {
    final f = ForeignNode.read(
      const RawJson.trusted('{"id":"f","type":"text","x":0,"y":0,"width":9,"height":9,"text":"a"}'),
      fallbackId: '#0',
    );
    final f2 = ForeignNode.read(
      const RawJson.trusted('{"id":"f","type":"text","x":0,"y":0,"width":9,"height":9,"text":"b"}'),
      fallbackId: '#0',
    );
    final f3 = ForeignNode.read(
      const RawJson.trusted('{"id":"f","type":"text","x":0,"y":0,"width":9,"height":9,"text":"c"}'),
      fallbackId: '#0',
    );

    test('one side changed: that side wins', () {
      final b0 = pageOf([f]);
      expect(merge(b0, b0, pageOf([f2])).page.node('f')!.toRaw(), f2.toRaw());
      expect(merge(b0, pageOf([f2]), b0).page.node('f')!.toRaw(), f2.toRaw());
    });

    test('both changed: mine kept, theirs kept as a copy', () {
      final b0 = pageOf([f]);
      final r = merge(b0, pageOf([f2]), pageOf([f3]));
      expect(r.page.nodes, hasLength(2));
      expect(r.page.node('f')!.toRaw(), f2.toRaw());
      expect(r.page.nodes.last.toRaw().text, contains('"c"'));
      expect(r.page.nodes.last.id, isNot('f'));
    });
  });

  group('conflict field', () {
    test('adding and removing it leaves other fields byte-identical', () {
      final orig = box('z', 'test.plain', 'x');
      final withC = orig.withConflict(
        BoxConflict.other(node: const RawJson.trusted('{"id":"z"}'), at: 5),
      );
      expect(withC.isConflicted, isTrue);
      expect(withC.conflicts.single.at, 5);
      expect(withC.withoutConflicts().toRaw(), orig.toRaw());
      expect(withC.data, orig.data);
      expect(withC.rev, orig.rev);
      final read = readPage(writePage(pageOf([withC]))).node('z')! as BoxRecord;
      expect(read.conflicts, withC.conflicts);
      expect(read.toRaw(), withC.toRaw());
    });

    test('an unknown noted field and odd spacing pass through untouched', () {
      const raw =
          '{"id":"k","type":"text","x":1,"y":2,"width":3,"height":4,"text":"s",'
          '"noted":{"type":"x.new","v":9,"rev":"r","conflicts": [ {"deleted":true,"at":3} ],"future":{"a": 1}}}';
      final page = readPage(
        '{"nodes":[$raw],"edges":[],"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
      );
      final k = page.node('k')! as BoxRecord;
      expect(k.conflicts.single.deleted, isTrue);
      expect(writePage(page), contains(raw));
      final r = merge(page, page, page);
      expect(writePage(r.page), writePage(page));
    });

    test('a conflict recorded by theirs is taken when mine is unchanged', () {
      final flagged = a.withConflict(BoxConflict.deleted(at: 9));
      final r = merge(base, base, base.replaceNode(flagged));
      expect((r.page.node('a')! as BoxRecord).conflicts.single.at, 9);
    });
  });
}
