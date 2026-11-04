// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Deterministic performance guards: they count file reads and writes instead
// of timing them (see 0091 and 0095 for the canvas counts). Every file the
// notebook touches goes through `countingIo`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/notebook_search.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/testing.dart';

import 'support/counting_io.dart';

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
  final log = IoLog();

  /// Opens a notebook on a fresh folder holding [pages] pages (each with one
  /// note), all inside `countingIo`.
  Future<List<String>> start({
    int pages = 0,
    bool watch = false,
    Duration saveDelay = const Duration(hours: 1),
    Duration folderCheck = Duration.zero,
  }) async {
    dir = await Directory.systemTemp.createTemp('noted_perf');
    modules = buildModules();
    other = PageStore(dir);
    final ids = <String>[];
    for (var i = 0; i < pages; i++) {
      final codec = modules.codecs.codecFor('noted.note')!;
      final box = commitBox(
        createBox(codec, const Bounds(10, 10, 200, 40)),
        codec,
        codec.decode(doc('page $i alpha'), 1),
      );
      final page = NotedPage.create(
        PageMeta.create(id: 'p$i', title: 'Page $i', order: i),
      ).insertNode(box);
      await other.save(page);
      ids.add(page.id);
    }
    nb = Notebook(
      PageStore(dir),
      modules,
      saveDelay: saveDelay,
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
      folderCheckInterval: folderCheck,
    );
    await nb.load();
    await other.scan();
    log.clear();
    return ids;
  }

  tearDown(() async {
    nb.dispose();
    // On Windows a watcher's handle, or a check that was already reading, is
    // released a moment after dispose; a delete then fails with errno 32.
    for (var attempt = 1; Directory(dir.path).existsSync(); attempt++) {
      try {
        await Directory(dir.path).delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  String pathOf(String id) => other.pathFor(id);

  Future<void> realWait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('saving', () {
    test('a typing burst makes a bounded number of page writes', () async {
      await countingIo(log, () async {
        await start(saveDelay: const Duration(milliseconds: 150));
        final c = nb.current!;
        final path = pathOf(nb.currentId!);
        final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
        final codec = modules.codecs.codecFor('noted.note')!;
        await nb.flush();
        log.clear();

        // 60 keystrokes, each restarting the autosave delay, so the save
        // waits until the typing pauses.
        for (var i = 0; i < 60; i++) {
          c.commit(box.id, codec.decode(doc('typed ${'x' * i}'), 1));
          await realWait(1);
        }
        while (nb.unsavedDescription != null) {
          await realWait(20);
        }
        await nb.flush();
        // The delay restarts with each change, so the burst is one save; a
        // second only if a pause between two keystrokes outlasted the delay
        // on a slow machine. Never one per keystroke.
        // Each save writes one temporary file, which is then published
        // exclusively (on Windows through the OS, which IOOverrides doesn't
        // see, so publishes are counted by their temporary files).
        expect(log.writes('.tmp'), inInclusiveRange(1, 2));
        expect(File(path).readAsStringSync(), contains('typed ${'x' * 59}'));
      });
    });

    test('no change makes no write', () async {
      await countingIo(log, () async {
        final ids = await start(
          pages: 2,
          saveDelay: const Duration(milliseconds: 50),
        );
        await nb.open(ids[1]);
        await nb.open(ids[0]);
        await nb.flush();
        await realWait(300);
        await nb.flush();
        expect(
          log.ops.where((o) => o.kind == 'write' || o.kind == 'rename'),
          isEmpty,
        );
      });
    });
  });

  group('reading', () {
    test('opening a page reads its file once', () async {
      await countingIo(log, () async {
        final ids = await start(pages: 3);
        resetPageParseCount();
        await nb.open(ids[2]);
        expect(nb.currentId, ids[2]);
        expect(log.reads(pathOf(ids[2])), 1);
        expect(pageParseCount, 1, reason: 'parsed once');
        expect(log.reads(pathOf(ids[1])), 0, reason: 'other pages untouched');
        expect(log.reads(pathOf(ids[0])), 0);
      });
    });

    test('the app\'s own save is not read in again or merged', () async {
      await countingIo(log, () async {
        await start(watch: true);
        final id = nb.currentId!;
        final c = nb.current!;
        final codec = modules.codecs.codecFor('noted.note')!;
        await realWait(300); // let the OS watcher start
        var contentReports = 0;
        nb.onPageContent = (_, _) => contentReports++;
        var notified = 0;
        c.addListener(() => notified++);
        final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
        c.commit(box.id, codec.decode(doc('mine'), 1));
        notified = 0;
        log.clear();
        resetPageParseCount();
        await nb.flush();
        final page = c.page;
        final reportsAfterSave = contentReports;
        // The save's own reads (the outside-change check and the
        // compare-and-swap's look at the target) are the baseline.
        final base = log.reads(pathOf(id));
        // Wait for the watcher to report our own write, up to a deadline, so
        // a slow runner doesn't fail the test.
        for (
          var waited = 0;
          waited < 5000 && log.reads(pathOf(id)) <= base;
          waited += 50
        ) {
          await realWait(50);
        }
        await realWait(200); // let a second report, if any, arrive
        // The watcher compares the text with what was written (once, or
        // twice if the debounce split the move-aside and the publish); it is
        // never parsed and merged into the page. It must have fired, or this
        // would pass without testing the compare path.
        expect(
          log.reads(pathOf(id)) - base,
          inInclusiveRange(1, 2),
          reason: 'the watcher read the file',
        );
        final beforeCheck = log.reads(pathOf(id));
        await nb.checkFile(pathOf(id)); // and a check by hand finds the same
        expect(log.reads(pathOf(id)) - beforeCheck, 1);
        expect(pageParseCount, 0, reason: 'our own write is not parsed again');
        expect(contentReports, reportsAfterSave, reason: 'no page read in');
        expect(identical(c.page, page), isTrue, reason: 'no merge');
        expect(notified, 0);
      });
    });
  });

  group('search', () {
    test(
      'a repeated search reads no page; a change rereads only that page',
      () async {
        await countingIo(log, () async {
          final ids = await start(pages: 6);
          final search = NotebookSearch(nb);
          addTearDown(search.dispose);

          await search.setText('alpha'); // builds the index
          expect(search.results, hasLength(6));
          final built = log.totalReads;
          expect(built, greaterThan(0), reason: 'the counter sees the build');
          expect(built, lessThanOrEqualTo(6), reason: 'each page read once');

          log.clear();
          for (final q in ['alpha', 'page 3', 'alpha page', 'zzz', 'alpha']) {
            await search.setText(q);
          }
          expect(log.totalReads, 0, reason: 'unchanged notebook, no file read');

          // Another device changes page 4.
          final disk = await other.load(ids[4]);
          final codec = modules.codecs.codecFor('noted.note')!;
          final box = disk.nodes.whereType<BoxRecord>().single;
          await other.save(
            disk.replaceNode(
              commitBox(box, codec, codec.decode(doc('page 4 omega'), 1)),
            ),
          );
          log.clear();
          await nb.checkFile(pathOf(ids[4]));
          await search.setText('omega');
          expect(search.results.map((p) => p.pageId), [ids[4]]);
          expect(log.reads(pathOf(ids[4])), 1);
          expect(log.totalReads, 1, reason: 'only the changed page was read');
        });
      },
    );
  });

  group('folder timer', () {
    test('rereads no unchanged page', () async {
      await countingIo(log, () async {
        await start(
          pages: 5,
          watch: true,
          folderCheck: const Duration(milliseconds: 40),
        );
        await realWait(300);
        log.clear();
        await realWait(600);
        expect(
          log.existsChecks(dir.path),
          greaterThanOrEqualTo(3),
          reason: 'the timer ran',
        );
        expect(
          log.ops.where((o) => o.kind == 'read' && o.path.endsWith('.canvas')),
          isEmpty,
        );
      });
    });
  });
}
