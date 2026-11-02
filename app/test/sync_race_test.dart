// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Failure injection: the sync writer replaces a file at the exact moment the
// app is about to overwrite or delete it (0051, 0053).

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

void main() {
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
    nb = Notebook(
      PageStore(dir),
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
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('text that is not UTF-8 is not overwritten', () async {
      final (id, mine) = await editedPage();
      final bytes = [0xff, 0xfe, 0xfd];
      File(pathOf(id)).writeAsBytesSync(bytes);
      await nb.flush();
      expect(File(pathOf(id)).readAsBytesSync(), bytes);
      expect(nb.readOnlyReason, isNotNull);
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a read error is not treated as a missing file', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).deleteSync();
      Directory(pathOf(id)).createSync(); // present, but can't be read as a file
      await nb.flush();
      expect(Directory(pathOf(id)).existsSync(), isTrue);
      expect(nb.readOnlyReason, isNotNull);
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
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
  });
}
