// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'support/busy_retry.dart';

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late Directory root;
  late Directory pages;
  late Notebook nb;
  late FolderLocks locks;
  late List<LocalChange> events;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_publock');
    pages = await Directory('${root.path}${sep}pages').create();
    locks = FolderLocks();
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    events = [];
    await nb.load();
    nb.localChanges.listen(events.add);
    await pump();
    events.clear();
  });

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  String pagePath(String id, [Directory? d]) => '${(d ?? pages).path}$sep$id.canvas';

  test('createPage waits for the folder lock before it publishes or emits', () async {
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    final before = pages.listSync().length;
    var done = false;
    final create = nb.createPage().whenComplete(() => done = true);
    await pump();
    expect(done, isFalse);
    expect(pages.listSync().length, before);
    expect(events, isEmpty);
    gate.complete();
    await held;
    final id = await create.timeout(const Duration(seconds: 10));
    await pump();
    expect(File(pagePath(id)).existsSync(), isTrue);
    expect(events.where((e) => e.path == pagePath(id)), hasLength(1));
  });

  test('undo of a delete (restore) waits for the folder lock', () async {
    final first = nb.currentId!;
    await nb.createPage();
    final deleted = await nb.delete(first);
    await pump();
    events.clear();
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    var done = false;
    final undo = nb.undoDelete(deleted).whenComplete(() => done = true);
    await pump();
    expect(done, isFalse);
    expect(File(pagePath(first)).existsSync(), isFalse);
    expect(events, isEmpty);
    gate.complete();
    await held;
    await undo.timeout(const Duration(seconds: 10));
    await pump();
    expect(File(pagePath(first)).existsSync(), isTrue);
    expect(events.where((e) => e.path == pagePath(first) && e.kind == LocalChangeKind.published), hasLength(1));
  });

  test('a binder made from a template publishes its pages only under the folder lock', () async {
    final src = await Directory('${root.path}${sep}Src').create();
    final section = await nb.addBinder(src.path);
    await nb.createPage(binderPath: section.path);
    await nb.flush();
    final template = await nb.saveBinderAsTemplate(section.path, name: 'B');
    final target = await Directory('${root.path}${sep}FromTemplate').create();
    await pump();
    events.clear();
    final gate = Completer<void>();
    final held = locks.run(target, () => gate.future);
    var done = false;
    final made = nb.createBinderFromTemplate(template, target.path).whenComplete(() => done = true);
    await pump();
    expect(done, isFalse);
    expect(target.listSync().where((e) => e.path.endsWith('.canvas')), isEmpty);
    expect(events.where((e) => e.path.endsWith('.canvas')), isEmpty);
    gate.complete();
    await held;
    await made.timeout(const Duration(seconds: 10));
    await pump();
    expect(target.listSync().where((e) => e.path.endsWith('.canvas')), isNotEmpty);
    expect(events.where((e) => e.path.endsWith('.canvas')), isNotEmpty);
  });

  test('an undo that meets a newer file (conflict copy merge) does not deadlock', () async {
    final first = nb.currentId!;
    await nb.createPage();
    final deleted = await nb.delete(first);
    File(pagePath(first)).writeAsStringSync(
      writePage(NotedPage.create(PageMeta.create(id: first, title: 'Newer', order: 0))),
    );
    try {
      await nb.undoDelete(deleted).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      fail('undoDelete hung');
    } on Object {
      // The outcome is told as an error or not; only a hang fails.
    }
    expect(locks.busyCount, 0);
  });

  test('a move between folders does not deadlock', () async {
    final other = await Directory('${root.path}${sep}Other').create();
    final section = await nb.addBinder(other.path);
    final id = await nb.createPage();
    await nb.flush();
    final moved = nb.moveToLocation(id, binderPath: section.path);
    await moved.timeout(const Duration(seconds: 20));
    expect(id, isNotEmpty);
    expect(locks.busyCount, 0);
  });
}
