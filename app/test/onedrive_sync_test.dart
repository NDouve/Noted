// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The OneDrive controller (sync stage 3, G3, G5, G14): what it starts, when it
// polls and what it tells the notebook after a round. Time is the test clock;
// the files are real, so the world is built inside `runAsync`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/onedrive_sync.dart';
import 'package:noted_auth/noted_auth.dart' show AuthErrorKind, AuthException;
import 'package:noted_sync/noted_sync.dart';

import 'support/onedrive_world.dart';

RoundResult _round({List<String> paths = const [], Object? error}) {
  final r = RoundResult()..changedPaths.addAll(paths);
  r.error = error;
  return r;
}

void main() {
  late OneDriveWorld w;

  Future<void> build(
    WidgetTester t, {
    bool chosen = true,
    bool pageInFolder = false,
    String? chosenText,
    DateTime Function()? now,
    Duration pollOpen = oneDrivePollOpen,
    Duration pollIdle = oneDrivePollIdle,
  }) async {
    await t.runAsync(() async {
      w = await OneDriveWorld.create(
        chosen: chosen,
        pageInFolder: pageInFolder,
        chosenText: chosenText,
        now: now,
        pollOpen: pollOpen,
        pollIdle: pollIdle,
      );
    });
  }

  // A widget test that lets go of the controller (its timer) before the test
  // ends, then removes the files.
  void sTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (t) async {
      try {
        await body(t);
      } finally {
        w.sync.dispose();
        await t.runAsync(() async {
          w.nb.dispose();
          await w.top.delete(recursive: true);
        });
      }
    });
  }

  Future<void> start(WidgetTester t) async {
    await t.runAsync(() => w.sync.start());
    await t.pump();
  }

  // Lets the controller's own microtasks (made outside the test clock by start)
  // run, then the frame.
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
  }

  // Leaves and returns to the foreground, so the timer is made on the test clock
  // (and a round runs, as on any resume).
  Future<void> foregroundAgain(WidgetTester t) async {
    w.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
    w.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle(t);
  }

  test('the intervals are 10 s with a OneDrive page open and 5 min otherwise', () {
    expect(oneDrivePollOpen, const Duration(seconds: 10));
    expect(oneDrivePollIdle, const Duration(minutes: 5));
  });

  group('start', () {
    sTest('a chosen folder is listed in the notebook, then polled', (t) async {
      await build(t, pageInFolder: true);
      await start(t);
      expect(w.nb.standaloneFolders.map((f) => f.path.replaceAll(r'\', '/')), contains(w.workingCopy.path.replaceAll(r'\', '/')));
      expect(w.nb.pageTitleOf(oneDrivePageId), 'From OneDrive');
      expect(w.runner.rounds, 1, reason: 'a launch polls');
      // Idempotent: a second start does nothing more.
      await t.runAsync(() => w.sync.start());
      expect(w.runner.rounds, 1);
    });

    sTest('no chosen folder: nothing starts and the notebook has no folder', (t) async {
      await build(t, chosen: false);
      await start(t);
      expect(w.sync.chosen, isNull);
      expect(w.sync.canChoose, isTrue);
      expect(w.runner.rounds, 0);
      expect(w.nb.standaloneFolders, isEmpty);
    });

    sTest('a chosen file that cannot be read pauses and is never overwritten', (t) async {
      await build(t, chosen: false, chosenText: '{ not json');
      await start(t);
      expect(w.sync.chosenUnreadable, isTrue);
      expect(w.sync.canChoose, isFalse);
      expect(w.sync.statusLine, contains("can't be read"));
      expect(w.runner.rounds, 0);
      expect(w.nb.standaloneFolders, isEmpty);
      // Choosing is refused, and the file is as it was.
      await t.runAsync(
        () => w.sync.choose(const ChosenRoot(driveId: 'd', itemId: 'X', path: 'X')),
      );
      expect(w.chosenFile.readAsStringSync(), '{ not json');
      expect(w.runner.rounds, 0);
    });

    sTest('a chosen file with the wrong fields counts as unreadable', (t) async {
      await build(t, chosen: false, chosenText: '{"driveId": 3}');
      await start(t);
      expect(w.sync.chosenUnreadable, isTrue);
    });

    sTest('choosing writes the file before the folder is added', (t) async {
      await build(t, chosen: false);
      await start(t);
      const root = ChosenRoot(driveId: 'drv1', itemId: oneDriveRootId, path: 'Documents/Notes');
      await t.runAsync(() => w.sync.choose(root));
      await t.pump();
      expect(w.chosenFile.existsSync(), isTrue);
      expect(ChosenRoot.fromJson(jsonDecodeFile(w.chosenFile))!.itemId, oneDriveRootId);
      expect(File('${w.chosenFile.path}.tmp').existsSync(), isFalse);
      expect(w.workingCopy.existsSync(), isTrue);
      expect(w.nb.standaloneFolders.length, 1);
      expect(w.runner.rounds, 1);
      expect(w.sync.canChoose, isFalse, reason: 'no way to pick another folder');
    });
  });

  group('polling', () {
    sTest('5 min with no OneDrive page open', (t) async {
      await build(t);
      await start(t);
      await foregroundAgain(t);
      final base = w.runner.rounds;
      await t.pump(const Duration(minutes: 4, seconds: 59));
      expect(w.runner.rounds, base);
      await t.pump(const Duration(seconds: 1));
      expect(w.runner.rounds, base + 1);
      await t.pump(const Duration(minutes: 5));
      expect(w.runner.rounds, base + 2);
    });

    sTest('10 s with a page of the OneDrive folder open', (t) async {
      await build(t, pageInFolder: true);
      await start(t);
      await t.runAsync(() => w.nb.open(oneDrivePageId));
      expect(w.nb.isPullOnlyPage(oneDrivePageId), isTrue);
      await foregroundAgain(t);
      final base = w.runner.rounds;
      await t.pump(const Duration(seconds: 9));
      expect(w.runner.rounds, base);
      await t.pump(const Duration(seconds: 1));
      expect(w.runner.rounds, base + 1);
      await t.pump(const Duration(seconds: 10));
      expect(w.runner.rounds, base + 2);
    });

    sTest('timers stop in the background and a resume polls at once', (t) async {
      await build(t, pageInFolder: true);
      await start(t);
      await t.runAsync(() => w.nb.open(oneDrivePageId));
      await foregroundAgain(t);
      w.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      final base = w.runner.rounds;
      await t.pump(const Duration(hours: 1));
      expect(w.runner.rounds, base, reason: 'no round in the background');
      w.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle(t);
      expect(w.runner.rounds, base + 1, reason: 'a resume polls');
      await t.pump(const Duration(seconds: 10));
      expect(w.runner.rounds, base + 2);
    });

    sTest('rounds never overlap: a tick during a round is skipped', (t) async {
      await build(t, pageInFolder: true);
      await start(t);
      await t.runAsync(() => w.nb.open(oneDrivePageId));
      await foregroundAgain(t);
      final base = w.runner.rounds;
      final gate = Completer<void>();
      w.runner.hold = gate;
      await t.pump(const Duration(seconds: 10));
      expect(w.runner.rounds, base + 1);
      expect(w.sync.checking, isTrue);
      await t.pump(const Duration(seconds: 30));
      expect(w.runner.rounds, base + 1, reason: 'three ticks fell in the round');
      w.runner.hold = null;
      gate.complete();
      await t.pump();
      expect(w.sync.checking, isFalse);
      await t.pump(const Duration(seconds: 10));
      expect(w.runner.rounds, base + 2);
    });

    sTest('signing out pauses, and signing in again polls', (t) async {
      await build(t);
      await start(t);
      await foregroundAgain(t);
      await t.runAsync(() => w.account.signOut());
      await t.pump();
      expect(w.sync.statusLine, 'Signed out');
      final base = w.runner.rounds;
      await t.pump(const Duration(minutes: 30));
      expect(w.runner.rounds, base);
      await t.runAsync(() => w.account.signIn());
      await t.pump();
      expect(w.runner.rounds, base + 1);
    });
  });

  group('after a round', () {
    sTest('filesChanged runs for a failed round, with what it applied, and then the check and discovery', (t) async {
      await build(t);
      await start(t);
      w.nb.log.clear();
      w.runner.next = () => _round(paths: ['/x/a.canvas', '/x/b.canvas'], error: StateError('boom'));
      await w.sync.checkNow();
      expect(w.nb.changedPaths.last, ['/x/a.canvas', '/x/b.canvas']);
      // It applied something, so the folders are checked and binders discovered, in that order.
      expect(w.nb.log, ['filesChanged', 'checkFolders', 'discoverBinders']);
    });

    sTest('a round that applied nothing only reports its (empty) files', (t) async {
      await build(t);
      await start(t);
      w.nb.log.clear();
      await w.sync.checkNow();
      expect(w.nb.log, ['filesChanged']);
    });

    sTest('the 5-minute tick after a failed round checks the folders too', (t) async {
      await build(t);
      await start(t);
      await foregroundAgain(t);
      w.runner.next = () => _round(error: StateError('offline'));
      await w.sync.checkNow();
      w.runner.next = RoundResult.new;
      w.nb.log.clear();
      await t.pump(const Duration(minutes: 5));
      expect(w.nb.log, ['filesChanged', 'checkFolders', 'discoverBinders']);
      w.nb.log.clear();
      await t.pump(const Duration(minutes: 5));
      expect(w.nb.log, ['filesChanged'], reason: 'the last round worked');
    });

    sTest('a round that throws is a failed one', (t) async {
      await build(t);
      await start(t);
      await foregroundAgain(t);
      w.runner.next = () => throw StateError('x');
      await w.sync.checkNow();
      w.runner.next = RoundResult.new;
      w.nb.log.clear();
      await t.pump(const Duration(minutes: 5));
      expect(w.nb.log, contains('checkFolders'));
    });

    sTest('answering the guard reports the round it ran, like any other round', (t) async {
      await build(t);
      await start(t);
      final q = GuardQuestion(['a.canvas']);
      w.nb.log.clear();
      w.runner.answerResult = _round(paths: ['/x/a.canvas']);
      await w.sync.answerGuard(q, remove: true);
      expect(w.runner.answers, [(q, true)]);
      expect(w.nb.changedPaths.last, ['/x/a.canvas']);
      expect(w.nb.log, ['filesChanged', 'checkFolders', 'discoverBinders']);
      // A round that applied nothing only reports its (empty) files; no round at all, nothing.
      w.nb.log.clear();
      w.runner.answerResult = _round();
      await w.sync.answerGuard(q, remove: false);
      expect(w.nb.log, ['filesChanged']);
      w.nb.log.clear();
      w.runner.answerResult = null;
      await w.sync.answerGuard(q, remove: false);
      expect(w.nb.log, isEmpty);
    });

    sTest('after Remove them here too, a page whose original was removed moves to its duplicate (G3)', (t) async {
      await build(t, pageInFolder: true);
      w.nb.passThrough = true;
      final copy = File('${w.workingCopy.path}/$oneDrivePageId-DESKTOP-9.canvas');
      final orig = File('${w.workingCopy.path}/$oneDrivePageId.canvas');
      await t.runAsync(() async {
        await copy.writeAsString(await orig.readAsString());
        await w.sync.start();
      });
      await t.pump();
      final folder = w.nb.standaloneFolders.single;
      expect(folder.unreadable.map((u) => u.reason), ['duplicate page id $oneDrivePageId'], reason: 'listed as a duplicate');
      // The engine removes the original after the answer; the round reports it.
      final q = GuardQuestion(['$oneDrivePageId.canvas']);
      w.runner.answerResult = _round(paths: [orig.path]);
      await t.runAsync(() async {
        await orig.delete();
        await w.sync.answerGuard(q, remove: true);
      });
      await t.pump();
      expect(folder.unreadable, isEmpty, reason: 'the page moved to the surviving file');
      expect(w.nb.pageTitleOf(oneDrivePageId), 'From OneDrive');
    });
  });

  group('status line', () {
    sTest('up to date and when, checking, paused with its reason, waiting, signed out', (t) async {
      final at = DateTime(2026, 11, 8, 9, 5);
      await build(t, now: () => at);
      await start(t);
      expect(w.sync.statusLine, 'Up to date, checked 09:05');
      w.runner.status = const SyncStatus(SyncState.paused, 'Offline');
      expect(w.sync.statusLine, 'Paused: Offline');
      w.runner.status = const SyncStatus(SyncState.running);
      expect(w.sync.statusLine, 'Checking…');
      w.runner.status = const SyncStatus(SyncState.rootGone);
      expect(w.sync.statusLine, 'Paused: the OneDrive folder is gone');
      w.runner.status = const SyncStatus(SyncState.journalUnreadable, 'x');
      expect(w.sync.statusLine, contains("can't be read"));
      w.runner.status = const SyncStatus(SyncState.guardWaiting);
      expect(w.sync.statusLine, contains('Waiting for your answer'));
      w.runner.status = const SyncStatus(SyncState.signedOut);
      expect(w.sync.statusLine, 'Signed out');
      w.runner.status = const SyncStatus(SyncState.idle);
      await t.runAsync(() => w.account.signOut());
      expect(w.sync.statusLine, 'Signed out');
    });
  });

  group('review fixes', () {
    sTest('a working copy removed on this device is not made again once the pull has run', (t) async {
      await build(t);
      await t.runAsync(() async {
        final journal = File('${oneDriveStateDir(w.support, w.accountKey, oneDriveRootId).path}/journal.json');
        await journal.parent.create(recursive: true);
        await journal.writeAsString('{}');
      });
      await start(t);
      expect(w.workingCopy.existsSync(), isFalse, reason: 'not made again');
      expect(w.runner.rounds, 0);
      expect(w.nb.standaloneFolders, isEmpty);
      expect(w.sync.statusLine, 'Paused: the OneDrive folder is missing on this device');
      // It comes back: Check now looks again.
      await t.runAsync(() async {
        await w.workingCopy.create(recursive: true);
        await w.sync.checkNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(w.runner.rounds, 1);
      expect(w.nb.standaloneFolders.length, 1);
    });

    sTest('a folder that was listed while it was missing comes back, and the pull goes on', (t) async {
      await build(t, pageInFolder: true);
      w.nb.passThrough = true;
      await t.runAsync(() async {
        // Listed, then removed on the device and noticed by the notebook.
        await w.nb.addStandaloneFolder(w.workingCopy.path);
        final journal = syncJournalFile(oneDriveStateDir(w.support, w.accountKey, oneDriveRootId));
        await journal.parent.create(recursive: true);
        await journal.writeAsString('{}');
        await w.workingCopy.delete(recursive: true);
        await w.nb.checkFolders();
      });
      expect(w.nb.standaloneFolders.single.available, isFalse);
      await start(t);
      expect(w.sync.statusLine, 'Paused: the OneDrive folder is missing on this device');
      // Back on the device (a restored copy): Check now lists it again.
      await t.runAsync(() async {
        await w.workingCopy.create(recursive: true);
        await w.sync.checkNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(w.sync.statusLine, isNot(startsWith('Paused')));
      expect(w.nb.standaloneFolders.single.available, isTrue);
      expect(w.runner.rounds, 1);
    });

    sTest('a hostile item id in chosen.json stays inside the working folder', (t) async {
      final hostile = jsonEncode({'driveId': 'd', 'itemId': '../../evil', 'path': 'x'});
      await build(t, chosen: false, chosenText: hostile);
      await start(t);
      final copy = w.sync.workingCopy!;
      expect(copy.path, startsWith(w.workingRoot.path));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(copy.path.split(RegExp(r'[\\/]')).last), isTrue, reason: 'hashed');
      expect(copy.existsSync(), isTrue);
      expect(Directory('${w.top.path}/evil').existsSync(), isFalse);
      expect(Directory('${w.workingRoot.path}/evil').existsSync(), isFalse);
    });

    sTest('the file is written, whole, before the folder is added; a failed write leaves none', (t) async {
      await build(t, chosen: false);
      await start(t);
      // A write that cannot go through (its temporary name is taken) leaves no file.
      await t.runAsync(() => Directory('${w.chosenFile.path}.tmp').create(recursive: true));
      const root = ChosenRoot(driveId: 'drv1', itemId: oneDriveRootId, path: 'Documents/Notes');
      await t.runAsync(() => w.sync.choose(root));
      expect(w.chosenFile.existsSync(), isFalse);
      expect(w.sync.chosen, isNull);
      expect(w.sync.statusLine, contains("couldn't be saved"));
      await t.runAsync(() => Directory('${w.chosenFile.path}.tmp').delete());
      // Then the file is there, and parses, when the folder is added.
      ChosenRoot? atAdd;
      w.nb.onAddFolder = (_) => atAdd = ChosenRoot.fromJson(jsonDecode(w.chosenFile.readAsStringSync()));
      await t.runAsync(() => w.sync.choose(root));
      expect(atAdd?.itemId, oneDriveRootId);
    });

    sTest('a page open in the OneDrive folder speeds the polling up by itself', (t) async {
      await build(
        t,
        pageInFolder: true,
        pollOpen: const Duration(milliseconds: 40),
        pollIdle: const Duration(minutes: 10),
      );
      await t.runAsync(() async {
        await w.sync.start();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(w.runner.rounds, 1, reason: 'idle: the launch round only');
        await w.nb.open(oneDrivePageId);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(w.runner.rounds, greaterThan(2));
      });
    });

    sTest('a round that ends after dispose tells the notebook nothing', (t) async {
      await build(t);
      await start(t);
      w.nb.changedPaths.clear();
      w.nb.log.clear();
      final gate = Completer<void>();
      w.runner.hold = gate;
      w.runner.next = () => _round(paths: ['/x/a.canvas']);
      unawaited(w.sync.checkNow());
      await t.pump();
      w.sync.dispose();
      gate.complete();
      await settle(t);
      expect(w.nb.changedPaths, isEmpty);
      expect(w.nb.log, isNot(contains('checkFolders')));
    });

    sTest('a poll wanted during a round runs when the round ends', (t) async {
      await build(t);
      await start(t);
      await foregroundAgain(t);
      final gate = Completer<void>();
      w.runner.hold = gate;
      unawaited(w.sync.checkNow());
      await t.pump();
      final base = w.runner.rounds;
      w.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      w.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle(t);
      expect(w.runner.rounds, base, reason: 'not while a round runs');
      w.runner.hold = null;
      gate.complete();
      await settle(t);
      expect(w.runner.rounds, base + 1, reason: 'the resume was not forgotten');
    });

    sTest('an answer waits for the round that is running', (t) async {
      await build(t);
      await start(t);
      final gate = Completer<void>();
      w.runner.hold = gate;
      unawaited(w.sync.checkNow());
      await t.pump();
      final q = GuardQuestion(['a.canvas']);
      final answered = w.sync.answerGuard(q, remove: false);
      await settle(t);
      expect(w.runner.answers, isEmpty);
      w.runner.hold = null;
      gate.complete();
      await settle(t);
      expect(await answered, isTrue);
      expect(w.runner.answers, [(q, false)]);
    });

    sTest('an answer that cannot be saved, or is for another pull, is refused', (t) async {
      await build(t);
      await start(t);
      final q = GuardQuestion(['a.canvas']);
      w.nb.changedPaths.clear();
      expect(await w.sync.answerGuard(q, remove: true, source: Object()), isFalse);
      expect(w.runner.answers, isEmpty);
      w.runner.answerError = StateError('disk full');
      expect(await w.sync.answerGuard(q, remove: true, source: w.sync.guardSource), isFalse);
      expect(w.nb.changedPaths, isEmpty);
      expect(w.sync.checking, isFalse);
      w.runner.answerError = null;
      expect(await w.sync.answerGuard(q, remove: true, source: w.sync.guardSource), isTrue);
    });

    sTest('a notebook that fails to hear a round does not stop the next one', (t) async {
      await build(t);
      await start(t);
      w.nb.failing.add('filesChanged');
      await w.sync.checkNow();
      expect(w.sync.checking, isFalse);
      final before = w.runner.rounds;
      await w.sync.checkNow();
      expect(w.runner.rounds, before + 1);
    });

    sTest('a failed folder check does not skip discovery', (t) async {
      await build(t);
      await start(t);
      w.nb.failing.add('checkFolders');
      w.nb.log.clear();
      w.runner.next = () => _round(paths: ['/x/a.canvas']);
      await w.sync.checkNow();
      expect(w.nb.log, ['filesChanged', 'checkFolders', 'discoverBinders']);
    });

    testWidgets('only a lost sign-in reads as signed out; an unreachable endpoint pauses the round', (t) async {
      late TestTokens tokens;
      late OneDriveSync sync;
      await t.runAsync(() async {
        w = await OneDriveWorld.create(chosen: false);
        final account = await signedInAccount(tokens: (c) => tokens = TestTokens(c, expiresIn: Duration.zero));
        sync = OneDriveSync.create(
          notebook: w.nb,
          microsoft: account,
          workingRoot: w.workingRoot,
          support: w.support,
          graphOrigin: Uri.parse('http://127.0.0.1:9'),
        );
        tokens.refreshError = const AuthException(AuthErrorKind.unreachable, 'offline');
        await expectLater(sync.folders.listFolders(), throwsA(isA<GraphException>()));
        tokens.refreshError = const AuthException(AuthErrorKind.invalidGrant, 'gone');
        await expectLater(sync.folders.listFolders(), throwsA(isA<SignedOutException>()));
        sync.dispose();
        w.sync.dispose();
        w.nb.dispose();
        await w.top.delete(recursive: true);
      });
    });
  });

  group('desktop and builds without a client id', () {
    test('the paths are mobile only', () {
      expect(isMobilePlatform, isFalse);
      expect(deviceOneDriveRoot(), isNull);
    });

    sTest('the section is not there without a controller', (t) async {
      await build(t);
      await t.pumpWidget(oneDriveApp(null, const Scaffold(body: SizedBox())));
      expect(find.byKey(const ValueKey('od-section')), findsNothing);
    });
  });
}


Object? jsonDecodeFile(File f) => jsonDecode(f.readAsStringSync());
