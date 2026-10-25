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

void main() {
  final empty = Page.create(PageMeta.create(id: 'p', title: '', order: 0));

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

    page = h.undo(page)!; // remove b undone
    expect(page.node('b'), isNotNull);
    page = h.undo(page)!; // add b undone
    expect(page.node('b'), isNull);
    page = h.undo(page)!; // move undone
    expect(page.node('a')!.bounds!.x, 0);
    page = h.redo(page)!;
    expect(page.node('a')!.bounds!.x, 50);
    page = h.undo(page)!;
    page = h.undo(page)!; // add a undone
    expect(page.nodes, isEmpty);
    expect(h.undo(page), isNull);
    page = h.redo(page)!;
    expect(page.node('a'), isNotNull);
  });

  test('changes that no longer apply are skipped', () {
    final h = PageHistory();
    var page = empty.insertNode(box('a'));
    h.record(const PageChange.added('a'));
    h.record(const PageChange.bounds('gone', Bounds.zero));
    page = h.undo(page)!;
    expect(page.nodes, isEmpty);
  });

  test('forgetAdded drops a discarded empty box', () {
    final h = PageHistory()..record(const PageChange.added('a'));
    h.forgetAdded('a');
    expect(h.canUndo, isFalse);
  });
}
