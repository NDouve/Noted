// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Binder writes (R-2): a change is reapplied to the file as it is on disk, a
// refused change shows the saved value again, a missing file makes the binder
// unavailable at once and the same binder's file brings it back, another
// binder's file is never adopted, and nothing that isn't saved loosens what AI
// may do. Run with `--dart-define=CACHED_SAVE=true` to run the tests against
// the old cached write and see which of them fail on it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

import 'support/binder_seams.dart';
import 'support/real_io.dart';

void main() {
  late Directory root;
  late Directory folder;
  late Notebook nb;
  late BinderSection section;
  late String pageId;
  late String standalonePage;
  late Seams seams;
  late StreamSubscription<String> noticeSub;
  late List<String> notices;
  late List<(UserQuestion, String)> asked;
  late bool answer;

  File binderFile() => File('${folder.path}${Platform.pathSeparator}$binderFileName');
  String fileText() => binderFile().readAsStringSync();
  // For waiting on the file while another job may have it set aside.
  String textOrEmpty() {
    try {
      return binderFile().readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }
  List<String> names() => [
    for (final e in folder.listSync()) e.path.split(RegExp(r'[\\/]')).last,
  ]..sort();

  Notebook makeNotebook({bool watch = false, DateTime Function()? clock}) {
    final n = Notebook(
      PageStore(Directory('${root.path}/pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/binders.json'),
      binderStoreFactory: (d) => SeamStore(d, seams),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
      binderRecheckDelay: const Duration(milliseconds: 100),
      asideRestoreAfter: const Duration(milliseconds: 400),
      coverRetryFirst: const Duration(milliseconds: 60),
    );
    if (clock != null) n.now = clock;
    n.questioner = (q, title) async {
      asked.add((q, title));
      return answer;
    };
    return n;
  }

  Future<void> start({bool watch = false}) async {
    seams = Seams();
    notices = [];
    asked = [];
    answer = true;
    root = await Directory.systemTemp.createTemp('noted_binder_writes');
    await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    nb = makeNotebook(watch: watch);
    noticeSub = nb.attachmentNotices.listen(notices.add);
    await nb.load();
    standalonePage = nb.currentId!;
    section = await nb.addBinder(folder.path);
    pageId = await nb.createPage(binderPath: section.path);
  }

  Future<void> idle() => nb.runOnChainForTest(() async {});

  Future<void> stop() async {
    for (final g in seams.gates) {
      if (!g.isCompleted) g.complete();
    }
    await nb.flush();
    await idle();
    await noticeSub.cancel();
    nb.dispose();
    await root.delete(recursive: true);
  }

  Future<void> until(bool Function() done, String what) => realIoUntil(done, what);

  // What another device does: replaces the file behind the app's back, adding a
  // field this build doesn't know and changing two cover fields.
  void externalReplace({String owner = 'Them', String title = 'Theirs'}) {
    final b = Binder.parse(fileText()).withOwner(owner).withTitle(title);
    binderFile().writeAsStringSync(b.write().replaceFirst('{', '{"x-future":{"k":1},'));
  }

  void expectExternalSurvived() {
    final text = fileText();
    expect(text, contains('"x-future":{"k":1}'));
    expect(text, contains('"owner":"Them"'));
    expect(text, contains('"title":"Theirs"'));
  }

  Binder foreign({String id = 'otherbinder00001', String title = 'Other'}) =>
      Binder.create(id: id, title: title, color: binderPalette.first);

  setUp(() {
    answer = true;
  });

  group('9. a change after an unseen replacement keeps the replacement', () {
    for (final (name, change) in <(String, Future<void> Function(Notebook, String))>[
      ('AI access', (nb, p) => nb.setBinderAiAccess(p, AiAccess.open)),
      ('a box type', (nb, p) => nb.setBinderBoxType(p, 'image', false)),
      ('attachment storage', (nb, p) => nb.setBinderAttachmentStorage(p, AttachmentStorage.embedded)),
      ('the cover', (nb, p) => nb.updateBinder(p, description: 'mine')),
    ]) {
      test(name, () async {
        await start();
        externalReplace();
        await change(nb, section.path);
        await nb.flush();
        expectExternalSurvived();
        await stop();
      });
    }

    test('queued changes each apply only their own delta', () async {
      await start();
      externalReplace();
      final a = nb.setBinderAiAccess(section.path, AiAccess.privileged);
      final b = nb.updateBinder(section.path, owner: 'Mine');
      await Future.wait([a, b]);
      final saved = Binder.parse(fileText());
      expect(saved.aiAccess, AiAccess.privileged);
      expect(saved.owner, 'Mine');
      expect(saved.title, 'Theirs');
      expect(fileText(), contains('"x-future":{"k":1}'));
      await stop();
    });
  });

  group('10. a refused setting shows the saved value', () {
    test('the panel value, aiAccessFor and a fresh notebook, with a notice', () async {
      await start();
      seams.failMoves = 5;
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      expect(nb.binderAiAccess(section.path), isNull);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.guarded);
      expect(section.pending, isEmpty);
      expect(notices.single, startsWith("Binder Work: the change wasn't saved."));
      expect(fileText(), isNot(contains('"ai"')));
      expect(names().where((n) => n.endsWith('.tmp')), isEmpty, reason: 'the refused change''s temp is removed (T)');
      final again = makeNotebook();
      await again.load();
      final fresh = await again.addBinder(folder.path);
      expect(again.binderAiAccess(fresh.path), isNull);
      again.dispose();
      await stop();
    });

    test('a read-only file is named as such, with the file unchanged', () async {
      await start();
      final before = fileText();
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['444', binderFile().path]);
      }
      await nb.setBinderBoxType(section.path, 'image', false);
      if (Platform.isWindows) {
        Process.runSync('attrib', ['-R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['644', binderFile().path]);
      }
      expect(notices.single, contains('The binder file is read-only'));
      expect(nb.binderBoxType(section.path, 'image'), isNull);
      expect(fileText(), before);
      expect(names().where((n) => n.endsWith('.tmp')), isEmpty);
      await stop();
    });
  });

  test('11. a refused first setting with a second queued: saved plus the second', () async {
    await start();
    final c0 = seams.holdNext();
    final c1 = seams.holdNext();
    seams.failMoves = 5; // update 0 fails on every try
    final first = nb.setBinderAiAccess(section.path, AiAccess.open);
    final second = nb.updateBinder(section.path, title: 'Second');
    expect(nb.binderAiAccess(section.path), AiAccess.open);
    expect(section.title, 'Second');
    c0.complete();
    await first;
    // The second change is still waiting: the screen is saved plus the second.
    expect(nb.binderAiAccess(section.path), isNull);
    expect(section.title, 'Second');
    c1.complete();
    expect(await second, isTrue);
    expect(fileText(), contains('"title":"Second"'));
    expect(fileText(), isNot(contains('"ai"')));
    await stop();
  });

  group('12. a pending change never loosens what AI may do', () {
    test('a pending loosening leaves AI strict, the screen shows it', () async {
      await start();
      final c0 = seams.holdNext();
      final f = nb.setBinderAiAccess(section.path, AiAccess.open);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.open);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      c0.complete();
      await f;
      expect(nb.aiAccessFor(pageId).value, AiAccess.open);
      await stop();
    });

    test('a pending tightening applies at once', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      final c = seams.holdNext();
      final f = nb.setBinderAiAccess(section.path, AiAccess.guarded);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      c.complete();
      await f;
      await stop();
    });
  });

  group('13. the stricter value on disk is kept', () {
    test('a. AI access made stricter elsewhere: the request does not loosen it, with a notice', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      binderFile().writeAsStringSync(Binder.parse(fileText()).withAiAccess(AiAccess.guarded).write());
      await nb.setBinderAiAccess(section.path, AiAccess.privileged);
      expect(Binder.parse(fileText()).aiAccess, AiAccess.guarded);
      expect(nb.binderAiAccess(section.path), AiAccess.guarded);
      expect(notices.single, contains('AI access stays Guarded'));
      await stop();
    });

    test('a. a box type disallowed elsewhere stays disallowed', () async {
      await start();
      binderFile().writeAsStringSync(Binder.parse(fileText()).withBoxType('image', false).write());
      await nb.setBinderBoxType(section.path, 'image', true);
      expect(Binder.parse(fileText()).boxTypeChoice('image'), isFalse);
      expect(nb.binderBoxType(section.path, 'image'), isFalse);
      expect(notices.single, contains('stays not allowed'));
      await stop();
    });

    test('b. made stricter after the request was queued', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      final c = seams.holdNext();
      final f = nb.setBinderAiAccess(section.path, AiAccess.privileged);
      binderFile().writeAsStringSync(Binder.parse(fileText()).withAiAccess(AiAccess.guarded).write());
      c.complete();
      await f;
      expect(Binder.parse(fileText()).aiAccess, AiAccess.guarded);
      await stop();
    });

    test('c. a looser value on disk is replaced by a stricter request (guard)', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      await nb.setBinderAiAccess(section.path, AiAccess.guarded);
      expect(Binder.parse(fileText()).aiAccess, AiAccess.guarded);
      expect(notices, isEmpty);
      await stop();
    });

    test('d. a request that loosens with nothing stricter on disk lands (guard)', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      expect(Binder.parse(fileText()).aiAccess, AiAccess.open);
      expect(notices, isEmpty);
      await stop();
    });

    test('e. saved Guarded; Open refused; Privileged queued: Privileged lands with no notice', () async {
      await start();
      final c0 = seams.holdNext();
      final c1 = seams.holdNext();
      seams.failMoves = 5;
      final first = nb.setBinderAiAccess(section.path, AiAccess.open);
      final second = nb.setBinderAiAccess(section.path, AiAccess.privileged);
      c0.complete();
      await first;
      seams.failMoves = 0;
      c1.complete();
      await second;
      expect(Binder.parse(fileText()).aiAccess, AiAccess.privileged);
      expect(notices.where((n) => n.contains('stays')), isEmpty);
      await stop();
    });
  });

  group('14. a binder that was here is the only one taken up again', () {
    late String original;
    late String id;

    Future<void> begin() async {
      await start();
      original = fileText();
      id = section.saved!.id;
    }

    Future<void> foreignThenRestore() async {
      final other = foreign().write();
      binderFile().writeAsStringSync(other);
      await nb.checkBinderFile(binderFile().path);
      final s = nb.binders.single;
      expect(s.available, isFalse);
      expect(s.binder, isNull);
      expect(s.other!.title, 'Other');
      expect(s.reason, startsWith('This folder now holds another binder ("Other")'));
      expect(nb.isReadOnlyPage(pageId), isTrue);
      expect(fileText(), other, reason: 'the other binder file is not touched');
      binderFile().writeAsStringSync(original);
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.available, isTrue);
      expect(nb.binders.single.binder!.id, id);
    }

    test('original, missing, foreign', () async {
      await begin();
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.status, BinderStatus.unavailable);
      await foreignThenRestore();
      await stop();
    });

    test('original, damaged, foreign', () async {
      await begin();
      binderFile().writeAsStringSync('{oops');
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.status, BinderStatus.unreadable);
      await foreignThenRestore();
      await stop();
    });

    test('the folder gone, back with another binder', () async {
      await begin();
      await nb.flush();
      final moved = Directory('${root.path}/Elsewhere');
      folder.renameSync(moved.path);
      await nb.checkFolders();
      expect(nb.binders.single.missing, isTrue);
      moved.renameSync(folder.path);
      binderFile().writeAsStringSync(foreign().write());
      await nb.checkFolders();
      final s = nb.binders.single;
      expect(s.binder, isNull);
      expect(s.other, isNotNull);
      expect(s.available, isFalse);
      await stop();
    });

    test('a replacement between the watcher read and the reopen read', () async {
      await begin();
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      binderFile().writeAsStringSync(original);
      // The checker reads the original; before the reopen reads again, another
      // binder's file takes its place.
      seams.afterSweep = () {
        seams.afterSweep = null;
        binderFile().writeAsStringSync(foreign().write());
      };
      await nb.checkBinderFile(binderFile().path);
      final s = nb.binders.single;
      expect(s.available, isFalse);
      expect(s.other, isNotNull);
      expect(Binder.parse(fileText()).title, 'Other');
      await stop();
    });

    test('a restart lists the folder read-only too', () async {
      await begin();
      binderFile().writeAsStringSync(foreign().write());
      await nb.flush();
      final again = makeNotebook();
      await again.load();
      final s = again.binders.single;
      expect(s.available, isFalse);
      expect(s.other, isNotNull);
      again.dispose();
      await stop();
    });

    test('the same id reopens (guard)', () async {
      await begin();
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      binderFile().writeAsStringSync(original);
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.available, isTrue);
      expect(nb.binders.single.other, isNull);
      await stop();
    });

    test('Use this binder adopts the other binder and its id', () async {
      await begin();
      final other = foreign();
      binderFile().writeAsStringSync(other.write());
      await nb.checkBinderFile(binderFile().path);
      await nb.useThisBinder(section.path);
      final s = nb.binders.single;
      expect(s.available, isTrue);
      expect(s.binder!.id, other.id);
      final saved = jsonDecode(File('${root.path}/binders.json').readAsStringSync()) as Map;
      expect((saved['binderIds'] as Map).values, [other.id]);
      await stop();
    });

    test('Use this binder is refused for an id listed at another folder', () async {
      await begin();
      final second = await Directory('${root.path}/Second').create();
      final other = foreign(id: 'secondbinder0001', title: 'Second');
      File('${second.path}/$binderFileName').writeAsStringSync(other.write());
      await nb.addBinder(second.path);
      binderFile().writeAsStringSync(other.write());
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.first.other, isNotNull);
      await expectLater(nb.useThisBinder(section.path), throwsA(isA<NotebookException>()));
      expect(nb.binders.first.other, isNotNull);
      await stop();
    });

    test('Use this binder asks when cover changes of the old binder are pending', () async {
      await begin();
      seams.failMoves = 50;
      await nb.updateBinder(section.path, title: 'Draft');
      binderFile().writeAsStringSync(foreign().write());
      seams.failMoves = 0;
      await nb.checkBinderFile(binderFile().path);
      expect(nb.coverPendingFor(section.path), isNotEmpty);
      answer = false;
      await nb.useThisBinder(section.path);
      expect(asked.single.$1, UserQuestion.discardCoverChanges);
      expect(nb.binders.single.other, isNotNull, reason: 'declined: nothing changed');
      answer = true;
      await nb.useThisBinder(section.path);
      expect(nb.binders.single.available, isTrue);
      expect(nb.coverPendingFor(section.path), isEmpty);
      expect(Binder.parse(fileText()).title, 'Other');
      await stop();
    });
  });

  group('15. a missing file', () {
    test('a locked not-found read makes the binder unavailable at once, the file back reopens the page', () async {
      await start();
      final original = fileText();
      await nb.open(pageId);
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unavailable);
      expect(nb.currentId, standalonePage, reason: 'the fallback page');
      binderFile().writeAsStringSync(original);
      await nb.checkBinderFile(binderFile().path);
      final back = nb.binders.single;
      expect(back.available, isTrue);
      expect(nb.currentId, pageId, reason: 'the page that was open comes back');
      await stop();
    });

    test('a page the user opened meanwhile is not replaced', () async {
      await start();
      final original = fileText();
      await nb.open(pageId);
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      final other = await nb.createPage();
      await nb.open(other);
      binderFile().writeAsStringSync(original);
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.available, isTrue);
      expect(nb.currentId, other);
      await stop();
    });

    test('a not-found read after an abandoned lock wait decides nothing; it is checked again', () async {
      await start();
      final hold = Completer<void>();
      unawaited(nb.folderLocks.run(folder, () => hold.future));
      binderFile().deleteSync();
      final check = nb.checkBinderFile(binderFile().path);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(section.status, BinderStatus.available, reason: 'not acted on');
      hold.complete();
      await check;
      await until(() => nb.binders.single.status == BinderStatus.unavailable, 'the recheck');
      await stop();
    });

    test('a binder-file aside with no file is not unavailable; it is put back after the wait', () async {
      await start();
      final original = fileText();
      File('${folder.path}/$binderFileName.4242-ab12-cd34.cas-old').writeAsStringSync(original);
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.available);
      expect(binderFile().existsSync(), isFalse);
      await until(() => binderFile().existsSync(), 'the aside put back');
      expect(fileText(), original);
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.available, isTrue);
      await stop();
    });
  });

  group('16. kept copies of the binder file', () {
    // An update that ends with the file deleted leaves its temp.
    Future<BinderCopyRow> goneWithTemp() async {
      await start();
      seams.beforeMoveAside = () {
        seams.beforeMoveAside = null;
        binderFile().deleteSync();
      };
      await nb.setBinderBoxType(section.path, 'image', false);
      await nb.checkBinderFile(binderFile().path);
      final rows = nb.binderCopyRows(nb.binders.single);
      expect(rows, hasLength(1));
      return rows.single;
    }

    test('gone: the temp is listed at once with Put back; Put back restores it', () async {
      final row = await goneWithTemp();
      expect(nb.binders.single.status, BinderStatus.unavailable);
      expect(row.canPutBack, isTrue);
      expect(row.label, 'an interrupted change');
      await nb.putBackBinderCopy(section.path, row.path);
      expect(binderFile().existsSync(), isTrue);
      await until(() => nb.binders.single.available, 'the binder back');
      expect(nb.binderCopyRows(nb.binders.single), isEmpty);
      await stop();
    });


    test('R-3: a copy that arrives or goes while the app runs is listed or dropped through the change event', () async {
      await start();
      expect(nb.binderCopyRows(section), isEmpty);
      final copy = File('${folder.path}${Platform.pathSeparator}$binderFileName.1-2.tmp')..writeAsStringSync(fileText());
      await nb.filesChanged([copy.path]);
      expect(nb.binderCopyRows(nb.binders.single).map((r) => r.path), [copy.path]);
      copy.deleteSync();
      await nb.filesChanged([copy.path]);
      expect(nb.binderCopyRows(nb.binders.single), isEmpty);
      await stop();
    });

    testWidgets('R-2: a foreign copy offers only Delete; a valid copy offers Put back and Delete', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late String valid;
      late String foreignCopy;
      await t.runAsync(() async {
        await start();
        valid = '${folder.path}${Platform.pathSeparator}$binderFileName.1-2.tmp';
        foreignCopy = '${folder.path}${Platform.pathSeparator}noted-binder-conflict-ab.json';
        File(valid).writeAsStringSync(fileText());
        File(foreignCopy).writeAsStringSync(foreign().write());
        binderFile().deleteSync();
        await nb.checkBinderFile(binderFile().path);
        await nb.refreshBinderCopies(folder.path);
      });
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await t.pump();
      expect(find.byKey(ValueKey('binder-copy-put-back-$valid')), findsOneWidget);
      expect(find.byKey(ValueKey('binder-copy-delete-$valid')), findsOneWidget);
      expect(find.byKey(ValueKey('binder-copy-put-back-$foreignCopy')), findsNothing);
      expect(find.byKey(ValueKey('binder-copy-delete-$foreignCopy')), findsOneWidget);
      expect(find.textContaining("Copy of another binder's file"), findsOneWidget);
      final rows = {for (final r in nb.binderCopyRows(nb.binders.single)) r.path: r.forOtherBinder};
      expect(rows, {valid: false, foreignCopy: true});
      await t.pumpWidget(const SizedBox());
      await t.runAsync(stop);
    });

    test('R-1 (round 2): a copy replaced between the publish and its removal survives; the binder holds the verified bytes', () async {
      final row = await goneWithTemp();
      nb.putBackBeforeDeleteHook = () async => File(row.path).writeAsStringSync('a sync replacement');
      await nb.putBackBinderCopy(section.path, row.path);
      nb.putBackBeforeDeleteHook = null;
      expect(fileText(), utf8.decode(row.bytes!));
      expect(File(row.path).readAsStringSync(), 'a sync replacement');
      expect(nb.binderCopyRows(nb.binders.single).map((r) => r.path), contains(row.path));
      await nb.checkBinderFile(binderFile().path); // the reconcile that Put back queued
      await stop();
    });

    test('round 3: the binder file removed between the publish and the copy\'s removal: the copy survives', () async {
      final row = await goneWithTemp();
      nb.putBackBeforeDeleteHook = () async => binderFile().deleteSync();
      await nb.putBackBinderCopy(section.path, row.path);
      nb.putBackBeforeDeleteHook = null;
      expect(File(row.path).existsSync(), isTrue, reason: 'the only copy is kept');
      expect(File(row.path).readAsBytesSync(), row.bytes);
      await nb.checkBinderFile(binderFile().path);
      await stop();
    });

    test('the binder file replaced by another version of the same binder before the copy\'s removal: the copy survives '
        '(Codex run-diff-9 R-1)', () async {
      final row = await goneWithTemp();
      nb.putBackBeforeDeleteHook = () async {
        final json = jsonDecode(binderFile().readAsStringSync()) as Map<String, dynamic>;
        json['title'] = 'Changed on another device';
        binderFile().writeAsStringSync(jsonEncode(json));
      };
      await nb.putBackBinderCopy(section.path, row.path);
      nb.putBackBeforeDeleteHook = null;
      expect(File(row.path).existsSync(), isTrue, reason: 'the restored fields are kept only in the copy');
      expect(File(row.path).readAsBytesSync(), row.bytes);
      expect(nb.binderCopyRows(nb.binders.single).map((r) => r.path), contains(row.path));
      await nb.checkBinderFile(binderFile().path);
      expect(File(row.path).existsSync(), isTrue);
      expect(nb.binderCopyRows(nb.binders.single).map((r) => r.path), contains(row.path));
      await stop();
    });

    test('a pending cover change\'s temp, put back and kept, is not deleted when that change lands '
        '(Codex run-diff-9 R-1, reviewer)', () async {
      await start();
      var n = 0;
      seams.beforeMoveAside = () => externalReplace(owner: 'Them ${n++}');
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      seams.beforeMoveAside = null;
      final temp = nb.binderCopyRows(section).firstWhere((r) => r.label == 'an interrupted change');
      final kept = File(temp.path).readAsBytesSync();
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      nb.putBackBeforeDeleteHook = () async {
        final json = jsonDecode(binderFile().readAsStringSync()) as Map<String, dynamic>;
        json['owner'] = 'Another device';
        binderFile().writeAsStringSync(jsonEncode(json));
      };
      await nb.putBackBinderCopy(section.path, temp.path);
      nb.putBackBeforeDeleteHook = null;
      await nb.checkBinderFile(binderFile().path, force: true);
      nb.retryCovers();
      await until(() => textOrEmpty().contains('Draft'), 'the cover change lands');
      await idle();
      expect(File(temp.path).existsSync(), isTrue, reason: 'only its row\'s Delete removes a copy that was put back');
      expect(File(temp.path).readAsBytesSync(), kept);
      expect(nb.binderCopyRows(nb.binders.single).map((r) => r.path), contains(temp.path));
      await stop();
    });

    test('round 3: a check after a keepsChanging halt does not retry the cover change', () async {
      await start();
      var n = 0;
      seams.beforeMoveAside = () => externalReplace(owner: 'Them ${n++}');
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      seams.beforeMoveAside = null;
      await idle();
      final before = seams.updates;
      await nb.checkBinderFile(binderFile().path, force: true);
      await idle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await idle();
      expect(seams.updates, before, reason: 'the halt holds until resume, hide or quit');
      // A check with no force, on the unchanged file, does not lift it either.
      await nb.checkBinderFile(binderFile().path);
      await idle();
      expect(seams.updates, before, reason: 'a plain check does not retry');
      expect(nb.coverNotSaved(section.path), isTrue);
      nb.retryCovers();
      await until(() => !nb.coverNotSaved(section.path), 'the retry after resume');
      await stop();
    });

    test('round 4: Put back with a failed temp write: a NotebookException, the temp gone, a foreign file kept', () async {
      final row = await goneWithTemp();
      Set<String> tmps() => {
        for (final f in folder.listSync().whereType<File>())
          if (f.path.endsWith('.tmp')) f.path,
      };
      final before = tmps();
      seams.partialTempWrite = true;
      await expectLater(nb.putBackBinderCopy(section.path, row.path), throwsA(isA<NotebookException>()));
      expect(tmps(), before, reason: 'the part-written temp is gone');
      expect(binderFile().existsSync(), isFalse);
      // Someone else's file at the temp path is kept.
      seams.partialTempWrite = true;
      seams.afterPartialTemp = (t) {
        seams.afterPartialTemp = null;
        t.writeAsStringSync('someone else wrote this');
      };
      await expectLater(nb.putBackBinderCopy(section.path, row.path), throwsA(isA<NotebookException>()));
      final extra = tmps().difference(before);
      expect(extra, hasLength(1));
      expect(File(extra.single).readAsStringSync(), 'someone else wrote this');
      await stop();
    });

    test('round 4: Discard removes only the changes the user was asked about', () async {
      await start();
      seams.failMoves = 100;
      await nb.updateBinder(section.path, title: 'First');
      expect(nb.coverNotSaved(section.path), isTrue);
      nb.questioner = (q, title) async {
        // A change typed while the question is open.
        unawaited(nb.updateBinder(section.path, description: 'Added while asking'));
        return true;
      };
      expect(await nb.confirmDiscardCoverChanges(section.path), isTrue);
      final left = nb.coverPendingFor(section.path);
      expect(left.map((c) => c.fields), [
        {'description': 'Added while asking'},
      ]);
      seams.failMoves = 0;
      await until(() => textOrEmpty().contains('Added while asking'), 'the kept change to land');
      expect(fileText(), isNot(contains('First')));
      await stop();
    });

    test('round 4: removing the binder lifts the halt, so a change after re-adding it is retried', () async {
      await start();
      var n = 0;
      seams.beforeMoveAside = () => externalReplace(owner: 'Them ${n++}');
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      seams.beforeMoveAside = null;
      await idle();
      answer = true;
      await nb.removeBinder(section.path);
      final again = await nb.addBinder(folder.path);
      seams.failMoves = 5;
      expect(await nb.updateBinder(again.path, title: 'New'), isFalse);
      seams.failMoves = 0;
      await until(() => textOrEmpty().contains('"title":"New"'), 'the retry after re-adding');
      await stop();
    });

    test('an unlisted folder (no id recorded) uses the temp\'s own id', () async {
      final row = await goneWithTemp();
      nb.forgetBinderIdForTest(section.path);
      await nb.reopenForTest(section.path);
      final rows = nb.binderCopyRows(nb.binders.single);
      expect(rows.single.canPutBack, isTrue);
      await nb.putBackBinderCopy(section.path, rows.single.path);
      expect(binderFile().existsSync(), isTrue);
      expect(Binder.parse(fileText()).id, Binder.parse(utf8.decode(row.bytes!)).id);
      await stop();
    });

    test('Delete asks, and Cancel keeps; the only readable copy is named', () async {
      final row = await goneWithTemp();
      answer = false;
      expect(await nb.deleteBinderCopy(section.path, row.path), isFalse);
      expect(asked.single.$1, UserQuestion.deleteOnlyBinderCopy);
      expect(File(row.path).existsSync(), isTrue);
      answer = true;
      expect(await nb.deleteBinderCopy(section.path, row.path), isTrue);
      expect(File(row.path).existsSync(), isFalse);
      await stop();
    });

    test('Delete with a readable binder file asks the plain question', () async {
      final row = await goneWithTemp();
      await nb.putBackBinderCopy(section.path, row.path);
      await until(() => nb.binders.single.available, 'the binder back');
      final other = File('${folder.path}/$binderFileName.1-2.tmp')..writeAsStringSync('half');
      await nb.checkBinderFile(binderFile().path, force: true);
      await idle();
      await nb.reopenForTest(section.path);
      final rows = nb.binderCopyRows(nb.binders.single);
      expect(rows.single.label, "can't be read by this version");
      answer = false;
      await nb.deleteBinderCopy(section.path, rows.single.path);
      expect(asked.last.$1, UserQuestion.deleteBinderCopy);
      expect(other.existsSync(), isTrue);
      await stop();
    });

    test('a copy of another listed binder is refused; an unlisted folder uses the copy\'s own id', () async {
      final row = await goneWithTemp();
      // Another listed binder holds the id of the temp.
      final id = section.saved?.id ?? Binder.parse(utf8.decode(row.bytes!)).id;
      final second = await Directory('${root.path}/Second').create();
      File('${second.path}/$binderFileName').writeAsStringSync(
        Binder.create(id: 'secondbinder0001', title: 'Second', color: binderPalette.first).write(),
      );
      await nb.addBinder(second.path);
      // Make the copy hold the second binder's id: it belongs to another listed folder.
      final swapped = utf8.encode(Binder.parse(utf8.decode(row.bytes!)).write().replaceAll(id, 'secondbinder0001'));
      File(row.path).writeAsBytesSync(swapped);
      await nb.reopenForTest(section.path);
      final rows = nb.binderCopyRows(nb.binders.firstWhere((b) => b.path == section.path));
      expect(rows, isNotEmpty);
      await expectLater(
        nb.putBackBinderCopy(section.path, rows.first.path),
        throwsA(isA<NotebookException>()),
      );
      expect(binderFile().existsSync(), isFalse);
      await stop();
    });
  });

  group('17. a refused cover edit stays pending and lands by itself', () {
    test('inUse, then the lock is released: it lands, and its temps go only then', () async {
      await start();
      seams.failMoves = 5;
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      expect(nb.coverNotSaved(section.path), isTrue);
      expect(section.title, 'Draft', reason: 'the screen shows what was typed');
      expect(fileText(), isNot(contains('Draft')));
      seams.failMoves = 0;
      await until(() => !nb.coverNotSaved(section.path) && textOrEmpty().contains('Draft'), 'the retry');
      await idle();
      expect(nb.coverPendingFor(section.path), isEmpty);
      expect(nb.binderCopyRows(nb.binders.single), isEmpty, reason: 'the temp is not listed once its change landed');
      expect(names().where((n) => n.endsWith('.tmp')), isEmpty);
      await stop();
    });

    test('readOnly: Not saved yet, nothing written, no temp', () async {
      await start();
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['444', binderFile().path]);
      }
      addTearDown(() {
        if (Platform.isWindows) {
          Process.runSync('attrib', ['-R', binderFile().path]);
        } else {
          Process.runSync('chmod', ['644', binderFile().path]);
        }
      });
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      expect(nb.coverNotSaved(section.path), isTrue);
      expect(names().where((n) => n.endsWith('.tmp')), isEmpty);
      await nb.discardCoverChanges(section.path);
      await stop();
    });

    test('keepsChanging: Not saved yet, the temp is listed', () async {
      await start();
      var n = 0;
      seams.beforeMoveAside = () => externalReplace(owner: 'Them ${n++}');
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      seams.beforeMoveAside = null;
      expect(nb.coverNotSaved(section.path), isTrue);
      expect(nb.binderCopyRows(section).where((r) => r.label == 'an interrupted change'), isNotEmpty);
      await nb.discardCoverChanges(section.path);
      expect(nb.binderCopyRows(nb.binders.single).where((r) => r.label == 'an interrupted change'), isEmpty);
      await stop();
    });

    test('cantWrite: Not saved yet', () async {
      await start();
      seams.failTempWrites = 100;
      expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
      expect(nb.coverNotSaved(section.path), isTrue);
      seams.failTempWrites = 0;
      await until(() => textOrEmpty().contains('Draft'), 'the retry');
      await stop();
    });
  });

  test('18. a refused cover edit, then the binder damaged and repaired: it lands', () async {
    await start();
    final original = fileText();
    seams.failMoves = 5;
    await nb.updateBinder(section.path, title: 'Draft');
    seams.failMoves = 100;
    binderFile().writeAsStringSync('{oops');
    await nb.checkBinderFile(binderFile().path);
    expect(nb.binders.single.status, BinderStatus.unreadable);
    expect(nb.coverPendingFor(section.path), hasLength(1));
    seams.failMoves = 0;
    binderFile().writeAsStringSync(original);
    await nb.checkBinderFile(binderFile().path);
    await until(() => textOrEmpty().contains('Draft'), 'the cover change to land');
    expect(nb.coverPendingFor(section.path), isEmpty);
    await stop();
  });

  group('19. a change that can no longer be written is skipped', () {
    // The first change is held inside its update; the binder turns unreadable
    // while the second waits behind it, so the second's job finds it so (U0).
    test('a queued setting, the binder damaged before its job: nothing written; a cover stays pending', () async {
      await start();
      final c0 = seams.holdNext();
      final first = nb.setBinderBoxType(section.path, 'image', false);
      await until(() => seams.updates == 1, 'the first update to start');
      final second = nb.setBinderAiAccess(section.path, AiAccess.open);
      final third = nb.updateBinder(section.path, title: 'Draft');
      nb.markDamagedForTest(section.path);
      c0.complete();
      await first;
      await second;
      await third;
      final text = fileText();
      expect(text, isNot(contains('"ai"')), reason: 'the skipped change wrote nothing');
      expect(nb.coverPendingCountForTest(section.path), 1, reason: 'a cover change stays pending');
      expect(text, isNot(contains('Draft')));
      await stop();
    });

    test('19b. a skipped setting: the screen and aiAccessFor are back to saved, a notice, no temps', () async {
      await start();
      final c0 = seams.holdNext();
      final first = nb.setBinderBoxType(section.path, 'image', false);
      await until(() => seams.updates == 1, 'the first update to start');
      final second = nb.setBinderAiAccess(section.path, AiAccess.open);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.open);
      nb.markDamagedForTest(section.path);
      c0.complete();
      await first;
      await second;
      expect(notices.where((n) => n.contains("the change wasn't saved")), hasLength(1));
      expect(names().where((n) => n.endsWith('.tmp')), isEmpty);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(section.pending.where((p) => p.what == 'AI access'), isEmpty);
      await nb.reopenForTest(section.path);
      expect(nb.binderAiAccess(section.path), isNull);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.guarded);
      await nb.checkBinderFile(binderFile().path); // the reconcile that was queued
      await stop();
    });
  });

  test('20. a read during our own update is not a missing file (guard)', () async {
    await start();
    Future<void>? check;
    seams.beforePublish = () {
      seams.beforePublish = null;
      // The binder file is set aside right now.
      expect(binderFile().existsSync(), isFalse);
      check = nb.checkBinderFile(binderFile().path);
    };
    await nb.setBinderAiAccess(section.path, AiAccess.open);
    await check;
    await idle();
    expect(nb.binders.single.status, BinderStatus.available);
    expect(Binder.parse(fileText()).aiAccess, AiAccess.open);
    await stop();
  });

  group('22. typing taken before a state change', () {
    Future<void> cover(WidgetTester t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: BinderCover(notebook: nb, path: section.path))));
      await t.pump();
    }

    Future<void> run(WidgetTester t, Future<void> Function() f) async {
      var done = false;
      Object? error;
      unawaited(
        f().then<void>(
          (_) => done = true,
          onError: (Object e) {
            error = e;
            done = true;
          },
        ),
      );
      for (var i = 0; i < 400 && !done; i++) {
        await t.pump(const Duration(milliseconds: 25));
        await t.runAsync(() => realIoPause(20));
      }
      expect(done, isTrue);
      if (error != null) throw error!;
    }

    Future<void> drain(WidgetTester t) async {
      for (var i = 0; i < 400 && nb.unsavedDescription != null; i++) {
        await t.pump(const Duration(milliseconds: 25));
        await t.runAsync(() => realIoPause(20));
      }
    }

    Future<void> begin(WidgetTester t) async {
      await t.runAsync(start);
      await t.pumpWidget(const SizedBox());
      nb.showCover(section.path);
      await cover(t);
    }

    Future<void> end(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await drain(t);
      await t.runAsync(stop);
    }

    for (final (name, damage, repair) in <(String, void Function(), void Function(String))>[
      ('damaged', () => binderFile().writeAsStringSync('{oops'), (o) => binderFile().writeAsStringSync(o)),
      ('missing', () => binderFile().deleteSync(), (o) => binderFile().writeAsStringSync(o)),
    ]) {
      testWidgets('the typing survives: $name', (t) async {
        await begin(t);
        final original = await t.runAsync(() async => fileText());
        await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed title');
        await t.pump();
        await t.runAsync(() async => damage());
        await run(t, () => nb.checkBinderFile(binderFile().path));
        expect(nb.coverPendingFor(section.path).map((c) => c.fields['title']), ['Typed title']);
        await t.runAsync(() async => repair(original!));
        await run(t, () => nb.checkBinderFile(binderFile().path));
        await drain(t);
        await run(t, () => until(() => textOrEmpty().contains('Typed title'), 'the typing to land'));
        await end(t);
      });
    }

    testWidgets('another binder\'s file: the typing is kept, nothing lands on the other binder, the same binder lands it', (t) async {
      await begin(t);
      final original = await t.runAsync(() async => fileText());
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed title');
      await t.pump();
      final other = foreign().write();
      await t.runAsync(() async => binderFile().writeAsStringSync(other));
      await run(t, () => nb.checkBinderFile(binderFile().path));
      expect(nb.coverPendingFor(section.path), hasLength(1));
      await drain(t);
      expect(fileText(), other);
      await t.runAsync(() async => binderFile().writeAsStringSync(original!));
      await run(t, () => nb.checkBinderFile(binderFile().path));
      await run(t, () => until(() => textOrEmpty().contains('Typed title'), 'the typing to land'));
      await end(t);
    });

    testWidgets('typed in the cover, the binder goes away, another device changes the description: the title lands and the description survives', (t) async {
      await begin(t);
      final original = await t.runAsync(() async => fileText());
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed while away');
      await t.pump();
      await t.runAsync(() async => binderFile().deleteSync());
      await run(t, () => nb.checkBinderFile(binderFile().path));
      expect(nb.binders.single.status, BinderStatus.unavailable);
      expect(nb.coverPendingFor(section.path), hasLength(1));
      // Another device changed the description meanwhile.
      final theirs = Binder.parse(original!).withDescription('Their description').write();
      await t.runAsync(() async => binderFile().writeAsStringSync(theirs));
      await run(t, () => nb.checkBinderFile(binderFile().path));
      await run(t, () => until(() => textOrEmpty().contains('Typed while away'), 'the title to land'));
      expect(Binder.parse(fileText()).description, 'Their description');
      await end(t);
    });

    testWidgets('a delta with no recorded id carries the shown binder\'s id; X\'s file is not given A\'s text', (t) async {
      await begin(t);
      // No id is recorded for the folder (an upgrade left none).
      nb.forgetBinderIdForTest(section.path);
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed title');
      await t.pump();
      final other = foreign().write();
      await t.runAsync(() async => binderFile().writeAsStringSync(other));
      await run(t, () => nb.checkBinderFile(binderFile().path));
      await drain(t);
      expect(fileText(), other, reason: 'nothing lands on the other binder');
      expect(nb.coverPendingCountForTest(section.path), 1);
      final x = nb.binders.single;
      expect(x.title, isNot('Typed title'), reason: 'the sidebar does not show A\'s text');
      expect(x.title, 'Other');
      expect(nb.coverPendingFor(section.path), isEmpty, reason: 'A\'s change is not shown as X\'s');
      // X\'s cover shows X\'s values, not A\'s text.
      nb.showCover(section.path);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: BinderCover(notebook: nb, path: section.path))));
      await t.pump();
      expect((t.widget(find.byKey(const ValueKey('cover-title'))) as TextField).controller!.text, 'Other');
      // Leaving X\'s cover records nothing.
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await drain(t);
      expect(nb.coverPendingCountForTest(section.path), 1);
      expect(fileText(), other);
      await end(t);
    });

    testWidgets('the dispose microtask after a state change records nothing more', (t) async {
      await begin(t);
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed title');
      await t.pump();
      await t.runAsync(() async => binderFile().writeAsStringSync('{oops'));
      await run(t, () => nb.checkBinderFile(binderFile().path));
      expect(nb.coverPendingFor(section.path), hasLength(1));
      // The cover closes; its dispose call finds the text equal to the base.
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(nb.coverPendingFor(section.path), hasLength(1));
      await end(t);
    });

    testWidgets('Discard with the field focused, then leaving the cover records nothing', (t) async {
      await begin(t);
      seams.failMoves = 100;
      await t.tap(find.byKey(const ValueKey('cover-title')));
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed title');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cover-owner')));
      await run(t, () async {});
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cover-title')));
      await t.pump();
      await run(t, () => until(() => nb.coverNotSaved(section.path), 'not saved yet'));
      await run(t, idle);
      await t.pump();
      expect(find.byKey(const ValueKey('cover-not-saved')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cover-discard')));
      await run(t, () => until(() => nb.coverPendingFor(section.path).isEmpty, 'the confirmed discard'));
      await run(t, () => nb.runOnChainForTest(() async {}));
      await run(t, () => nb.refreshBinderCopies(folder.path)); // after the discard's own listing
      expect(asked.last.$1, UserQuestion.discardCoverChanges, reason: 'the cover Discard asks first');
      await t.pump();
      expect(nb.coverPendingFor(section.path), isEmpty);
      expect((t.widget(find.byKey(const ValueKey('cover-title'))) as TextField).controller!.text, 'Work');
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await drain(t);
      expect(nb.coverPendingFor(section.path), isEmpty, reason: 'leaving the cover recorded nothing');
      seams.failMoves = 0;
      await t.runAsync(stop);
    });
  });

  group('23. quit and hide', () {
    Future<void> cover(WidgetTester t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: BinderCover(notebook: nb, path: section.path))));
      await t.pump();
    }

    Future<T> run<T>(WidgetTester t, Future<T> Function() f) async {
      var done = false;
      T? value;
      Object? error;
      unawaited(
        f().then((v) {
          value = v;
          done = true;
        }).catchError((Object e) {
          error = e;
          done = true;
        }),
      );
      for (var i = 0; i < 600 && !done; i++) {
        await t.pump(const Duration(milliseconds: 25));
        await t.runAsync(() => realIoPause(20));
      }
      expect(done, isTrue);
      if (error != null) throw error!;
      return value as T;
    }

    Future<void> begin(WidgetTester t) async {
      await t.runAsync(start);
      await t.pumpWidget(const SizedBox());
      nb.showCover(section.path);
      await cover(t);
    }

    Future<void> end(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 200 && nb.unsavedDescription != null; i++) {
        await t.pump(const Duration(milliseconds: 25));
        await t.runAsync(() => realIoPause(20));
      }
      await t.runAsync(stop);
    }

    testWidgets('a pending cover change at quit: one try, then the question; Cancel keeps Noted open; Leave quits', (t) async {
      await begin(t);
      seams.failMoves = 10000;
      await run(t, () => nb.updateBinder(section.path, title: 'Draft'));
      expect(nb.coverNotSaved(section.path), isTrue);
      answer = false;
      expect(await run(t, () => nb.prepareToExit()), isFalse);
      expect(asked.single.$1, UserQuestion.leaveCoverUnsaved);
      expect(asked.single.$2, contains('title'));
      expect(nb.coverPendingFor(section.path), hasLength(1));
      answer = true;
      asked.clear();
      expect(await run(t, () => nb.prepareToExit()), isTrue);
      expect(asked, hasLength(1));
      seams.failMoves = 0;
      await end(t);
    });

    testWidgets('quit with a focused field and unsent typing: taken, tried and landed', (t) async {
      await begin(t);
      await t.tap(find.byKey(const ValueKey('cover-title')));
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed at quit');
      await t.pump();
      expect(fileText(), isNot(contains('Typed at quit')));
      expect(await run(t, () => nb.prepareToExit()), isTrue);
      expect(asked, isEmpty);
      expect(fileText(), contains('Typed at quit'));
      await end(t);
    });

    testWidgets('quit refused for the typing: the question names it', (t) async {
      await begin(t);
      seams.failMoves = 10000;
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed at quit');
      await t.pump();
      answer = false;
      expect(await run(t, () => nb.prepareToExit()), isFalse);
      expect(asked.single.$1, UserQuestion.leaveCoverUnsaved);
      seams.failMoves = 0;
      await end(t);
    });

    // The real lifecycle: NotedApp's AppLifecycleListener reaches coverHidden
    // (main.dart onHide), not only a direct call.
    Future<void> beginApp(WidgetTester t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(start);
      nb.showCover(section.path);
      await t.pumpWidget(NotedApp(notebook: nb, settings: AppSettings(null)));
      await t.pump();
    }

    void hide(WidgetTester t) {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }

    testWidgets('hide (the app lifecycle) takes the typing and lands it', (t) async {
      await beginApp(t);
      seams.failMoves = 10000;
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed at hide');
      await t.pump();
      hide(t);
      await run(t, () async {});
      expect(nb.coverPendingFor(section.path).map((c) => c.fields['title']), ['Typed at hide']);
      seams.failMoves = 0;
      await run(t, () => until(() => textOrEmpty().contains('Typed at hide'), 'the hide write'));
      await end(t);
    });

    testWidgets('quit, Cancel, type more in the open cover, leave it: the dispose microtask carries it', (t) async {
      await begin(t);
      seams.failMoves = 10000;
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'First');
      await t.pump();
      answer = false;
      expect(await run(t, () => nb.prepareToExit()), isFalse);
      expect(nb.coverPendingFor(section.path).map((c) => c.fields['title']), ['First']);
      // The cover stays open; more typing follows, and then the cover closes
      // with the field still focused.
      await t.tap(find.byKey(const ValueKey('cover-description')));
      await t.enterText(find.byKey(const ValueKey('cover-description')), 'More typing');
      await t.pump();
      expect(nb.coverPendingFor(section.path).any((c) => c.fields.containsKey('description')), isFalse);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await run(t, () async {});
      expect(nb.coverPendingFor(section.path).any((c) => c.fields['description'] == 'More typing'), isTrue);
      seams.failMoves = 0;
      await run(t, () => until(() => textOrEmpty().contains('More typing'), 'it to land'));
      await end(t);
    });

    testWidgets('hide (the app lifecycle), more typing, leave the cover: the dispose microtask carries it', (t) async {
      await beginApp(t);
      seams.failMoves = 10000;
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'First');
      await t.pump();
      hide(t);
      await run(t, () async {});
      expect(nb.coverPendingFor(section.path).map((c) => c.fields['title']), ['First']);
      // Frames are off while hidden: the app comes back, and the cover is still open.
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cover-owner')));
      await t.enterText(find.byKey(const ValueKey('cover-owner')), 'Later');
      await t.pump();
      // Leaving the cover with the field still focused.
      await t.pumpWidget(const SizedBox());
      await run(t, () => until(() => nb.coverPendingFor(section.path).any((c) => c.fields['owner'] == 'Later'), 'the dispose call to record it'));
      await t.pump();
      expect(nb.coverPendingFor(section.path).any((c) => c.fields['owner'] == 'Later'), isTrue);
      seams.failMoves = 0;
      await end(t);
    });
  });

  test('24. Discard of a cover change whose temp fails g: the change is gone, the temp is listed', () async {
    await start();
    // The update ends gone: the file is deleted while the first try is under way.
    seams.beforeMoveAside = () {
      seams.beforeMoveAside = null;
      binderFile().deleteSync();
    };
    expect(await nb.updateBinder(section.path, title: 'Draft'), isFalse);
    expect(binderFile().existsSync(), isFalse);
    await nb.checkBinderFile(binderFile().path);
    expect(nb.coverPendingFor(section.path), hasLength(1));
    await nb.discardCoverChanges(section.path);
    expect(nb.coverPendingFor(section.path), isEmpty);
    final rows = nb.binderCopyRows(nb.binders.single);
    expect(rows, hasLength(1));
    expect(File(rows.single.path).existsSync(), isTrue);
    await stop();
  });
}
