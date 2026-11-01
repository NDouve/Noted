// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  MergeResult<String> merge(String base, String mine, String theirs) =>
      const Conflicted();
}

const _plain = _Codec();

CodecRegistry registry() => CodecRegistry()..register(_plain);

BoxRecord box(
  String id,
  String data, {
  Bounds at = const Bounds(0, 0, 100, 50),
  String type = 'test.plain',
  String? device,
  int? time,
}) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: at,
  data: RawJson.encode(data),
  snapshotText: 'snap:$data',
  rev: 'r-$id',
  device: device,
  at: time,
);

NotedPage pageOf(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

NotedPage threeWay(NotedPage base, NotedPage mine, NotedPage theirs) =>
    mergePage(base, mine, theirs, registry(), theirsTime: 5000).page;

NotedPage viaFile(NotedPage p) => readPage(writePage(p));

BoxRecord boxOf(NotedPage p, String id) => p.node(id)! as BoxRecord;

void main() {
  final a = box('a', 'one');
  final far = const Bounds(500, 500, 100, 50);

  group('landed marking', () {
    test('three-way: an arriving box that overlaps is marked, with its device and time', () {
      final base = pageOf([a]);
      final arriving = box(
        'n',
        'new',
        at: const Bounds(50, 20, 100, 50),
        device: 'LAPTOP',
        time: 123,
      );
      final merged = threeWay(base, base, base.insertNode(arriving));
      expect(boxOf(merged, 'n').landed, BoxLanded(at: 123, device: 'LAPTOP'));
      expect(boxOf(merged, 'a').landed, isNull);
    });

    test(
      'three-way: no device or time on the box: the merge time, no device',
      () {
        final base = pageOf([a]);
        final theirs = base.insertNode(
          box('n', 'new', at: const Bounds(10, 10, 20, 20)),
        );
        final l = boxOf(threeWay(base, base, theirs), 'n').landed!;
        expect(l.at, 5000);
        expect(l.device, isNull);
      },
    );

    test('three-way: not marked when it does not overlap or only touches', () {
      final base = pageOf([a]);
      final theirs = base
          .insertNode(box('n', 'x', at: far))
          .insertNode(box('t', 'y', at: const Bounds(100, 0, 50, 50)));
      final merged = threeWay(base, base, theirs);
      expect(boxOf(merged, 'n').landed, isNull);
      expect(boxOf(merged, 't').landed, isNull);
      expect(writePage(merged), contains('"n"'));
      expect(writePage(merged), isNot(contains('landed')));
    });

    test('three-way: overlap with a box added here counts; boxes only mine removed do not', () {
      final base = pageOf([a]);
      final mine = base.insertNode(box('m', 'mine', at: far));
      final theirs = base.insertNode(
        box('n', 'new', at: const Bounds(520, 510, 10, 10)),
      );
      expect(boxOf(threeWay(base, mine, theirs), 'n').landed, isNotNull);
    });

    test('three-way: a box without bounds never counts', () {
      final foreign = ForeignNode.read(
        const RawJson.trusted('{"id":"f","type":"text","text":"hi"}'),
        fallbackId: 'f',
      );
      final base = pageOf([foreign]);
      final theirs = base.insertNode(box('n', 'new'));
      expect(boxOf(threeWay(base, base, theirs), 'n').landed, isNull);
    });

    test('three-way: an existing marker passes through', () {
      final base = pageOf([a]);
      final marked = box(
        'n',
        'new',
        at: far,
      ).withLanded(BoxLanded(at: 9, device: 'OLD'));
      final merged = threeWay(base, base, base.insertNode(marked));
      expect(boxOf(merged, 'n').landed, BoxLanded(at: 9, device: 'OLD'));
    });

    test('three-way: clearing the marker on the other side clears it here', () {
      final marked = box('n', 'new').withLanded(BoxLanded(at: 9));
      final base = pageOf([a, marked]);
      final theirs = base.replaceNode(marked.withoutLanded());
      expect(boxOf(threeWay(base, base, theirs), 'n').landed, isNull);
    });

    test('conflict copy: marked only on overlap', () {
      final original = pageOf([a]);
      final copy = original
          .insertNode(
            box(
              'n',
              'new',
              at: const Bounds(10, 10, 20, 20),
              device: 'PC',
              time: 77,
            ),
          )
          .insertNode(box('q', 'quiet', at: far));
      final merged = mergeConflictCopy(
        original,
        copy,
        registry(),
        copyTime: 999,
      ).page;
      expect(boxOf(merged, 'n').landed, BoxLanded(at: 77, device: 'PC'));
      expect(boxOf(merged, 'q').landed, isNull);
      expect(boxOf(merged, 'a').landed, isNull);
    });

    test('conflict copy: the copy time when the box has no time', () {
      final original = pageOf([a]);
      final copy = original.insertNode(
        box('n', 'new', at: const Bounds(10, 10, 20, 20)),
      );
      final merged = mergeConflictCopy(
        original,
        copy,
        registry(),
        copyTime: 999,
      ).page;
      expect(boxOf(merged, 'n').landed, BoxLanded(at: 999));
    });

    test('the marker survives save and load verbatim', () {
      final base = pageOf([a]);
      final theirs = base.insertNode(
        box(
          'n',
          'new',
          at: const Bounds(10, 10, 20, 20),
          device: 'PC',
          time: 1,
        ),
      );
      final merged = threeWay(base, base, theirs);
      final text = writePage(merged);
      expect(text, contains('"landed":{"at":1,"device":"PC"}'));
      final again = viaFile(merged);
      expect(boxOf(again, 'n').landed, BoxLanded(at: 1, device: 'PC'));
      expect(writePage(again), text);
    });

    test('withoutLanded removes only that field', () {
      final marked = box('n', 'new').withLanded(BoxLanded(at: 4, device: 'PC'));
      final cleared = marked.withoutLanded();
      expect(cleared.landed, isNull);
      expect(cleared.toRaw().text, box('n', 'new').toRaw().text);
      // A box with other fields around the marker keeps them in order.
      final withFlags = marked
          .withFixedHeight(true)
          .withConflict(BoxConflict.deleted(at: 3));
      final expected = box(
        'n',
        'new',
      ).withFixedHeight(true).withConflict(BoxConflict.deleted(at: 3));
      expect(withFlags.withoutLanded().toRaw().text, expected.toRaw().text);
      expect(identical(cleared.withoutLanded(), cleared), isTrue);
    });
  });

  group('pageIssues', () {
    bool all(BoxRecord _) => true;

    test('reading order, kinds, and unreadable', () {
      final conflicted = box(
        'c',
        'x',
        at: const Bounds(300, 0, 10, 10),
      ).withConflict(BoxConflict.other(node: box('c', 'y').toRaw(), at: 1));
      final deleted = box(
        'd',
        'x',
        at: const Bounds(0, 100, 10, 10),
      ).withConflict(BoxConflict.deleted(at: 2));
      final unreadable =
          box(
            'u',
            'x',
            type: 'x.unknown',
            at: const Bounds(0, 0, 10, 10),
          ).withConflict(
            BoxConflict.other(
              node: box('u', 'y', type: 'x.unknown').toRaw(),
              at: 1,
            ),
          );
      final landed = box(
        'l',
        'x',
        at: const Bounds(150, 0, 10, 10),
      ).withLanded(BoxLanded(at: 3));
      final tie = box(
        'a2',
        'x',
        at: const Bounds(150, 0, 10, 10),
      ).withLanded(BoxLanded(at: 3));
      final page = pageOf([deleted, conflicted, landed, unreadable, tie, a]);
      final issues = pageIssues(page, canOpen: (b) => b.typeId == 'test.plain');
      expect(
        [for (final i in issues) (i.boxId, i.kind)],
        [
          ('u', PageIssueKind.unreadableConflict),
          ('a2', PageIssueKind.landed),
          ('l', PageIssueKind.landed),
          ('c', PageIssueKind.conflict),
          ('d', PageIssueKind.deleteConflict),
        ],
      );
      expect(issues[0].conflict, isNotNull);
      expect(issues[1].landed, BoxLanded(at: 3));
    });

    test('a box with both: the conflict first, then landed', () {
      final both = box(
        'b',
        'x',
      ).withLanded(BoxLanded(at: 3)).withConflict(BoxConflict.deleted(at: 2));
      final issues = pageIssues(pageOf([both]), canOpen: all);
      expect(
        [for (final i in issues) i.kind],
        [PageIssueKind.deleteConflict, PageIssueKind.landed],
      );
    });

    test('no issues on a clean page', () {
      expect(pageIssues(pageOf([a]), canOpen: all), isEmpty);
    });
  });

  group('resolutions', () {
    final other = box(
      'a',
      'theirs',
      at: const Bounds(0, 0, 80, 40),
      device: 'PC',
      time: 8,
    );
    final conflict = BoxConflict.other(
      node: other.toRaw(),
      at: 8,
      device: 'PC',
    );
    final conflicted = a.withConflict(conflict);
    final page = pageOf([
      box('z', 'under'),
      conflicted,
      box('y', 'over', at: far),
    ]);

    test('keepMine drops the conflict and keeps the content', () {
      final r = keepMine(page, 'a');
      final m = boxOf(r, 'a');
      expect(m.isConflicted, isFalse);
      expect(m.toRaw().text, a.toRaw().text);
      expect(pageIssues(r, canOpen: (_) => true), isEmpty);
    });

    test('keepOther replaces the box verbatim, in place', () {
      final r = keepOther(page, 'a');
      expect(r.node('a')!.toRaw().text, other.toRaw().text);
      expect([for (final n in r.nodes) n.id], ['z', 'a', 'y']);
    });

    test('placeBoth adds the other version beside, with a fresh id', () {
      final r = placeBoth(page, 'a');
      expect(r.nodes.length, 4);
      expect(boxOf(r, 'a').isConflicted, isFalse);
      expect(boxOf(r, 'a').toRaw().text, a.toRaw().text);
      final added = r.nodes[2] as BoxRecord;
      expect(added.id, isNot('a'));
      expect(added.data!.text, other.data!.text);
      expect(added.rev, other.rev);
      expect(added.bounds, const Bounds(124, 0, 80, 40));
      expect(added.isConflicted, isFalse);
      expect(added.landed, isNull);
    });

    test('placeBoth goes below when beside would be too wide', () {
      final r = placeBoth(page, 'a', maxRight: 150);
      expect((r.nodes[2] as BoxRecord).bounds, const Bounds(0, 74, 80, 40));
    });

    test(
      'placeBoth clears the other version\'s own conflicts and landed marker',
      () {
        final messy = other
            .withLanded(BoxLanded(at: 1))
            .withConflict(BoxConflict.deleted(at: 1));
        final p = pageOf([
          a.withConflict(BoxConflict.other(node: messy.toRaw(), at: 8)),
        ]);
        final added = placeBoth(p, 'a').nodes[1] as BoxRecord;
        expect(added.isConflicted, isFalse);
        expect(added.landed, isNull);
      },
    );

    test('unreadable boxes: raw bytes kept, nothing decoded', () {
      final theirsU = box('u', 'theirs', type: 'x.unknown');
      final mineU = box(
        'u',
        'mine',
        type: 'x.unknown',
      ).withConflict(BoxConflict.other(node: theirsU.toRaw(), at: 2));
      final p = pageOf([mineU]);
      expect(
        boxOf(keepMine(p, 'u'), 'u').toRaw().text,
        box('u', 'mine', type: 'x.unknown').toRaw().text,
      );
      expect(keepOther(p, 'u').node('u')!.toRaw().text, theirsU.toRaw().text);
      final both = placeBoth(p, 'u');
      expect(both.nodes.length, 2);
      final added = both.nodes[1] as BoxRecord;
      expect(added.data!.text, theirsU.data!.text);
      expect(added.snapshotText, theirsU.snapshotText);
      expect(boxOf(both, 'u').data!.text, mineU.data!.text);
    });

    test('keeping a box after a delete conflict, and deleting it', () {
      final d = a.withConflict(BoxConflict.deleted(at: 2));
      final p = pageOf([d]);
      expect(boxOf(keepBox(p, 'a'), 'a').toRaw().text, a.toRaw().text);
      expect(deleteBox(p, 'a').nodes, isEmpty);
      expect(keepOther(p, 'a'), same(p));
      expect(placeBoth(p, 'a'), same(p));
    });

    test('acceptMerged commits through the codec as one new revision', () {
      final r = acceptMerged(page, 'a', _plain, 'merged', device: 'ME', at: 50);
      final m = boxOf(r, 'a');
      expect(m.data!.decode(), 'merged');
      expect(m.snapshotText, 'snap:merged');
      expect(m.rev, isNot(a.rev));
      expect(m.baseRev, a.rev);
      expect(m.isConflicted, isFalse);
    });

    test('only the resolved conflict goes; the next one shows', () {
      final second = BoxConflict.other(node: box('a', 'third').toRaw(), at: 9);
      final p = pageOf([conflicted.withConflict(second)]);
      final r = keepMine(p, 'a');
      expect(boxOf(r, 'a').conflicts, [second]);
      expect(boxOf(keepOther(p, 'a'), 'a').conflicts, [second]);
    });

    test('keepOther keeps a landed marker that was on this box', () {
      final p = pageOf([conflicted.withLanded(BoxLanded(at: 4))]);
      expect(boxOf(keepOther(p, 'a'), 'a').landed, BoxLanded(at: 4));
    });

    test('clearLanded', () {
      final p = pageOf([a.withLanded(BoxLanded(at: 4))]);
      expect(boxOf(clearLanded(p, 'a'), 'a').toRaw().text, a.toRaw().text);
    });
  });
}
