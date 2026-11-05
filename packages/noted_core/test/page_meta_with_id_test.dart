// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('withId changes only the page id', () {
    final meta = PageMeta.create(id: 'p1', parentId: 'q', title: 'T', order: 3);
    final copy = meta.withId('p2');
    expect(copy.id, 'p2');
    expect(copy.parentId, 'q');
    expect(copy.title, 'T');
    expect(copy.order, 3);
    expect(copy.fields.string('pageId'), 'p2');
    // The original is untouched.
    expect(meta.id, 'p1');
  });
}
