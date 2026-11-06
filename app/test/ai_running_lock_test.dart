// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted/src/ai/ai_link_server.dart';
import 'package:noted/src/ai/ai_running_lock.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/lock_holder_process.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('noted_running'));
  tearDown(() => dir.deleteSync(recursive: true));

  File lockFile() => File('${dir.path}/$aiRunningLockFileName');

  // Another handle taking the lock; null if it is held. OS locks between
  // handles of one process conflict on Windows only.
  RandomAccessFile? probe() {
    final f = lockFile().openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.exclusive);
      return f;
    } on FileSystemException {
      f.closeSync();
      return null;
    }
  }

  test('the file name is the one noted_mcp uses', () {
    expect(aiRunningLockFileName, 'noted-running.lock');
  });

  test('the lock is held until released, and the file is created', () {
    final lock = AiRunningLock(dir);
    expect(lock.acquire(), isTrue);
    expect(lock.held, isTrue);
    expect(lockFile().existsSync(), isTrue);
    if (Platform.isWindows) expect(probe(), isNull, reason: 'held while the app runs');
    lock.release();
    expect(lock.held, isFalse);
    final p = probe();
    expect(p, isNotNull, reason: 'released');
    p!.closeSync();
    lock.release(); // again: harmless
    lock.dispose();
  });

  test('9a. a shared holder keeps the app waiting, with no limit, until it lets go', () async {
    lockFile().writeAsStringSync('1234\n'); // left by an earlier run
    // Another process, as a noted_mcp write is: it also excludes this one on Linux.
    final holder = await LockHolder.hold(lockFile(), shared: true);
    addTearDown(holder.release);
    final lock = AiRunningLock(dir);
    addTearDown(lock.dispose);
    expect(lock.acquire(tries: 1), isFalse);
    var told = 0;
    lock.addListener(() => told++);
    var done = false;
    final waiting = lock.waitHeld(every: const Duration(milliseconds: 20)).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(done, isFalse);
    expect(lock.held, isFalse);
    expect(lock.lastTry, LockTry.heldByOther);
    expect(lockFile().readAsStringSync(), '1234\n', reason: 'a failed attempt never changes the file');

    await holder.release();
    await waiting.timeout(const Duration(seconds: 5));
    expect(lock.held, isTrue);
    expect(lock.lastTry, LockTry.none);
    expect(told, greaterThanOrEqualTo(1), reason: 'told when it was taken');
  });

  test('9b. an unusable lock file (a folder at its path) keeps the app waiting, classed unusable, until it clears', () async {
    Directory(lockFile().path).createSync();
    final lock = AiRunningLock(dir);
    addTearDown(lock.dispose);
    var done = false;
    final waiting = lock.waitHeld(every: const Duration(milliseconds: 20)).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse);
    expect(lock.lastTry, LockTry.unusable);
    Directory(lockFile().path).deleteSync();
    await waiting.timeout(const Duration(seconds: 5));
    expect(lock.held, isTrue);
  });

  test('a folder that is missing is created; one that cannot be used just means not held', () {
    final lock = AiRunningLock(Directory('${dir.path}/new/sub'));
    addTearDown(lock.dispose);
    expect(lock.acquire(), isTrue);
    final blocker = File('${dir.path}/file')..writeAsStringSync('x');
    final bad = AiRunningLock(Directory(blocker.path));
    addTearDown(bad.dispose);
    expect(bad.acquire(tries: 2, pause: const Duration(milliseconds: 10)), isFalse);
  });

  group('the waiting screen', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('11. shows the notice for each class and a Quit button, in ${brightness.name} mode, after the delay', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        var quit = 0;
        late AiRunningLock held;
        await t.runAsync(() async {
          // Held by another process: a real shared holder.
          held = AiRunningLock(dir);
          addTearDown(held.dispose);
        });
        lockFile().writeAsStringSync(''); // a shared holder needs the file, as a server does
        final other = await t.runAsync(() => LockHolder.hold(lockFile(), shared: true));
        addTearDown(() async => other!.release());
        held.acquire(tries: 1);
        expect(held.lastTry, LockTry.heldByOther);
        await t.pumpWidget(WaitingForLockApp(lock: held, noticeDelay: const Duration(seconds: 1), onQuit: () => quit++));
        // Before the delay: nothing but the empty window.
        expect(find.byKey(const ValueKey('waiting-lock-notice')), findsNothing);
        expect(find.byKey(const ValueKey('waiting-lock-quit')), findsNothing);
        await t.pump(const Duration(milliseconds: 1100));
        expect(find.text(waitingForHolderMessage), findsOneWidget);
        expect(find.text('Quit'), findsOneWidget);
        // Nothing else: no page tree, no commands.
        expect(find.byType(Home), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(find.byType(IconButton), findsNothing);
        // The design system: text in `text`, the window on the theme's surface, light and dark.
        final scheme = Theme.of(t.element(find.byType(Scaffold))).colorScheme;
        final text = t.widget<Text>(find.byKey(const ValueKey('waiting-lock-notice')));
        expect(text.style!.color, scheme.onSurface);
        expect(Theme.of(t.element(find.byType(Scaffold))).brightness, brightness);
        expect(t.widget<Scaffold>(find.byType(Scaffold)).backgroundColor ?? Theme.of(t.element(find.byType(Scaffold))).scaffoldBackgroundColor, isNotNull);

        await t.tap(find.byKey(const ValueKey('waiting-lock-quit')));
        expect(quit, 1);

        // An unusable lock file: the other notice.
        final badDir = Directory('${dir.path}/bad')..createSync();
        Directory('${badDir.path}/$aiRunningLockFileName').createSync();
        final bad = AiRunningLock(badDir)..acquire(tries: 1);
        addTearDown(bad.dispose);
        await t.pumpWidget(WaitingForLockApp(lock: bad, noticeDelay: Duration.zero, onQuit: () {}));
        await t.pump(const Duration(milliseconds: 50));
        expect(bad.lastTry, LockTry.unusable);
        expect(find.text(waitingUnusableMessage), findsOneWidget);
        expect(find.text(waitingForHolderMessage), findsNothing);
      });
    }
  });

  group('openWhenOwned', () {
    testWidgets('10. while a shared holder keeps the lock only the waiting screen is shown and nothing is written, read or answered', (t) async {
      late Notebook nb;
      late AiAccessService service;
      late Future<({AiRunningLock? lock, AiLinkServer? link})> started;
      final shown = <Widget>[];
      var loadedDone = false;
      late LockHolder holder;
      final accessFile = File('${dir.path}/ai-access.json');
      final logFile = File('${dir.path}/ai-mcp-log.jsonl');
      await t.runAsync(() async {
        service = AiAccessService(dataFolder: dir);
        // A revoked code with no activity: polling would prune it (a write).
        final id = service.store
            .issue(target: const AiCodeTarget.box('b1', page: 'p1'), role: AiCodeRole.reader, label: 'A')
            .record
            .id;
        service.store.revoke(id);
        logFile.writeAsStringSync('');
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages')..createSync()),
          buildModules(),
          bindersFile: File('${dir.path}/binders.json'),
          saveDelay: Duration.zero,
          aiAccess: service,
        );
        unawaited(nb.loaded.then((_) => loadedDone = true));
        lockFile().writeAsStringSync('');
        holder = await LockHolder.hold(lockFile(), shared: true);
      });
      addTearDown(() async {
        await holder.release();
        service.dispose();
        nb.dispose();
      });
      final accessBefore = accessFile.readAsBytesSync();
      final logBefore = logFile.readAsBytesSync();
      await t.runAsync(() async {
        started = openWhenOwned(nb, dir, show: shown.add);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      expect(shown, hasLength(1));
      expect(shown.single, isA<WaitingForLockApp>());
      await t.pumpWidget(shown.single);
      await t.pump(const Duration(milliseconds: 1100));
      expect(find.byType(Home), findsNothing);
      expect(find.text('New binder'), findsNothing);
      expect(find.text('New page'), findsNothing);
      await t.sendKeyDownEvent(LogicalKeyboardKey.control);
      await t.sendKeyEvent(LogicalKeyboardKey.keyN);
      await t.sendKeyUpEvent(LogicalKeyboardKey.control);
      await t.pump();
      expect(find.byType(Home), findsNothing);
      expect(accessFile.readAsBytesSync(), accessBefore);
      expect(logFile.readAsBytesSync(), logBefore);
      expect(File('${dir.path}/binders.json').existsSync(), isFalse);
      expect(File('${dir.path}/settings.json').existsSync(), isFalse);
      expect(loadedDone, isFalse, reason: 'load has not been called');
      expect(Directory('${dir.path}/pages').listSync(), isEmpty);
      expect(File('${dir.path}/ai-link.json').existsSync(), isFalse, reason: 'the link is not listening');

      await t.runAsync(() async {
        await holder.release();
        final r = await started.timeout(const Duration(seconds: 10));
        addTearDown(() async {
          await r.link?.dispose();
          r.lock?.dispose();
        });
        expect(r.lock!.held, isTrue);
        expect(r.link, isNotNull, reason: 'the link listens once the lock is held');
        expect(File('${dir.path}/ai-link.json').existsSync(), isTrue);
        await nb.loaded.timeout(const Duration(seconds: 10));
      });
      expect(shown, hasLength(2));
      expect(shown.last, isA<NotedApp>());
      expect(service.store.codes(), isEmpty, reason: 'polling started after the lock: the revoked code is pruned');
    });

    test('the production factory (buildAppNotebook) writes nothing before the lock: ai-access.json and the MCP log are untouched while waiting', () async {
      final accessFile = File('${dir.path}/ai-access.json');
      final logFile = File('${dir.path}/ai-mcp-log.jsonl');
      final seed = AiAccessService(dataFolder: dir);
      final id = seed.store
          .issue(target: const AiCodeTarget.box('b1', page: 'p1'), role: AiCodeRole.reader, label: 'A')
          .record
          .id;
      seed.store.revoke(id); // polling would prune it
      seed.dispose();
      logFile.writeAsStringSync('');
      lockFile().writeAsStringSync('');
      final holder = await LockHolder.hold(lockFile(), shared: true);
      addTearDown(holder.release);
      final accessBefore = accessFile.readAsBytesSync();
      final logBefore = logFile.readAsBytesSync();
      final nb = buildAppNotebook(
        pagesDirectory: Directory('${dir.path}/pages')..createSync(),
        bindersFile: File('${dir.path}/binders.json'),
      );
      addTearDown(() {
        nb.aiAccess?.dispose();
        nb.dispose();
      });
      final shown = <Widget>[];
      final started = openWhenOwned(nb, dir, show: shown.add);
      await Future<void>.delayed(const Duration(milliseconds: 4000)); // longer than one poll
      expect(shown.single, isA<WaitingForLockApp>());
      expect(accessFile.readAsBytesSync(), accessBefore);
      expect(logFile.readAsBytesSync(), logBefore);
      await holder.release();
      final r = await started.timeout(const Duration(seconds: 10));
      addTearDown(() async {
        await r.link?.dispose();
        r.lock?.dispose();
      });
      expect(nb.aiAccess!.store.codes(), isEmpty, reason: 'pruned only after the lock');
    });

    test('a lock disposed while waiting ends the start: no polling, no link, no load', () async {
      lockFile().writeAsStringSync('');
      final holder = await LockHolder.hold(lockFile(), shared: true);
      addTearDown(holder.release);
      final service = AiAccessService(dataFolder: dir);
      addTearDown(service.dispose);
      final nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        bindersFile: File('${dir.path}/binders.json'),
        saveDelay: Duration.zero,
        aiAccess: service,
      );
      addTearDown(nb.dispose);
      var loadedDone = false;
      unawaited(nb.loaded.then((_) => loadedDone = true));
      final shown = <Widget>[];
      final started = openWhenOwned(nb, dir, show: shown.add);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      appRunningLock!.dispose();
      final r = await started.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(r.lock!.held, isFalse);
      expect(r.link, isNull);
      expect(shown.single, isA<WaitingForLockApp>());
      expect(loadedDone, isFalse, reason: 'load never started');
      expect(File('${dir.path}/ai-link.json').existsSync(), isFalse);
    });

    testWidgets('startLink: false owns the lock and loads, with no link', (t) async {
      late Notebook nb;
      await t.runAsync(() async {
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages')..createSync()),
          buildModules(),
          bindersFile: File('${dir.path}/binders.json'),
          saveDelay: Duration.zero,
        );
        final shown = <Widget>[];
        final r = await openWhenOwned(nb, dir, show: shown.add, startLink: false);
        addTearDown(() => r.lock?.dispose());
        expect(r.lock!.held, isTrue);
        expect(r.link, isNull);
        expect(shown.single, isA<NotedApp>());
        expect(File('${dir.path}/ai-link.json').existsSync(), isFalse);
      });
      addTearDown(nb.dispose);
    });
  });
}
