// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory root;
  late Directory pages;
  late Notebook nb;
  late FolderLocks locks;
  final sep = Platform.pathSeparator;

  Future<void> build({bool watch = false}) async {
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
      // A short stand-in for the 3 seconds, so the tests need no fake clock.
      folderWaitNote: const Duration(milliseconds: 300),
    );
    await nb.load();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_folderwait');
    pages = await Directory('${root.path}${sep}pages').create();
    locks = FolderLocks();
    await build();
  });

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  int pageFiles(Directory d) => d.listSync().where((e) => e.path.endsWith('.canvas')).length;

  // Holds [dir]'s lock until the returned completer completes.
  (Completer<void>, Future<void>) hold(Directory dir) {
    final gate = Completer<void>();
    return (gate, locks.run(dir, () => gate.future));
  }

  // Waits until no folder job is running or queued.
  Future<void> idle() async {
    for (var i = 0; i < 100 && locks.busyCount > 0; i++) {
      await _wait(50);
    }
  }

  List<bool> record() {
    final seen = <bool>[];
    nb.waitingForFolder.addListener(() => seen.add(nb.waitingForFolder.value));
    return seen;
  }

  test('the note shows after the wait limit, not before, and clears when the job ends', () async {
    final seen = record();
    final (gate, held) = hold(pages);
    final create = nb.createPage();
    await _wait(100);
    expect(nb.waitingForFolder.value, isFalse);
    await _wait(500);
    expect(nb.waitingForFolder.value, isTrue);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
    expect(seen, [true, false]);
  });

  test('a short wait shows nothing, and a later long wait shows the note', () async {
    final seen = record();
    var (gate, held) = hold(pages);
    var create = nb.createPage();
    await _wait(50);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    await _wait(500);
    expect(seen, isEmpty);
    (gate, held) = hold(pages);
    create = nb.createPage();
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
  });

  test('overlapping waits keep the note on until the last one ends', () async {
    final other = await Directory('${root.path}${sep}other').create();
    await nb.addStandaloneFolder(other.path);
    final (gateA, heldA) = hold(pages);
    final (gateB, heldB) = hold(other);
    final a = nb.createPage();
    await _wait(100);
    final b = nb.createPage(folderPath: other.path);
    await _wait(500);
    expect(nb.waitingForFolder.value, isTrue);
    gateA.complete();
    await heldA;
    await a.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isTrue, reason: 'the second is still waiting');
    gateB.complete();
    await heldB;
    await b.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
  });

  test('Undo of a delete shows the note when its folder is held', () async {
    final first = nb.currentId!;
    await nb.createPage();
    final deleted = await nb.delete(first);
    final (gate, held) = hold(pages);
    final undo = nb.undoDelete(deleted);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue);
    gate.complete();
    await held;
    await undo.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
  });

  test('moveToLocation and move into a held folder show the note', () async {
    final other = await Directory('${root.path}${sep}other').create();
    final section = await nb.addBinder(other.path);
    final inBinder = await nb.createPage(binderPath: section.path);
    final id = await nb.createPage();
    await nb.flush();

    var (gate, held) = hold(other);
    var move = nb.moveToLocation(id, binderPath: section.path);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue, reason: 'moveToLocation');
    gate.complete();
    await held;
    await move.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);

    // Back to the first folder, then under the binder's page.
    await nb.moveToLocation(id);
    (gate, held) = hold(other);
    move = nb.move(id, parentId: inBinder);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue, reason: 'move');
    gate.complete();
    await held;
    await move.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
  });

  test('moveRelative into a held folder shows the note', () async {
    final other = await Directory('${root.path}${sep}other').create();
    final section = await nb.addBinder(other.path);
    final inBinder = await nb.createPage(binderPath: section.path);
    final id = await nb.createPage();
    await nb.flush();

    final (gate, held) = hold(other);
    final move = nb.moveRelative(id, inBinder, after: true);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue, reason: 'moveRelative');
    expect(nb.folderWaitersForTest, 1);
    gate.complete();
    await held;
    expect(await move.timeout(const Duration(seconds: 10)), isTrue);
    expect(nb.waitingForFolder.value, isFalse);
    expect(nb.folderWaitersForTest, 0);
  });

  test('moveToFolder into a held folder shows the note', () async {
    final other = await Directory('${root.path}${sep}other').create();
    await nb.addStandaloneFolder(other.path);
    final id = await nb.createPage();
    await nb.flush();

    final (gate, held) = hold(other);
    final move = nb.moveToFolder(id, other.path);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue);
    expect(nb.folderWaitersForTest, 1);
    gate.complete();
    await held;
    expect(await move.timeout(const Duration(seconds: 10)), isTrue);
    expect(nb.waitingForFolder.value, isFalse);
    expect(nb.folderWaitersForTest, 0);
  });

  test('createPageFromTemplate into a held folder shows the note', () async {
    final other = await Directory('${root.path}${sep}other').create();
    final section = await nb.addBinder(other.path);
    final template = NotedTemplate.forPage(
      name: 'T',
      page: nb.current!.page,
      id: 'aaaaaaaaaaaaaaaa',
      created: DateTime.utc(2026, 1, 1),
    );
    final (gate, held) = hold(other);
    final made = nb.createPageFromTemplate(template, binderPath: section.path);
    await _wait(600);
    expect(nb.waitingForFolder.value, isTrue);
    gate.complete();
    await held;
    await made.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
    expect(nb.folderWaitersForTest, 0);
  });

  test('two New page calls during a stall make one page', () async {
    final before = pageFiles(pages);
    final (gate, held) = hold(pages);
    final a = nb.createPage();
    final b = nb.createPage();
    await _wait(100);
    gate.complete();
    await held;
    final ids = await Future.wait([a, b]).timeout(const Duration(seconds: 10));
    expect(ids[0], ids[1]);
    expect(pageFiles(pages), before + 1);
  });

  test('a joining call with focusTitle asks for the title focus', () async {
    final (gate, held) = hold(pages);
    final a = nb.createPage();
    final b = nb.createPage(focusTitle: true);
    gate.complete();
    await held;
    final id = await b.timeout(const Duration(seconds: 10));
    expect(await a, id);
    expect(nb.takeTitleFocus(id), isTrue);
  });

  test('a New page after the first finished makes a second page', () async {
    final before = pageFiles(pages);
    final first = await nb.createPage();
    final second = await nb.createPage();
    expect(second, isNot(first));
    expect(pageFiles(pages), before + 2);
  });

  test('the guard clears after a failed create', () async {
    final missing = '${root.path}${sep}nobinder';
    await expectLater(nb.createPage(binderPath: missing), throwsA(anything));
    final before = pageFiles(pages);
    final id = await nb.createPage(binderPath: missing).then<String?>((_) => null, onError: (Object _) => null);
    expect(id, isNull, reason: 'it fails again, not a stuck pending call');
    expect(await nb.createPage(), isNotEmpty);
    expect(pageFiles(pages), before + 1);
  });

  test('a watcher made inside an action does not show the note later', () async {
    nb.dispose();
    await build(watch: true);
    final x = await Directory('${root.path}${sep}x').create();
    await nb.createPage(folderPath: x.path);
    final seen = record();
    final (gate, held) = hold(x);
    // Another program writes a page into x: the watcher looks at it.
    final theirs = NotedPage.create(
      PageMeta.create(id: newId(), parentId: null, title: 'Theirs', order: 0),
    );
    // Its name is not its id, so finding it scans the folder under the lock.
    await File('${x.path}${sep}theirs copy.canvas').writeAsString(writePage(theirs));
    await _wait(1800);
    expect(nb.waitingForFolder.value, isFalse);
    expect(seen, isEmpty);
    gate.complete();
    await held;
    await idle();
  });

  test('work queued during a long action does not keep the note on after the action ends', () async {
    nb.dispose();
    await build(watch: true);
    final x = await Directory('${root.path}${sep}x').create();
    final (gate1, held1) = hold(x);
    final create = nb.createPage(folderPath: x.path);
    await _wait(50);
    // Queued behind the action's join scan, ahead of its page write.
    final (gate2, held2) = hold(x);
    gate1.complete();
    await held1;
    await _wait(200);
    // Queued behind the page write, ahead of the scan the watcher will ask for.
    final (gate3, held3) = hold(x);
    final theirs = NotedPage.create(
      PageMeta.create(id: newId(), parentId: null, title: 'Theirs', order: 0),
    );
    await File('${x.path}${sep}theirs copy.canvas').writeAsString(writePage(theirs));
    // Both the write and the watcher's scan must be counted, or the check
    // below would pass without the take-back.
    for (var i = 0; i < 200 && nb.folderWaitersForTest < 2; i++) {
      await _wait(50);
    }
    expect(nb.folderWaitersForTest, 2, reason: 'the write and the scan wait');
    expect(nb.waitingForFolder.value, isTrue);
    gate2.complete();
    await held2;
    await create.timeout(const Duration(seconds: 10));
    // The action is over; its scan still waits behind gate3.
    expect(nb.waitingForFolder.value, isFalse);
    gate3.complete();
    await held3;
    await idle();
  });

  testWidgets('Home shows the note while waiting and drops it after, and leaves a delete Undo bar alone', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await tester.pump(const Duration(milliseconds: 100));
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).showSnackBar(
      SnackBar(content: const Text('Deleted'), persist: true, action: SnackBarAction(label: 'Undo', onPressed: () {})),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Waiting for the folder…'), findsNothing);

    late Completer<void> gate;
    late Future<void> held;
    late Future<String> create;
    await tester.runAsync(() async {
      (gate, held) = hold(pages);
      create = nb.createPage();
      await _wait(600);
    });
    await tester.pump();
    expect(find.text('Waiting for the folder…'), findsOneWidget);
    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.runAsync(() async {
      gate.complete();
      await held;
      await create;
    });
    await tester.pump();
    expect(find.text('Waiting for the folder…'), findsNothing);
    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    // Take the tree down before the notebook is disposed.
    await tester.pumpWidget(const SizedBox());
  });
}
