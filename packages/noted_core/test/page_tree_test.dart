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

  test('withParent and withPlacement change only their header values', () {
    final meta = PageMeta.tryRead(
      RawObject.parse(
        '{"format":1,"pageId":"p","parentId":null,"title":"T","order":3,'
        '"extra":1.50,"later":{"a":[1,2]}}',
      ),
    )!;
    final moved = meta.withParent('q');
    expect(moved.parentId, 'q');
    expect(
      moved.fields.toRaw().text,
      '{"format":1,"pageId":"p","parentId":"q","title":"T","order":3,'
      '"extra":1.50,"later":{"a":[1,2]}}',
    );
    final back = moved.withPlacement(parentId: null, order: 0);
    expect(back.parentId, isNull);
    expect(
      back.fields.toRaw().text,
      '{"format":1,"pageId":"p","parentId":null,"title":"T","order":0,'
      '"extra":1.50,"later":{"a":[1,2]}}',
    );
  });

  test('parentIdOf, siblingsOf and wouldCycle', () {
    final tree = PageTree.build([
      meta('a', order: 0),
      meta('b', order: 1),
      meta('a1', parent: 'a'),
      meta('a1x', parent: 'a1'),
      meta('lost', parent: 'gone', order: 2),
    ]);
    expect(tree.parentIdOf('a'), isNull);
    expect(tree.parentIdOf('a1x'), 'a1');
    expect(tree.parentIdOf('lost'), isNull);
    expect(tree.siblingsOf('b').map((p) => p.id), ['a', 'b', 'lost']);
    expect(tree.siblingsOf('a1x').map((p) => p.id), ['a1x']);
    expect(tree.wouldCycle('a', 'a'), isTrue);
    expect(tree.wouldCycle('a', 'a1x'), isTrue);
    expect(tree.wouldCycle('a1', 'a'), isFalse);
    expect(tree.wouldCycle('a', 'b'), isFalse);
    expect(tree.wouldCycle('a', null), isFalse);
  });
}
