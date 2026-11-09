// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// recordLostEdits and settledInFile: a landed recovery page that another
// writer overwrote right after landing becomes a version conflict (0130).

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();

  @override
  String get typeId => 'test.plain';
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
  MergeResult<String> merge(String base, String mine, String theirs) => const Conflicted();
}

const _plain = _Codec();

BoxRecord box(String id, String data, {Bounds? at, String type = 'test.plain'}) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: at ?? const Bounds(0, 0, 100, 50),
  data: RawJson.encode(data),
  snapshotText: 'snap:$data',
  rev: 'r-$id',
);

BoxRecord edit(BoxRecord b, String data) => commitBox(b, _plain, data);

NotedPage pageOf(List<CanvasNode> nodes, {String title = 'T'}) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: title, order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

BoxRecord boxOf(NotedPage p, String id) => p.node(id)! as BoxRecord;
List<String> ids(NotedPage p) => [for (final n in p.nodes) n.id];
String text(NotedPage p) => writePage(p);

NotedPage fix(NotedPage base, NotedPage mine, NotedPage landed, NotedPage now, {bool structure = true}) =>
    recordLostEdits(base, mine, landed, now, at: 500, structure: structure).page;

void main() {
  final a = box('a', 'one');
  final b = box('b', 'two');
  final c = box('c', 'three');
  final base = pageOf([a, b, c]);
  final a1 = edit(a, 'mine');
  final mineA = pageOf([a1, b, c]);

  group('recordLostEdits: boxes', () {
    test('content put back as it was is recorded, the other version displayed', () {
      final r = fix(base, mineA, mineA, base);
      final x = boxOf(r, 'a');
      expect(x.rev, a.rev);
      expect(x.conflicts, hasLength(1));
      expect(x.conflicts.single.node!.text, a1.toRaw().text);
      expect(x.conflicts.single.at, 500);
    });

    test('a version not derived from it is recorded', () {
      final a2 = edit(a, 'theirs');
      final r = fix(base, mineA, mineA, pageOf([a2, b, c]));
      expect(boxOf(r, 'a').rev, a2.rev);
      expect(boxOf(r, 'a').conflicts.single.node!.text, a1.toRaw().text);
    });

    test('the same version or one derived from it records nothing', () {
      expect(identical(fix(base, mineA, mineA, mineA), mineA), isTrue);
      final more = pageOf([edit(a1, 'more'), b, c]);
      expect(identical(fix(base, mineA, mineA, more), more), isTrue);
    });

    test('an edit of another box, or of the box already conflicted, changes nothing', () {
      final other = pageOf([a1, edit(b, 'x'), c]);
      expect(identical(fix(base, mineA, mineA, other), other), isTrue);
    });

    test('a box only the other writer changed (content put back is not mine) is left', () {
      // Mine changed only a's position; the other writer's content stays, no record.
      final moved = pageOf([a.withBounds(const Bounds(5, 5, 100, 50)), b, c]);
      final a2 = edit(a, 'theirs');
      final r = fix(base, moved, moved, pageOf([a2, b, c]));
      expect(boxOf(r, 'a').conflicts, isEmpty);
      expect(boxOf(r, 'a').rev, a2.rev);
      expect(boxOf(r, 'a').bounds, const Bounds(5, 5, 100, 50));
    });

    test('a box the other writer deleted comes back flagged deleted after its predecessor', () {
      final r = fix(base, mineA, mineA, pageOf([b, c]));
      expect(ids(r), ['a', 'b', 'c']);
      final x = boxOf(r, 'a');
      expect(x.rev, a1.rev);
      expect(x.conflicts.single.deleted, isTrue);
      expect(x.conflicts.single.at, 500);

      final r2 = fix(base, mineA, mineA, pageOf([a1, c]));
      expect(ids(r2), ['a', 'c']);
      final mineB = pageOf([a, edit(b, 'x'), c]);
      final r3 = fix(base, mineB, mineB, pageOf([a, c]));
      expect(ids(r3), ['a', 'b', 'c']);
    });

    test('a flag it already carries is not added twice', () {
      final flagged = a1.withConflict(BoxConflict.deleted(at: 9));
      final landed = pageOf([flagged, b, c]);
      final mine = pageOf([flagged, b, c]);
      final r = fix(base, mine, landed, pageOf([b, c]));
      expect(boxOf(r, 'a').conflicts, hasLength(1));
      expect(boxOf(r, 'a').conflicts.single.at, 9);
    });

    test('a box mine deleted that is back is flagged deleted, once', () {
      final mine = pageOf([a, c]);
      final r = fix(base, mine, mine, base);
      expect(boxOf(r, 'b').conflicts.single.deleted, isTrue);
      expect(identical(fix(base, mine, mine, r), r), isTrue);
      // Gone in both: nothing to do.
      expect(identical(fix(base, mine, mine, mine), mine), isTrue);
    });

    test('idempotent on its own output', () {
      final a2 = edit(a, 'theirs');
      for (final now in [
        base,
        pageOf([a2, b, c]),
        pageOf([b, c]),
      ]) {
        final r1 = fix(base, mineA, mineA, now);
        final r2 = fix(base, mineA, mineA, r1);
        expect(text(r2), text(r1));
        expect(identical(r2, r1), isTrue);
      }
    });

    test('recorded versions are combined without nesting, and x never records itself', () {
      final other = edit(a, 'other');
      final cIn = BoxConflict.other(node: other.toRaw(), at: 3);
      final m = a1.withConflict(cIn);
      final mine = pageOf([m, b, c]);
      final x = edit(a, 'theirs');
      final r = fix(base, mine, mine, pageOf([x, b, c]));
      final got = boxOf(r, 'a').conflicts;
      expect(got, hasLength(2));
      expect(got[0].node!.text, a1.toRaw().text); // the version, no conflicts of its own
      expect(got[1].node!.text, other.toRaw().text);
      expect(got[0].node!.text.contains('"conflicts"'), isFalse);
      // x is a version recorded in what landed: it stays displayed, not recorded again.
      final xr = pageOf([other, b, c]);
      final r2 = fix(base, mine, mine, xr);
      expect(boxOf(r2, 'a').conflicts.map((k) => k.node!.text), [a1.toRaw().text]);
    });

    test('a version recorded in what landed is combined even when x is derived from it', () {
      final other = edit(a, 'other');
      final m = a1.withConflict(BoxConflict.other(node: other.toRaw(), at: 3));
      final mine = pageOf([m, b, c]);
      final x = edit(a1, 'further');
      final r = fix(base, mine, mine, pageOf([x, b, c]));
      expect(boxOf(r, 'a').conflicts.single.node!.text, other.toRaw().text);
    });

    test('version records go before a deleted record', () {
      final m = a1.withConflict(BoxConflict.deleted(at: 4));
      final mine = pageOf([m, b, c]);
      final r = fix(base, mine, mine, pageOf([edit(a, 'theirs'), b, c]));
      final got = boxOf(r, 'a').conflicts;
      expect(got, hasLength(2));
      expect(got.first.deleted, isFalse);
      expect(got.last.deleted, isTrue);
    });

    test('a version recorded after an existing deleted record still goes before it', () {
      final x = edit(a, 'theirs').withConflict(BoxConflict.deleted(at: 4));
      final r = fix(base, mineA, mineA, pageOf([x, b, c]));
      final got = boxOf(r, 'a').conflicts;
      expect(got, hasLength(2));
      expect(got.first.deleted, isFalse);
      expect(got.last.deleted, isTrue);
    });

    test('revision guards: a box without revs is compared by content', () {
      BoxRecord strip(BoxRecord x) {
        final t = x.toRaw().text.replaceAll(RegExp(r'"rev":"[^"]*",?'), '');
        return BoxRecord.tryRead(RawObject.parse(t), RawJson.trusted(t))!;
      }

      final plain = pageOf([strip(a), b, c]);
      final mine = pageOf([strip(a1), b, c]);
      expect(boxOf(mine, 'a').rev, isNull);
      // The same content: nothing recorded. Different content: recorded.
      expect(identical(fix(plain, mine, mine, mine), mine), isTrue);
      final r = fix(plain, mine, mine, plain);
      expect(boxOf(r, 'a').conflicts, hasLength(1));
    });

    test('unknown box types pass byte for byte, undecoded', () {
      final u = box('u', 'raw', type: 'future.thing');
      final u1 = u.withContent(data: RawJson.encode('mine'), dataVersion: 1, snapshotText: 's', newRev: 'r2');
      final b0 = pageOf([u, b]);
      final mine = pageOf([u1, b]);
      final r = fix(b0, mine, mine, b0);
      final x = boxOf(r, 'u');
      expect(x.toRaw().text.contains('"conflicts"'), isTrue);
      expect(x.conflicts.single.node!.text, u1.toRaw().text);
      expect(boxOf(r, 'b').toRaw().text, b.toRaw().text);
      expect(x.data!.text, u.data!.text);
    });
  });

  group('recordLostEdits: position, order and header', () {
    test('mine\'s bounds and fixed height are put back, with no conflict', () {
      final moved = b.withBounds(const Bounds(40, 40, 120, 80)).withFixedHeight(true);
      final mine = pageOf([a, moved, c]);
      final r = fix(base, mine, mine, base);
      expect(boxOf(r, 'b').bounds, const Bounds(40, 40, 120, 80));
      expect(boxOf(r, 'b').fixedHeight, isTrue);
      expect(boxOf(r, 'b').conflicts, isEmpty);
      expect(identical(fix(base, mine, mine, r), r), isTrue);
    });

    test('a geometry change mine did not make is the other writer\'s', () {
      final now = pageOf([a, b.withBounds(const Bounds(9, 9, 100, 50)), c]);
      expect(boxOf(fix(base, mineA, mineA, now), 'b').bounds, const Bounds(9, 9, 100, 50));
    });

    test('a geometry put back goes on a flagged or conflicted box too', () {
      final m = a1.withBounds(const Bounds(7, 7, 100, 50));
      final mine = pageOf([m, b, c]);
      final x = edit(a, 'theirs');
      final r = fix(base, mine, mine, pageOf([x, b, c]));
      expect(boxOf(r, 'a').bounds, const Bounds(7, 7, 100, 50));
      expect(boxOf(r, 'a').conflicts, hasLength(1));
    });

    test('an order mine changed is put back; not when only the other writer reordered', () {
      final mine = pageOf([c, a, b]);
      final r = fix(base, mine, mine, base);
      expect(ids(r), ['c', 'a', 'b']);
      expect(identical(fix(base, mine, mine, r), r), isTrue);
      // Mine didn't reorder: the order now is the other writer's.
      final now = pageOf([b, a1, c]);
      expect(identical(fix(base, mineA, mineA, now), now), isTrue);
    });

    test('order is put back after a deleted box is put back', () {
      final mine = pageOf([c, a1, b]);
      final r = fix(base, mine, mine, pageOf([b, c]));
      expect(ids(r), ['c', 'a', 'b']);
    });

    test('a title and a top-level field mine changed are put back', () {
      final mine = pageOf([a, b, c], title: 'Mine');
      final r = fix(base, mine, mine, base);
      expect(r.meta.title, 'Mine');
      expect(identical(fix(base, mine, mine, r), r), isTrue);
      // The other writer's title is kept when mine didn't change it.
      final now = pageOf([a, b, c], title: 'Theirs');
      expect(fix(base, mineA, mineA, now).meta.title, 'Theirs');
    });

    test('structure: false leaves positions, order and header', () {
      final moved = b.withBounds(const Bounds(40, 40, 120, 80));
      final mine = pageOf([c, a, moved], title: 'Mine');
      final r = fix(NotedPage.create(base.meta), mine, mine, base, structure: false);
      expect(ids(r), ['a', 'b', 'c']);
      expect(boxOf(r, 'b').bounds, b.bounds);
      expect(r.meta.title, 'T');
    });
  });

  group('recordLostEdits: foreign nodes', () {
    ForeignNode foreign(String id, String extra) => ForeignNode.read(
      RawJson.trusted('{"id":"$id","type":"group","x":0,"y":0,"width":10,"height":10,"label":"$extra"}'),
      fallbackId: id,
    );
    final f = foreign('f', 'one');
    final f1 = foreign('f', 'mine');
    final fbase = pageOf([a, f]);
    final fmine = pageOf([a, f1]);

    test('gone: back, no flag', () {
      final r = fix(fbase, fmine, fmine, pageOf([a]));
      expect(r.node('f')!.toRaw().text, f1.toRaw().text);
      expect(ids(r), ['a', 'f']);
    });

    test('a foreign node that differs is kept beside it once', () {
      final f2 = foreign('f', 'theirs');
      final now = pageOf([a, f2]);
      final r = fix(fbase, fmine, fmine, now);
      expect(r.nodes, hasLength(3));
      expect(r.nodes[1].toRaw().text, f2.toRaw().text);
      expect(r.nodes[2].toRaw().text.contains('mine'), isTrue);
      expect(r.nodes[2].id, isNot('f'));
      final again = fix(fbase, fmine, fmine, r);
      expect(again.nodes, hasLength(3));
    });

    test('a box at its id records the foreign node once', () {
      final x = box('f', 'box');
      final r = fix(fbase, fmine, fmine, pageOf([a, x]));
      expect(boxOf(r, 'f').conflicts.single.node!.text, f1.toRaw().text);
      expect(identical(fix(fbase, fmine, fmine, r), r), isTrue);
    });

    test('mine\'s box where a foreign node now stands is kept beside it once', () {
      final fb = box('f', 'x');
      final base2 = pageOf([a, fb]);
      final mine2 = pageOf([a, edit(fb, 'y')]);
      final r = fix(base2, mine2, mine2, fbase);
      expect(r.nodes, hasLength(3));
      expect(fix(base2, mine2, mine2, r).nodes, hasLength(3));
    });

    test('a foreign node mine deleted that is back stays, and is reported', () {
      final mine = pageOf([a]);
      final res = recordLostEdits(fbase, mine, mine, fbase, at: 5);
      expect(res.foreignBack, isTrue);
      expect(identical(res.page, fbase), isTrue);
    });
  });

  group('settledInFile', () {
    test('an entry holding A with an alternative C over a file holding B with A recorded keeps C', () {
      final cAlt = edit(a, 'alt');
      final mineBox = a1.withConflict(BoxConflict.other(node: cAlt.toRaw(), at: 1));
      final mine = pageOf([mineBox, b, c]);
      final bx = edit(a, 'theirs').withConflict(BoxConflict.other(node: a1.toRaw(), at: 2));
      final theirs = pageOf([bx, b, c]);
      final out = settledInFile(base, mine, theirs);
      final x = boxOf(out, 'a');
      expect(x.rev, bx.rev);
      expect(x.conflicts.map((k) => k.node!.text), [a1.toRaw().text, cAlt.toRaw().text]);
      expect(x.conflicts.every((k) => !k.node!.text.contains('"conflicts"')), isTrue);
    });

    test('mine displayed with theirs recorded matches too', () {
      final t = edit(a, 'theirs');
      final shown = a1.withConflict(BoxConflict.other(node: t.toRaw(), at: 2));
      final theirs = pageOf([shown, b, c]);
      final out = settledInFile(base, mineA, theirs);
      expect(boxOf(out, 'a').toRaw().text, shown.toRaw().text);
    });

    test('a repeat replay over a conflicted file leaves it byte for byte', () {
      final t = edit(a, 'theirs');
      final shown = t.withConflict(BoxConflict.other(node: a1.toRaw(), at: 2));
      final theirs = pageOf([shown, b, c]);
      final merged = mergePage(
        base,
        settledInFile(base, mineA, theirs),
        theirs,
        CodecRegistry()..register(_plain),
        theirsTime: 9,
        markLanded: false,
      );
      expect(text(merged.page), text(theirs));
    });

    test('a record the base already held stays settled', () {
      final t = edit(a, 'theirs');
      final held = a.withConflict(BoxConflict.other(node: t.toRaw(), at: 2));
      final baseHeld = pageOf([held, b, c]);
      // The user settled offline: mine has the box with the record gone.
      final mine = pageOf([edit(a, 'settled'), b, c]);
      final theirs = pageOf([held, b, c]);
      expect(identical(settledInFile(baseHeld, mine, theirs), mine), isTrue);
    });

    test('a move in mine survives a match', () {
      final moved = a1.withBounds(const Bounds(30, 30, 100, 50));
      final mine = pageOf([moved, b, c]);
      final bx = edit(a, 'theirs').withConflict(BoxConflict.other(node: a1.toRaw(), at: 2));
      final out = settledInFile(base, mine, pageOf([bx, b, c]));
      expect(boxOf(out, 'a').bounds, const Bounds(30, 30, 100, 50));
    });

    test('a learned deleted flag on an unrelated version keeps A recorded', () {
      final bx = edit(a, 'theirs').withConflict(BoxConflict.deleted(at: 3));
      final theirs = pageOf([bx, b, c]);
      expect(identical(settledInFile(base, mineA, theirs), mineA), isTrue);
      final merged = mergePage(
        base,
        mineA,
        theirs,
        CodecRegistry()..register(_plain),
        theirsTime: 9,
        markLanded: false,
      );
      // The ordinary merge ran: mine's A is kept (displayed), theirs recorded.
      expect(boxOf(merged.page, 'a').rev, a1.rev);
      expect(boxOf(merged.page, 'a').conflicts.any((k) => !k.deleted), isTrue);
    });

    test('a learned deleted flag on mine\'s own version matches', () {
      final shown = a1.withConflict(BoxConflict.deleted(at: 3));
      final theirs = pageOf([shown, b, c]);
      expect(boxOf(settledInFile(base, mineA, theirs), 'a').toRaw().text, shown.toRaw().text);
    });

    test('a box mine removed that theirs holds flagged deleted is put back after its predecessor', () {
      final mine = pageOf([a, c]);
      final flagged = b.withConflict(BoxConflict.deleted(at: 3));
      final theirs = pageOf([a, flagged, c]);
      final out = settledInFile(base, mine, theirs);
      expect(ids(out), ['a', 'b', 'c']);
      // Not when the base already held the flag.
      final baseFlag = pageOf([a, flagged, c]);
      expect(identical(settledInFile(baseFlag, mine, theirs), mine), isTrue);
    });

    test('nothing learned: mine itself', () {
      expect(identical(settledInFile(base, mineA, base), mineA), isTrue);
    });

    test('a foreign node kept beside its place is not kept twice', () {
      ForeignNode foreign(String id, String extra) => ForeignNode.read(
        RawJson.trusted('{"id":"$id","type":"group","x":0,"y":0,"width":10,"height":10,"label":"$extra"}'),
        fallbackId: id,
      );
      final f = foreign('f', 'one');
      final f1 = foreign('f', 'mine');
      final f2 = foreign('f', 'theirs');
      final fbase = pageOf([a, f]);
      final fmine = pageOf([a, f1]);
      final landed = fix(fbase, fmine, fmine, pageOf([a, f2]));
      final out = settledInFile(fbase, fmine, landed);
      final merged = mergePage(
        fbase,
        out,
        landed,
        CodecRegistry()..register(_plain),
        theirsTime: 9,
        markLanded: false,
      );
      expect(merged.page.nodes, hasLength(3));
    });
  });
}
