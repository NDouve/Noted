// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
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

void main() {
  late Directory dir;
  late Notebook nb;
  late PageStore other; // "the other device"
  late ModuleRegistry modules;

  Future<void> start({bool watch = false}) async {
    dir = await Directory.systemTemp.createTemp('noted_external');
    modules = buildModules();
    nb = Notebook(
      PageStore(dir),
      modules,
      saveDelay: const Duration(hours: 1), // saves happen on flush()
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

  String pathOf(String id) => other.pathFor(id);

  /// Another device writes [page] to the folder.
  Future<void> externalWrite(NotedPage page) => other.save(page);

  group('page that is not open', () {
    test('a title change updates the tree', () async {
      await start();
      final a = nb.currentId!;
      final b = await nb.createPage();
      expect(nb.currentId, b);
      final page = await other.load(a);
      await externalWrite(page.withMeta(page.meta.withTitle('Changed elsewhere')));
      await nb.checkFile(pathOf(a));
      expect(nb.tree[a]!.title, 'Changed elsewhere');
    });

    test('a new file adds a page, a deleted file removes it', () async {
      await start();
      final fresh = NotedPage.create(
        PageMeta.create(id: 'fresh', title: 'From the cloud', order: 5),
      );
      await externalWrite(fresh);
      await nb.checkFile(pathOf('fresh'));
      expect(nb.tree['fresh']!.title, 'From the cloud');
      // It can be opened.
      await nb.open('fresh');
      expect(nb.currentId, 'fresh');
      await nb.open(nb.tree.roots.first.id == 'fresh' ? nb.tree.roots.last.id : nb.tree.roots.first.id);

      await File(pathOf('fresh')).delete();
      await nb.checkFile(pathOf('fresh'));
      expect(nb.tree['fresh'], isNull);
    });

    test('an unreadable file goes to the cannot-open list', () async {
      await start();
      final bad = '${dir.path}${Platform.pathSeparator}broken.canvas';
      await File(bad).writeAsString('{ not json');
      await nb.checkFile(bad);
      expect(nb.unreadable.map((u) => u.path), [bad]);
      // Fixing it brings it back.
      await File(bad).delete();
      await nb.checkFile(bad);
      expect(nb.unreadable, isEmpty);
    });

    test('a page that becomes unreadable leaves the tree', () async {
      await start();
      final a = nb.currentId!;
      await nb.createPage();
      await File(pathOf(a)).writeAsString('garbage');
      await nb.checkFile(pathOf(a));
      expect(nb.tree[a], isNull);
      expect(nb.unreadable, hasLength(1));
    });

    test('other files and temporary files are ignored', () async {
      await start();
      final before = nb.tree.roots.length;
      final tmp = '${dir.path}${Platform.pathSeparator}x.canvas.tmp';
      await File(tmp).writeAsString('{}');
      await nb.checkFile(tmp);
      expect(nb.tree.roots, hasLength(before));
      expect(nb.unreadable, isEmpty);
    });
  });

  group('open page', () {
    test('own writes are ignored', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
      await nb.flush();
      final before = c.page;
      var notified = 0;
      c.addListener(() => notified++);
      await nb.checkFile(pathOf(id));
      expect(identical(c.page, before), isTrue);
      expect(notified, 0);
    });

    test('a remote change is merged without losing an unsaved local edit', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
      await nb.flush();

      // Someone else adds a box and renames the page; meanwhile a local edit
      // is made but not yet saved.
      final disk = await other.load(id);
      final theirsBox = noteBox('theirs', at: const Bounds(400, 10, 200, 40));
      await externalWrite(disk.insertNode(theirsBox).withMeta(disk.meta.withTitle('Theirs')));
      final local = c.createBoxAt(const Bounds(10, 300, 0, 0));
      c.commit(local.id, modules.codecs.codecFor('noted.note')!.decode(doc('local'), 1));

      await nb.checkFile(pathOf(id));
      expect(c.page.nodes.map((n) => n.id).toSet(), {mine.id, theirsBox.id, local.id});
      expect(c.page.meta.title, 'Theirs');
      expect(nb.tree[id]!.title, 'Theirs');
      expect(c.conflictedBoxes, isEmpty);

      await nb.flush();
      final saved = await other.load(id);
      expect(saved.nodes.map((n) => n.id).toSet(), {mine.id, theirsBox.id, local.id});
      expect(saved.meta.title, 'Theirs');
    });

    test('a remote edit of an unchanged box is taken', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc('one'), 1));
      await nb.flush();
      final disk = await other.load(id);
      await externalWrite(disk.replaceNode(withText(disk.node(box.id)! as BoxRecord, 'two')));
      await nb.checkFile(pathOf(id));
      expect((c.page.node(box.id)! as BoxRecord).snapshotText, 'two');
      expect(c.conflictedBoxes, isEmpty);
    });

    test('both sides editing the same box: conflicted and saved with conflicts', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      final codec = modules.codecs.codecFor('noted.note')!;
      c.commit(box.id, codec.decode(doc('base'), 1));
      await nb.flush();

      final disk = await other.load(id);
      final theirs = withText(disk.node(box.id)! as BoxRecord, 'theirs');
      await externalWrite(disk.replaceNode(theirs));
      c.commit(box.id, codec.decode(doc('mine'), 1)); // not saved yet

      await nb.checkFile(pathOf(id));
      final now = c.page.node(box.id)! as BoxRecord;
      expect(now.snapshotText, 'mine');
      expect(now.isConflicted, isTrue);
      expect(now.conflicts.single.node, theirs.toRaw());
      expect(nb.hasConflict(id), isTrue);

      await nb.flush();
      final saved = (await other.load(id)).node(box.id)! as BoxRecord;
      expect(saved.snapshotText, 'mine');
      expect(saved.conflicts.single.node, theirs.toRaw());

      // Resolving clears the marker.
      c.resolveKeepMine(box.id);
      expect(nb.hasConflict(id), isFalse);
      await nb.flush();
      expect(((await other.load(id)).node(box.id)! as BoxRecord).isConflicted, isFalse);
    });

    test('a deleted file keeps the page open and the next save writes it again', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc('keep me'), 1));
      await nb.flush();
      await File(pathOf(id)).delete();
      final before = c.page;
      await nb.checkFile(pathOf(id));
      expect(nb.current, same(c));
      expect(identical(c.page, before), isTrue);
      expect(nb.tree[id], isNotNull);

      c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc('edited'), 1));
      await nb.flush();
      expect(File(pathOf(id)).existsSync(), isTrue);
      expect(((await other.load(id)).node(box.id)! as BoxRecord).snapshotText, 'edited');
    });

    test('a save does not overwrite an outside change it has not looked at yet', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      final disk = await other.load(id);
      final theirsBox = noteBox('theirs');
      await externalWrite(disk.insertNode(theirsBox)); // no checkFile
      final mine = c.createBoxAt(const Bounds(10, 300, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
      await nb.flush();
      final saved = await other.load(id);
      expect(saved.nodes.map((n) => n.id).toSet(), {theirsBox.id, mine.id});
    });
  });

  test('a watcher notices a new file and a change to the open page', () async {
    await start(watch: true);
    final id = nb.currentId!;

    Future<void> until(bool Function() ok) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('the watcher did not report the change in time');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    // Give the OS watcher a moment to start.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final fresh = NotedPage.create(PageMeta.create(id: 'watched', title: 'Watched', order: 9));
    await externalWrite(fresh);
    await until(() => nb.tree['watched'] != null);

    final disk = await other.load(id);
    final theirsBox = noteBox('via watcher');
    await externalWrite(disk.insertNode(theirsBox));
    await until(() => nb.current!.page.node(theirsBox.id) != null);

    // The app's own autosave does not come back as a change.
    final c = nb.current!;
    final box = c.createBoxAt(const Bounds(10, 300, 0, 0));
    c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc('own'), 1));
    final before = c.page;
    await nb.flush();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(identical(c.page, before), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('the sidebar marks a page with a conflicted box', (tester) async {
    late BoxRecord box;
    late NotedPage marked;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_external');
      modules = buildModules();
      other = PageStore(dir);
      final opened = NotedPage.create(PageMeta.create(id: 'open', title: 'Open one', order: 0));
      box = noteBox('x').withConflict(BoxConflict.deleted(at: 1));
      marked = NotedPage.create(
        PageMeta.create(id: 'marked', title: 'Marked', order: 1),
      ).insertNode(box);
      await other.save(opened);
      await other.save(marked);
      nb = Notebook(PageStore(dir), modules, saveDelay: Duration.zero);
      await nb.load();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 600,
            child: ListenableBuilder(
              listenable: nb,
              builder: (context, _) => PageTreeView(notebook: nb),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(nb.currentId, 'open');
    expect(find.byKey(const ValueKey('page-conflict-marked')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-conflict-open')), findsNothing);

    // Another device resolves it: the file loses the flag and the marker goes.
    await tester.runAsync(() async {
      await other.save(marked.replaceNode(box.withoutConflicts()));
      await nb.checkFile(pathOf('marked'));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('page-conflict-marked')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
