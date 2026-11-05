// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// R-1 v5: failed saves never lose edits (runs/designs/2026-11-05-r1-v5.md).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

import 'support/trouble_world.dart';

void main() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
  });

  tearDown(() => w.dispose());

  group('a save fails with the folder present (states 2 and 4)', () {
    test('the page stays editable, the bar says why, and one entry holds the editor text and the file as base', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      final before = w.pageFile(id).readAsStringSync();
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.failing);
      expect(nb.trouble.reason, 'Access is denied');
      expect(nb.current!.readOnly, isFalse);
      expect(nb.currentId, id);
      final entries = (await nb.pendingRecovery()).entries;
      expect(entries, hasLength(1));
      expect(entries.single.pageText, writePage(nb.current!.page));
      expect(entries.single.baseText, before);
      expect(
        w.pageFile(id).readAsStringSync(),
        before,
        reason: 'the file was not touched',
      );
    });

    test(
      'Retry lands the save, clears the bar and retires the entry (T)',
      () async {
        final nb = w.make();
        final id = await w.editedPage(nb);
        final store = w.storeFor(w.pages)..failWith = accessDenied();
        await nb.flush();
        expect(nb.trouble.isTrouble, isTrue);
        store.failWith = null;
        await nb.retrySave();
        expect(nb.trouble.isTrouble, isFalse);
        expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(1));
        expect((await nb.pendingRecovery()).entries, isEmpty);
        expect(w.recFiles(), isEmpty);
      },
    );

    test(
      'the backoff tries again by itself and a landed save ends the trouble',
      () async {
        final nb = w.make(
          backoffFirst: const Duration(milliseconds: 30),
          backoffMax: const Duration(milliseconds: 60),
        );
        final id = await w.editedPage(nb);
        final store = w.storeFor(w.pages)..failWith = accessDenied();
        await nb.flush();
        final attempts = store.attempts;
        await until(
          () => store.attempts >= attempts + 2,
          what: 'two more attempts',
        );
        store.failWith = null;
        await until(() => !nb.trouble.isTrouble, what: 'the page to save');
        expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(1));
        await until(() => w.recFiles().isEmpty, what: 'the entry to go');
      },
    );

    test(
      'an error that is not an I/O error also enters state 2 and is kept',
      () async {
        final nb = w.make();
        await w.editedPage(nb);
        w.storeFor(w.pages).failWith = StateError('bug');
        await nb.flush();
        expect(nb.trouble.kind, TroubleKind.failing);
        expect(nb.trouble.reason, 'an unexpected error');
        expect(w.recFiles(), hasLength(1));
      },
    );

    test(
      'equal snapshots are dropped: a failed retry writes no new generation',
      () async {
        final nb = w.make();
        await w.editedPage(nb);
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
        final first = w.recFiles().single.readAsStringSync();
        await nb.retrySave();
        expect(w.recFiles().single.readAsStringSync(), first);
      },
    );
  });

  group('leaving a page', () {
    test('from state 2 the edits stay in recovery, one notice is shown, and Show opens a preview that lands later', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      final notices = <KeptNotice>[];
      nb.keptNotices.listen(notices.add);
      final store = w.storeFor(w.pages)..failWith = accessDenied();
      await nb.flush();
      final other = await nb.createPage();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(nb.currentId, other);
      expect(notices.map((n) => n.pageId), [id]);
      expect(w.recFiles(), hasLength(1));
      // Show: the file can't be written, so the kept changes are shown read-only.
      await nb.open(id);
      expect(nb.trouble.kind, TroubleKind.preview);
      expect(nb.current!.readOnly, isTrue);
      expect(boxCount(nb.current!.page), 1);
      expect(nb.isBusy(id), isFalse);
      // Replay lands once the file can be written; the page is editable again.
      store.failWith = null;
      await nb.retryPreview();
      expect(nb.trouble.isTrouble, isFalse);
      expect(nb.current!.readOnly, isFalse);
      expect(boxCount(nb.current!.page), 1);
      expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(1));
      expect(w.recFiles(), isEmpty);
    });

    test('the notice is shown once per failure streak', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      final notices = <KeptNotice>[];
      nb.keptNotices.listen(notices.add);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      final other = await nb.createPage();
      await nb.open(id); // preview
      await nb.open(other);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notices, hasLength(1));
    });

    test('a save that hangs is cut at the limit: the edits are kept, the next page opens, and the old job frees the page when it ends', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(
        w.other.path,
      ); // known before anything hangs (it also saves)
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id;
      final left = Stopwatch()..start();
      // A page of another folder: the hung one holds its own folder's lock.
      final other = await nb.createPage(folderPath: w.other.path);
      expect(left.elapsed, lessThan(const Duration(seconds: 5)));
      expect(nb.currentId, other);
      expect(w.recFiles(), hasLength(1), reason: 'kept after the limit');
      expect(
        nb.isBusy(id),
        isTrue,
        reason: 'a job of the page is still on the old chain',
      );
      // The new chain works: a watcher check completes while the old job hangs.
      await nb
          .checkFile(w.pageFile(id).path)
          .timeout(const Duration(seconds: 3));
      // A page opens and saves before the stalled job ends (review-7 R-1).
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.flush().timeout(const Duration(seconds: 3));
      expect(
        readPage(w.pageFile(other, w.other).readAsStringSync()).nodes,
        hasLength(1),
      );
      // The old job ends: it lands, retires its own generation and frees the page.
      store.stall!.complete();
      await until(() => !nb.isBusy(id), what: 'the page to be free');
      await until(() => w.recFiles().isEmpty, what: 'its entry to be retired');
      expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(2));
    });

    test('with the recovery write failing too, leaving asks; Cancel keeps the page, and the quit is cancelled', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await w.rec.parent.create(recursive: true);
      File(w.rec.path)
          .writeAsStringSync('in the way'); // a file where the folder should be
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      final asked = <UserQuestion>[];
      var answer = false;
      nb.questioner = (q, t) async {
        asked.add(q);
        return answer;
      };
      expect(await nb.prepareToExit(), isFalse);
      expect(asked, [UserQuestion.leaveAndLose]);
      expect(nb.currentId, id, reason: 'Cancel keeps the page');
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      expect(boxCount(nb.current!.page), 1);
      // Leaving by choosing another page asks too.
      final other = await nb.createPage();
      expect(nb.currentId, id);
      expect(asked, hasLength(2));
      answer = true;
      await nb.open(other);
      expect(nb.currentId, other, reason: 'the user chose to leave');
    });

    test('leaving from the saved state decides on its own outcome', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.flush(); // state 1
      expect(nb.trouble.isTrouble, isFalse);
      // A change after the last save; the leave save fails, and so does recovery.
      nb.current!.createBoxAt(const Bounds(80, 80, 0, 0));
      File(w.rec.path).createSync(recursive: true);
      w.storeFor(w.pages).failWith = accessDenied();
      var asked = false;
      nb.questioner = (q, t) async {
        asked = true;
        return false;
      };
      await nb.createPage();
      expect(asked, isTrue);
      expect(nb.currentId, id);
    });
  });

  group('opening', () {
    test('the file is read and the page looked up in one chain job: no write runs between', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.flush();
      final other = await nb.createPage();
      expect(other, isNot(id));
      if (w.settings.existsSync()) w.settings.deleteSync();
      Future<void>? queued;
      var settingsWrittenInside = false;
      nb.syncHook = (point, path) async {
        if (point != 'open-read') return;
        // A write queued now must wait until the open job is over.
        queued = nb.addStandaloneFolder(w.other.path);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        settingsWrittenInside = w.settings.existsSync();
      };
      await nb.open(id);
      nb.syncHook = null;
      await queued;
      expect(settingsWrittenInside, isFalse);
      expect(w.settings.existsSync(), isTrue);
      expect(nb.currentId, id);
    });

    test('a busy page cannot be deleted or moved', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id;
      await nb.createPage(folderPath: w.other.path);
      expect(nb.isBusy(id), isTrue);
      await expectLater(nb.delete(id), throwsA(isA<NotebookException>()));
      await expectLater(nb.moveToFolder(id, w.other.path), throwsA(isA<NotebookException>()));
      expect(w.pageFile(id).existsSync(), isTrue);
    });
  });

  group('Discard changes', () {
    test(
      'removes the kept generations and reopens the page as it is on disk',
      () async {
        final nb = w.make();
        final id = await w.editedPage(nb);
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
        expect(w.recFiles(), hasLength(1));
        await nb.discardChanges();
        expect(nb.currentId, id);
        expect(nb.trouble.isTrouble, isFalse);
        expect(boxCount(nb.current!.page), 0);
        expect(w.recFiles(), isEmpty);
        expect(nb.isBusy(id), isFalse);
      },
    );

    test('a delete that fails leaves the page in state 2 with the reason, and the page is not busy', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point == 'delete') throw accessDenied();
      };
      await expectLater(
        nb.discardChanges(),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            startsWith("Couldn't remove the changes kept"),
          ),
        ),
      );
      expect(nb.trouble.kind, TroubleKind.failing);
      expect(nb.currentId, id);
      expect(
        nb.isBusy(id),
        isFalse,
        reason: 'a failed Discard leaves busy (build note 5)',
      );
      expect(w.recFiles(), hasLength(1));
    });
  });

  group('entries that landed but could not be deleted', () {
    test(
      'open and replay delete them and merge nothing; quit retries the delete',
      () async {
        final nb = w.make();
        final id = await w.editedPage(nb);
        final box = nb.current!.page.nodes.single.id;
        final store = w.storeFor(w.pages)..failWith = accessDenied();
        await nb.flush();
        store.failWith = null;
        // The page lands, but the entry can't be deleted.
        nb.recoveryStoreForTest!.hook = (point) async {
          if (point == 'delete') throw accessDenied();
        };
        await nb.retrySave();
        expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(1));
        expect(w.recFiles(), hasLength(1));
        expect(nb.recoveryStoreForTest!.landedEntries, hasLength(1));
        // The user deletes the box and saves.
        nb.current!.delete(box);
        await nb.flush();
        expect(readPage(w.pageFile(id).readAsStringSync()).nodes, isEmpty);
        // Quitting retries the delete; it fails again, and the notice will say so.
        expect(await nb.prepareToExit(), isTrue);
        expect(nb.landedEntryLeft, isTrue);
        // Leaving and coming back: the entry is deleted, not merged.
        nb.recoveryStoreForTest!.hook = null;
        final other = await nb.createPage();
        await nb.open(id);
        expect(
          boxCount(nb.current!.page),
          0,
          reason: 'the deleted box did not come back',
        );
        expect(w.recFiles(), isEmpty);
        expect(nb.currentId, id);
        expect(other, isNot(id));
      },
    );
  });

  group('a preview that cannot land', () {
    test(
      'Discard kept changes asks first, then deletes only that generation',
      () async {
        final nb = w.make(
          backoffFirst: const Duration(milliseconds: 20),
          backoffMax: const Duration(milliseconds: 20),
        );
        final id = await w.editedPage(nb);
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
        await nb.createPage();
        await nb.open(id);
        expect(nb.trouble.kind, TroubleKind.preview);
        // The write keeps failing past the longest wait: the preview offers to discard.
        await until(
          () => nb.trouble.canDiscardKept,
          what: 'Discard kept changes',
        );
        var answer = false;
        final asked = <UserQuestion>[];
        nb.questioner = (q, t) async {
          asked.add(q);
          return answer;
        };
        await nb.discardKept();
        expect(asked, [UserQuestion.discardKept]);
        expect(w.recFiles(), hasLength(1), reason: 'Cancel changes nothing');
        answer = true;
        w.storeFor(w.pages).failWith = null;
        await nb.discardKept();
        expect(w.recFiles(), isEmpty);
        await until(
          () => nb.trouble.kind == TroubleKind.saved,
          what: 'the page to open editable',
        );
        expect(boxCount(nb.current!.page), 0);
      },
    );

    test('a box deleted after the preview landed stays deleted, live and after a restart', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      final x = nb.current!.page.nodes.single.id;
      final store = w.storeFor(w.pages)..failWith = accessDenied();
      await nb.flush();
      await nb.createPage();
      await nb.open(id);
      expect(nb.trouble.kind, TroubleKind.preview);
      expect(nb.current!.page.node(x), isNotNull);
      store.failWith = null;
      await nb.retryPreview();
      expect(nb.trouble.isTrouble, isFalse);
      nb.current!.delete(x);
      await nb.flush();
      expect(readPage(w.pageFile(id).readAsStringSync()).node(x), isNull);
      w.crash(nb);
      final again = w.make();
      await again.load();
      await again.open(id);
      expect(again.current!.page.node(x), isNull);
      expect(w.recFiles(), isEmpty);
    });
  });

  group('another entry for the page', () {
    test('an entry this window did not write is never replaced', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      // A restored backup: an entry for the open page appears in the folder.
      final foreign = RecoveryStore(w.rec);
      final disk = readPage(w.pageFile(id).readAsStringSync());
      await foreign.write(
        folder: w.pages.path,
        page: disk.withMeta(disk.meta.withTitle('from a backup')),
        baseText: writePage(disk),
        time: DateTime.now(),
      );
      final planted = w.recFiles().single.readAsStringSync();
      await nb.refreshRecoveryIndexForTest();
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      expect(
        w.recFiles().single.readAsStringSync(),
        planted,
        reason: 'byte-identical',
      );
    });

    test('a file added to the slot from outside is not replaced even if the index does not list it', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(w.recFiles(), hasLength(1));
      // The slot's content is replaced from outside (a backup put back).
      final disk = readPage(w.pageFile(id).readAsStringSync());
      final foreign = RecoveryStore(w.rec);
      final slot = w.recFiles().single;
      slot.deleteSync();
      await foreign.write(
        folder: w.pages.path,
        page: disk.withMeta(disk.meta.withTitle('backup')),
        baseText: writePage(disk),
        time: DateTime.now(),
      );
      final planted = w.recFiles().single.readAsStringSync();
      nb.current!.createBoxAt(const Bounds(90, 90, 0, 0)); // a newer snapshot
      await nb.flush();
      expect(w.recFiles().single.readAsStringSync(), planted);
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
    });
  });

  group('closed writers merge into the entries of a page', () {
    test('a closed write and an entry become one entry holding both, and the old generation is gone', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      final base = readPage(w.pageFile(id).readAsStringSync());
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      final other = await nb
          .createPage(); // the first page is closed with its entry
      expect(other, isNot(id));
      final entry = w.recFiles().single.readAsStringSync();
      // Another writer's change to the same page, with the same base.
      final b = BoxRecord.create(
        id: '00000000000000b1',
        typeId: 'x.unregistered',
        dataVersion: 1,
        bounds: const Bounds(300, 300, 10, 10),
        data: const RawJson.trusted('{"k":1}'),
        snapshotText: 's',
        rev: 'r',
      );
      final out = await nb.keepClosedForTest(
        base.insertNode(b),
        base,
        w.pages.path,
      );
      expect(out.kind, KeepKind.kept);
      final files = w.recFiles();
      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), isNot(entry));
      final listing = await nb.pendingRecovery();
      expect(
        listing.entries.single.page.nodes,
        hasLength(2),
        reason: 'the entry\'s box and the closed writer\'s',
      );
    });
  });

  group(
    'boxes this build does not know come back unchanged (build note 8)',
    () {
      test(
        'an unsupported box survives recovery and the preview byte for byte',
        () async {
          const data = r'{"b":1,  "z":"caf\u00e9", "a":[1, 2 ,3],"n":null}';
          final box = BoxRecord.create(
            id: '00000000000000f1',
            typeId: 'x.unregistered',
            dataVersion: 3,
            bounds: const Bounds(900, 900, 100, 50),
            data: const RawJson.trusted(data),
            snapshotText: 'snapshot',
            rev: 'opaquerev',
          );
          final nb = w.make();
          final id = await w.editedPage(nb);
          nb.current!.insertBox(box);
          w.storeFor(w.pages).failWith = accessDenied();
          await nb.flush();
          final kept = (await nb.pendingRecovery()).entries.single;
          expect(kept.page.node(box.id)!.toRaw().text, box.toRaw().text);
          // Leaving and coming back shows it unchanged in the preview.
          await nb.createPage();
          await nb.open(id);
          expect(nb.trouble.kind, TroubleKind.preview);
          final shown = nb.current!.page.node(box.id)! as BoxRecord;
          expect(shown.data!.text, data);
          expect(shown.toRaw().text, box.toRaw().text);
          // And lands unchanged.
          w.storeFor(w.pages).failWith = null;
          await nb.retryPreview();
          final onDisk =
              readPage(w.pageFile(id).readAsStringSync()).node(box.id)!
                  as BoxRecord;
          expect(onDisk.data!.text, data);
          expect(onDisk.toRaw().text, box.toRaw().text);
        },
      );
    },
  );

  group('quitting', () {
    test('a save stuck on the drive does not hold up quitting; the edits are in recovery', () async {
      final nb = w.make();
      await w.editedPage(nb);
      w.storeFor(w.pages).stall = Completer<void>();
      final s = Stopwatch()..start();
      expect(await nb.prepareToExit(), isTrue);
      expect(s.elapsed, lessThan(const Duration(seconds: 6)));
      expect(w.recFiles(), hasLength(1));
    });
  });
}
