// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A move renames the one copy (design 2026-11-14-02): page files and folders
// move with a rename that never replaces, never deleting, never reading a page
// whose stamp Noted holds. Between two folders it runs inside both folders'
// locks, each waited for a limited time, and a failure puts the pages back.

import 'dart:async';
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
  late List<String> reads;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_rename');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    reads = [];
    PageStore.fileReadObserver = reads.add; // every read of a page file, anywhere
    hook = null;
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    PageStore.fileReadObserver = null;
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
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    nb.syncHook = (point, path) async {
      await hook?.call(point, path);
    };
    opened.add(nb);
    return nb;
  }

  String text(Directory d, String id) => File('${d.path}/$id.canvas').readAsStringSync();
  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  // A page `a` with a subpage and a page `x` in the other folder, written by
  // one notebook; a second notebook then scans them (so each file has a stamp
  // and nothing was read since).
  Future<(Notebook, String, String, String)> scanned() async {
    final first = make();
    await first.load();
    final a = first.currentId!;
    final ca = await first.createPage(parentId: a);
    final x = await first.createPage(folderPath: extra.path);
    await first.open(a);
    await first.flush();
    first.dispose();
    opened.remove(first);
    final nb = make();
    await nb.load();
    reads.clear();
    return (nb, a, ca, x);
  }

  test('a page and its subpage are renamed to the other folder without a content read', () async {
    final (nb, a, ca, x) = await scanned();
    final sub = text(pages, ca);
    final stampBefore = fileStamp('${pages.path}/$ca.canvas');
    final seen = <LocalChange>[];
    final feed = nb.localChanges.listen(seen.add);
    addTearDown(feed.cancel);
    expect(await nb.move(a, parentId: x), isTrue);
    await Future<void>.delayed(Duration.zero);
    // Every page that left the source arrived: deleted, then published.
    for (final id in [a, ca]) {
      final gone = seen.indexWhere((c) => c.kind == LocalChangeKind.deleted && c.path.endsWith('$id.canvas') && c.path.startsWith(pages.path));
      final came = seen.indexWhere((c) => c.kind == LocalChangeKind.published && c.path.endsWith('$id.canvas') && c.path.startsWith(extra.path));
      expect(gone, isNonNegative, reason: 'deleted($id): $seen');
      expect(came, greaterThan(gone), reason: 'published($id) after it: $seen');
      // The scanned-only subpage was never read: its event has no identity.
      if (id == ca) expect(seen[came].identity, isNull, reason: 'unread, so no identity');
    }
    expect(has(extra, a) && has(extra, ca), isTrue);
    expect(has(pages, a) || has(pages, ca), isFalse);
    // The same file: a rename keeps its stamp, and its bytes.
    expect(fileStamp('${extra.path}/$ca.canvas'), stampBefore);
    expect(text(extra, ca), sub);
    expect(readPage(text(extra, a)).meta.parentId, x);
    expect(nb.tree.descendantsOf(x), [a, ca]);
    // Only the root is read, by its placement (the header is in the file): the
    // subpage is stamped, so no check of it reads it either.
    expect(reads.where((r) => !r.endsWith('$a.canvas')), isEmpty, reason: 'rule P: $reads');
  });

  test('the images and files folder is renamed with its page', () async {
    final (nb, a, _, x) = await scanned();
    final assets = Directory('${pages.path}/$a.assets')..createSync();
    File('${assets.path}/one.bin').writeAsBytesSync([1, 2, 3]);
    expect(await nb.move(a, parentId: x), isTrue);
    expect(Directory('${pages.path}/$a.assets').existsSync(), isFalse);
    expect(File('${extra.path}/$a.assets/one.bin').readAsBytesSync(), [1, 2, 3]);
  });

  test('a taken name in the target folder stays at the source, reported, and the page moves', () async {
    final (nb, a, _, x) = await scanned();
    Directory('${pages.path}/$a.assets').createSync();
    Directory('${extra.path}/$a.assets').createSync();
    File('${pages.path}/$a.assets/same.bin').writeAsBytesSync([1]);
    File('${pages.path}/$a.assets/free.bin').writeAsBytesSync([2]);
    File('${extra.path}/$a.assets/same.bin').writeAsBytesSync([9]);
    await expectLater(
      nb.move(a, parentId: x),
      throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('stayed in'))),
    );
    expect(has(extra, a), isTrue);
    expect(File('${extra.path}/$a.assets/same.bin').readAsBytesSync(), [9], reason: 'never replaced');
    expect(File('${pages.path}/$a.assets/same.bin').readAsBytesSync(), [1], reason: 'never deleted');
    expect(File('${extra.path}/$a.assets/free.bin').readAsBytesSync(), [2]);
  });

  test('a newer version written at the source just before the rename moves, and is read once', () async {
    final (nb, a, ca, x) = await scanned();
    hook = (point, path) async {
      if (point != 'move-before-rename') return;
      hook = null;
      final f = File('${pages.path}/$a.canvas');
      final page = readPage(f.readAsStringSync());
      f.writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Newer'))));
    };
    expect(await nb.move(a, parentId: x), isTrue);
    expect(has(pages, a), isFalse);
    // The stamp changed, so the moved root was read (by its placement) and its
    // newer title is the page's; a stamped page isn't read.
    expect(nb.pageTitleOf(a), 'Newer');
    expect(reads.where((r) => r.endsWith('$ca.canvas')), isEmpty);
    expect(nb.tree.descendantsOf(x), contains(a));
  });

  test('a stalled target folder refuses the move after the limit: nothing moved', () async {
    final (nb, a, ca, x) = await scanned();
    final stall = Completer<void>();
    final held = nb.folderLocks.run(extra, () => stall.future);
    try {
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('busy'))),
      );
    } finally {
      stall.complete();
      await held;
    }
    expect(has(pages, a) && has(pages, ca), isTrue);
    expect(has(extra, a) || has(extra, ca), isFalse);
  });

  test('a failure at the second page puts the first back', () async {
    final (nb, a, ca, x) = await scanned();
    final before = text(pages, a);
    // The target already holds a file named for the subpage.
    File('${extra.path}/$ca.canvas').writeAsStringSync('someone else');
    await expectLater(
      nb.move(a, parentId: x),
      throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('already has a file'))),
    );
    expect(text(pages, a), before);
    expect(has(pages, ca), isTrue);
    expect(has(extra, a), isFalse);
    expect(File('${extra.path}/$ca.canvas').readAsStringSync(), 'someone else', reason: 'never replaced');
    expect(nb.tree.descendantsOf(a), [ca]);
  });

  test('a rollback whose stamp no longer matches publishes the source again and deletes the target', () async {
    final (nb, a, ca, x) = await scanned();
    File('${extra.path}/$ca.canvas').writeAsStringSync('someone else'); // page 2 fails: page 1 goes back
    final feed = <LocalChange>[];
    final sub = nb.localChanges.listen(feed.add);
    addTearDown(sub.cancel);
    hook = (point, path) async {
      if (point != 'move-after-rename' || !path.startsWith(extra.path)) return;
      hook = null;
      // The moved file changes before it goes back: its stamp is not the one carried.
      final f = File('${extra.path}/$a.canvas');
      final page = readPage(f.readAsStringSync());
      f.writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Changed on the way'))));
    };
    await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final source = '${pages.path}/$a.canvas';
    expect(has(pages, a), isTrue);
    String norm(String p) => p.replaceAll(r'\', '/');
    expect(
      feed.any((c) => c.kind == LocalChangeKind.deleted && norm(c.path) == norm('${extra.path}/$a.canvas')),
      isTrue,
      reason: 'the target went',
    );
    expect(
      feed.lastWhere((c) => norm(c.path) == norm(source)).kind,
      LocalChangeKind.published,
      reason: 'the source is back: published, not left unmentioned',
    );
  });
}
