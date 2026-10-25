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
