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
    mergeConflictCopy(original, copy, registry(), copyTime: 777);

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
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
    });

    test('rejects a result that dropped a non-object node', () {
      final original = pageOf([raw('1', '#node0')]);
      final copy = pageOf([raw('2', '#node0')]);
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
    });

    String obj(String id, String text) =>
        '{"id":"$id","type":"text","x":0,"y":0,"width":5,"height":5,"text":"$text"}';

    test('accepts a foreign copy node recorded in the conflicts of a box with its id', () {
      final original = pageOf([box('b', 'mine')]);
      final copy = pageOf([raw(a.replaceFirst('"f"', '"b"'), 'b')]);
      final m = merge(original, copy).page;
      expect((m.node('b')! as BoxRecord).conflicts, hasLength(1));
      expect(verifyConflictCopyMerge(readPage(writePage(m)), original, copy), isNull);
      // Without the record it is lost.
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
    });

    test('matches nodes one to one', () {
      final x = raw(obj('x', 'one'), 'x');
      final g = raw(obj('g', 'one'), 'g');
      expect(verifyConflictCopyMerge(pageOf([x]), pageOf([x]), pageOf([g])), isNotNull);
      final one = raw('1', '#node0');
      final two = raw('1', '#node1');
      final both = pageOf([one, two]);
      expect(verifyConflictCopyMerge(pageOf([one]), both, both), isNotNull);
      expect(verifyConflictCopyMerge(both, both, both), isNull);
    });

    test('the original foreign node must be there with its own id', () {
      final original = pageOf([raw(a, 'f')]);
      final moved = pageOf([raw(obj('z', 'A'), 'z')]);
      expect(verifyConflictCopyMerge(moved, original, pageOf([])), isNotNull);
    });

    test('checks a box the copy has against a foreign node of the original', () {
      final original = pageOf([raw(obj('b', 'A'), 'b')]);
      final copy = pageOf([box('b', 'theirs')]);
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
      final m = merge(original, copy).page;
      expect(verifyConflictCopyMerge(readPage(writePage(m)), original, copy), isNull);
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
        expect(verifyConflictCopyMerge(next, cur, copy), isNull, reason: 'round $i');
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
        expect(verifyConflictCopyMerge(next, cur, copy), isNull, reason: 'round $i');
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
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
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
      expect(verifyConflictCopyMerge(disk, pageOf([]), copy), isNull);
    });

    test('accepts the merge, including a copy moved to a new id', () {
      final original = pageOf([raw(a, 'f'), raw('1', '#node1')]);
      final copy = pageOf([raw(b, 'f'), raw('2', '#node1')]);
      final m = merge(original, copy).page;
      expect(verifyConflictCopyMerge(readPage(writePage(m)), original, copy), isNull);
    });
  });

  group('verifyConflictCopyMerge', () {
    test('accepts what the merge wrote', () {
      final original = base.replaceNode(edit(a, 'mine')).insertNode(box('x', 'x'));
      final copy = base.replaceNode(edit(a, 'theirs')).insertNode(box('y', 'y'));
      final m = merge(original, copy).page;
      expect(verifyConflictCopyMerge(readPage(writePage(m)), original, copy), isNull);
    });

    test('accepts the newer side taken', () {
      final copy = base.replaceNode(edit(a, 'newer'));
      final m = merge(base, copy).page;
      expect(verifyConflictCopyMerge(m, base, copy), isNull);
    });

    test('rejects a missing node', () {
      final copy = base.insertNode(box('y', 'y'));
      expect(verifyConflictCopyMerge(base, base, copy), contains('y'));
    });

    test('rejects a lost version', () {
      final original = base.replaceNode(edit(a, 'mine'));
      final copy = base.replaceNode(edit(a, 'theirs'));
      // The original kept, but the copy's version not recorded.
      expect(verifyConflictCopyMerge(original, original, copy), isNotNull);
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
}
