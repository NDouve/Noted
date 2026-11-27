// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

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

CodecRegistry registry() => CodecRegistry()..register(_plain);

BoxRecord box(String id, String data, {Bounds? at}) => BoxRecord.create(
  id: id,
  typeId: 'test.plain',
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

String dataOf(CanvasNode? n) => (n as BoxRecord).data!.decode()! as String;

PageMerge merge(NotedPage original, NotedPage copy) =>
    mergeConflictCopy(original, copy, registry(), copyTime: 777, topOfChain: false);

String? verifyMerge(NotedPage onDisk, NotedPage original, NotedPage copy, {bool forRecovery = false}) =>
    verifyConflictCopyMerge(onDisk, original, copy, topOfChain: false, forRecovery: forRecovery);

List<String> o2(String n) => conflictCopyOriginalNames(n);

void main() {
  final a = box('a', 'one');
  final b = box('b', 'two');
  final base = pageOf([a, b]);

  group('conflictCopyOriginalNames', () {
    test('OneDrive style names', () {
      expect(
        conflictCopyOriginalNames('3f2a9c0d1e4b5a67-DESKTOP-4QK2N8L.canvas'),
        ['3f2a9c0d1e4b5a67.canvas', '3f2a9c0d1e4b5a67-DESKTOP.canvas'],
      );
      expect(
        conflictCopyOriginalNames('abc-LAPTOP-ABC-1.canvas'),
        containsAllInOrder(['abc.canvas', 'abc-LAPTOP.canvas', 'abc-LAPTOP-ABC.canvas']),
      );
      expect(conflictCopyOriginalNames('abc-MyPC.canvas'), ['abc.canvas']);
      expect(conflictCopyOriginalNames('abc-12345.canvas'), ['abc.canvas']);
    });

    test('provider names', () {
      List<String> o(String n) => conflictCopyOriginalNames(n);
      expect(o('abc (1).canvas'), ['abc.canvas']); // Drive for desktop
      expect(o('abc 2.canvas'), ['abc.canvas']); // Finder-style
      expect(o('abc (conflicted copy 2018-04-10 093612).canvas'), ['abc.canvas']);
      expect(o('abc (conflicted copy user 2018-04-10 093612).canvas'), ['abc.canvas']);
      expect(o('abc_conflict-20180410-093612.canvas'), contains('abc.canvas'));
      expect(o('abc (conflicted copy 2018-04-10).canvas'), isEmpty);
      expect(o('abc (x).canvas'), isEmpty);
    });

    test('every combination of suffixes is a candidate, shortest first', () {
      expect(o2('abc-HOST (1).canvas'), ['abc.canvas', 'abc-HOST.canvas']);
      expect(o2('abc 2 (1).canvas'), ['abc.canvas', 'abc 2.canvas']);
      expect(o2('abc (1) (2).canvas'), ['abc.canvas', 'abc (1).canvas']);
      expect(o2('abc-PC (conflicted copy 2018-04-10 093612).canvas'), ['abc.canvas', 'abc-PC.canvas']);
    });

    test('the table is exported and a stem is not a candidate of itself', () {
      expect(conflictCopyOriginalStems('abc 2'), ['abc']);
      expect(conflictCopyOriginalStems('abc'), isEmpty);
      expect(conflictCopyOriginalStems(' 2'), isEmpty);
    });

    test('names without the shape', () {
      expect(conflictCopyOriginalNames('abc.canvas'), isEmpty);
      expect(conflictCopyOriginalNames('abc-.canvas'), isEmpty);
      expect(conflictCopyOriginalNames('-abc.canvas'), isEmpty);
      expect(conflictCopyOriginalNames('abc-PC.json'), isEmpty);
    });
  });

  test('identical pages: the original, verbatim', () {
    final r = merge(base, base);
    expect(r.conflictedIds, isEmpty);
    expect(writePage(r.page), writePage(base));
  });

  test('the copy edited a box further: the copy is taken', () {
    final copy = base.replaceNode(edit(a, 'newer'));
    final r = merge(base, copy);
    expect(dataOf(r.page.node('a')), 'newer');
    expect(r.page.node('a')!.toRaw(), copy.node('a')!.toRaw());
    expect(r.conflictedIds, isEmpty);
    expect(dataOf(r.page.node('b')), 'two');
  });

  test('the original is newer: it is kept', () {
    final original = base.replaceNode(edit(a, 'newer'));
    final r = merge(original, base);
    expect(dataOf(r.page.node('a')), 'newer');
    expect(r.conflictedIds, isEmpty);
    expect(writePage(r.page), writePage(original));
  });

  test('both edited the same box: original kept, the copy recorded', () {
    final original = base.replaceNode(edit(a, 'mine'));
    final copy = base.replaceNode(edit(a, 'theirs'));
    final r = merge(original, copy);
    expect(r.conflictedIds, {'a'});
    final m = r.page.node('a')! as BoxRecord;
    expect(dataOf(m), 'mine');
    expect(m.conflicts.single.node, copy.node('a')!.toRaw());
    expect(m.conflicts.single.at, 777);
    expect(dataOf(r.page.node('b')), 'two'); // untouched
  });

  test('boxes only one side has are kept', () {
    final original = base.insertNode(box('x', 'only here'));
    final copy = base.insertNode(box('y', 'only there'));
    final r = merge(original, copy);
    expect(r.page.nodes.map((n) => n.id).toSet(), {'a', 'b', 'x', 'y'});
    expect(r.conflictedIds, isEmpty);
  });

  test('a box only the copy has is placed after its predecessor', () {
    final copy = base.insertNode(box('y', 'new'));
    final order = copy.nodes.map((n) => n.id).toList();
    final r = merge(base, copy);
    expect(r.page.nodes.map((n) => n.id).toList(), order);
  });

  test('the header and top-level fields are the original', () {
    final original = pageOf([a], title: 'Original title');
    final copy = pageOf([a], title: 'Copy title');
    final r = merge(original, copy);
    expect(r.page.meta.title, 'Original title');
  });

  test('recorded conflicts on both sides are combined', () {
    final c1 = BoxConflict.deleted(at: 1);
    final c2 = BoxConflict.deleted(at: 2);
    final original = base.replaceNode(a.withConflict(c1));
    final copy = base.replaceNode(a.withConflict(c2));
    final r = merge(original, copy);
    expect((r.page.node('a')! as BoxRecord).conflicts, [c1, c2]);
  });

  test('a differing foreign node is kept with the copy beside it', () {
    final f1 = ForeignNode.read(
      const RawJson.trusted('{"id":"f","type":"text","x":0,"y":0,"width":5,"height":5,"text":"A"}'),
      fallbackId: 'f',
    );
    final f2 = ForeignNode.read(
      const RawJson.trusted('{"id":"f","type":"text","x":0,"y":0,"width":5,"height":5,"text":"B"}'),
      fallbackId: 'f',
    );
    final r = merge(pageOf([f1]), pageOf([f2]));
    expect(r.page.nodes, hasLength(2));
    expect(r.page.nodes.first.toRaw(), f1.toRaw());
    expect((r.page.nodes.last as ForeignNode).text, 'B');
  });

  ForeignNode raw(String text, String id) =>
      ForeignNode.read(RawJson.trusted(text), fallbackId: id);

  test('differing non-object nodes at the same position are both kept', () {
    final one = raw('1', '#node0');
    final two = raw('2', '#node0');
    final r = merge(pageOf([one]), pageOf([two]));
    expect(r.page.nodes.map((n) => n.toRaw().text), ['1', '2']);
  });

  group('verifyConflictCopyMerge foreign content', () {
    const a = '{"id":"f","type":"text","x":0,"y":0,"width":5,"height":5,"text":"A"}';
    const b = '{"id":"f","type":"text","x":0,"y":0,"width":5,"height":5,"text":"B"}';

    test('rejects a result that dropped a same-id foreign node with other content', () {
      final original = pageOf([raw(a, 'f')]);
      final copy = pageOf([raw(b, 'f')]);
      expect(verifyMerge(original, original, copy), isNotNull);
    });

    test('rejects a result that dropped a non-object node', () {
      final original = pageOf([raw('1', '#node0')]);
      final copy = pageOf([raw('2', '#node0')]);
      expect(verifyMerge(original, original, copy), isNotNull);
    });

    String obj(String id, String text) =>
        '{"id":"$id","type":"text","x":0,"y":0,"width":5,"height":5,"text":"$text"}';

    test('accepts a foreign copy node recorded in the conflicts of a box with its id', () {
      final original = pageOf([box('b', 'mine')]);
      final copy = pageOf([raw(a.replaceFirst('"f"', '"b"'), 'b')]);
      final m = merge(original, copy).page;
      expect((m.node('b')! as BoxRecord).conflicts, hasLength(1));
      expect(verifyMerge(readPage(writePage(m)), original, copy), isNull);
      // Without the record it is lost.
      expect(verifyMerge(original, original, copy), isNotNull);
    });

    test('matches nodes one to one', () {
      final x = raw(obj('x', 'one'), 'x');
      final g = raw(obj('g', 'one'), 'g');
      expect(verifyMerge(pageOf([x]), pageOf([x]), pageOf([g])), isNotNull);
      final one = raw('1', '#node0');
      final two = raw('1', '#node1');
      final both = pageOf([one, two]);
      expect(verifyMerge(pageOf([one]), both, both), isNotNull);
      expect(verifyMerge(both, both, both), isNull);
    });

    test('the original foreign node must be there with its own id', () {
      final original = pageOf([raw(a, 'f')]);
      final moved = pageOf([raw(obj('z', 'A'), 'z')]);
      expect(verifyMerge(moved, original, pageOf([])), isNotNull);
    });

    test('checks a box the copy has against a foreign node of the original', () {
      final original = pageOf([raw(obj('b', 'A'), 'b')]);
      final copy = pageOf([box('b', 'theirs')]);
      expect(verifyMerge(original, original, copy), isNotNull);
      final m = merge(original, copy).page;
      expect(verifyMerge(readPage(writePage(m)), original, copy), isNull);
    });

    String boxText(String data, String rev) =>
        '{"id":"b","x":0,"y":0,"width":50,"height":50,"text":"snap:$data",'
        '"noted":{"type":"test.plain","v":1,"rev":"$rev","data":"$data"}}';
    NotedPage fileOf(List<String> nodes) => readPage(
      '{"nodes":[${nodes.join(',')}],'
      '"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
    );

    test('a repeated box id: the merge is accepted and a retry adds nothing', () {
      final original = fileOf([boxText('one', 'r1'), boxText('two', 'r2')]);
      final copy = fileOf([boxText('one', 'r1'), boxText('three', 'r3')]);
      var cur = original;
      var count = -1;
      for (var i = 0; i < 3; i++) {
        final next = readPage(writePage(merge(cur, copy).page));
        expect(verifyMerge(next, cur, copy), isNull, reason: 'round $i');
        if (i > 0) expect(next.nodes.length, count, reason: 'round $i grew');
        count = next.nodes.length;
        cur = next;
      }
      expect(count, 3);
    });

    // Merges [copy] into [original] up to three times as a retry would; returns
    // the page after the first merge and checks the later ones add nothing.
    NotedPage mergeRetried(NotedPage original, NotedPage copy) {
      var cur = original;
      NotedPage? first;
      for (var i = 0; i < 3; i++) {
        final next = readPage(writePage(merge(cur, copy).page));
        expect(verifyMerge(next, cur, copy), isNull, reason: 'round $i');
        first ??= next;
        expect(next.nodes.length, first.nodes.length, reason: 'round $i changed the count');
        cur = next;
      }
      return first!;
    }

    test('equal content under another id does not account for a different node', () {
      final original = pageOf([raw(obj('x', 'A'), 'x'), raw(obj('y', 'B'), 'y')]);
      final copy = pageOf([raw(obj('x', 'B'), 'x'), raw(obj('y', 'B'), 'y')]);
      final m = mergeRetried(original, copy);
      expect(m.nodes, hasLength(3));
      expect(m.nodes.map((n) => n.toRaw().text).join(), contains('"text":"B"'));
      expect(m.nodes.where((n) => n.toRaw().text.contains('"text":"B"')), hasLength(2));
      // A page holding only the original's two nodes lost the copy's x.
      expect(verifyMerge(original, original, copy), isNotNull);
    });

    test('equal non-object nodes in the copy are all kept', () {
      final r1 = mergeRetried(pageOf([raw('1', '#node0')]), pageOf([raw('1', '#node0'), raw('1', '#node1')]));
      expect(r1.nodes.map((n) => n.toRaw().text), ['1', '1']);
      final a = raw(obj('a', 'A'), 'a');
      final r2 = mergeRetried(pageOf([a]), readPage(
        '{"nodes":[${obj('a', 'A')},${obj('a', 'A')},${obj('a', 'A')}],'
        '"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
      ));
      expect(r2.nodes, hasLength(3));
    });

    test('a copy-only node with a made-up id gets a real new id', () {
      final original = pageOf([raw(obj('g', 'A'), 'g')]);
      final copy = fileOf([obj('g', 'B'), obj('g', 'C')]);
      final m = merge(original, copy).page;
      final withG = m.nodes.where((n) => n.toRaw().text.contains('"id":"g"'));
      expect(withG, hasLength(1));
      expect(m.nodes, hasLength(3));
      final back = readPage(writePage(m));
      expect(back.node('g')!.toRaw(), original.node('g')!.toRaw());
    });

    test('boxes are matched by revision before content', () {
      String text(String id, String? rev) =>
          '{"id":"$id","x":0,"y":0,"width":50,"height":50,"text":"snap:k",'
          '"noted":{"type":"test.plain","v":1,${rev == null ? '' : '"rev":"$rev",'}"data":"k"}}';
      final copy = fileOf([text('b', null), text('a', 'ra')]);
      final disk = fileOf([text('a', 'ra'), text('b', null)]);
      expect(verifyMerge(disk, pageOf([]), copy), isNull);
    });

    test('accepts the merge, including a copy moved to a new id', () {
      final original = pageOf([raw(a, 'f'), raw('1', '#node1')]);
      final copy = pageOf([raw(b, 'f'), raw('2', '#node1')]);
      final m = merge(original, copy).page;
      expect(verifyMerge(readPage(writePage(m)), original, copy), isNull);
    });
  });

  group('verifyConflictCopyMerge', () {
    test('accepts what the merge wrote', () {
      final original = base.replaceNode(edit(a, 'mine')).insertNode(box('x', 'x'));
      final copy = base.replaceNode(edit(a, 'theirs')).insertNode(box('y', 'y'));
      final m = merge(original, copy).page;
      expect(verifyMerge(readPage(writePage(m)), original, copy), isNull);
    });

    test('accepts the newer side taken', () {
      final copy = base.replaceNode(edit(a, 'newer'));
      final m = merge(base, copy).page;
      expect(verifyMerge(m, base, copy), isNull);
    });

    test('rejects a missing node', () {
      final copy = base.insertNode(box('y', 'y'));
      expect(verifyMerge(base, base, copy), contains('y'));
    });

    test('rejects a lost version', () {
      final original = base.replaceNode(edit(a, 'mine'));
      final copy = base.replaceNode(edit(a, 'theirs'));
      // The original kept, but the copy's version not recorded.
      expect(verifyMerge(original, original, copy), isNotNull);
    });
  });

  group('recovery mode (forRecovery)', () {
    PageMerge recover(NotedPage original, NotedPage copy) =>
        mergeConflictCopy(original, copy, registry(), copyTime: 777, topOfChain: false, forRecovery: true);

    test('a box only the copy has, overlapping, gets no landed marker; the default does', () {
      final original = pageOf([box('a', 'one')]);
      final copy = pageOf([box('y', 'why')]); // same bounds as a
      expect((merge(original, copy).page.node('y')! as BoxRecord).landed, isNotNull);
      final r = recover(original, copy).page;
      expect((r.node('y')! as BoxRecord).landed, isNull);
      expect(verifyMerge(readPage(writePage(r)), original, copy, forRecovery: true), isNull);
    });

    test('a landed marker already on either side is kept', () {
      final marked = box('a', 'one').withLanded(BoxLanded(at: 5));
      final original = pageOf([box('a', 'one')]);
      final copy = pageOf([marked]);
      expect((recover(original, copy).page.node('a')! as BoxRecord).landed, isNotNull);
      expect((recover(copy, original).page.node('a')! as BoxRecord).landed, isNotNull);
    });

    test('a recorded version has no conflicts of its own, and a repeat does not nest', () {
      final x = base.replaceNode(edit(a, 'mine'));
      final y = base.replaceNode(edit(a, 'theirs'));
      final theirs = (y.node('a')! as BoxRecord).withConflict(BoxConflict.other(node: RawJson.encode('old'), at: 1));
      final copy = y.replaceNode(theirs);
      var cur = x;
      for (var i = 0; i < 3; i++) {
        final next = readPage(writePage(recover(cur, copy).page));
        expect(verifyMerge(next, cur, copy, forRecovery: true), isNull, reason: 'round $i');
        cur = next;
      }
      final m = cur.node('a')! as BoxRecord;
      expect(dataOf(m), 'mine');
      // The recorded version and the copy's own recorded one, once each.
      expect(m.conflicts, hasLength(2));
      expect(m.conflicts.where((k) => k.node == (y.node('a')! as BoxRecord).toRaw()), hasLength(1));
    });

    test('a file box without a rev and the same content is accepted', () {
      String text(String data, {String? rev}) =>
          '{"id":"b","x":0,"y":0,"width":50,"height":50,"text":"snap:$data",'
          '"noted":{"type":"test.plain","v":1,${rev == null ? '' : '"rev":"$rev",'}"data":"$data"}}';
      NotedPage file(String n) => readPage(
        '{"nodes":[$n],"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
      );
      final original = file(text('same'));
      final copy = file(text('same', rev: 'r9'));
      final m = readPage(writePage(merge(original, copy).page));
      expect(verifyMerge(m, original, copy), isNull);
      expect(verifyMerge(original, original, copy), isNull);
    });

    test('a foreign node recorded on a box is recorded once over repeats', () {
      const f = '{"id":"b","type":"text","x":0,"y":0,"width":5,"height":5,"text":"A"}';
      var cur = pageOf([box('b', 'mine')]);
      final copy = pageOf([raw(f, 'b')]);
      for (var i = 0; i < 3; i++) {
        cur = readPage(writePage(merge(cur, copy).page));
      }
      expect((cur.node('b')! as BoxRecord).conflicts, hasLength(1));
    });
  });

  group('PageStore.scan', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('noted_copy'));
    tearDown(() async => dir.delete(recursive: true));

    Future<void> put(String name, NotedPage page) =>
        File('${dir.path}${Platform.pathSeparator}$name').writeAsString(writePage(page));

    NotedPage withId(String id) =>
        NotedPage.create(PageMeta.create(id: id, title: id, order: 0));

    test('a conflict copy is reported as such, not as a duplicate', () async {
      await put('3f2a.canvas', withId('3f2a'));
      await put('3f2a-DESKTOP-4QK2N8L.canvas', withId('3f2a'));
      await put('3f2a-LAPTOP-ABC-1.canvas', withId('3f2a'));
      final entries = await PageStore(dir).scan();
      expect(entries.whereType<ReadablePage>(), hasLength(1));
      expect(entries.whereType<UnreadablePage>(), isEmpty);
      final copies = entries.whereType<ConflictCopyPage>().toList();
      expect(copies, hasLength(2));
      for (final c in copies) {
        expect(c.originalPath, endsWith('3f2a.canvas'));
      }
    });

    test('a hyphenated file with another page id is not a copy', () async {
      await put('3f2a.canvas', withId('3f2a'));
      await put('3f2a-other.canvas', withId('zzzz'));
      await put('dup-PC.canvas', withId('3f2a')); // no dup.canvas
      final entries = await PageStore(dir).scan();
      expect(entries.whereType<ConflictCopyPage>(), isEmpty);
      expect(entries.whereType<ReadablePage>(), hasLength(2));
      expect(entries.whereType<UnreadablePage>().single.reason, contains('duplicate'));
    });

    test('findConflictOriginal', () async {
      await put('3f2a.canvas', withId('3f2a'));
      await put('3f2a-PC.canvas', withId('3f2a'));
      await put('3f2a-OTHER.canvas', withId('zzzz'));
      final sep = Platform.pathSeparator;
      expect(
        await PageStore.findConflictOriginal('${dir.path}${sep}3f2a-PC.canvas', withId('3f2a')),
        '${dir.path}${sep}3f2a.canvas',
      );
      expect(
        await PageStore.findConflictOriginal('${dir.path}${sep}3f2a-OTHER.canvas', withId('zzzz')),
        isNull,
      );
    });
  });

  group('same-id AI access: the stricter', () {
    // The own values of the matrix: null is absent, 'x' an unknown value.
    const values = <String?>[null, 'open', 'privileged', 'guarded', 'x'];
    // How strict each is, below the top of a chain (absent inherits) and at
    // the top (absent is the default, Guarded).
    int rank(String? v, bool top) => switch (v) {
      null => top ? 2 : -1,
      'open' => 0,
      'privileged' => 1,
      _ => 2,
    };
    NotedPage withAi(List<CanvasNode> nodes, String? v) {
      final p = pageOf(nodes);
      if (v == null) return p;
      return p.withMeta(PageMeta.tryRead(p.meta.fields.set(aiAccessKey, RawJson.encode(v)))!);
    }

    for (final top in [false, true]) {
      for (final o in values) {
        for (final c in values) {
          test('original $o, copy $c, top of chain $top', () {
            final original = withAi([a], o);
            final copy = withAi([a, b], c);
            final want = rank(c, top) > rank(o, top) ? c : o;
            final merged = mergeConflictCopy(original, copy, registry(), copyTime: 1, topOfChain: top).page;
            expect(merged.meta.rawAiAccess, want == null ? isNull : RawJson.encode(want));
            final back = readPage(writePage(merged));
            expect(verifyConflictCopyMerge(back, original, copy, topOfChain: top), isNull);
            final recovered = mergeConflictCopy(
              original,
              copy,
              registry(),
              copyTime: 1,
              topOfChain: top,
              forRecovery: true,
            ).page;
            expect(recovered.meta.rawAiAccess, merged.meta.rawAiAccess);
          });
        }
      }
    }

    test('a tie keeps the original raw value ("guarded" against an unknown one)', () {
      final merged = mergeConflictCopy(withAi([a], 'guarded'), withAi([a], 'x'), registry(), copyTime: 1, topOfChain: false);
      expect(merged.page.meta.rawAiAccess, RawJson.encode('guarded'));
    });

    test('the rest of the header stays the original\'s', () {
      final original = withAi([a], 'open');
      final copy = withAi([a], 'guarded').withMeta(
        PageMeta.tryRead(withAi([a], 'guarded').meta.fields.set('title', RawJson.encode('Other')))!,
      );
      final merged = mergeConflictCopy(original, copy, registry(), copyTime: 1, topOfChain: true).page;
      expect(merged.meta.title, original.meta.title);
      expect(merged.meta.aiAccess, AiAccess.guarded);
    });

    test('verifyConflictCopyMerge rejects a disk header looser than either side', () {
      final original = withAi([a], 'open');
      final copy = withAi([a], 'privileged');
      expect(verifyConflictCopyMerge(withAi([a], 'open'), original, copy, topOfChain: false), isNotNull);
      expect(verifyConflictCopyMerge(withAi([a], 'privileged'), original, copy, topOfChain: false), isNull);
      // At the top, absent is Guarded: a disk without the field is strict enough.
      expect(verifyConflictCopyMerge(withAi([a], null), original, copy, topOfChain: true), isNull);
      expect(verifyConflictCopyMerge(withAi([a], null), original, copy, topOfChain: false), isNotNull);
    });
  });

  group('consumedCopyHeld', () {
    final v1 = edit(a, 'v1');
    final conflicted = a.withConflict(BoxConflict.other(node: v1.toRaw(), at: 3));

    test('the merged file holds the copy', () {
      final copy = pageOf([a, b]);
      final disk = readPage(writePage(merge(pageOf([a]), copy).page));
      expect(consumedCopyHeld(disk, copy, topOfChain: false), isNull);
    });

    test('the pre-merge file put back does not', () {
      expect(consumedCopyHeld(pageOf([a]), pageOf([a, b]), topOfChain: false), contains('b'));
    });

    test('a box edited from the copy\'s version, or recording it, is held', () {
      final copy = pageOf([a]);
      expect(consumedCopyHeld(pageOf([edit(a, 'later')]), copy, topOfChain: false), isNull);
      // Another device's version, not edited from the copy's.
      final other = BoxRecord.create(
        id: 'a',
        typeId: 'test.plain',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 100, 50),
        data: RawJson.encode('other'),
        snapshotText: 'snap:other',
        rev: 'r-other',
      );
      final recording = other.withConflict(BoxConflict.other(node: a.toRaw(), at: 1));
      expect(consumedCopyHeld(pageOf([recording]), copy, topOfChain: false), isNull);
      expect(consumedCopyHeld(pageOf([other]), copy, topOfChain: false), isNotNull);
    });

    test('equal revs without the copy\'s recorded conflict fail, with it pass', () {
      final copy = pageOf([conflicted]);
      expect(conflicted.rev, a.rev);
      expect(consumedCopyHeld(pageOf([a]), copy, topOfChain: false), contains('recorded'));
      expect(consumedCopyHeld(pageOf([conflicted]), copy, topOfChain: false), isNull);
    });

    test('equal revs without the copy\'s landed marker fail, with any marker pass', () {
      final landed = a.withLanded(BoxLanded(at: 5));
      final copy = pageOf([landed]);
      expect(consumedCopyHeld(pageOf([a]), copy, topOfChain: false), contains('landed'));
      expect(consumedCopyHeld(pageOf([a.withLanded(BoxLanded(at: 9))]), copy, topOfChain: false), isNull);
    });

    test('a box that took a new id is found by revision', () {
      final copy = pageOf([b]);
      expect(consumedCopyHeld(pageOf([b.withId('n')]), copy, topOfChain: false), isNull);
    });

    test('disk nodes are claimed one to one', () {
      final twin = box('t', 'two').withId('t');
      // Two copy-only boxes with the same rev under other ids: one disk box
      // can't stand for both.
      final c1 = BoxRecord.create(
        id: 'c1',
        typeId: 'test.plain',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 10, 10),
        data: RawJson.encode('same'),
        snapshotText: 'snap:same',
        rev: 'r-same',
      );
      final c2 = c1.withId('c2');
      final copy = pageOf([c1, c2]);
      expect(consumedCopyHeld(pageOf([twin, c1.withId('n1')]), copy, topOfChain: false), isNotNull);
      expect(consumedCopyHeld(pageOf([c1.withId('n1'), c1.withId('n2')]), copy, topOfChain: false), isNull);
    });

    test('touched boxes and a touched header are not checked', () {
      expect(consumedCopyHeld(pageOf([a]), pageOf([a, b]), touched: {'b'}, topOfChain: false), isNull);
      final strict = pageOf([a]).withMeta(pageOf([a]).meta.withAiAccess(AiAccess.guarded));
      final loose = pageOf([a]).withMeta(pageOf([a]).meta.withAiAccess(AiAccess.open));
      expect(consumedCopyHeld(loose, strict, topOfChain: false), contains('AI access'));
      expect(consumedCopyHeld(loose, strict, headerTouched: true, topOfChain: false), isNull);
      expect(consumedCopyHeld(strict, loose, topOfChain: false), isNull);
    });

    test('a foreign node needs its equal on disk, or a record at its id', () {
      const f = '{"id":"f","type":"text","x":0,"y":0,"width":5,"height":5,"text":"A"}';
      final copy = pageOf([raw(f, 'f')]);
      expect(consumedCopyHeld(pageOf([raw(f, 'f')]), copy, topOfChain: false), isNull);
      expect(consumedCopyHeld(pageOf([]), copy, topOfChain: false), isNotNull);
    });
  });

  // A revision match is the same version only with the same content.
  group('same rev, other content', () {
    BoxRecord sameRev(BoxRecord b, String data) => BoxRecord.create(
      id: b.id,
      typeId: b.typeId,
      dataVersion: b.dataVersion,
      bounds: b.bounds,
      data: RawJson.encode(data),
      snapshotText: 'snap:$data',
      rev: b.rev!,
    );

    test('consumedCopyHeld, same id: other data is older, same data or other bounds hold', () {
      final copy = pageOf([a]);
      expect(consumedCopyHeld(pageOf([sameRev(a, 'changed')]), copy, topOfChain: false), contains('older'));
      expect(consumedCopyHeld(pageOf([sameRev(a, 'one')]), copy, topOfChain: false), isNull);
      expect(
        consumedCopyHeld(pageOf([a.withBounds(const Bounds(9, 9, 100, 50))]), copy, topOfChain: false),
        isNull,
      );
    });

    test('consumedCopyHeld, re-id\'d copy box: the box with its content is claimed', () {
      final copy = pageOf([b]);
      final wrong = sameRev(b, 'other').withId('n1');
      final right = b.withId('n2');
      expect(consumedCopyHeld(pageOf([wrong, right]), copy, topOfChain: false), isNull);
      expect(consumedCopyHeld(pageOf([wrong]), copy, topOfChain: false), contains('older'));
      expect(consumedCopyHeld(pageOf([wrong, sameRev(b, 'else').withId('n2')]), copy, topOfChain: false),
          isNotNull);
    });

    test('merge records the copy\'s form; verify and consumedCopyHeld pass', () {
      final original = pageOf([sameRev(a, 'mine')]);
      final copy = pageOf([sameRev(a, 'theirs')]);
      final m = merge(original, copy);
      expect(m.conflictedIds, {'a'});
      final x = m.page.node('a')! as BoxRecord;
      expect(dataOf(x), 'mine');
      expect(x.conflicts.single.node, copy.node('a')!.toRaw());
      final disk = readPage(writePage(m.page));
      expect(verifyMerge(disk, original, copy), isNull);
      expect(consumedCopyHeld(disk, copy, topOfChain: false), isNull);
      // Verify rejects the original put back without the record.
      expect(verifyMerge(original, original, copy), isNotNull);
    });

    test('same rev and same content records nothing', () {
      final original = pageOf([a]);
      final copy = pageOf([a.withBounds(const Bounds(3, 3, 100, 50))]);
      final m = merge(original, copy);
      expect(m.conflictedIds, isEmpty);
      expect((m.page.node('a')! as BoxRecord).conflicts, isEmpty);
    });

    test('re-id after a foreign-id collision: a box changed under its rev is added again', () {
      const f = '{"id":"x","type":"text","x":0,"y":0,"width":5,"height":5,"text":"A"}';
      final x = sameRev(box('x', 'v'), 'copy');
      final original = pageOf([raw(f, 'x')]);
      final copy = pageOf([x]);
      final first = merge(original, copy).page;
      final reidd = first.nodes.whereType<BoxRecord>().single;
      expect(reidd.id, isNot('x'));
      // The same copy again adds nothing.
      expect(merge(first, copy).page.nodes, hasLength(2));
      // The kept box was changed under its rev: the copy's box is added again.
      final changed = first.replaceNode(sameRev(reidd, 'changed'));
      final again = merge(changed, copy).page;
      expect(again.nodes, hasLength(3));
      final disk = readPage(writePage(again));
      expect(consumedCopyHeld(disk, copy, topOfChain: false), isNull);
    });

    test('an unsupported type is compared byte for byte', () {
      BoxRecord u(String data) => BoxRecord.create(
        id: 'u',
        typeId: 'x.unregistered',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 10, 10),
        data: RawJson.trusted(data),
        snapshotText: 's',
        rev: 'r-u',
      );
      expect(sameBoxVersion(u('{"k":1}'), u('{"k":2}')), isFalse);
      expect(sameBoxVersion(u('{"k":1}'), u('{"k": 1}')), isFalse);
      expect(sameBoxVersion(u('{"k":1}'), u('{"k":1}')), isTrue);
    });
  });
}
