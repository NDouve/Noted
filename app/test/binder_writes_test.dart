// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Binder writes (R-2): a change is reapplied to the file as it is on disk, a
// refused change shows the saved value again, and nothing that is not saved
// loosens what AI may do. Run with `--dart-define=CACHED_SAVE=true` to run the
// tests against the old cached save and see which of them fail on it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_core/noted_core.dart';

import 'support/binder_seams.dart';
import 'support/real_io.dart';
import 'support/settle_saves.dart';

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

  File binderFile() => File('${folder.path}${Platform.pathSeparator}$binderFileName');
  String fileText() => binderFile().readAsStringSync();

  Notebook makeNotebook({bool watch = false}) => Notebook(
    PageStore(Directory('${root.path}/pages')),
    buildModules(),
    saveDelay: Duration.zero,
    bindersFile: File('${root.path}/binders.json'),
    binderStoreFactory: (d) => SeamStore(d, seams),
    watchFiles: watch,
    watchDebounce: const Duration(milliseconds: 50),
  );

  Future<void> start({bool watch = false}) async {
    seams = Seams();
    notices = [];
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

  Future<void> stop() async {
    for (final g in seams.gates) {
      if (!g.isCompleted) g.complete();
    }
    await nb.flush();
    // A check queued after a refused change has finished.
    await nb.checkBinderFile(binderFile().path);
    await noticeSub.cancel();
    nb.dispose();
    await root.delete(recursive: true);
  }

  // What another device does: replace the file behind the app's back, adding a
  // field this build doesn't know and a cover field.
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

  Future<BinderRefused?> refusedSetting(Future<void> Function() f) async {
    try {
      await f();
      return null;
    } on NotebookException catch (e) {
      return BinderRefused(BinderRefusal.inUse, e.message);
    }
  }

  group('7. a refused update shows the saved value', () {
    test('the setting, the AI value, the cover and a fresh notebook', () async {
      await start();
      seams.failRenames = 5;
      final r = await refusedSetting(() => nb.setBinderAiAccess(section.path, AiAccess.open));
      expect(r, isNotNull);
      expect(r!.reason, startsWith('The binder file is in use by another program'));
      expect(nb.binderAiAccess(section.path), isNull);
      expect(section.binder!.aiAccess, isNull);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.guarded);
      expect(section.pending, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notices.single, startsWith("Binder Work: the change wasn't saved."));

      seams.failRenames = 5;
      expect(await nb.updateBinder(section.path, title: 'Renamed'), isFalse);
      expect(section.title, 'Work');
      await nb.flush();
      expect(fileText(), isNot(contains('Renamed')));
      expect(fileText(), isNot(contains('"ai"')));

      final again = makeNotebook();
      await again.load();
      final fresh = await again.addBinder(folder.path);
      expect(fresh.binder!.title, 'Work');
      expect(again.binderAiAccess(fresh.path), isNull);
      again.dispose();
      await stop();
    });

    test('a read-only file is named as such', () async {
      await start();
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['444', binderFile().path]);
      }
      final r = await refusedSetting(() => nb.setBinderBoxType(section.path, 'image', false));
      if (Platform.isWindows) {
        Process.runSync('attrib', ['-R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['644', binderFile().path]);
      }
      expect(r!.reason, 'The binder file is read-only');
      expect(nb.binderBoxType(section.path, 'image'), isNull);
      await stop();
    }, skip: seamsUseCached());

    testWidgets('the settings panel shows the reason inline and the saved value', (t) async {
      late SettingsPanel panel;
      await t.runAsync(() async {
        await start();
        seams.failRenames = 5;
        panel = SettingsPanel.binder(notebook: nb, binderPath: section.path);
      });
      t.view.physicalSize = const Size(1000, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: panel)));
      await t.pump();
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('settings-ai-open')));
        await realIoPause(100);
      });
      await settleSaves(t, nb);
      await t.pump();
      expect(find.textContaining('The binder file is in use by another program'), findsOneWidget);
      expect(
        t.widget<ChoiceChip>(find.byKey(const ValueKey('settings-ai-open'))).selected,
        isFalse,
      );
      await t.pumpWidget(const SizedBox());
      await t.runAsync(stop);
    });
  });

  test('8. a refused first change with a second queued: saved plus the second', () async {
    await start();
    final c0 = seams.holdNext();
    final c1 = seams.holdNext();
    seams.failRenames = 5; // update 0 fails on every try
    final first = refusedSetting(() => nb.setBinderAiAccess(section.path, AiAccess.open));
    final second = nb.updateBinder(section.path, title: 'Second');
    expect(nb.binderAiAccess(section.path), AiAccess.open);
    expect(section.title, 'Second');
    c0.complete();
    expect(await first, isNotNull);
    // The second change is still waiting: the screen is saved plus the second.
    expect(nb.binderAiAccess(section.path), isNull);
    expect(section.title, 'Second');
    expect(section.pending, hasLength(1));
    c1.complete();
    expect(await second, isTrue);
    expect(section.pending, isEmpty);
    expect(fileText(), contains('"title":"Second"'));
    expect(fileText(), isNot(contains('"ai"')));
    expect(section.saved!.title, 'Second');
    await stop();
  });

  group('9. a change after an external replacement keeps the external fields', () {
    // Each change is made right after the file was replaced, without the watcher
    // or checkBinderFile having seen it.
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

  group('10. the watcher reads strictly', () {
    test('invalid UTF-8 makes the binder unreadable and writes nothing', () async {
      await start();
      final bytes = [...utf8.encode('{"format":1,"binderId":"x","title":"'), 0xff, 0xfe, ...utf8.encode('"}')];
      binderFile().writeAsBytesSync(bytes);
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unreadable);
      expect(nb.isReadOnlyPage(pageId), isTrue);
      expect(binderFile().readAsBytesSync(), bytes);
      expect(await nb.updateBinder(section.path, title: 'x'), isFalse);
      expect(binderFile().readAsBytesSync(), bytes);
      await stop();
    });

    test('an I/O error keeps the binder available', () async {
      await start();
      seams.failReads = true;
      await nb.checkBinderFile(binderFile().path, force: true);
      expect(section.status, BinderStatus.available);
      expect(section.binder!.title, 'Work');
      expect(nb.isReadOnlyPage(pageId), isFalse);
      seams.failReads = false;
      await stop();
    });

    test('a read error when the binder is opened makes it unavailable, then it reopens', () async {
      await start();
      await nb.removeBinder(section.path);
      seams.failReads = true;
      final s = await nb.addBinder(folder.path);
      expect(s.status, BinderStatus.unavailable);
      expect(s.reason, contains("can't be read right now"));
      seams.failReads = false;
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.available, isTrue);
      await stop();
    });

    test('the watcher does not adopt another binder\'s file', () async {
      await start();
      final other = Binder.create(id: 'otherbinder00001', title: 'Other', color: binderPalette.first).write();
      binderFile().writeAsStringSync(other);
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unavailable);
      expect(section.reason, 'The binder file in this folder belongs to another binder');
      expect(section.pending, isEmpty);
      expect(fileText(), other);
      await stop();
    });

    test('a change meant for the old binder is dropped, and the folder is read afresh', () async {
      await start();
      final c0 = seams.holdNext();
      final f = nb.setBinderAiAccess(section.path, AiAccess.open).catchError((Object _) {});
      expect(section.pending, hasLength(1));
      final other = Binder.create(id: 'otherbinder00001', title: 'Other', color: binderPalette.first).write();
      binderFile().writeAsStringSync(other);
      c0.complete();
      await f;
      await nb.checkBinderFile(binderFile().path); // waits for the queued reopen
      expect(section.pending, isEmpty);
      expect(nb.binders.single.binder!.id, 'otherbinder00001');
      expect(nb.binders.single.binder!.aiAccess, isNull);
      expect(fileText(), other, reason: 'the other binder\'s file is not written');
      expect(notices.any((n) => n.contains('now belongs to another binder')), isTrue);
      await stop();
    });
  });

  test('11. a binder file that appears while a binder is created is opened as it is', () async {
    await start();
    await nb.removeBinder(section.path);
    binderFile().deleteSync();
    seams.beforePublish = () => binderFile().writeAsStringSync(
      Binder.create(id: 'theirs0000000001', title: 'Theirs', color: binderPalette[2]).write(),
    );
    final s = await nb.addBinder(folder.path);
    expect(s.available, isTrue);
    expect(s.binder!.id, 'theirs0000000001');
    expect(s.title, 'Theirs');
    expect(Binder.parse(fileText()).title, 'Theirs');
    expect(folder.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
    await stop();
  });

  group('12. nothing unsaved loosens what AI may do', () {
    test('a pending loosening of AI access and of a box type', () async {
      await start();
      final type = nb.switchableBoxTypes.first;
      await nb.setBinderBoxType(section.path, type, false);
      expect(nb.aiMergeTypeAllowed(pageId, type), isFalse);
      final target = AiCodeTarget.binder(section.binder!.id);
      expect(nb.aiReadablePages(target), isEmpty);

      final gate = seams.holdNext();
      final open = nb.setBinderAiAccess(section.path, AiAccess.open);
      // The screen shows Open; AI still sees what is saved.
      expect(nb.binderAiAccess(section.path), AiAccess.open);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.open);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(nb.aiReadablePages(target), isEmpty);

      final allow = nb.setBinderBoxType(section.path, type, null);
      expect(nb.boxTypeAvailabilityFor(pageId, type).allowed, isTrue);
      expect(nb.aiMergeTypeAllowed(pageId, type), isFalse);

      gate.complete();
      await Future.wait([open, allow]);
      expect(nb.aiAccessFor(pageId).value, AiAccess.open);
      expect(nb.aiReadablePages(target), [pageId]);
      expect(nb.aiMergeTypeAllowed(pageId, type), isTrue);
      await stop();
    });

    test('a refused loosening never applies', () async {
      await start();
      seams.failRenames = 5;
      final r = refusedSetting(() => nb.setBinderAiAccess(section.path, AiAccess.open));
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(await r, isNotNull);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(nb.shownAiAccessFor(pageId).value, AiAccess.guarded);
      await stop();
    });

    test('a pending tightening applies at once', () async {
      await start();
      await nb.setBinderAiAccess(section.path, AiAccess.open);
      expect(nb.aiAccessFor(pageId).value, AiAccess.open);
      final c = seams.holdNext();
      final tighten = nb.setBinderAiAccess(section.path, AiAccess.guarded);
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      expect(nb.aiReadablePages(AiCodeTarget.binder(section.binder!.id)), isEmpty);
      c.complete();
      await tighten;
      expect(nb.aiAccessFor(pageId).value, AiAccess.guarded);
      await stop();
    });
  });

  test('14. another writer loosening AI access this device wrote posts a notice once', () async {
    await start();
    await nb.setBinderAiAccess(section.path, AiAccess.guarded);
    binderFile().writeAsStringSync(Binder.parse(fileText()).withAiAccess(AiAccess.open).write());
    await nb.checkBinderFile(binderFile().path);
    await nb.checkBinderFile(binderFile().path, force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notices, [
      'Binder Work: AI access was changed to Open outside this app (it was Guarded).',
    ]);
    // A tightening is not announced.
    binderFile().writeAsStringSync(Binder.parse(fileText()).withAiAccess(AiAccess.guarded).write());
    await nb.checkBinderFile(binderFile().path);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notices, hasLength(1));
    await stop();
  });

  group('15. kept temporary files', () {
    File temp(String name, String text) {
      final f = File('${folder.path}/$name')..writeAsStringSync(text);
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      return f;
    }

    test('listed, kept over a rescan, not blocking everythingReadable, and deleted', () async {
      await start();
      final other = Binder.parse(fileText()).withTitle('Interrupted').write();
      final t = temp('$binderFileName.1-1.tmp', other);
      await nb.checkBinderFile(binderFile().path);
      expect(section.keptTemps, hasLength(1));
      expect(section.unreadable, isEmpty);
      expect(nb.everythingReadable, isTrue);
      await nb.checkBinderFile(binderFile().path, force: true);
      expect(section.keptTemps, hasLength(1));
      expect(t.existsSync(), isTrue);

      await nb.deleteKeptBinderTemp(section.path, section.keptTemps.single.path);
      expect(t.existsSync(), isFalse);
      expect(section.keptTemps, isEmpty);
      await stop();
    });

    test('a temp that changed since it was listed is kept', () async {
      await start();
      final t = temp('$binderFileName.1-2.tmp', 'first');
      await nb.checkBinderFile(binderFile().path);
      expect(section.keptTemps, hasLength(1));
      t.writeAsStringSync('second');
      t.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      await expectLater(
        nb.deleteKeptBinderTemp(section.path, section.keptTemps.single.path),
        throwsA(isA<NotebookException>()),
      );
      expect(t.readAsStringSync(), 'second');
      expect(section.keptTemps.single.bytes, utf8.encode('second'));
      await stop();
    });

    test('with no binder file, a complete copy is offered back and put back', () async {
      await start();
      final text = fileText();
      binderFile().deleteSync();
      final t = temp('$binderFileName.1-3.tmp', text);
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unavailable);
      expect(section.keptTemps.single.complete, isTrue);
      await nb.putBackKeptBinderTemp(section.path, section.keptTemps.single.path);
      expect(fileText(), text);
      expect(t.existsSync(), isFalse);
      expect(nb.binders.single.available, isTrue);
      await stop();
    });

    test('a complete copy is not put back over a file that appeared', () async {
      await start();
      final text = fileText();
      binderFile().deleteSync();
      temp('$binderFileName.1-4.tmp', text);
      await nb.checkBinderFile(binderFile().path);
      binderFile().writeAsStringSync('theirs');
      await expectLater(
        nb.putBackKeptBinderTemp(section.path, section.keptTemps.single.path),
        throwsA(isA<NotebookException>()),
      );
      expect(fileText(), 'theirs');
      await stop();
    });

    test('a binder opened at startup lists them, and the sweep runs before the page scan', () async {
      await start();
      final aside = File('${folder.path}/$binderFileName.1-5.tmp.77-1-1$asideSuffix')
        ..writeAsStringSync('x');
      aside.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final other = temp('$binderFileName.1-6.tmp', 'other');
      await nb.removeBinder(section.path);
      final s = await nb.addBinder(folder.path);
      expect(s.keptTemps.map((k) => k.path.split(RegExp(r'[\\/]')).last), contains(
        other.path.split(RegExp(r'[\\/]')).last,
      ));
      expect(s.unreadable, isEmpty);
      await stop();
    });
  });

  group('16. results for a binder that was removed are ignored', () {
    test('a queued change never runs', () async {
      await start();
      await nb.open(standalonePage); // removing a binder with the open page waits for saves
      final c0 = seams.holdNext();
      final held = nb.setBinderAiAccess(section.path, AiAccess.open).catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 30)); // the first write is under way
      final queued = nb.updateBinder(section.path, title: 'Queued');
      final removed = nb.removeBinder(section.path);
      c0.complete();
      await Future.wait([held, queued, removed]);
      expect(seams.updates, 1);
      expect(fileText(), isNot(contains('Queued')));
      await stop();
    });

    test('a result for the removed section is not applied to it or to the new one', () async {
      await start();
      await nb.open(standalonePage);
      final c0 = seams.holdNext();
      final held = nb.setBinderAiAccess(section.path, AiAccess.open).catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final removed = nb.removeBinder(section.path);
      final added = nb.addBinder(folder.path);
      c0.complete();
      await Future.wait([held, removed]);
      final again = await added;
      expect(identical(again, section), isFalse);
      expect(section.saved!.aiAccess, isNull, reason: 'the old section did not take the result');
      expect(again.pending, isEmpty);
      await stop();
    });
  });

  group('13. a refused cover edit keeps the typed text', () {
    testWidgets('and saves it again when the field loses focus', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(start);
      await t.pumpWidget(
        MaterialApp(home: Scaffold(body: BinderCover(notebook: nb, path: section.path))),
      );
      await t.pump();
      String text(String key) => t.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

      seams.failRenames = 5;
      await t.tap(find.byKey(const ValueKey('cover-title')));
      await t.enterText(find.byKey(const ValueKey('cover-title')), 'Typed');
      await t.tap(find.byKey(const ValueKey('cover-owner'))); // leaves the title: saves
      await t.pump();
      await settleSaves(t, nb);
      await t.pump();
      expect(section.title, 'Work', reason: 'the screen value is the saved one');
      expect(text('cover-title'), 'Typed', reason: 'the typing is kept');
      expect(fileText(), isNot(contains('Typed')));

      // Leaving another field tries again, once per blur.
      final before = seams.updates;
      await t.tap(find.byKey(const ValueKey('cover-description')));
      await t.pump();
      await settleSaves(t, nb);
      await t.pump();
      expect(seams.updates, before + 1);
      expect(section.title, 'Typed');
      expect(fileText(), contains('"title":"Typed"'));

      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await realIoPause(50);
      });
      await settleSaves(t, nb);
      await t.runAsync(stop);
    });
  });

  group('sidebar', () {
    testWidgets('a kept temp is listed in Can\'t open with Delete; a complete copy has Put back', (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late File tmp;
      await t.runAsync(() async {
        await start();
        tmp = File('${folder.path}/$binderFileName.1-9.tmp')..writeAsStringSync('half a binder');
        tmp.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
        await nb.checkBinderFile(binderFile().path);
      });
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await t.pump();
      expect(find.text("CAN'T OPEN"), findsOneWidget);
      expect(find.text('an interrupted change to the binder file'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.byKey(ValueKey('kept-temp-delete-${nb.binders.single.keptTemps.single.path}')));
        await realIoPause(100);
      });
      await settleSaves(t, nb);
      await t.pump();
      expect(tmp.existsSync(), isFalse);
      expect(find.text('an interrupted change to the binder file'), findsNothing);

      // No binder file, and a complete copy of it.
      late File copy;
      await t.runAsync(() async {
        final text = fileText();
        binderFile().deleteSync();
        copy = File('${folder.path}/$binderFileName.1-10.tmp')..writeAsStringSync(text);
        copy.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
        await nb.checkBinderFile(binderFile().path);
      });
      await t.pump();
      expect(find.text('a complete copy of the binder file'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      await t.runAsync(() async {
        await t.tap(find.byKey(ValueKey('kept-temp-put-back-${nb.binders.single.keptTemps.single.path}')));
        await realIoPause(100);
      });
      await settleSaves(t, nb);
      await t.pump();
      expect(binderFile().existsSync(), isTrue);
      expect(find.text('a complete copy of the binder file'), findsNothing);

      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
        await t.runAsync(() => realIoPause(30));
      }
      await settleSaves(t, nb);
      await t.runAsync(stop);
    }, skip: seamsUseCached());
  });
}

bool seamsUseCached() => cachedSaveByDefault;
