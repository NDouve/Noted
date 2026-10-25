// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  late Notebook nb;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_tree');
    nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
  });

  tearDown(() async {
    nb.dispose();
    await dir.delete(recursive: true);
  });

  Future<PageTree> reread() async {
    final entries = await PageStore(dir).scan();
    return PageTree.build(entries.whereType<ReadablePage>().map((e) => e.meta));
  }

  Future<List<String>> three() async {
    await nb.load();
    final a = nb.currentId!;
    final b = await nb.createPage();
    final c = await nb.createPage();
    return [a, b, c];
  }

  List<String> rootIds(PageTree t) => t.roots.map((p) => p.id).toList();
  List<String> kids(PageTree t, String id) => t.childrenOf(id).map((p) => p.id).toList();

  test('reorders siblings and writes the new order to disk', () async {
    final [a, b, c] = await three();
    expect(await nb.moveUp(c), isTrue);
    expect(rootIds(nb.tree), [a, c, b]);
    expect(await nb.moveDown(a), isTrue);
    expect(rootIds(nb.tree), [c, a, b]);
    expect(await nb.moveUp(c), isFalse);
    expect(await nb.moveDown(b), isFalse);
    await nb.flush();
    final disk = await reread();
    expect(rootIds(disk), [c, a, b]);
    expect([a, b, c].map((i) => disk[i]!.order), [1, 2, 0]);
  });

  test('moveRelative places a page before or after another', () async {
    final [a, b, c] = await three();
    await nb.moveRelative(c, a, after: false);
    expect(rootIds(nb.tree), [c, a, b]);
    await nb.moveRelative(c, b, after: true);
    expect(rootIds(nb.tree), [a, b, c]);
    await nb.flush();
    expect(rootIds(await reread()), [a, b, c]);
  });

  test('moves a page under another, with its subpages, and back out', () async {
    final [a, b, c] = await three();
    final b1 = await nb.createPage(parentId: b);
    expect(await nb.move(b, parentId: a), isTrue);
    expect(nb.tree.isDivider(a), isTrue);
    expect(nb.tree.parentIdOf(b), a);
    expect(kids(nb.tree, b), [b1]);
    expect(rootIds(nb.tree), [a, c]);
    await nb.flush();
    var disk = await reread();
    expect(disk[b]!.parentId, a);
    expect(disk[b1]!.parentId, b);
    expect(disk.descendantsOf(a), [b, b1]);

    expect(await nb.move(b, parentId: null, index: 0), isTrue);
    expect(rootIds(nb.tree), [b, a, c]);
    expect(nb.tree.isDivider(a), isFalse);
    await nb.flush();
    disk = await reread();
    expect(rootIds(disk), [b, a, c]);
    expect(disk[b]!.parentId, isNull);
    expect(kids(disk, b), [b1]);
  });

  test('indent and outdent', () async {
    final [a, b, c] = await three();
    expect(await nb.indent(a), isFalse);
    expect(await nb.outdent(a), isFalse);
    expect(await nb.indent(b), isTrue);
    expect(nb.tree.parentIdOf(b), a);
    expect(await nb.indent(c), isTrue);
    expect(kids(nb.tree, a), [b, c]);
    expect(await nb.indent(c), isTrue);
    expect(nb.tree.parentIdOf(c), b);
    expect(await nb.outdent(c), isTrue);
    expect(kids(nb.tree, a), [b, c]);
    expect(await nb.outdent(b), isTrue);
    expect(rootIds(nb.tree), [a, b]);
    await nb.flush();
    final disk = await reread();
    expect(rootIds(disk), [a, b]);
    expect(kids(disk, a), [c]);
  });

  test('refuses to move a page under itself or its descendants', () async {
    final [a, b, _] = await three();
    final a1 = await nb.createPage(parentId: a);
    final a2 = await nb.createPage(parentId: a1);
    expect(await nb.move(a, parentId: a), isFalse);
    expect(await nb.move(a, parentId: a1), isFalse);
    expect(await nb.move(a, parentId: a2), isFalse);
    expect(await nb.moveRelative(a, a2, after: true), isFalse);
    expect(nb.tree.parentIdOf(a), isNull);
    expect(nb.tree.parentIdOf(a1), a);
    expect(await nb.move(a1, parentId: b), isTrue);
    expect(kids(nb.tree, a1), [a2]);
    await nb.flush();
    expect((await reread())[a]!.parentId, isNull);
  });

  test('moving the open page goes through its controller and is autosaved', () async {
    final [a, b, _] = await three();
    await nb.open(b);
    final c = nb.current!;
    c.createBoxAt(const Bounds(10, 10, 0, 0));
    expect(await nb.move(b, parentId: a), isTrue);
    expect(nb.currentId, b);
    expect(nb.current!.page.meta.parentId, a);
    await nb.flush();
    final page = await PageStore(dir).load(b);
    expect(page.meta.parentId, a);
    expect(page.nodes.length, nb.current!.page.nodes.length);
  });

  test('delete then undo restores ids, content, parents and order', () async {
    final [a, b, c] = await three();
    final b1 = await nb.createPage(parentId: b);
    await nb.open(b1);
    final cc = nb.current!;
    final box = cc.createBoxAt(const Bounds(10, 10, 0, 0));
    cc.commit(
      box.id,
      cc.modules.codecs.codecFor(box.typeId)!.decode({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'precious'},
                ],
              },
            },
          ],
        },
      }, 1),
    );
    await nb.flush();
    final before = {
      for (final id in [b, b1]) id: await File('${dir.path}/$id.canvas').readAsString(),
    };

    final deleted = await nb.delete(b);
    expect(rootIds(nb.tree), [a, c]);
    expect(File('${dir.path}/$b.canvas').existsSync(), isFalse);
    expect(File('${dir.path}/$b1.canvas').existsSync(), isFalse);
    expect(nb.currentId, isNot(b1));

    await nb.undoDelete(deleted);
    expect(rootIds(nb.tree), [a, b, c]);
    expect(kids(nb.tree, b), [b1]);
    expect(nb.currentId, b1);
    for (final id in [b, b1]) {
      expect(await File('${dir.path}/$id.canvas').readAsString(), before[id]);
    }
    final back = await PageStore(dir).load(b1);
    expect((back.nodes.single as BoxRecord).snapshotText, 'precious');
  });

  test('only the latest delete can be undone', () async {
    final [a, b, c] = await three();
    final first = await nb.delete(b);
    final second = await nb.delete(c);
    await nb.undoDelete(first);
    expect(rootIds(nb.tree), [a]);
    await nb.undoDelete(second);
    expect(rootIds(nb.tree), [a, c]);
  });

  test('a discarded delete cannot be undone', () async {
    final [a, b, _] = await three();
    final d = await nb.delete(b);
    nb.discardDeleted(d);
    await nb.undoDelete(d);
    expect(nb.tree[b], isNull);
    expect(File('${dir.path}/$b.canvas').existsSync(), isFalse);
    expect(nb.tree[a], isNotNull);
  });
}
