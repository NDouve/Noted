// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

PageMeta meta(String id, {String? parent, int order = 0, String? title}) =>
    PageMeta.create(id: id, parentId: parent, title: title ?? id, order: order);

void main() {
  test('builds roots and children sorted by order', () {
    final tree = PageTree.build([
      meta('b', order: 1),
      meta('a', order: 0),
      meta('a2', parent: 'a', order: 2),
      meta('a1', parent: 'a', order: 1),
      meta('a1x', parent: 'a1'),
    ]);
    expect(tree.roots.map((p) => p.id), ['a', 'b']);
    expect(tree.childrenOf('a').map((p) => p.id), ['a1', 'a2']);
    expect(tree.isDivider('a'), isTrue);
    expect(tree.isDivider('b'), isFalse);
    expect(tree.descendantsOf('a'), ['a1', 'a1x', 'a2']);
    expect(tree.nextOrder('a'), 3);
    expect(tree.nextOrder(null), 2);
  });

  test('pages with a missing parent or a parent loop go to the top level', () {
    final tree = PageTree.build([
      meta('orphan', parent: 'gone'),
      meta('x', parent: 'y'),
      meta('y', parent: 'x'),
    ]);
    expect(tree.roots.map((p) => p.id).toSet(), {'orphan', 'x', 'y'});
  });
}
