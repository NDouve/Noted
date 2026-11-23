// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The review of the copy path (design 2026-11-14-02): the copy's recorded text,
// the check of what was held back during the copy, and Delete the original's
// check of an attachment's copy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_review_copy');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    hook = null;
    Notebook.forceCopyMoveForTest = true;
  });
  tearDown(() async {
    Notebook.forceCopyMoveForTest = false;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  // A page `a` with a subpage `ca` and an attachment of `a`; the other folder is
  // a standalone folder.
  Future<(Notebook, String, String)> setup() async {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    nb.syncHook = (point, path) async => hook?.call(point, path);
    opened.add(nb);
    await nb.load();
    final a = nb.currentId!;
    final ca = await nb.createPage(parentId: a);
    await nb.flush();
    Directory('${pages.path}/$a.assets').createSync();
    File('${pages.path}/$a.assets/one.bin').writeAsBytesSync([1, 2, 3]);
    await nb.addStandaloneFolder(extra.path);
    await nb.createPage(folderPath: extra.path); // opens it, so the moved pages are closed
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

  test('finding 9: a write that lands after the placement is not the copy\'s text', () async {
    final (nb, a, _) = await setup();
    hook = (point, path) async {
      if (point != 'move-copy-placed') return;
      hook = null;
      final f = File('${extra.path}/$a.canvas');
      final page = readPage(f.readAsStringSync());
      f.writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Changed by sync'))));
    };
    final kept = await copied(nb, a);
    await expectLater(nb.deleteOriginals(kept), throwsA(isA<NotebookException>()));
    expect(has(pages, a), isTrue, reason: 'the copy is not what the move put there: the original stays');
  });

  test('finding 12: a change of a copy during the move is looked at when it ends', () async {
    final (nb, a, ca) = await setup();
    hook = (point, path) async {
      if (point != 'move-copy-placed') return;
      hook = null;
      final f = File('${extra.path}/$ca.canvas');
      final page = readPage(f.readAsStringSync());
      f.writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Held back'))));
    };
    await copied(nb, a);
    expect(nb.pageTitleOf(ca), 'Held back');
  });

  test('finding 14: an attachment\'s copy replaced just before the unlink keeps the original', () async {
    final (nb, a, _) = await setup();
    final kept = await copied(nb, a);
    hook = (point, path) async {
      if (point != 'originals-file-before-final-check') return;
      hook = null;
      File('${extra.path}/$a.assets/one.bin').writeAsBytesSync([9, 9, 9]);
    };
    await expectLater(nb.deleteOriginals(kept), throwsA(isA<NotebookException>()));
    expect(File('${pages.path}/$a.assets/one.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('${extra.path}/$a.assets/one.bin').readAsBytesSync(), [9, 9, 9]);
  });

  test('finding 14: an attachment whose copy is unchanged goes, after a hash made off the lock-held path', () async {
    final (nb, a, _) = await setup();
    final kept = await copied(nb, a);
    await nb.deleteOriginals(kept);
    expect(File('${pages.path}/$a.assets/one.bin').existsSync(), isFalse);
    expect(File('${extra.path}/$a.assets/one.bin').readAsBytesSync(), [1, 2, 3]);
  });
}
