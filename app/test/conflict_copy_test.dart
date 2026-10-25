// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

/// A store that can be told to fail, to test that a copy is kept then.
class FlakyStore extends PageStore {
  FlakyStore(super.directory);

  bool dropSaves = false;
  bool failReads = false;

  @override
  Future<void> save(NotedPage page) async {
    if (!dropSaves) await super.save(page);
  }

  @override
  Future<String> readText(String pageId) async {
    if (failReads) throw const FileSystemException('read failed');
    return super.readText(pageId);
  }
}

void main() {
  late Directory dir;
  late Notebook nb;
  late PageStore other;
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  Future<void> start({bool watch = false, PageStore Function(Directory)? make}) async {
    dir = await Directory.systemTemp.createTemp('noted_copies');
    modules = buildModules();
    nb = Notebook(
      (make ?? PageStore.new)(dir),
      modules,
      saveDelay: const Duration(hours: 1),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
    );
    other = PageStore(dir);
    await nb.load();
    await other.scan();
  }

  tearDown(() async {
    nb.dispose();
    await dir.delete(recursive: true);
  });

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  BoxRecord withText(BoxRecord b, String text) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(b, codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';

  String copyPath(String id, String suffix) => '${dir.path}$sep$id-$suffix.canvas';

  Future<void> writeCopy(String path, NotedPage page) =>
      File(path).writeAsString(writePage(page));

  NotedPage onDisk(String id) => readPage(File(pathOf(id)).readAsStringSync());

  /// A closed page [id] holding one note, and the open page is another one.
  Future<(String, BoxRecord)> closedPageWithBox() async {
    final id = nb.currentId!;
    final box = noteBox('base');
    await other.save((await other.load(id)).insertNode(box));
    await nb.createPage(); // opens another page; [id] is closed
    await nb.checkFile(pathOf(id));
    return (id, box);
  }

  test('a copy with a computer name is merged into a closed page and deleted', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final disk = await other.load(id);
    final added = noteBox('from the other machine', at: const Bounds(400, 10, 200, 40));
    final copy = disk.insertNode(added).replaceNode(withText(box, 'edited there'));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, copy);

    await nb.checkFile(path);

    expect(File(path).existsSync(), isFalse);
    final merged = onDisk(id);
    expect(merged.nodes.map((n) => n.id).toSet(), {box.id, added.id});
    expect((merged.node(box.id)! as BoxRecord).snapshotText, 'edited there');
    expect(nb.unreadable, isEmpty);
    expect(nb.tree[id], isNotNull);
  });

  test('a copy with a hyphenated name and a number', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final added = noteBox('two');
    final path = copyPath(id, 'LAPTOP-ABC-1');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
  });

  test('a computer name made of digits, and a name that is a plain word', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    for (final name in ['20481024', 'MyPC']) {
      final added = noteBox('from $name');
      final path = copyPath(id, name);
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse, reason: name);
      expect(onDisk(id).node(added.id), isNotNull, reason: name);
    }
  });

  test('a hyphenated file with another page id is a page, not a copy', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final path = copyPath(id, 'notes');
    await writeCopy(
      path,
      NotedPage.create(PageMeta.create(id: 'different', title: 'Different', order: 7)),
    );
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.tree['different']!.title, 'Different');
    expect(File(pathOf(id)).readAsStringSync(), before);
  });

  test('a hyphenated duplicate without an original is still cannot-open', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final path = '${dir.path}${sep}zzzz-PC.canvas'; // no zzzz.canvas
    await writeCopy(path, await other.load(id));
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.unreadable.map((u) => u.path), [path]);
    expect(nb.unreadable.single.reason, contains('duplicate'));
  });

  test('the open page keeps an unsaved local edit when a copy is merged', () async {
    await start();
    final id = nb.currentId!;
    final c = nb.current!;
    final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
    c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
    await nb.flush();

    final added = noteBox('theirs', at: const Bounds(400, 10, 200, 40));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    final local = c.createBoxAt(const Bounds(10, 300, 0, 0)); // not saved yet
    c.commit(local.id, modules.codecs.codecFor('noted.note')!.decode(doc('local'), 1));

    await nb.checkFile(path);

    expect(nb.current, same(c));
    expect(c.page.nodes.map((n) => n.id).toSet(), {mine.id, added.id, local.id});
    expect(File(path).existsSync(), isFalse);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {mine.id, added.id, local.id});
  });

  test('a copy that edited the same box differently leaves a conflict', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final disk = await other.load(id);
    final mineEdit = withText(box, 'original side');
    final theirEdit = withText(box, 'copy side');
    await other.save(disk.replaceNode(mineEdit));
    await nb.checkFile(pathOf(id));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, disk.replaceNode(theirEdit));

    await nb.checkFile(path);

    expect(File(path).existsSync(), isFalse);
    final saved = onDisk(id).node(box.id)! as BoxRecord;
    expect(saved.snapshotText, 'original side');
    expect(saved.conflicts.single.node, theirEdit.toRaw());
    expect(nb.hasConflict(id), isTrue);
  });

  test('an identical copy is deleted and the page file is not rewritten', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final stamp = File(pathOf(id)).lastModifiedSync();
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await File(path).writeAsString(before);
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(File(pathOf(id)).readAsStringSync(), before);
    expect(File(pathOf(id)).lastModifiedSync(), stamp);
  });

  test('a copy found at startup is merged on load', () async {
    dir = await Directory.systemTemp.createTemp('noted_copies');
    modules = buildModules();
    other = PageStore(dir);
    final page = NotedPage.create(PageMeta.create(id: 'aaaa1111', title: 'A', order: 0));
    await other.save(page);
    final added = noteBox('new');
    final path = copyPath('aaaa1111', 'DESKTOP-4QK2N8L');
    await writeCopy(path, page.insertNode(added));
    nb = Notebook(PageStore(dir), modules, saveDelay: const Duration(hours: 1));
    await nb.load();
    expect(File(path).existsSync(), isFalse);
    expect(nb.unreadable, isEmpty);
    expect(onDisk('aaaa1111').node(added.id), isNotNull);
    expect(nb.currentId, 'aaaa1111');
    expect(nb.current!.page.node(added.id), isNotNull);
  });

  test('a store that does not keep the write: the copy stays and is listed', () async {
    late FlakyStore store;
    await start(make: (d) => store = FlakyStore(d));
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final added = noteBox('lost?');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    store.dropSaves = true;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(File(pathOf(id)).readAsStringSync(), before);
    expect(nb.unreadable.map((u) => u.path), [path]);
  });

  test('a read-back that fails keeps the copy; a later try merges it', () async {
    late FlakyStore store;
    await start(make: (d) => store = FlakyStore(d));
    final (id, box) = await closedPageWithBox();
    final added = noteBox('kept');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    store.failReads = true;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.unreadable.map((u) => u.path), [path]);

    store.failReads = false;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(nb.unreadable, isEmpty);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
  });

  test('a watcher merges a copy that appears while running', () async {
    await start(watch: true);
    final (id, box) = await closedPageWithBox();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final added = noteBox('via watcher');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));

    final end = DateTime.now().add(const Duration(seconds: 20));
    while (File(path).existsSync()) {
      if (DateTime.now().isAfter(end)) fail('the copy was not merged in time');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    expect(nb.unreadable, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
