// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The copy path of a move (design 2026-11-14-02, rule 4): where a page can't
// be renamed (another drive or cloud) it is copied and the original is kept,
// until the user chooses Delete the original, which removes an original only
// while it is unchanged and its copy still holds what the move put there.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose pages in [offline] can't be read, like files not downloaded.
class _OfflineStore extends PageStore {
  _OfflineStore(super.directory);

  final Set<String> offline = {};

  @override
  Future<String> readText(String pageId) {
    if (offline.contains(pageId)) {
      throw const FileSystemException('not downloaded');
    }
    return super.readText(pageId);
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  late _OfflineStore store;
  Future<void> Function(String, String)? hook;
  final locks = FolderLocks();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_copy');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    hook = null;
    store = _OfflineStore(pages);
    Notebook.forceCopyMoveForTest = true;
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    Notebook.forceCopyMoveForTest = false;
    Notebook.cannotRenamePagesForTest = {};
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  Notebook make() {
    final nb = Notebook(
      store,
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      folderLocks: locks,
    );
    nb.syncHook = (point, path) async => hook?.call(point, path);
    opened.add(nb);
    return nb;
  }

  String text(Directory d, String id) =>
      File('${d.path}/$id.canvas').readAsStringSync();
  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  // A page `a` with a subpage `ca`, an attachment of `a`, and the extra folder
  // as a standalone folder.
  Future<(Notebook, String, String)> setup() async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    final ca = await nb.createPage(parentId: a);
    await nb.flush();
    Directory('${pages.path}/$a.assets').createSync();
    File('${pages.path}/$a.assets/one.bin').writeAsBytesSync([1, 2, 3]);
    await nb.addStandaloneFolder(extra.path);
    return (nb, a, ca);
  }

  Future<CopiedMove> copied(Notebook nb, String a) async {
    try {
      await nb.moveToFolder(a, extra.path);
    } on OriginalsKeptException catch (e) {
      return e.move;
    }
    fail('the move should have copied and kept the originals');
  }

  Future<Object?> failure(Future<Object?> f) async {
    try {
      await f;
    } on Object catch (e) {
      return e;
    }
    return null;
  }

  test('a move that can not rename copies the tree and keeps every original, offering Delete the original', () async {
    final (nb, a, ca) = await setup();
    final before = {a: text(pages, a), ca: text(pages, ca)};
    final e = await failure(nb.moveToFolder(a, extra.path));
    expect(e, isA<OriginalsKeptException>());
    expect(
      (e! as OriginalsKeptException).message,
      allOf(contains('copied'), contains('Delete the original')),
    );
    expect((e as NotebookException).needsAction, isTrue);
    for (final id in [a, ca]) {
      expect(has(extra, id), isTrue, reason: 'the copy');
      expect(
        text(pages, id),
        before[id],
        reason: 'the original is never changed or deleted',
      );
    }
    expect(File('${pages.path}/$a.assets/one.bin').existsSync(), isTrue);
    expect(File('${extra.path}/$a.assets/one.bin').readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    // The copies are the pages; each original is listed as a duplicate.
    expect(
      nb.unreadable.map((u) => u.reason),
      everyElement(startsWith('duplicate page id')),
    );
    expect(nb.unreadable, hasLength(2));
    expect(nb.tree.descendantsOf(a), [ca]);
  });

  test(
    'Delete the original removes each unchanged original and its files',
    () async {
      final (nb, a, ca) = await setup();
      final kept = await copied(nb, a);
      expect(await nb.deleteOriginals(kept), contains('deleted'));
      expect(has(pages, a) || has(pages, ca), isFalse);
      expect(Directory('${pages.path}/$a.assets').existsSync(), isFalse);
      expect(has(extra, a) && has(extra, ca), isTrue);
      expect(File('${extra.path}/$a.assets/one.bin').existsSync(), isTrue);
      expect(nb.unreadable, isEmpty, reason: 'no duplicates are left');
      expect(kept.pending, 0);
    },
  );

  test('an original that changed since the move is kept, with its attachments, and the rest goes', () async {
    final (nb, a, ca) = await setup();
    final kept = await copied(nb, a);
    final f = File('${pages.path}/$a.canvas');
    f.writeAsStringSync('${f.readAsStringSync()} ');
    await expectLater(
      nb.deleteOriginals(kept),
      throwsA(
        isA<NotebookException>().having(
          (e) => e.message,
          'message',
          contains('changed'),
        ),
      ),
    );
    expect(f.existsSync(), isTrue, reason: 'the changed original stays');
    expect(
      File('${pages.path}/$a.assets/one.bin').existsSync(),
      isTrue,
      reason: 'its files stay with it',
    );
    expect(has(pages, ca), isFalse, reason: 'the other original went');
    expect(kept.pending, 1);
  });

  for (final how in ['edited', 'replaced', 'removed']) {
    test('a copy that was $how keeps its original', () async {
      final (nb, a, ca) = await setup();
      final kept = await copied(nb, a);
      final d = File('${extra.path}/$a.canvas');
      switch (how) {
        case 'edited':
          d.writeAsStringSync('${d.readAsStringSync()} ');
        case 'replaced':
          d.deleteSync();
          Directory(d.path).createSync();
        case 'removed':
          d.deleteSync();
      }
      await expectLater(
        nb.deleteOriginals(kept),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            contains('copy'),
          ),
        ),
        reason: how,
      );
      expect(has(pages, a), isTrue, reason: 'the original stays');
    });
  }

  test(
    'a copy replaced between the final check and the unlink keeps the original',
    () async {
      final (nb, a, _) = await setup();
      final kept = await copied(nb, a);
      hook = (point, path) async {
        if (point != 'originals-before-final-check') return;
        hook = null;
        File('${extra.path}/$a.canvas').writeAsStringSync('another version');
      };
      await expectLater(
        nb.deleteOriginals(kept),
        throwsA(isA<NotebookException>()),
      );
      expect(
        has(pages, a),
        isTrue,
        reason: 'the second check of the copy caught it',
      );
    },
  );

  test('a copied file rewritten in place (same size, time put back) just before the unlink keeps the original', () async {
    final (nb, a, _) = await setup();
    final kept = await copied(nb, a);
    final d = File('${extra.path}/$a.assets/one.bin');
    // A time a file system keeps exactly, so putting it back gives the same stamp.
    final when = DateTime.utc(2020, 1, 1);
    d.setLastModifiedSync(when);
    hook = (point, path) async {
      if (point != 'originals-file-before-final-check') return;
      hook = null;
      d.writeAsBytesSync([9, 9, 9]);
      d.setLastModifiedSync(when);
    };
    final e = await failure(nb.deleteOriginals(kept));
    expect(e, isA<NotebookException>());
    expect(
      File('${pages.path}/$a.assets/one.bin').readAsBytesSync(),
      [1, 2, 3],
      reason: 'the original of the file stays: the copy no longer holds what the move put there',
    );
  });

  test('an original is kept while its folder lock is held: both copies stay, reported', () async {
    final (nb, a, ca) = await setup();
    final kept = await copied(nb, a);
    final gate = Completer<void>();
    final held = locks.run(extra, () => gate.future);
    final e = await failure(nb.deleteOriginals(kept));
    gate.complete();
    await held;
    expect(e, isA<NotebookException>());
    expect((e! as NotebookException).message, contains('busy'));
    expect(has(pages, a) && has(pages, ca), isTrue);
    expect(kept.pending, 2);
    // Once the folder is free the originals go.
    expect(await nb.deleteOriginals(kept), contains('deleted'));
    expect(has(pages, a), isFalse);
  });

  test('a page that can not be renamed at page 2: the pages are put back, then the whole tree is copied', () async {
    Notebook.forceCopyMoveForTest = false;
    final (nb, a, ca) = await setup();
    Notebook.cannotRenamePagesForTest = {ca};
    final e = await failure(nb.moveToFolder(a, extra.path));
    expect(e, isA<OriginalsKeptException>());
    for (final id in [a, ca]) {
      expect(has(pages, id), isTrue, reason: 'the original of $id stays');
      expect(has(extra, id), isTrue, reason: 'the copy of $id');
    }
  });

  test(
    'a page that is not downloaded refuses the copy before anything is written',
    () async {
      final (nb, a, ca) = await setup();
      store.offline.add(ca);
      final e = await failure(nb.moveToFolder(a, extra.path));
      expect(e, isA<NotebookException>());
      expect((e! as NotebookException).message, contains('not downloaded'));
      expect(extra.listSync(), isEmpty, reason: 'nothing was written');
      expect(has(pages, a) && has(pages, ca), isTrue);
    },
  );
}
