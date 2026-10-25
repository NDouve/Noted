// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord box(String id, {double x = 0}) => BoxRecord.create(
  id: id,
  typeId: 't',
  dataVersion: 1,
  bounds: Bounds(x, 0, 10, 10),
  data: RawJson.nullValue,
  snapshotText: '',
  rev: 'r',
);

final codecs = CodecRegistry();

void main() {
  final empty = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));

  test('undo and redo an add, a move and a remove', () {
    final h = PageHistory();
    var page = empty.insertNode(box('a'));
    h.record(const PageChange.added('a'));

    final a = page.node('a')! as BoxRecord;
    page = page.replaceNode(a.withBounds(const Bounds(50, 0, 10, 10)));
    h.record(PageChange.bounds('a', a.bounds));

    page = page.insertNode(box('b'));
    h.record(const PageChange.added('b'));
    final bIndex = page.indexOf('b');
    page = page.removeNode('b');
    h.record(PageChange.removed(box('b'), bIndex));

    page = h.undo(page, codecs)!; // remove b undone
    expect(page.node('b'), isNotNull);
    page = h.undo(page, codecs)!; // add b undone
    expect(page.node('b'), isNull);
    page = h.undo(page, codecs)!; // move undone
    expect(page.node('a')!.bounds!.x, 0);
    page = h.redo(page, codecs)!;
    expect(page.node('a')!.bounds!.x, 50);
    page = h.undo(page, codecs)!;
    page = h.undo(page, codecs)!; // add a undone
    expect(page.nodes, isEmpty);
    expect(h.undo(page, codecs), isNull);
    page = h.redo(page, codecs)!;
    expect(page.node('a'), isNotNull);
  });

  test('changes that no longer apply are skipped', () {
    final h = PageHistory();
    var page = empty.insertNode(box('a'));
    h.record(const PageChange.added('a'));
    h.record(const PageChange.bounds('gone', Bounds.zero));
    page = h.undo(page, codecs)!;
    expect(page.nodes, isEmpty);
  });

  test('forgetAdded drops a discarded empty box', () {
    final h = PageHistory()..record(const PageChange.added('a'));
    h.forgetAdded('a');
    expect(h.canUndo, isFalse);
  });

  test('forgetAdded works when a later box was added first', () {
    final h = PageHistory()
      ..record(const PageChange.added('a'))
      ..record(const PageChange.bounds('a', Bounds.zero))
      ..record(const PageChange.added('b'));
    h.forgetAdded('a');
    var page = empty.insertNode(box('b'));
    page = h.undo(page, codecs)!;
    expect(page.nodes, isEmpty);
    expect(h.canUndo, isFalse);
  });

  test('undoing a height resize restores auto height too', () {
    final h = PageHistory();
    final a = box('a');
    var page = empty.insertNode(a.withBounds(const Bounds(0, 0, 10, 50)).withFixedHeight(true));
    h.record(PageChange.bounds('a', a.bounds));
    page = h.undo(page, codecs)!;
    final undone = page.node('a')! as BoxRecord;
    expect(undone.bounds.height, 10);
    expect(undone.fixedHeight, isFalse);
    page = h.redo(page, codecs)!;
    expect((page.node('a')! as BoxRecord).fixedHeight, isTrue);
  });

  test('content changes are replayed as diffs through the codec', () {
    const codec = _SetCodec();
    final registry = CodecRegistry()..register(codec);
    final h = PageHistory();
    // The box had [a]; an edit added b and grew the box.
    final before = BoxRecord.create(
      id: 's',
      typeId: 'test.set',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.encode(['a']),
      snapshotText: 'a',
      rev: 'r0',
    );
    final after = commitBox(before, codec, ['a', 'b']).withBounds(const Bounds(0, 0, 20, 10));
    var page = empty.insertNode(after);
    h.record(PageChange.content('s', const _SetEdit(remove: ['b']), boundsBefore: before.bounds));

    page = h.undo(page, registry)!;
    var box = page.node('s')! as BoxRecord;
    expect(box.data!.decode(), ['a']);
    expect(box.bounds.width, 10);
    expect(box.rev, isNot(after.rev));

    page = h.redo(page, registry)!;
    box = page.node('s')! as BoxRecord;
    expect(box.data!.decode(), ['a', 'b']);
    expect(box.bounds.width, 20);

    // Without the box's codec the change can't apply and is skipped.
    expect(h.undo(page, CodecRegistry()), isNull);
  });
}

/// Data is a sorted list of strings; edits add or remove items.
class _SetCodec extends BoxCodec<List<String>> {
  const _SetCodec();
  @override
  String get typeId => 'test.set';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  List<String> create() => const [];
  @override
  List<String> decode(Object? json, int storedVersion) => (json! as List).cast<String>();
  @override
  Object? encode(List<String> data) => data;
  @override
  String snapshotText(List<String> data) => data.join(',');
  @override
  AiExposure aiExposure(List<String> data) => const AiHidden();
}

class _SetEdit implements BoxEdit {
  const _SetEdit({this.add = const [], this.remove = const []});
  final List<String> add;
  final List<String> remove;
  @override
  (Object?, BoxEdit) apply(Object? data) {
    final items = (data! as List<String>).where((e) => !remove.contains(e)).toList()
      ..addAll(add)
      ..sort();
    return (items, _SetEdit(add: remove, remove: add));
  }
}
