// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  test('a page with a landed box counts as having issues (the page list mark)', () {
    final box = BoxRecord.create(
      id: 'a',
      typeId: 't',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.nullValue,
      snapshotText: '',
      rev: 'r',
    );
    final page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    expect(hasConflicts(page.insertNode(box)), isFalse);
    expect(hasConflicts(page.insertNode(box.withLanded(BoxLanded(at: 1)))), isTrue);
  });

  test('undoing a landed change restores only the marker, not later content', () {
    final landed = BoxLanded(at: 5, device: 'Laptop');
    final box = BoxRecord.create(
      id: 'a',
      typeId: 't',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.nullValue,
      snapshotText: 'old',
      rev: 'r',
    ).withLanded(landed);
    final h = PageHistory();
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(box);
    // The box is placed (marker cleared), then its content changes.
    h.record(PageChange.landed('a', landed));
    page = page.replaceNode(box.withoutLanded());
    final b = page.node('a')! as BoxRecord;
    page = page.replaceNode(
      b.withContent(data: RawJson.nullValue, dataVersion: 1, snapshotText: 'typed', newRev: 'r2'),
    );
    page = h.undo(page, CodecRegistry())!;
    final back = page.node('a')! as BoxRecord;
    expect(back.landed, landed);
    expect(back.snapshotText, 'typed');
    page = h.redo(page, CodecRegistry())!;
    expect((page.node('a')! as BoxRecord).landed, isNull);
    expect((page.node('a')! as BoxRecord).snapshotText, 'typed');
  });
}
