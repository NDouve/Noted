// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Failure injection: the sync writer replaces a file at the exact moment the
// app is about to overwrite or delete it (0051, 0053).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
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

// Counts the writes that reach the folder. [beforeWrite] runs once, just
// before the next write or compare-and-swap replace: a sync client landing a
// newer version of the file at that moment.
class CountingStore extends PageStore {
  CountingStore(super.directory);
  int saves = 0;
  void Function()? beforeWrite;
  // Runs once, between the compare-and-swap replace reading the set-aside
  // original and publishing the new file.
  void Function()? beforePublishOnce;

  void _fire() {
    final f = beforeWrite;
    beforeWrite = null;
    f?.call();
  }

  @override
  Future<void> save(NotedPage page) {
    saves++;
    _fire();
    return super.save(page);
  }

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) {
    saves++;
    _fire();
    final hook = beforePublishOnce;
    beforePublishOnce = null;
    return super.saveIfUnchanged(page, expectedText, beforePublish: hook ?? beforePublish);
  }
}

void main() {
  late CountingStore counting;
  late Directory root;
  late Directory dir;
  late Directory rec;
  late Notebook nb;
  late PageStore other; // "the other device"
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('noted_race');
    dir = await Directory('${root.path}${sep}pages').create();
    rec = Directory('${root.path}${sep}rec');
    modules = buildModules();
    counting = CountingStore(dir);
    nb = Notebook(
      counting,
      modules,
      saveDelay: const Duration(hours: 1),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    other = PageStore(dir);
    await nb.load();
    await nb.flush();
    await other.scan();
  }

  tearDown(() async {
    nb.dispose();
    await root.delete(recursive: true);
  });

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';
  NotedPage onDisk(String id) => readPage(File(pathOf(id)).readAsStringSync());

  group('the open page file is replaced by something unreadable', () {
    // Local edit, then the file is replaced behind the app's back and the
    // autosave runs without a watcher event in between.
    Future<(String, BoxRecord)> editedPage() async {
      await start();
      final id = nb.currentId!;
      final mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      return (id, mine);
    }

    void expectBlocked(String id, BoxRecord mine, String bytes) {
      // The file on disk is untouched.
      expect(File(pathOf(id)).readAsStringSync(), bytes);
      // The page is read-only with the reason shown.
      expect(nb.readOnlyReason, isNotNull);
      expect(nb.current!.readOnly, isTrue);
    }

    test('malformed text is not overwritten; edits go to recovery', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expectBlocked(id, mine, '{ not json');
      expect(nb.readOnlyReason, allOf(contains("it isn't a valid page file"), contains('open another page')));
      expect(nb.readOnlyReason, isNot(contains('JSON')));
      final entries = (await nb.pendingRecovery()).entries;
      expect(entries.single.pageId, id);
      expect(entries.single.page.node(mine.id), isNotNull);
    });

    test('a newer format is not overwritten', () async {
      final (id, mine) = await editedPage();
      final newer = writePage(onDisk(id)).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
      expect(() => readPage(newer), throwsA(isA<UnsupportedPageFormatException>()));
      File(pathOf(id)).writeAsStringSync(newer);
      await nb.flush();
      expectBlocked(id, mine, newer);
      expect(nb.readOnlyReason, contains('it is from a newer version of Noted'));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a valid file of a different page is not overwritten', () async {
      final (id, mine) = await editedPage();
      final foreign = File(pathOf(id)).readAsStringSync().replaceAll(
        RegExp('"pageId"\\s*:\\s*"$id"'),
        '"pageId":"0000000000000abc"',
      );
      expect(foreign, isNot(contains(id)));
      File(pathOf(id)).writeAsStringSync(foreign);
      await nb.flush();
      expectBlocked(id, mine, foreign);
      expect(nb.readOnlyReason, contains('it holds a different page'));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a late change from a controller that was closed saves nothing', () async {
      await start();
      final first = nb.currentId!;
      final old = nb.current!;
      final second = await nb.createPage();
      await nb.flush();
      expect(nb.currentId, second);
      final before = File(pathOf(first)).readAsStringSync();
      final saves = counting.saves;
      try {
        old.createBoxAt(const Bounds(10, 10, 0, 0));
      } on Object {
        return; // a closed controller refuses edits: nothing to guard
      }
      await nb.flush();
      expect(counting.saves, saves);
      expect(File(pathOf(first)).readAsStringSync(), before);
    });

    test('text that is not UTF-8 is not overwritten', () async {
      final (id, mine) = await editedPage();
      final bytes = [0xff, 0xfe, 0xfd];
      File(pathOf(id)).writeAsBytesSync(bytes);
      await nb.flush();
      expect(File(pathOf(id)).readAsBytesSync(), bytes);
      expect(nb.readOnlyReason, isNotNull);
      expect(nb.readOnlyReason, anyOf(contains("it isn't a valid page file"), contains("it couldn't be read")));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a read error is not treated as a missing file', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).deleteSync();
      Directory(pathOf(id)).createSync(); // present, but can't be read as a file
      final writes = counting.saves;
      await nb.flush();
      expect(counting.saves, writes); // the save gate stopped the write
      expect(Directory(pathOf(id)).existsSync(), isTrue);
      expect(nb.readOnlyReason, isNotNull);
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a read error that passes is rechecked on the folder timer', () async {
      final (id, mine) = await editedPage();
      final original = File(pathOf(id)).readAsStringSync();
      File(pathOf(id)).deleteSync();
      Directory(pathOf(id)).createSync();
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      Directory(pathOf(id)).deleteSync();
      File(pathOf(id)).writeAsStringSync(original); // no watcher event
      await nb.checkFolders();
      expect(nb.readOnlyReason, isNull);
      expect(nb.current!.readOnly, isFalse);
      await nb.flush();
      expect(onDisk(id).node(mine.id), isNotNull);
    });

    // A sync client often deletes a file and then renames the new one in.
    for (final withCreateEvent in [true, false]) {
      for (final (label, bytes) in [
        ('malformed', '{ not json'),
        ('newer-format', null),
      ]) {
        test(
          'deleted, then put back as $label text ${withCreateEvent ? 'with' : 'without'} a create event: not overwritten',
          () async {
            final (id, mine) = await editedPage();
            final text =
                bytes ??
                writePage(onDisk(id)).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
            File(pathOf(id)).deleteSync();
            await nb.checkFile(pathOf(id)); // the delete event
            File(pathOf(id)).writeAsStringSync(text);
            if (withCreateEvent) await nb.checkFile(pathOf(id));
            final writes = counting.saves;
            await nb.flush();
            expect(counting.saves, writes);
            expectBlocked(id, mine, text);
            expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
          },
        );
      }
    }

    test('a file that is really absent is written', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).deleteSync();
      await nb.checkFile(pathOf(id));
      await nb.flush();
      expect(nb.readOnlyReason, isNull);
      expect(onDisk(id).node(mine.id), isNotNull);
    });

    test('a folder that comes back holding a newer-format file is not overwritten', () async {
      await start();
      final extra = await Directory('${root.path}${sep}Elsewhere').create();
      final away = Directory('${root.path}${sep}Elsewhere-away');
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      await nb.open(x);
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      final file = File('${extra.path}$sep$x.canvas');
      final newer = file.readAsStringSync().replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
      await extra.rename(away.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      File('${away.path}$sep$x.canvas').writeAsStringSync(newer);
      await away.rename(extra.path);
      await nb.checkFolders();
      await nb.flush();
      expect(file.readAsStringSync(), newer);
      expect((await nb.pendingRecovery()).entries, hasLength(1)); // kept
    });

    test('a readable version later is merged and the page is editable again', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      // The same bad bytes again change nothing.
      await nb.checkFile(pathOf(id));
      expect(nb.readOnlyReason, isNotNull);

      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final disk = NotedPage.create(nb.current!.page.meta).insertNode(theirs);
      await other.save(disk);
      await nb.checkFile(pathOf(id));

      expect(nb.readOnlyReason, isNull);
      expect(nb.current!.readOnly, isFalse);
      expect(nb.current!.page.node(mine.id), isNotNull);
      expect(nb.current!.page.node(theirs.id), isNotNull);
      await nb.flush();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {mine.id, theirs.id});
      // The entry kept for the block is gone once the merged save landed.
      expect((await nb.pendingRecovery()).entries, isEmpty);
    });

    test('a recovery entry that is not the block\'s own stays', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      final entry = (await nb.pendingRecovery()).entries.single;
      // Someone else's newer entry for the same page replaces it.
      await RecoveryStore(rec).write(
        folder: entry.folder,
        page: nb.current!.page.insertNode(noteBox('other')),
        baseText: entry.baseText,
        time: DateTime.now(),
      );
      await other.save(NotedPage.create(nb.current!.page.meta));
      await nb.checkFile(pathOf(id));
      await nb.flush();
      expect(nb.readOnlyReason, isNull);
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      expect(mine.id, isNotEmpty);
    });

    test('the file being deleted lifts the block; the next save writes the page', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      File(pathOf(id)).deleteSync();
      await nb.checkFile(pathOf(id));
      expect(nb.readOnlyReason, isNull);
      await nb.flush();
      expect(onDisk(id).node(mine.id), isNotNull);
    });
  });

  group('conflict copy cleanup', () {
    Future<(String, BoxRecord)> closedPageWithBox() async {
      await start();
      final id = nb.currentId!;
      final box = noteBox('base');
      await other.save((await other.load(id)).insertNode(box));
      await nb.createPage(); // opens another page; [id] is closed
      await nb.checkFile(pathOf(id));
      return (id, box);
    }

    test('a copy replaced during the merge is merged again, not deleted', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final first = noteBox('first', at: const Bounds(400, 10, 200, 40));
      final later = noteBox('added later', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(first)));
      var fired = false;
      nb.syncHook = (point, p) async {
        if (point != 'copy-merged' || fired) return;
        fired = true; // the sync provider replaces the copy with a newer one
        File(path).writeAsStringSync(writePage(disk.insertNode(first).insertNode(later)));
      };

      await nb.checkFile(path);

      expect(fired, isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, first.id, later.id});
      expect(nb.unreadable, isEmpty);
    });

    test('a copy that keeps changing is kept and listed', () async {
      final (id, _) = await closedPageWithBox();
      final disk = await other.load(id);
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      var n = 0;
      File(path).writeAsStringSync(writePage(disk.insertNode(noteBox('0'))));
      nb.syncHook = (point, p) async {
        if (point != 'copy-merged') return;
        n++;
        File(path).writeAsStringSync(writePage(disk.insertNode(noteBox('$n'))));
      };
      await nb.checkFile(path);
      expect(File(path).existsSync(), isTrue);
      expect(nb.unreadable.map((u) => u.path), [path]);
      // Once it settles, the next pass merges and removes it.
      nb.syncHook = null;
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(nb.unreadable, isEmpty);
    });

    test('an original changed after it was read is not overwritten', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('newer on the original', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(fromCopy)));
      var fired = false;
      nb.syncHook = (point, p) async {
        if (point != 'original-read' || fired) return;
        fired = true; // the other device's edit lands on the original now
        await other.save(disk.insertNode(newer));
      };

      await nb.checkFile(path);

      expect(fired, isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, fromCopy.id, newer.id});
    });

    test('an original replaced at the moment of the merge write is not overwritten', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('newer on the original', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(fromCopy)));
      // After the reread, right before the write: only the compare-and-swap
      // replace sees this.
      counting.beforeWrite = () => File(pathOf(id)).writeAsStringSync(writePage(disk.insertNode(newer)));

      await nb.checkFile(path);

      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, fromCopy.id, newer.id});
    });

    test('R-3: a sync writer taking the target at the publish keeps the original-only box', () async {
      final (id, box) = await closedPageWithBox(); // the original holds box A
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('from the other device', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      // The copy does not have box A; the other device's newer version does not either.
      final withoutA = disk.removeNode(box.id);
      File(path).writeAsStringSync(writePage(withoutA.insertNode(fromCopy)));
      var fired = false;
      // After the original was set aside and verified, right before the merged
      // page is published: the sync writer publishes its own version.
      counting.beforePublishOnce = () {
        fired = true;
        File(pathOf(id)).writeAsStringSync(writePage(withoutA.insertNode(newer)));
      };

      await nb.checkFile(path);
      // Settle: merge every conflict copy that is left, as the folder scan would.
      for (var i = 0; i < 4; i++) {
        final copies = dir
            .listSync()
            .map((f) => f.path)
            .where((f) => f.endsWith('.canvas') && f != pathOf(id))
            .toList();
        if (copies.isEmpty) break;
        for (final c in copies) {
          await nb.checkFile(c);
        }
      }

      expect(fired, isTrue);
      final ids = onDisk(id).nodes.map((n) => n.id).toSet();
      expect(ids, containsAll({box.id, fromCopy.id, newer.id}));
    });
  });
}
