// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Held edits: a binder folder seen to hold another binder's file, a damaged
// binder file or none turns read-only before anything is written there; the
// open page's unsaved edits go to recovery, every write or delete checks the
// binder file at its turn at the folder, and what was kept lands when the
// folder holds this binder again (or Use this binder).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_canvas/noted_canvas.dart' show AttachmentState;
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';

enum _Swap { other, damaged, missing }

void main() {
  final sep = Platform.pathSeparator;
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Directory rec;
  late Notebook nb;
  late String pageId;
  late String standalone;
  late List<KeptNotice> keptNotices;
  late StreamSubscription<KeptNotice> keptSub;
  late List<(UserQuestion, String)> asked;
  late bool answer;
  var disposed = false;

  File binderFile() => File('${folder.path}$sep$binderFileName');
  File pageFile(String id) => File('${folder.path}$sep$id.canvas');
  BinderSection section() => nb.binders.single;
  final otherBinder = Binder.create(title: 'Other', color: binderPalette[2]);

  String? picked;

  Notebook make() {
    final n = Notebook(
      PageStore(pages),
      buildModules(),
      // The autosave stays pending until the hold flushes it.
      saveDelay: const Duration(minutes: 10),
      bindersFile: File('${root.path}${sep}binders.json'),
      recoveryDirectory: rec,
      pickFolder: () async => picked,
      binderRecheckDelay: const Duration(milliseconds: 300),
      backoffFirst: const Duration(milliseconds: 100),
      backoffMax: const Duration(milliseconds: 200),
    );
    n.questioner = (q, t) async {
      asked.add((q, t));
      return answer;
    };
    return n;
  }

  Future<void> start({bool recoveryBlocked = false}) async {
    root = await Directory.systemTemp.createTemp('noted_held_edits');
    pages = await Directory('${root.path}${sep}pages').create();
    folder = await Directory('${root.path}${sep}Work').create();
    rec = Directory('${root.path}${sep}recovery');
    asked = [];
    answer = true;
    keptNotices = [];
    disposed = false;
    // A file where the recovery folder should be: nothing can be kept.
    if (recoveryBlocked) File(rec.path).writeAsStringSync('not a folder');
    nb = make();
    keptSub = nb.keptNotices.listen(keptNotices.add);
    await nb.load();
    standalone = nb.currentId!;
    final s = await nb.addBinder(folder.path);
    pageId = await nb.createPage(binderPath: s.path);
    await nb.flush();
  }

  Future<void> stop() async {
    await keptSub.cancel();
    if (!disposed) {
      nb.syncHook = null;
      nb.binderHook = null;
      await nb.flush();
      await nb.afterHoldForTest(folder.path);
      nb.dispose();
    }
    for (var attempt = 1; root.existsSync(); attempt++) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  // Every file under [d] (relative name: bytes), for "nothing was written".
  Map<String, String> snapshot(Directory d) {
    final out = <String, String>{};
    if (!d.existsSync()) return out;
    for (final e in d.listSync(recursive: true)) {
      if (e is File) {
        out[e.path.substring(d.path.length)] = base64Encode(
          e.readAsBytesSync(),
        );
      }
    }
    return out;
  }

  String addBox() => nb.current!.createBoxAt(const Bounds(10, 10, 0, 0)).id;

  List<RecoveryEntry> kept([String? id]) => nb
      .recoveryStoreForTest!
      .indexEntries
      .where((e) => e.pageId == (id ?? pageId))
      .toList();

  bool fileHas(String id, String box) {
    try {
      return readPage(pageFile(id).readAsStringSync()).node(box) != null;
    } on Object {
      return false;
    }
  }

  void swap(_Swap s) {
    switch (s) {
      case _Swap.other:
        binderFile().writeAsStringSync(otherBinder.write());
      case _Swap.damaged:
        binderFile().writeAsStringSync('{ not json');
      case _Swap.missing:
        binderFile().deleteSync();
    }
  }

  Future<void> check() => nb.checkBinderFile(binderFile().path);

  group('1, 8. the change seen with an autosave pending', () {
    for (final kind in _Swap.values) {
      test(
        '${kind.name}: the folder is unchanged, the edits are in recovery, and they land when the file is back',
        () async {
          await start();
          final original = binderFile().readAsStringSync();
          final box = addBox();
          swap(kind);
          final swapped = snapshot(folder);
          await check();
          expect(
            snapshot(folder),
            swapped,
            reason: 'nothing is written to the folder',
          );
          expect(kept().single.page.node(box), isNotNull);
          expect(section().hold, BinderHold.values[kind.index]);
          if (kind == _Swap.missing) {
            expect(nb.currentId, standalone);
            expect(keptNotices.map((n) => n.pageId), contains(pageId));
          } else {
            expect(nb.isReadOnlyPage(pageId), isTrue);
            expect(nb.current!.readOnly, isTrue);
            expect(
              nb.trouble.isTrouble,
              isFalse,
              reason: 'no failing bar while held',
            );
          }
          // The original file back: the open page and its kept edits land.
          binderFile().writeAsStringSync(original);
          await check();
          await nb.flush();
          await realIoUntil(
            () => fileHas(pageId, box) && kept().isEmpty,
            'the kept edits to land',
          );
          expect(section().hold, isNull);
          expect(section().available, isTrue);
          expect(
            nb.currentId,
            pageId,
            reason: 'the page that was open opens again',
          );
          await stop();
        },
      );
    }

    test('nothing is captured when nothing was pending', () async {
      await start();
      swap(_Swap.other);
      final swapped = snapshot(folder);
      await check();
      expect(snapshot(folder), swapped);
      expect(kept(), isEmpty);
      expect(section().hold, BinderHold.otherBinder);
      await stop();
    });
  });

  test('2. a save queued on the folder lock, then the swap: refused at its turn, nothing written', () async {
    await start();
    final box = addBox();
    final release = Completer<void>();
    final holding = nb.folderLocks.run(folder, () => release.future);
    final saving = nb.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    swap(_Swap.other);
    final swapped = snapshot(folder);
    release.complete();
    await holding;
    await saving;
    await nb.afterHoldForTest(folder.path);
    expect(snapshot(folder), swapped);
    expect(section().hold, BinderHold.otherBinder);
    expect(kept().single.page.node(box), isNotNull);
    await check();
    expect(snapshot(folder), swapped);
    await stop();
  });

  test('3. a save whose turn comes with the binder file swapped: refused, the folder held', () async {
    await start();
    final before = pageFile(pageId).readAsStringSync();
    final box = addBox();
    var swapped = false;
    nb.syncHook = (point, path) async {
      if (point == 'binder-gate' && !swapped) {
        swapped = true;
        swap(_Swap.other);
      }
    };
    await nb.flush();
    await nb.afterHoldForTest(folder.path);
    expect(swapped, isTrue);
    expect(pageFile(pageId).readAsStringSync(), before);
    expect(section().hold, BinderHold.otherBinder);
    expect(section().heldOther?.id, otherBinder.id);
    expect(kept().single.page.node(box), isNotNull);
    expect(nb.isReadOnlyPage(pageId), isTrue);
    await stop();
  });

  test('13. a half-written binder file at the turn: refused, no hold; the same bytes back land the edits', () async {
    await start();
    final original = binderFile().readAsStringSync();
    final before = pageFile(pageId).readAsStringSync();
    final box = addBox();
    var damaged = false;
    nb.syncHook = (point, path) async {
      if (point == 'binder-gate' && !damaged) {
        damaged = true;
        binderFile().writeAsStringSync('{"format":1,"id":');
      }
    };
    await nb.flush();
    binderFile().writeAsStringSync(original);
    expect(damaged, isTrue);
    expect(pageFile(pageId).readAsStringSync(), before);
    expect(section().hold, isNull);
    expect(kept().single.page.node(box), isNotNull);
    // The watcher looks again (text unchanged) and the save is retried.
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edits to land',
    );
    expect(section().hold, isNull);
    expect(section().available, isTrue);
    await stop();
  });

  test('13, 31. a G2 hold whose own file is back before the state change: the section stays available, L lands', () async {
    await start();
    final original = binderFile().readAsStringSync();
    final box = addBox();
    var swapped = false;
    var restored = false;
    nb.syncHook = (point, path) async {
      if (point == 'binder-gate' && !swapped) {
        swapped = true;
        swap(_Swap.other);
      } else if (point == 'binder-hold-captured' && !restored) {
        restored = true;
        binderFile().writeAsStringSync(original);
        // A gated read inside the hold's own work clears it (G3): one rerun lands.
        await nb.scanLocationForTest(folder.path);
      }
    };
    await nb.flush();
    await nb.afterHoldForTest(folder.path);
    expect(restored, isTrue);
    expect(section().available, isTrue);
    expect(section().hold, isNull);
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'L to land the edits',
    );
    await stop();
  });

  test(
    '7. Use this binder: the open page merges and saves, the kept edits retire',
    () async {
      await start();
      final box = addBox();
      swap(_Swap.other);
      await check();
      expect(kept(), hasLength(1));
      await nb.useThisBinder(folder.path);
      await nb.flush();
      await realIoUntil(
        () => fileHas(pageId, box) && kept().isEmpty,
        'the edits to land',
      );
      expect(section().binder?.id, otherBinder.id);
      expect(section().hold, isNull);
      expect(nb.isReadOnlyPage(pageId), isFalse);
      await stop();
    },
  );

  test(
    '7, N5. Use this binder works from the held binder before the state change',
    () async {
      await start();
      final box = addBox();
      var swapped = false;
      final stepFour = Completer<void>();
      var captured = false;
      nb.syncHook = (point, path) async {
        if (point == 'binder-gate' && !swapped) {
          swapped = true;
          swap(_Swap.other);
        } else if (point == 'binder-hold-captured') {
          // Step 4's state change waits here.
          captured = true;
          await stepFour.future;
        }
      };
      await nb.flush();
      await realIoUntil(() => captured, 'the capture');
      expect(section().hold, BinderHold.otherBinder);
      expect(section().other, isNull, reason: 'the state change has not run');
      expect(section().heldOther?.id, otherBinder.id);
      expect(kept(), hasLength(1));
      await nb.useThisBinder(folder.path);
      stepFour.complete();
      await nb.afterHoldForTest(folder.path);
      nb.syncHook = null;
      await nb.flush();
      await realIoUntil(
        () => fileHas(pageId, box) && kept().isEmpty,
        'the edits to land',
      );
      expect(section().binder?.id, otherBinder.id);
      await stop();
    },
  );

  test('9. damaged, then another binder: still held, nothing lands', () async {
    await start();
    final box = addBox();
    swap(_Swap.damaged);
    await check();
    swap(_Swap.other);
    final swapped = snapshot(folder);
    await check();
    await nb.afterHoldForTest(folder.path);
    expect(section().hold, BinderHold.otherBinder);
    expect(section().other?.id, otherBinder.id);
    expect(snapshot(folder), swapped);
    expect(kept().single.page.node(box), isNotNull);
    await stop();
  });

  test('10. Remove binder while held asks; Cancel keeps it; the entries stay; re-adding lands them', () async {
    await start();
    final box = addBox();
    swap(_Swap.other);
    await check();
    answer = false;
    await expectLater(
      nb.removeBinder(folder.path),
      throwsA(isA<LeaveCancelled>()),
    );
    expect(asked.last, (UserQuestion.removeWithKeptChanges, '1'));
    expect(nb.binders, hasLength(1));
    answer = true;
    await nb.removeBinder(folder.path);
    expect(nb.binders, isEmpty);
    expect(kept(), hasLength(1), reason: 'the kept changes are never deleted');
    await nb.addBinder(folder.path);
    await nb.flush();
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edits to land after re-adding',
    );
    await stop();
  });

  test('14. a delete queued on the lock, then the swap: refused, the page file stays', () async {
    await start();
    final other = await nb.createPage(binderPath: section().path);
    await nb.open(pageId);
    await nb.flush();
    final before = pageFile(other).readAsStringSync();
    final release = Completer<void>();
    final holding = nb.folderLocks.run(folder, () => release.future);
    final deleting = nb.delete(other);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    swap(_Swap.other);
    release.complete();
    await holding;
    await expectLater(deleting, throwsA(isA<NotebookException>()));
    expect(pageFile(other).readAsStringSync(), before);
    await nb.afterHoldForTest(folder.path);
    expect(section().hold, BinderHold.otherBinder);
    await stop();
  });

  group('25, 26. scans while held', () {
    File aside() =>
        File('${folder.path}$sep$pageId.canvas.1-aa-bb$asideSuffix');

    test('25. a held folder\'s scan puts back no aside; after L the sweep runs again', () async {
      await start();
      final original = binderFile().readAsStringSync();
      swap(_Swap.other);
      await check();
      aside().writeAsStringSync(pageFile(pageId).readAsStringSync());
      final before = snapshot(folder);
      await nb.scanLocationForTest(folder.path);
      expect(snapshot(folder), before);
      binderFile().writeAsStringSync(original);
      await check();
      await nb.afterHoldForTest(folder.path);
      expect(section().available, isTrue);
      await nb.scanLocationForTest(folder.path);
      expect(
        aside().existsSync(),
        isFalse,
        reason: 'swept once the folder is this binder\'s again',
      );
      await stop();
    });

    test(
      '26. a scan queued on the lock across the swap sweeps nothing',
      () async {
        await start();
        aside().writeAsStringSync(pageFile(pageId).readAsStringSync());
        final release = Completer<void>();
        final holding = nb.folderLocks.run(folder, () => release.future);
        final scanning = nb.scanLocationForTest(folder.path);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        swap(_Swap.other);
        final swapped = snapshot(folder);
        release.complete();
        await holding;
        await scanning;
        expect(
          snapshot(folder),
          swapped,
          reason: 'no aside put back, no copy published',
        );
        expect(section().hold, BinderHold.otherBinder);
        await stop();
      },
    );

    test(
      '26. the same with an unreadable binder file: no hold, no sweep',
      () async {
        await start();
        final original = binderFile().readAsStringSync();
        aside().writeAsStringSync(pageFile(pageId).readAsStringSync());
        final release = Completer<void>();
        final holding = nb.folderLocks.run(folder, () => release.future);
        final scanning = nb.scanLocationForTest(folder.path);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        binderFile().writeAsStringSync('{"format":1,"id":');
        final swapped = snapshot(folder);
        release.complete();
        await holding;
        await scanning;
        expect(snapshot(folder), swapped);
        expect(section().hold, isNull);
        binderFile().writeAsStringSync(original);
        await stop();
      },
    );

    test('33. a swap between the open\'s read and its scan: built held and read-only, no sweep', () async {
      await start();
      aside().writeAsStringSync(pageFile(pageId).readAsStringSync());
      nb.binderHook = (point, path) async {
        if (point == 'parsed') {
          nb.binderHook = null;
          swap(_Swap.other);
        }
      };
      await nb.reopenForTest(folder.path);
      expect(section().hold, BinderHold.otherBinder);
      expect(section().available, isFalse);
      expect(section().other?.id, otherBinder.id);
      expect(aside().existsSync(), isTrue);
      await stop();
    });
  });

  test('22. G3 from a save-chain job: the job ends first, then L lands, with no deadlock', () async {
    await start();
    final original = binderFile().readAsStringSync();
    final box = addBox();
    swap(_Swap.other);
    await check();
    binderFile().writeAsStringSync(original);
    await nb
        .runOnChainForTest(() => nb.scanLocationForTest(folder.path))
        .timeout(const Duration(seconds: 10));
    await nb.afterHoldForTest(folder.path).timeout(const Duration(seconds: 10));
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'L to land the edits',
    );
    expect(section().available, isTrue);
    await stop();
  });

  test('28. G1 runs G3: L runs once and the binder is reopened once', () async {
    await start();
    final original = binderFile().readAsStringSync();
    final box = addBox();
    swap(_Swap.other);
    await check();
    final reopened = nb.reopenCountForTest;
    binderFile().writeAsStringSync(original);
    await check();
    expect(nb.reopenCountForTest - reopened, 1);
    await nb.flush();
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edits to land',
    );
    await stop();
  });

  test(
    '27. dispose during the hold\'s work: it returns, nothing is written',
    () async {
      await start();
      addBox();
      swap(_Swap.other);
      final swapped = snapshot(folder);
      nb.syncHook = (point, path) async {
        if (point == 'binder-hold-captured') {
          nb.syncHook = null;
          disposed = true;
          nb.dispose();
        }
      };
      await check();
      await nb.afterHoldForTest(folder.path);
      expect(snapshot(folder), swapped);
      await stop();
    },
  );

  test('5. a fresh launch while the folder holds another binder: held, replay skipped, the entry kept', () async {
    await start();
    final box = addBox();
    swap(_Swap.other);
    await check();
    final swapped = snapshot(folder);
    await nb.flush();
    await keptSub.cancel();
    nb.dispose();
    nb = make();
    keptSub = nb.keptNotices.listen(keptNotices.add);
    await nb.load();
    await nb.recoverNowForTest();
    expect(section().hold, BinderHold.otherBinder);
    expect(section().available, isFalse);
    expect(snapshot(folder), swapped);
    expect(kept().single.page.node(box), isNotNull);
    expect(nb.heldPagesFor(folder.path), 1);
    await stop();
  });

  test('11. recovery unavailable during the hold: the warning shows, nothing is written to the folder', () async {
    await start(recoveryBlocked: true);
    addBox();
    swap(_Swap.other);
    final swapped = snapshot(folder);
    await check();
    expect(snapshot(folder), swapped);
    expect(
      nb.trouble.isTrouble,
      isTrue,
      reason:
          'the edits are safe nowhere: the bar says so (${nb.trouble.kind} ${nb.unsavedDescription})',
    );
    expect(nb.isReadOnlyPage(pageId), isTrue);
    await stop();
  });

  group('29, 30. attachments of a held page', () {
    final good = utf8.encode('the good file');
    final other = utf8.encode('another good file');
    late Directory assets;
    late String keptName;
    late String damagedName;

    // One attachment missing with a kept copy beside it, one damaged.
    void seed() {
      assets = Directory('${folder.path}$sep${assetsFolderName(pageId)}')
        ..createSync();
      keptName = attachmentFileName(contentHash(good), 'txt');
      damagedName = attachmentFileName(contentHash(other), 'txt');
      File('${assets.path}$sep$keptName.kept-1').writeAsBytesSync(good);
      File('${assets.path}$sep$damagedName')
          .writeAsBytesSync(utf8.encode('not the file it was'));
    }

    test('displaying and verifying change nothing; adding is refused; after L the display repairs', () async {
      await start();
      final original = binderFile().readAsStringSync();
      seed();
      final store = nb.attachments!; // made before the hold (30)
      swap(_Swap.other);
      await check();
      final before = snapshot(folder);
      final recBefore = snapshot(rec);
      expect(
        (await store.verify(keptName, size: good.length)).state,
        AttachmentState.syncing,
      );
      expect(
        (await store.verify(damagedName, size: other.length)).state,
        AttachmentState.damaged,
      );
      expect(
        (await nb.attachments!.readVerified(keptName, size: good.length)).state,
        AttachmentState.syncing,
      );
      expect(
        snapshot(folder),
        before,
        reason: 'no kept copy put back, no damaged file renamed',
      );
      expect(snapshot(rec), recBefore);
      await expectLater(
        nb.attachments!.put(
          Uint8List.fromList(utf8.encode('new')),
          extension: 'txt',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(snapshot(folder), before);
      // The folder holds this binder again: the next display repairs.
      binderFile().writeAsStringSync(original);
      await check();
      await nb.afterHoldForTest(folder.path);
      expect(
        (await nb.attachments!.verify(keptName, size: good.length)).state,
        AttachmentState.ok,
      );
      expect(File('${assets.path}$sep$keptName').readAsBytesSync(), good);
      await stop();
    });

    test('a swap between the display\'s read and its repair: refused at the turn, nothing renamed', () async {
      await start();
      seed();
      var swapped = false;
      nb.syncHook = (point, path) async {
        if (point == 'binder-gate' && !swapped) {
          swapped = true;
          swap(_Swap.other);
        }
      };
      final r = await nb.attachments!.verify(damagedName, size: other.length);
      expect(swapped, isTrue);
      expect(r.state, AttachmentState.damaged);
      expect(
        File('${assets.path}$sep$damagedName').existsSync(),
        isTrue,
        reason: 'not set aside',
      );
      await nb.afterHoldForTest(folder.path);
      expect(section().hold, BinderHold.otherBinder);
      await stop();
    });

    test('B1. a copy out of the held page (Save a copy elsewhere, Save as template) sweeps nothing there', () async {
      await start();
      seed();
      // A leftover of a stopped replace of an attachment: a sweep would put it back.
      File('${assets.path}$sep$keptName.42-aa-bb$asideSuffix')
          .writeAsBytesSync(good);
      swap(_Swap.other);
      await check();
      final before = snapshot(folder);
      picked = Directory('${root.path}${sep}Elsewhere').path;
      await nb.saveCopyElsewhere();
      expect(snapshot(folder), before);
      await nb.savePageAsTemplate(pageId, name: 'From held');
      expect(snapshot(folder), before);
      await stop();
    });
  });

  test('21. Save a copy elsewhere into a held binder folder: nothing copied, nothing published', () async {
    await start();
    swap(_Swap.other);
    await check();
    await nb.open(standalone);
    final before = snapshot(folder);
    picked = folder.path;
    await expectLater(
      nb.saveCopyElsewhere(),
      throwsA(
        isA<NotebookException>().having(
          (e) => e.message,
          'message',
          contains('another binder'),
        ),
      ),
    );
    expect(snapshot(folder), before);
    await stop();
  });

  test('21. a swap after the gate of a copy into a binder folder: the next turn refuses', () async {
    await start();
    await nb.open(standalone);
    final before = snapshot(folder)..remove('$sep$binderFileName');
    var swapped = false;
    nb.syncHook = (point, path) async {
      if (point == 'binder-gate' && !swapped) {
        swapped = true;
        swap(_Swap.other);
      }
    };
    picked = folder.path;
    await expectLater(
      nb.saveCopyElsewhere(),
      throwsA(isA<NotebookException>()),
    );
    expect(snapshot(folder)..remove('$sep$binderFileName'), before);
    await stop();
  });

  // A note box holding [text].
  BoxRecord noteBox(String text, {Bounds at = const Bounds(300, 10, 200, 40)}) {
    final codec = buildModules().codecs.codecFor('noted.note')!;
    return commitBox(
      createBox(codec, at),
      codec,
      codec.decode({
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
      }, 1),
    );
  }

  test('15. a conflict-copy merge with the swap before the copy\'s delete: the copy stays, the merge is redone at L', () async {
    await start();
    final original = binderFile().readAsStringSync();
    await nb.createPage(binderPath: section().path); // [pageId] is closed now
    await nb.flush();
    final box = noteBox('from the other machine');
    final copy = File('${folder.path}$sep$pageId-DESKTOP-1.canvas')
      ..writeAsStringSync(
        writePage(
          readPage(pageFile(pageId).readAsStringSync()).insertNode(box),
        ),
      );
    nb.syncHook = (point, path) async {
      if (point == 'copy-merged') {
        nb.syncHook = null;
        swap(_Swap.other);
      }
    };
    await nb.checkFile(copy.path);
    await nb.afterHoldForTest(folder.path);
    expect(
      copy.existsSync(),
      isTrue,
      reason: 'the copy is not deleted from a held folder',
    );
    expect(section().hold, BinderHold.otherBinder);
    binderFile().writeAsStringSync(original);
    await check();
    await nb.afterHoldForTest(folder.path);
    await realIoUntil(
      () => !copy.existsSync() && fileHas(pageId, box.id),
      'the merge to be redone at L',
    );
    await stop();
  });

  test('16. an Undo whose page file was replaced, with the swap before the -undo- copy is published: not published', () async {
    await start();
    final other = await nb.createPage(binderPath: section().path);
    await nb.open(pageId);
    await nb.flush();
    final deleted = await nb.delete(other);
    // Another device puts a page with the id there meanwhile.
    pageFile(other).writeAsStringSync(
      writePage(
        NotedPage.create(PageMeta.create(id: other, title: 'Newer', order: 5)),
      ),
    );
    var reached = false;
    nb.syncHook = (point, path) async {
      if (point == 'undo-copy-before-publish') {
        reached = true;
        swap(_Swap.other);
      }
    };
    await nb.undoDelete(deleted).then<void>((_) {}, onError: (_) {});
    nb.syncHook = null;
    expect(reached, isTrue);
    expect(
      folder.listSync().where((e) => e.path.contains('-undo-')),
      isEmpty,
      reason: 'no copy and no temp',
    );
    expect(
      nb.isPendingDelete(deleted),
      isTrue,
      reason: 'the deleted page is still held for Undo',
    );
    await stop();
  });

  group('17. kept assets', () {
    late Directory kept;

    // A kept file of the page's attachments in the recovery folder.
    void keep() {
      kept = Directory('${rec.path}$sep${assetsFolderName(pageId)}')
        ..createSync(recursive: true);
      File('${kept.path}${sep}a.txt').writeAsStringSync('kept file');
    }

    test('a swap between landing and the deletes of the kept files: the sources stay', () async {
      await start();
      keep();
      nb.keptLandedHook = (_) async => swap(_Swap.other);
      await nb.recoverNowForTest();
      nb.keptLandedHook = null;
      expect(
        File('${kept.path}${sep}a.txt').existsSync(),
        isTrue,
        reason: 'the kept file is not deleted',
      );
      await stop();
    });

    test('a swap before landing: nothing is copied into the folder', () async {
      await start();
      keep();
      var swapped = false;
      nb.syncHook = (point, path) async {
        if (point == 'binder-gate' && !swapped) {
          swapped = true;
          swap(_Swap.other);
        }
      };
      await nb.recoverNowForTest();
      nb.syncHook = null;
      expect(swapped, isTrue);
      expect(
        Directory('${folder.path}$sep${assetsFolderName(pageId)}').existsSync(),
        isFalse,
      );
      expect(File('${kept.path}${sep}a.txt').existsSync(), isTrue);
      await stop();
    });
  });

  group('18. attachment moves', () {
    test('a delete with the swap before its attachments are set aside: they stay, the page file stays', () async {
      await start();
      final other = await nb.createPage(binderPath: section().path);
      await nb.open(pageId);
      await nb.flush();
      final assets = Directory('${folder.path}$sep${assetsFolderName(other)}')
        ..createSync();
      File('${assets.path}${sep}a.txt').writeAsStringSync('attached');
      var swapped = false;
      nb.syncHook = (point, path) async {
        if (point == 'binder-gate' && !swapped) {
          swapped = true;
          swap(_Swap.other);
        }
      };
      await expectLater(nb.delete(other), throwsA(isA<NotebookException>()));
      nb.syncHook = null;
      expect(File('${assets.path}${sep}a.txt').readAsStringSync(), 'attached');
      expect(pageFile(other).existsSync(), isTrue);
      await stop();
    });

    test(
      'an Undo with the swap before the attachments are put back: not moved',
      () async {
        await start();
        final other = await nb.createPage(binderPath: section().path);
        await nb.open(pageId);
        await nb.flush();
        final assets = Directory('${folder.path}$sep${assetsFolderName(other)}')
          ..createSync();
        File('${assets.path}${sep}a.txt').writeAsStringSync('attached');
        final deleted = await nb.delete(other);
        expect(assets.existsSync(), isFalse);
        var swapped = false;
        nb.syncHook = (point, path) async {
          if (point == 'binder-gate' && !swapped) {
            swapped = true;
            swap(_Swap.other);
          }
        };
        await nb.undoDelete(deleted).then<void>((_) {}, onError: (_) {});
        nb.syncHook = null;
        expect(swapped, isTrue);
        expect(
          assets.existsSync(),
          isFalse,
          reason: 'nothing is moved into the held folder',
        );
        expect(pageFile(other).existsSync(), isFalse);
        await stop();
      },
    );
  });

  test('19. an entry of a folder whose binder file is missing is not re-keyed to where its page is listed now', () async {
    await start();
    final original = binderFile().readAsStringSync();
    final box = addBox();
    swap(_Swap.missing);
    await check();
    expect(kept().single.folder.toLowerCase(), folder.path.toLowerCase());
    // The page's file in another binder, which lists it now.
    final elsewhere = await Directory('${root.path}${sep}Second').create();
    File('${elsewhere.path}$sep$pageId.canvas')
        .writeAsStringSync(pageFile(pageId).readAsStringSync());
    final second = await nb.addBinder(elsewhere.path);
    expect(nb.binderOfPage(pageId), second.path);
    final there = File('${elsewhere.path}$sep$pageId.canvas')
        .readAsStringSync();
    await nb.recoverNowForTest();
    expect(
      kept().single.folder.toLowerCase(),
      folder.path.toLowerCase(),
      reason: 'not re-keyed',
    );
    expect(
      File('${elsewhere.path}$sep$pageId.canvas').readAsStringSync(),
      there,
      reason: 'nothing landed there',
    );
    // It lands in its own folder once its binder file is back.
    await nb.removeBinder(second.path);
    binderFile().writeAsStringSync(original);
    await check();
    await nb.afterHoldForTest(folder.path);
    await nb.flush();
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edit to land in its own folder',
    );
    await stop();
  });

  test('23. Use this binder with a cover change of the old binder pending: it asks, then the held edits land', () async {
    await start();
    final box = addBox();
    swap(_Swap.other);
    await check();
    await nb.updateBinder(folder.path, title: 'Stale');
    expect(nb.coverPendingCountForTest(folder.path), 1);
    await nb.useThisBinder(folder.path);
    expect(asked.map((a) => a.$1), contains(UserQuestion.discardCoverChanges));
    expect(nb.coverPendingCountForTest(folder.path), 0);
    await nb.flush();
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edits to land',
    );
    await stop();
  });

  test('24. Delete of a copy while the binder file is missing, then Put back: the hold clears and the edits land', () async {
    await start();
    final box = addBox();
    final text = binderFile().readAsStringSync();
    final keep = File('${folder.path}${sep}noted-binder-DESKTOP-1.json')
      ..writeAsStringSync(text);
    final drop = File('${folder.path}${sep}noted-binder-LAPTOP-2.json')
      ..writeAsStringSync(text);
    swap(_Swap.missing);
    await check();
    await nb.refreshBinderCopies(folder.path);
    expect(section().hold, BinderHold.missing);
    expect(await nb.deleteBinderCopy(folder.path, drop.path), isTrue);
    expect(drop.existsSync(), isFalse);
    await nb.putBackBinderCopy(folder.path, keep.path);
    expect(binderFile().readAsStringSync(), text);
    await nb.checkBinderFile(binderFile().path);
    await nb.afterHoldForTest(folder.path);
    await nb.flush();
    await realIoUntil(
      () => fileHas(pageId, box) && kept().isEmpty,
      'the edits to land',
    );
    expect(section().hold, isNull);
    await stop();
  });

  group('32. the completion hook', () {
    test('a refused job: its caller gets the error once, nothing extra is logged, the hold\'s work still starts', () async {
      await start();
      final other = await nb.createPage(binderPath: section().path);
      await nb.open(pageId);
      await nb.flush();
      final logs = <String>[];
      final print = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        swap(_Swap.other);
        var errors = 0;
        await nb.delete(other).then<void>((_) {}, onError: (_) => errors++);
        expect(errors, 1);
        await nb.afterHoldForTest(folder.path);
      } finally {
        debugPrint = print;
      }
      expect(logs.where((l) => l.contains('binder hold')), isEmpty);
      expect(section().hold, BinderHold.otherBinder);
      expect(section().other?.id, otherBinder.id, reason: 'steps 3 and 4 ran');
      await stop();
    });

    test(
      'the abandoned watcher read starts the hold\'s work right after its read',
      () async {
        await start();
        addBox();
        final release = Completer<void>();
        final holding = nb.folderLocks.run(folder, () => release.future);
        swap(_Swap.other);
        final checking = check();
        // The read gives up the lock wait (500 ms) and reads; the hold's work
        // runs while the test still has the folder.
        await realIoUntil(
          () => section().other != null,
          'steps 3 and 4 after the abandoned read',
        );
        expect(kept(), hasLength(1));
        release.complete();
        await holding;
        await checking;
        await stop();
      },
    );
  });

  test('34. a hold from a user action: the hold\'s own waits at the folder do not show its folder-wait note', () async {
    root = await Directory.systemTemp.createTemp('noted_held_edits');
    pages = await Directory('${root.path}${sep}pages').create();
    folder = await Directory('${root.path}${sep}Work').create();
    rec = Directory('${root.path}${sep}recovery');
    asked = [];
    answer = true;
    keptNotices = [];
    disposed = false;
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: const Duration(minutes: 10),
      bindersFile: File('${root.path}${sep}binders.json'),
      recoveryDirectory: rec,
      folderWaitNote: const Duration(milliseconds: 50),
    );
    keptSub = nb.keptNotices.listen(keptNotices.add);
    await nb.load();
    final s = await nb.addBinder(folder.path);
    pageId = await nb.createPage(binderPath: s.path);
    await nb.flush();
    final original = binderFile().readAsStringSync();
    var noted = false;
    nb.waitingForFolder.addListener(
      () => noted = noted || nb.waitingForFolder.value,
    );
    final release = Completer<void>();
    var held = false;
    nb.syncHook = (point, path) async {
      if (point == 'binder-hold-captured' && !held) {
        held = true;
        // The hold's own work waits at the folder, longer than the note's delay.
        binderFile().writeAsStringSync(original);
        unawaited(nb.folderLocks.run(folder, () => release.future));
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 300),
            release.complete,
          ),
        );
        await nb.scanLocationForTest(folder.path);
      }
    };
    swap(_Swap.other);
    // A user action whose job meets the other binder's file at its turn.
    await expectLater(
      nb.createPage(binderPath: s.path),
      throwsA(isA<NotebookException>()),
    );
    await nb.afterHoldForTest(folder.path);
    expect(held, isTrue);
    expect(
      noted,
      isFalse,
      reason: 'the note is for the user action\'s own waits',
    );
    await stop();
  });

  test('35. a move out of a binder with the swap before the source attachments are removed: they stay and are named', () async {
    await start();
    final other = await nb.createPage(binderPath: section().path);
    await nb.open(pageId);
    await nb.flush();
    final assets = Directory('${folder.path}$sep${assetsFolderName(other)}')
      ..createSync();
    File('${assets.path}${sep}a.txt').writeAsStringSync('attached');
    nb.syncHook = (point, path) async {
      if (point == 'move-source-deleted') {
        nb.syncHook = null;
        swap(_Swap.other);
      }
    };
    Object? error;
    try {
      await nb.moveToLocation(other);
    } on NotebookException catch (e) {
      error = e;
    }
    expect(
      File('${assets.path}${sep}a.txt').readAsStringSync(),
      'attached',
      reason: 'the source attachments stay',
    );
    expect(
      '$error'.isNotEmpty &&
          error is NotebookException &&
          error.message.contains('stayed'),
      isTrue,
      reason: '$error',
    );
    await stop();
  });

  test(
    '36. dispose with a request made: it is cleared and no hold work starts',
    () async {
      await start();
      addBox();
      final swapped = snapshot(folder);
      var captured = false;
      nb.syncHook = (point, path) async {
        if (point == 'binder-hold-set') {
          disposed = true;
          nb.dispose();
        }
        if (point == 'binder-hold-captured') captured = true;
      };
      swap(_Swap.other);
      final after = snapshot(folder);
      await check();
      await nb.afterHoldForTest(folder.path);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(captured, isFalse);
      expect(snapshot(folder), after);
      expect(swapped, isNot(after));
      await stop();
    },
  );
}
