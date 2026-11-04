// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// R-1 v3: one recovery entry per writer generation (design note
// 2026-11-04-r1-recovery-per-writer, section 7). Failed autosaves keep their
// edits; entries are never replaced; an entry is retired only after its edits
// have landed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose compare-and-swap saves fail while [failSave] is set.
class _FlakyStore extends PageStore {
  _FlakyStore(super.directory);

  bool failSave = false;

  /// Runs just before every compare-and-swap save.
  void Function()? onSave;

  /// Held up in the next compare-and-delete until it completes.
  Future<void>? deleteGate;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) {
    onSave?.call();
    if (failSave) throw const FileSystemException('disk error');
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforePublish: beforePublish,
      beforeRestore: beforeRestore,
    );
  }

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) async {
    final gate = deleteGate;
    deleteGate = null;
    if (gate != null) await gate;
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
  }
}

final _modules = buildModules();

Map<String, Object?> _doc(String text) => {
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

// A note box: the editor can delete it.
BoxRecord _box(String id, int n) {
  final codec = _modules.codecs.codecFor('noted.note')!;
  final at = Bounds(10.0 + 300 * n, 10, 200, 40);
  return commitBox(
    createBox(codec, at).withId(id),
    codec,
    codec.decode(_doc('text $n'), 1),
  );
}

// A box of a type no module runs: two versions of it can only conflict.
BoxRecord _other(String id, int n, {String rev = 'r'}) => BoxRecord.create(
  id: id,
  typeId: 'test.other',
  dataVersion: 1,
  bounds: Bounds(10.0 + 300 * n, 10, 100, 40),
  data: RawJson.encode({'n': n}),
  snapshotText: 's$n',
  rev: '$rev$n',
);

void main() {
  late Directory root;
  late Directory pages;
  late Directory rec;
  late List<Notebook> opened;
  late _FlakyStore flaky;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_r1');
    pages = await Directory('${root.path}/pages').create();
    rec = Directory('${root.path}/rec');
    opened = [];
    flaky = _FlakyStore(pages);
  });

  tearDown(() async {
    for (final nb in opened) {
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({PageStore? store, Future<void> Function(String)? hook}) {
    final nb = Notebook(
      store ?? flaky,
      buildModules(),
      saveDelay: const Duration(hours: 1), // saves happen only through flush
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    nb.recoveryHook = hook;
    opened.add(nb);
    return nb;
  }

  void quit(Notebook nb) {
    nb.dispose();
    opened.remove(nb);
  }

  File pageFile(String id) => File('${pages.path}/$id.canvas');
  NotedPage disk(String id) => readPage(pageFile(id).readAsStringSync());
  Set<String> ids(NotedPage p) => {for (final n in p.nodes) n.id};
  RecoveryStore store() => RecoveryStore(rec);
  Future<List<RecoveryEntry>> entries(Notebook nb) async =>
      (await nb.pendingRecovery()).entries;
  List<String> recNames() => rec.existsSync()
      ? [
          for (final f in rec.listSync().whereType<File>())
            f.path.split(RegExp(r'[\\/]')).last,
        ]
      : const [];

  // Two pages in the default folder, both saved; [a] is open.
  Future<(Notebook, String, String)> twoPages({
    Future<void> Function(String)? hook,
  }) async {
    final nb = make(hook: hook);
    await nb.load();
    final a = nb.currentId!;
    final b = await nb.createPage();
    await nb.open(a);
    await nb.flush();
    return (nb, a, b);
  }

  // Writes an entry for page [id] whose edit adds [boxes] to the file as it is.
  Future<RecoveryEntry> entryAdding(
    String id,
    List<BoxRecord> boxes, {
    String kind = 'edit',
    DateTime? time,
  }) {
    final text = pageFile(id).readAsStringSync();
    var p = readPage(text);
    for (final b in boxes) {
      p = p.insertNode(b);
    }
    return store().write(
      folder: pages.path,
      page: p,
      baseText: text,
      time: time ?? DateTime.now(),
      kind: kind,
    );
  }

  Future<void> unreadable(Notebook nb, String id) async {
    final f = pageFile(id);
    f.writeAsStringSync(
      f.readAsStringSync().replaceFirst(
        RegExp(r'"format"\s*:\s*1'),
        '"format":99',
      ),
    );
    await nb.checkFile(f.path);
  }

  group('failed autosaves keep their edits', () {
    test('a publish that keeps failing, then leaving the page: the edit is in recovery and lands later', () async {
      final (nb, a, b) = await twoPages();
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final added = ids(nb.current!.page);
      flaky.failSave = true;
      await nb.flush();
      expect(ids(disk(a)), isNot(containsAll(added)));
      expect(await entries(nb), hasLength(1));
      await nb.open(b); // leaving the page; still failing
      quit(nb);
      flaky.failSave = false;
      final again = make();
      await again.load();
      expect(ids(disk(a)), containsAll(added));
      expect(await entries(again), isEmpty);
    });

    test('the user is told once per failure streak, and a landed save ends the streak', () async {
      final (nb, a, _) = await twoPages();
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      nb.current!.createBoxAt(const Bounds(400, 40, 0, 0));
      await nb.flush();
      await Future<void>.delayed(Duration.zero);
      expect(notices.where((n) => n.contains("Couldn't save")), hasLength(1));
      // Still one entry: the session's newer generation replaced its own older one.
      expect(await entries(nb), hasLength(1));
      flaky.failSave = false;
      await nb.flush();
      expect(ids(disk(a)), ids(nb.current!.page));
      expect(await entries(nb), isEmpty);
      expect(nb.unsavedDescription, isNull);
    });

    test('a second streak is told again', () async {
      final (nb, _, _) = await twoPages();
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      for (var i = 0; i < 2; i++) {
        flaky.failSave = true;
        nb.current!.createBoxAt(Bounds(40.0 + 300 * i, 40, 0, 0));
        await nb.flush();
        flaky.failSave = false;
        await nb.flush();
      }
      await Future<void>.delayed(Duration.zero);
      expect(notices.where((n) => n.contains("Couldn't save")), hasLength(2));
    });

    test('when recovery can not be written the edits are held in memory and counted', () async {
      final (nb, a, _) = await twoPages();
      File(rec.path)
          .createSync(recursive: true); // a file where the folder should be
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      expect(nb.unsavedPageCount, 1);
      expect(nb.unsavedDescription, contains('kept in memory'));
      File(rec.path).deleteSync();
      flaky.failSave = false;
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect(ids(disk(a)), ids(nb.current!.page));
    });

    test('a folder with edits held in memory is not removed without asking', () async {
      final (nb, _, _) = await twoPages();
      final extra = await Directory('${root.path}/Elsewhere').create();
      final other = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      await nb.open(other);
      File(rec.path).createSync(recursive: true);
      final st = nb;
      expect(st.unsavedPageCount, 0);
      // The default store fails, the extra folder is a different store: use the
      // default folder's page instead.
      File(rec.path).deleteSync();
      await nb.removeStandaloneFolder(extra.path);
    });
  });

  group('folding and retiring', () {
    test('(1) a box deleted in the reopened page before its file turned unreadable is not merged back', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      final e = await entryAdding(a, [_box('e1', 1)]);
      flaky.failSave = true; // the folded entry does not land
      await nb.open(a); // folds the entry
      expect(nb.current!.page.node('e1'), isNotNull);
      nb.current!.delete('e1');
      final readable = pageFile(a).readAsStringSync();
      await unreadable(
        nb,
        a,
      ); // the block keeps the edits (without e1) in a newer entry
      await nb.open(b);
      pageFile(a).writeAsStringSync(readable);
      flaky.failSave = false;
      quit(nb);
      final again = make();
      await again.load();
      expect(
        disk(a).node('e1'),
        isNull,
        reason: 'the older entry is superseded, not merged back',
      );
      expect(await entries(again), isEmpty);
      expect(e.gen, isNotEmpty);
    });

    test('(2) a failed save writes its own entry beside an AI entry and leaves it byte for byte', () async {
      final (nb, a, _) = await twoPages();
      final ai = await entryAdding(a, [_box('ai1', 1)], kind: 'ai');
      final before = ai.file.readAsBytesSync();
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(nb.current!.page);
      await nb.flush();
      expect(ai.file.readAsBytesSync(), before);
      expect((await entries(nb)).map((e) => e.kind).toSet(), {'ai', 'edit'});
      quit(nb);
      flaky.failSave = false;
      final again = make();
      await again.load();
      expect(ids(disk(a)), containsAll({...mine, 'ai1'}));
      expect(await entries(again), isEmpty);
    });

    test('(3) the open page\'s save retires only the entries it folded; an entry written meanwhile stays', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      final folded = await entryAdding(a, [_box('e1', 1)]);
      await nb.open(a);
      final later = await entryAdding(a, [_box('ai1', 2)], kind: 'ai');
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      final left = await entries(nb);
      expect(left.map((e) => e.gen), [later.gen]);
      expect(disk(a).node('e1'), isNotNull);
      expect(folded.gen, isNot(later.gen));
    });

    test('(5) E\'s replay failed; the user opens the page, edits, the publish fails, switches page and restarts: both edits land', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      final e = await entryAdding(a, [_box('e1', 1)]);
      quit(nb);
      flaky.failSave = true; // the replay at launch is busy
      final again = make();
      await again.load();
      expect(await entries(again), hasLength(1));
      await again.open(a);
      again.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(again.current!.page);
      expect(mine, contains('e1'));
      await again.flush(); // the publish fails with the folder present
      await again.open(b);
      quit(again);
      flaky.failSave = false;
      final third = make();
      await third.load();
      expect(ids(disk(a)), containsAll(mine));
      expect(await entries(third), isEmpty);
      expect(e.gen, isNotEmpty);
    });

    test('(5b) the same with the recovery listing failing at open', () async {
      var listFails = false;
      final (nb, a, b) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) {
            throw const FileSystemException('listing failed');
          }
        },
      );
      await nb.open(b);
      await entryAdding(a, [_box('e1', 1)]);
      listFails = true;
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      flaky.failSave = true;
      await nb.open(a); // opens from the file, with a notice
      await Future<void>.delayed(Duration.zero);
      expect(notices.join(), contains("couldn't be read"));
      expect(nb.current!.page.node('e1'), isNull);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(nb.current!.page);
      await nb.flush(); // fails: a second entry sits beside E
      listFails = false;
      expect(await entries(nb), hasLength(2));
      await nb.open(b);
      quit(nb);
      flaky.failSave = false;
      final again = make();
      await again.load();
      expect(ids(disk(a)), containsAll({...mine, 'e1'}));
      expect(await entries(again), isEmpty);
    });

    test('(6) an older entry that may have landed comes back with the landed marker, only for the box the file lacks', () async {
      final (nb, a, _) = await twoPages();
      final y = _box('y1', 2);
      final e = await entryAdding(a, [_other('x1', 1), y]);
      expect(
        (await store().markLanding([e])).ok,
        isTrue,
      ); // a replay stopped after this
      // Another device has y but deleted x.
      pageFile(a).writeAsStringSync(writePage(disk(a).insertNode(y)));
      quit(nb);
      final again = make();
      await again.load();
      final page = disk(a);
      expect((page.node('x1')! as BoxRecord).landed, isNotNull);
      expect((page.node('y1')! as BoxRecord).landed, isNull);
      expect(await entries(again), isEmpty);
    });

    test('(7)(15) an entry that deletes a box the file still has lands, and is retired', () async {
      final (nb, a, _) = await twoPages();
      pageFile(a)
          .writeAsStringSync(writePage(disk(a).insertNode(_box('d1', 1))));
      final text = pageFile(a).readAsStringSync();
      await store().write(
        folder: pages.path,
        page: disk(a).removeNode('d1'),
        baseText: text,
        time: DateTime.now(),
      );
      quit(nb);
      final again = make();
      await again.load();
      expect(disk(a).node('d1'), isNull);
      expect(await entries(again), isEmpty);
    });

    test('(8) two entries, one deleting a box the other left unchanged: both land, the box stays deleted', () async {
      final (nb, a, _) = await twoPages();
      pageFile(a)
          .writeAsStringSync(writePage(disk(a).insertNode(_box('d1', 1))));
      final text = pageFile(a).readAsStringSync();
      final t0 = DateTime.now();
      await store().write(
        folder: pages.path,
        page: disk(a).removeNode('d1'),
        baseText: text,
        time: t0,
      );
      await store().write(
        folder: pages.path,
        page: disk(a).insertNode(_box('g1', 2)),
        baseText: text,
        time: t0.add(const Duration(seconds: 1)),
      );
      quit(nb);
      final again = make();
      await again.load();
      expect(ids(disk(a)), containsAll({'g1'}));
      expect(disk(a).node('d1'), isNull);
      expect(await entries(again), isEmpty);
    });

    test('(9) a retire that fails: the entry is not folded again in this session, and is retired on backoff', () async {
      var failRetire = true;
      final (nb0, a, b) = await twoPages();
      await entryAdding(a, [_box('e1', 1)]);
      quit(nb0);
      final nb = make(
        hook: (p) async {
          if (failRetire && p == 'retire-before-delete') {
            throw const FileSystemException('locked');
          }
        },
      );
      await nb.load();
      expect(disk(a).node('e1'), isNotNull, reason: 'landed');
      expect(
        recNames().where((n) => n.endsWith('.landing')),
        hasLength(1),
        reason: 'retire failed',
      );
      await nb.open(a);
      nb.current!.delete('e1'); // the user deletes a recovered box
      await nb.open(b);
      await nb.open(a); // not folded again: it is waiting to be retired
      expect(nb.current!.page.node('e1'), isNull);
      expect(disk(a).node('e1'), isNull);
      failRetire = false;
      await nb.flush(); // the backoff's retry
      expect(recNames(), isEmpty);
      expect(disk(a).node('e1'), isNull);
    });

    test('retire completes, the user deletes a recovered box, a restart: the box stays deleted', () async {
      final (nb0, a, _) = await twoPages();
      await entryAdding(a, [_box('e1', 1)]);
      quit(nb0);
      final nb = make();
      await nb.load();
      expect(recNames(), isEmpty);
      await nb.open(a);
      nb.current!.delete('e1');
      await nb.flush();
      quit(nb);
      final again = make();
      await again.load();
      expect(disk(a).node('e1'), isNull);
    });

    test(
      '(10) a replay queued before an open runs first: no stale base',
      () async {
        final (nb, a, b) = await twoPages();
        await nb.open(b);
        flaky.failSave = true;
        await entryAdding(a, [_box('e1', 1)]);
        quit(nb);
        final again = make();
        await again.load(); // the replay fails; tracked
        await again.open(b); // page a is closed now
        flaky.failSave = false;
        unawaited(again.flush()); // the backoff's retry is queued
        await again.open(a);
        expect(again.current!.page.node('e1'), isNotNull);
        expect(disk(a).node('e1'), isNotNull);
        await again.flush();
        expect(await entries(again), isEmpty);
      },
    );

    test('(10) a replay that is running when a delete starts is waited for: the deleted page is not written again', () async {
      final (nb0, _, b) = await twoPages();
      await entryAdding(b, [_box('e1', 1)]);
      quit(nb0);
      flaky.failSave = true;
      final nb = make();
      await nb.load(); // the replay of page b fails; it is tracked, and page a is open
      flaky.failSave = false;
      final reached = Completer<void>();
      final gate = Completer<void>();
      nb.syncHook = (p, _) async {
        if (p != 'recover-reread' || reached.isCompleted) return;
        reached.complete();
        await gate.future;
      };
      unawaited(nb.flush()); // the retry of page b starts and stops at the reread
      await reached.future;
      final deleting = nb.delete(b);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      final deleted = await deleting;
      await nb.flush();
      expect(pageFile(b).existsSync(), isFalse);
      expect(deleted.pages.single.node('e1'), isNotNull, reason: 'the undo copy holds the kept edit');
      expect(recNames(), isEmpty);
    });

    test('(11) crash leftovers: a .cas-old entry is read and folds, a hard-linked tmp is deleted', () async {
      final (nb0, a, _) = await twoPages();
      final e = await entryAdding(a, [_box('e1', 1)]);
      quit(nb0);
      final bytes = e.file.readAsBytesSync();
      e.file.deleteSync();
      File('${e.file.path}.99-a-b.cas-old').writeAsBytesSync(bytes);
      File('${e.file.path}.5-5.tmp').writeAsBytesSync(bytes);
      final nb = make();
      await nb.load();
      expect(disk(a).node('e1'), isNotNull);
      expect(recNames(), isEmpty);
    });

    test(
      '(12) downgrade: a format 2 slot beside format 3 entries, all fold',
      () async {
        final (nb0, a, _) = await twoPages();
        final e3 = await entryAdding(a, [_box('e3', 1)]);
        final stem = e3.file.path
            .split(RegExp(r'[\\/]'))
            .last
            .split('.g')
            .first;
        final text = pageFile(a).readAsStringSync();
        File('${rec.path}/$stem.entry').writeAsStringSync(
          jsonEncode({
            'format': 2,
            'folder': pages.path,
            'pageId': a,
            'time': DateTime.now().toUtc().toIso8601String(),
            'base': text,
            'page': writePage(disk(a).insertNode(_box('e2', 2))),
          }),
        );
        quit(nb0);
        final nb = make();
        await nb.load();
        expect(ids(disk(a)), containsAll({'e2', 'e3'}));
        expect(recNames(), isEmpty);
      },
    );

    test('(13) equal times fold in the order of the generation, the same after a reload', () async {
      final (nb0, a, _) = await twoPages();
      quit(nb0);
      final text = pageFile(a).readAsStringSync();
      final base = disk(a).insertNode(_other('x1', 0));
      pageFile(a).writeAsStringSync(writePage(base));
      final baseText = writePage(base);
      final at = DateTime.utc(2026, 11, 4, 12);
      final e1 = await store().write(
        folder: pages.path,
        page: base.replaceNode(_other('x1', 1)),
        baseText: baseText,
        time: at,
      );
      final e2 = await store().write(
        folder: pages.path,
        page: base.replaceNode(_other('x1', 2)),
        baseText: baseText,
        time: at,
      );
      expect(text, isNotEmpty);
      final last = e1.gen.compareTo(e2.gen) < 0
          ? 2
          : 1; // the greater generation is folded last
      final copy = Directory('${root.path}/rec-copy')..createSync();
      for (final f in rec.listSync().whereType<File>()) {
        f.copySync('${copy.path}/${f.path.split(RegExp(r'[\\/]')).last}');
      }
      final saved = pageFile(a).readAsStringSync();
      Future<String> run(Directory r) async {
        pageFile(a).writeAsStringSync(saved);
        final nb = Notebook(
          flaky,
          buildModules(),
          saveDelay: const Duration(hours: 1),
          bindersFile: File('${root.path}/app/binders.json'),
          recoveryDirectory: r,
          folderCheckInterval: Duration.zero,
        );
        opened.add(nb);
        await nb.load();
        final out = pageFile(a).readAsStringSync();
        quit(nb);
        return out;
      }

      final first = await run(rec);
      final second = await run(copy);
      List<String?> conflicts(String text) => [
        for (final c in (readPage(text).node('x1')! as BoxRecord).conflicts)
          c.node?.text,
      ];
      expect(conflicts(second), conflicts(first));
      final box = readPage(first).node('x1')! as BoxRecord;
      expect(
        box.snapshotText,
        's$last',
        reason: 'mine is the entry folded last',
      );
    });

    for (final point in [
      'recover-landing',
      'recover-published',
      'recover-readback',
      'rename-back',
    ]) {
      test(
        '(16) crash at $point: the box another device deleted comes back with the landed marker, nothing else does',
        () async {
          final (nb0, _, a) = await twoPages();
          final y = _box('y1', 2);
          final e = await entryAdding(a, [_other('x1', 1), y]);
          quit(nb0);
          final st = _FlakyStore(pages);
          final nb = Notebook(
            st,
            buildModules(),
            saveDelay: const Duration(hours: 1),
            bindersFile: File('${root.path}/app/binders.json'),
            recoveryDirectory: rec,
            folderCheckInterval: Duration.zero,
          );
          opened.add(nb);
          nb.syncHook = (p, _) async {
            if (point == 'rename-back') {
              if (p == 'recover-landing') {
                // The rename back will find a folder at the `.entry` name and fail.
                Directory(e.file.path).createSync();
                st.failSave = true;
              }
            } else if (p == point) {
              nb.dispose(); // the process is gone: nothing runs after this
              opened.remove(nb);
              throw StateError('crash at $point');
            }
          };
          try {
            await nb.load();
          } on Object catch (_) {
            // A notebook that was disposed under its own load.
          }
          if (opened.contains(nb)) quit(nb);
          if (Directory(e.file.path).existsSync()) {
            Directory(e.file.path).deleteSync();
          }
          expect(
            recNames().where((n) => n.endsWith('.landing')),
            hasLength(1),
            reason: point,
          );
          // Another device deletes x1 (and the page has y1 as the entry left it).
          var f = disk(a);
          if (f.node('x1') != null) f = f.removeNode('x1');
          if (f.node('y1') == null) f = f.insertNode(y);
          pageFile(a).writeAsStringSync(writePage(f));
          final restart = make();
          await restart.load();
          final page = disk(a);
          expect(
            (page.node('x1')! as BoxRecord).landed,
            isNotNull,
            reason: point,
          );
          expect((page.node('y1')! as BoxRecord).landed, isNull, reason: point);
          expect(await entries(restart), isEmpty, reason: point);
          quit(restart);
        },
      );
    }

    test('a conflicted publish folds to the same page after a crash before the retire (R-2 of design review 3)', () async {
      final (nb0, a, _) = await twoPages();
      pageFile(a)
          .writeAsStringSync(writePage(disk(a).insertNode(_other('x1', 0))));
      final baseText = pageFile(a).readAsStringSync();
      await store().write(
        folder: pages.path,
        page: disk(a).replaceNode(_other('x1', 1)),
        baseText: baseText,
        time: DateTime.now(),
      );
      // The file changes the same box differently; test.other has no codec to merge.
      pageFile(a)
          .writeAsStringSync(writePage(disk(a).replaceNode(_other('x1', 2))));
      quit(nb0);
      final nb = make();
      nb.syncHook = (p, _) async {
        if (p == 'recover-readback') {
          throw StateError('crash before the retire');
        }
      };
      await nb.load();
      quit(nb);
      final published = pageFile(a).readAsStringSync();
      final conflicts =
          (readPage(published).node('x1')! as BoxRecord).conflicts.length;
      expect(conflicts, 1);
      final again = make();
      await again.load();
      expect(
        pageFile(a).readAsStringSync(),
        published,
        reason: 'out == F: nothing new is published',
      );
      expect(
        (readPage(published).node('x1')! as BoxRecord).conflicts,
        hasLength(conflicts),
      );
      expect(await entries(again), isEmpty);
    });
  });

  group('delete and move', () {
    test('(delete) kept edits go into the undo copy, and their entries are retired', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      await entryAdding(a, [_box('e1', 1)]);
      final deleted = await nb.delete(a);
      expect(deleted.pages.single.node('e1'), isNotNull);
      expect(recNames(), isEmpty);
      await nb.undoDelete(deleted);
      expect(disk(a).node('e1'), isNotNull);
    });

    test(
      '(move) kept edits move with the page, and their entries are retired',
      () async {
        final (nb, a, b) = await twoPages();
        final extra = await Directory('${root.path}/Elsewhere').create();
        await nb.addStandaloneFolder(extra.path);
        await nb.open(b);
        await entryAdding(a, [_box('e1', 1)]);
        await nb.moveToFolder(a, extra.path);
        final moved = readPage(
          File('${extra.path}/$a.canvas').readAsStringSync(),
        );
        expect(moved.node('e1'), isNotNull);
        expect(pageFile(a).existsSync(), isFalse);
        expect(recNames(), isEmpty);
      },
    );

    test('a delete refuses when the recovery folder can not be listed, and changes nothing', () async {
      var listFails = false;
      final (nb, a, _) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) {
            throw const FileSystemException('listing failed');
          }
        },
      );
      listFails = true;
      await expectLater(nb.delete(a), throwsA(isA<NotebookException>()));
      listFails = false;
      expect(pageFile(a).existsSync(), isTrue);
      expect(nb.current, isNotNull);
    });

    test(
      '(14) a flush while pages are deleted in two trees completes',
      () async {
        final (nb, a, b) = await twoPages();
        final c = await nb.createPage(parentId: a);
        final d = await nb.createPage(parentId: b);
        await nb.flush();
        await entryAdding(c, [_box('e1', 1)]);
        await entryAdding(d, [_box('e2', 2)]);
        final f1 = nb.delete(a);
        unawaited(nb.flush());
        await f1.timeout(const Duration(seconds: 30));
        final f2 = nb.delete(b);
        unawaited(nb.flush());
        await f2.timeout(const Duration(seconds: 30));
        await nb.flush().timeout(const Duration(seconds: 30));
        expect(recNames(), isEmpty);
      },
    );
  });

  group('the quit notice', () {
    test(
      '(19) counts pages, not entries, and leaves out landed ones',
      () async {
        final (nb, a, b) = await twoPages();
        await entryAdding(a, [_box('e1', 1)]);
        await entryAdding(a, [_box('e2', 2)]);
        final landed = await entryAdding(b, [_box('e3', 3)]);
        expect(
          await nb.pendingRecoveryPages(),
          2,
          reason: 'two pages, three entries',
        );
        // The third entry landed: its page holds the edit; it may still be .landing.
        pageFile(b)
            .writeAsStringSync(writePage(disk(b).insertNode(_box('e3', 3))));
        expect((await store().markLanding([landed])).ok, isTrue);
        expect(await nb.pendingRecoveryPages(), 1);
      },
    );
  });

  group('review round: copies held in memory and the order of things', () {
    BoxRecord same(int n) => BoxRecord.create(
      id: 'x1',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(500, 500, 100, 40),
      data: RawJson.encode({'n': n}),
      snapshotText: 's$n',
      rev: 'same',
    );

    // Page a holds an edit in memory only: recovery is a file.
    Future<(Notebook, String, String, Set<String>)> held() async {
      final (nb, a, b) = await twoPages();
      File(rec.path).createSync(recursive: true);
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(nb.current!.page);
      await nb.flush();
      expect(nb.unsavedPageCount, 1);
      await nb.open(b);
      return (nb, a, b, mine);
    }

    // An edit held for a that the fold rejects (see debugUnfit).
    void holdUnfit(Notebook nb, String a) {
      pageFile(a).writeAsStringSync(writePage(disk(a).insertNode(same(0))));
      final base = pageFile(a).readAsStringSync();
      nb.debugHold(a, readPage(base).replaceNode(same(1)), base);
    }

    test('(blocking 1) a held copy is folded in when the page opens although the listing fails, and is not lost', () async {
      var listFails = false;
      final (nb, a, b) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) throw const FileSystemException('listing failed');
        },
      );
      File(rec.path).createSync(recursive: true);
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(nb.current!.page);
      await nb.flush();
      expect(nb.unsavedPageCount, 1);
      await nb.open(b);
      listFails = true;
      await nb.open(a); // the listing fails: opens from the file, with the held copy
      expect(ids(nb.current!.page), containsAll(mine));
      flaky.failSave = false;
      await nb.flush();
      expect(ids(disk(a)), containsAll(mine), reason: 'the edit landed');
      expect(nb.unsavedPageCount, 0);
    });

    test('a closed page\'s held copy is folded in by the retry and lands', () async {
      final (nb, a, _, mine) = await held();
      flaky.failSave = false;
      File(rec.path).deleteSync();
      await nb.flush();
      expect(ids(disk(a)), containsAll(mine));
      expect(nb.unsavedPageCount, 0);
    });

    test('(6) a seed made from a held copy is written to recovery by a failed save once recovery works', () async {
      final (nb, a, _, mine) = await held();
      await nb.open(a); // folds the held copy
      File(rec.path).deleteSync(); // recovery works now
      await nb.flush(); // the save still fails
      final kept = await entries(nb);
      expect(kept, hasLength(1));
      expect(ids(kept.single.page), containsAll(mine));
      expect(nb.unsavedPageCount, 0);
    });

    for (final how in ['deleted elsewhere', 'unreadable']) {
      test('(blocking 2) a held copy outlives its page ($how): kept and counted, then written to recovery', () async {
        final (nb, a, _, mine) = await held();
        if (how == 'unreadable') {
          await unreadable(nb, a);
        } else {
          pageFile(a).deleteSync();
          await nb.checkFile(pageFile(a).path);
        }
        await nb.flush();
        await nb.flush();
        expect(nb.unsavedPageCount, 1, reason: 'still held and counted');
        File(rec.path).deleteSync();
        await nb.flush();
        expect(nb.unsavedPageCount, 0);
        final kept = await entries(nb);
        expect(kept.single.pageId, a);
        expect(ids(kept.single.page), containsAll(mine));
        quit(nb);
        if (how == 'unreadable') {
          pageFile(a).writeAsStringSync(pageFile(a).readAsStringSync().replaceFirst('"format":99', '"format":1'));
        }
        flaky.failSave = false;
        final again = make();
        await again.load();
        expect(ids(disk(a)), containsAll(mine));
        expect(await entries(again), isEmpty);
      });
    }

    test('(blocking 2) a delete with an unfit held copy keeps it held and lists it', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      holdUnfit(nb, a);
      nb.debugUnfit.add('held');
      File(rec.path).createSync(recursive: true);
      await nb.delete(a);
      expect(nb.unsavedPageCount, 1);
      expect(nb.recoveryProblems.join(), contains('did not make it into the saved page'));
      expect(nb.recoveryDamaged, isNotEmpty);
      await nb.flush();
      expect(nb.unsavedPageCount, 1, reason: 'recovery can not take it yet');
      File(rec.path).deleteSync();
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect((await entries(nb)).single.page.node('x1'), isNotNull);
      expect(nb.recoveryProblems, isEmpty);
    });

    test('(blocking 2) a move with an unfit held copy keeps it held and lists it', () async {
      final (nb, a, b) = await twoPages();
      final extra = await Directory('${root.path}/Elsewhere').create();
      await nb.addStandaloneFolder(extra.path);
      await nb.open(b);
      holdUnfit(nb, a);
      nb.debugUnfit.add('held');
      File(rec.path).createSync(recursive: true);
      await nb.moveToFolder(a, extra.path);
      expect(nb.unsavedPageCount, 1);
      expect(nb.recoveryProblems.join(), contains('did not make it into the saved page'));
      await nb.flush();
      expect(nb.unsavedPageCount, 1);
      File(rec.path).deleteSync();
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
    });

    test('(3) a replay that starts while a delete holds the page does not touch it', () async {
      final (nb0, _, b) = await twoPages();
      await entryAdding(b, [_box('e1', 1)]);
      quit(nb0);
      var failRetire = true;
      Completer<void>? atRetire;
      final release = Completer<void>();
      final nb = make(
        hook: (p) async {
          if (p != 'retire-before-delete') return;
          if (failRetire) throw const FileSystemException('locked');
          final reached = atRetire;
          if (reached != null && !reached.isCompleted) {
            reached.complete();
            await release.future;
          }
        },
      );
      await nb.load(); // e1 lands; its entry waits to be retired
      failRetire = false;
      await entryAdding(b, [_box('e2', 2)]); // a live entry the delete will fold
      atRetire = Completer<void>();
      unawaited(nb.flush()); // the retry of page b stops while retiring the waiting entry
      await atRetire.future;
      final gate = Completer<void>();
      flaky.deleteGate = gate.future;
      final deleting = nb.delete(b); // holds b, folds e2, stops before deleting the file
      await Future<void>.delayed(const Duration(milliseconds: 100));
      release.complete(); // the retry goes on: it must see the hold
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gate.complete();
      final deleted = await deleting;
      await nb.flush();
      expect(pageFile(b).existsSync(), isFalse, reason: 'the replay did not write the page');
      expect(deleted.pages.single.node('e2'), isNotNull);
      expect(recNames(), isEmpty);
    });

    test('(4) equal times fold in generation order, not in the order the listing reads the files', () async {
      final (nb0, a, _) = await twoPages();
      quit(nb0);
      final base = disk(a).insertNode(_other('x1', 0));
      pageFile(a).writeAsStringSync(writePage(base));
      final baseText = writePage(base);
      final at = DateTime.utc(2026, 11, 4, 12);
      final v3 = await store().write(
        folder: pages.path,
        page: base.replaceNode(_other('x1', 1)),
        baseText: baseText,
        time: at,
      );
      // A format 2 file: its generation sorts after every hex one, while its file
      // name sorts before every format 3 name.
      final stem = v3.file.path.split(RegExp(r'[\\/]')).last.split('.g').first;
      File('${rec.path}/$stem.entry').writeAsStringSync(
        jsonEncode({
          'format': 2,
          'folder': pages.path,
          'pageId': a,
          'time': at.toIso8601String(),
          'base': baseText,
          'page': writePage(base.replaceNode(_other('x1', 2))),
        }),
      );
      final again = make();
      await again.load();
      final box = disk(a).node('x1')! as BoxRecord;
      expect(box.snapshotText, 's2', reason: 'the format 2 entry is folded last: its generation is the greater');
    });

    test('ancestors are retired first: a retire that stops after one leaves the superseding entry', () async {
      final (nb0, a, _) = await twoPages();
      final e = await entryAdding(a, [_box('e1', 1)]);
      final text = pageFile(a).readAsStringSync();
      final e2 = await store().write(
        folder: pages.path,
        page: disk(a).insertNode(_box('e2', 2)),
        baseText: text,
        time: DateTime.now().add(const Duration(seconds: 1)),
        supersedes: [e.gen],
      );
      quit(nb0);
      var retires = 0;
      final nb = make(
        hook: (p) async {
          if (p == 'retire-before-delete' && ++retires >= 2) throw const FileSystemException('locked');
        },
      );
      await nb.load();
      expect(recNames(), hasLength(1));
      expect(recNames().single, contains(e2.gen), reason: 'the ancestor went first');
    });

    test('(2) the listing fails during a failed save: the AI entry stays byte for byte, and both edits land', () async {
      var listFails = false;
      final (nb, a, _) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) throw const FileSystemException('listing failed');
        },
      );
      final ai = await entryAdding(a, [_box('ai1', 1)], kind: 'ai');
      final before = ai.file.readAsBytesSync();
      flaky.failSave = true;
      listFails = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final mine = ids(nb.current!.page);
      await nb.flush();
      listFails = false;
      expect(ai.file.readAsBytesSync(), before);
      quit(nb);
      flaky.failSave = false;
      final again = make();
      await again.load();
      expect(ids(disk(a)), containsAll({...mine, 'ai1'}));
    });

    test('(14) the replay of the open page while its autosave is pending completes', () async {
      final (nb, a, _) = await twoPages();
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final moved = Directory('${root.path}/pages-away');
      await pages.rename(moved.path);
      await nb.checkFolders(); // the folder is gone: the edit goes to an entry
      expect(await entries(nb), hasLength(1));
      // The other device adds a box meanwhile; merging it makes the page save.
      final away = File('${moved.path}/$a.canvas');
      away.writeAsStringSync(writePage(readPage(away.readAsStringSync()).insertNode(_box('theirs', 3))));
      await moved.rename(pages.path);
      await nb.checkFolders().timeout(const Duration(seconds: 30));
      await nb.flush().timeout(const Duration(seconds: 30));
      expect(disk(a).node('theirs'), isNotNull);
      expect(ids(disk(a)), containsAll(ids(nb.current!.page)));
      expect(await entries(nb), isEmpty);
    });

    test('(8) only the entries no other one supersedes are marked landing', () async {
      final (nb0, a, b) = await twoPages();
      await nb0.open(b);
      final e = await entryAdding(a, [_box('e1', 1)]);
      quit(nb0);
      flaky.failSave = true;
      final nb = make();
      await nb.load(); // the replay fails; the open page folds the entry
      await nb.open(a);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush(); // fails: a generation that supersedes the entry
      expect(await entries(nb), hasLength(2));
      flaky.failSave = false;
      List<String>? seen;
      flaky.onSave = () => seen = recNames().where((n) => n.endsWith('.landing')).toList();
      await nb.flush();
      expect(seen, hasLength(1), reason: 'the superseded entry keeps its name');
      expect(seen!.single, isNot(contains(e.gen)));
      expect(recNames(), isEmpty);
    });
  });

  group('review round 2: an unfit copy held in memory', () {
    BoxRecord same(int n) => BoxRecord.create(
      id: 'x1',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(500, 500, 100, 40),
      data: RawJson.encode({'n': n}),
      snapshotText: 's$n',
      rev: 'same',
    );

    // An edit held for a that the fold rejects (see debugUnfit); recovery is a file.
    Future<(Notebook, String, String)> unfitHeld({bool recoveryWorks = false}) async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      pageFile(a).writeAsStringSync(writePage(disk(a).insertNode(same(0))));
      final base = pageFile(a).readAsStringSync();
      nb.debugHold(a, readPage(base).replaceNode(same(1)), base);
      nb.debugUnfit.add('held');
      if (!recoveryWorks) File(rec.path).createSync(recursive: true);
      return (nb, a, b);
    }

    test('(blocking 1) a session entry written without the unfit copy does not clear it', () async {
      final (nb, a, _) = await unfitHeld();
      await nb.open(a); // opens without the copy: it is unfit
      expect(nb.unsavedPageCount, 1);
      File(rec.path).deleteSync(); // recovery works now
      flaky.failSave = true;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush(); // the publish fails: a session entry, without the copy
      expect(await entries(nb), hasLength(1));
      expect(nb.unsavedPageCount, 1, reason: 'the copy is still only in memory');
    });

    test('(2) a save made without the unfit copy does not clear it', () async {
      final (nb, a, _) = await unfitHeld();
      await nb.open(a);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush(); // saves work
      expect(ids(disk(a)), ids(nb.current!.page));
      expect(nb.unsavedPageCount, 1);
    });

    test('(3) an unfit copy whose page stays in place is written to recovery', () async {
      final (nb, a, _) = await unfitHeld(recoveryWorks: true);
      await nb.flush(); // the retry replays page a: the copy is unfit
      expect(nb.unsavedPageCount, 0);
      final kept = await entries(nb);
      expect(kept.single.pageId, a);
      expect((kept.single.page.node('x1')! as BoxRecord).snapshotText, 's1');
      expect(nb.recoveryProblems, isEmpty, reason: 'the held-copy note goes with the copy');
    });

    test('(5) a held copy the open page does not show does not make it save on every retry', () async {
      final (nb, a, _) = await unfitHeld();
      await nb.open(a);
      var saves = 0;
      flaky.onSave = () => saves++;
      await nb.flush();
      await nb.flush();
      expect(saves, 0);
    });

    test('(4) entries a held copy was built on are retired once the listing works again', () async {
      var listFails = false;
      final (nb, a, b) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) throw const FileSystemException('listing failed');
        },
      );
      await nb.open(b);
      final old = await entryAdding(a, [_box('e1', 1)]);
      nb.debugHold(
        a,
        disk(a).insertNode(_box('e1', 1)),
        pageFile(a).readAsStringSync(),
        supersedes: [old.gen],
      );
      listFails = true;
      await nb.open(a); // the listing fails: the copy is folded in, its ancestors not retired
      listFails = false;
      await nb.flush();
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect(recNames(), isEmpty, reason: 'the superseded entry must not become live again');
      expect(disk(a).node('e1'), isNotNull);
    });
  });

  group('review round 3: ancestors of a held copy, backoff writes of held copies', () {
    BoxRecord same(int n) => BoxRecord.create(
      id: 'x1',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(500, 500, 100, 40),
      data: RawJson.encode({'n': n}),
      snapshotText: 's$n',
      rev: 'same',
    );

    Future<(Notebook, String, String)> unfitHeld() async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      pageFile(a).writeAsStringSync(writePage(disk(a).insertNode(same(0))));
      final base = pageFile(a).readAsStringSync();
      nb.debugHold(a, readPage(base).replaceNode(same(1)), base);
      nb.debugUnfit.add('held');
      File(rec.path).createSync(recursive: true);
      return (nb, a, b);
    }

    test('(blocking 1) entries a held copy was built on stay superseded and are retired after a listing that failed at open', () async {
      var listFails = false;
      final (nb, a, b) = await twoPages(
        hook: (p) async {
          if (p == 'list' && listFails) throw const FileSystemException('listing failed');
        },
      );
      await nb.open(b);
      final e1 = _box('e1', 1);
      final text = pageFile(a).readAsStringSync();
      final old = await store().write(
        folder: pages.path,
        page: readPage(text).insertNode(e1),
        baseText: text,
        time: DateTime.now(),
      );
      nb.debugHold(a, readPage(text).insertNode(e1), text, supersedes: [old.gen]);
      listFails = true;
      flaky.failSave = true;
      await nb.open(a); // opens with the held copy; its ancestor can't be listed
      expect(nb.current!.page.node('e1'), isNotNull);
      await nb.flush(); // the save failed: a session entry that supersedes the ancestor
      nb.current!.delete('e1'); // the user deletes the box
      await nb.flush();
      listFails = false;
      flaky.failSave = false;
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      await nb.flush();
      await nb.open(b);
      await nb.open(a);
      expect(nb.current!.page.node('e1'), isNull, reason: 'the ancestor did not come back');
      expect(disk(a).node('e1'), isNull);
      expect(recNames(), isEmpty, reason: 'the ancestor is retired');
    });

    test('(2) a held copy the open page does not show is written to recovery on backoff', () async {
      final (nb, a, _) = await unfitHeld();
      await nb.open(a);
      expect(nb.unsavedPageCount, 1);
      File(rec.path).deleteSync(); // recovery works now
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect((await entries(nb)).single.page.node('x1'), isNotNull);
    });

    test('(3) a blocked replay still writes its unfit copy to recovery once that works', () async {
      final (nb, _, _) = await unfitHeld();
      await nb.flush(); // the replay is blocked by the unfit copy; recovery can not take it
      expect(nb.unsavedPageCount, 1);
      File(rec.path).deleteSync();
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect(await entries(nb), hasLength(1));
    });

    test('(4) a held copy whose page is overwritten right after it lands gives a notice', () async {
      final (nb, a, b) = await twoPages();
      await nb.open(b);
      final text = pageFile(a).readAsStringSync();
      nb.debugHold(a, readPage(text).insertNode(_box('h1', 1)), text);
      nb.syncHook = (p, _) async {
        if (p == 'recover-published') {
          pageFile(a).writeAsStringSync(writePage(disk(a).removeNode('h1')));
        }
      };
      await nb.flush();
      expect(nb.unsavedPageCount, 0);
      expect(nb.recoveryProblems.join(), contains('page changed right after'));
    });
  });
}
