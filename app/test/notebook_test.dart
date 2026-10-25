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
    dir = await Directory.systemTemp.createTemp('noted_app');
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

  test('an empty folder gets a first page', () async {
    await nb.load();
    expect(nb.tree.roots, hasLength(1));
    expect(nb.currentId, nb.tree.roots.single.id);
    expect((await reread()).roots, hasLength(1));
  });

  test('subpages turn a page into a divider; delete removes the subtree', () async {
    await nb.load();
    final root = nb.currentId!;
    final child = await nb.createPage(parentId: root);
    await nb.createPage(parentId: child);
    final other = await nb.createPage();
    expect(nb.tree.isDivider(root), isTrue);
    expect(nb.currentId, other);

    var onDisk = await reread();
    expect(onDisk.descendantsOf(root), hasLength(2));

    await nb.open(child);
    await nb.delete(root);
    onDisk = await reread();
    expect(onDisk.roots.map((p) => p.id), [other]);
    expect(nb.currentId, other);
  });

  test('renames the open page and other pages', () async {
    await nb.load();
    final a = nb.currentId!;
    final b = await nb.createPage();
    await nb.rename(b, 'Open one');
    await nb.rename(a, 'Closed one');
    await nb.flush();
    final onDisk = await reread();
    expect(onDisk[a]!.title, 'Closed one');
    expect(onDisk[b]!.title, 'Open one');
  });

  test('box edits are saved, and saved before switching pages', () async {
    await nb.load();
    final first = nb.currentId!;
    final c = nb.current!;
    final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
    c.commit(box.id, c.modules.codecs.codecFor(box.typeId)!.decode({
      'document': {
        'type': 'page',
        'children': [
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': 'kept'},
              ],
            },
          },
        ],
      },
    }, 1));
    await nb.createPage(); // switches away, flushing the first page
    final page = await PageStore(dir).load(first);
    expect((page.nodes.single as BoxRecord).snapshotText, 'kept');
  });

  test('an empty box being edited is discarded when leaving the page', () async {
    await nb.load();
    final first = nb.currentId!;
    final c = nb.current!;
    final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
    c.setEditing(box.id, true);
    await nb.createPage();
    expect((await PageStore(dir).load(first)).nodes, isEmpty);
  });
}
