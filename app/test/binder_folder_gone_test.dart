// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Directory away;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_binder_gone');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    away = Directory('${root.path}/Work-away');
    opened = [];
  });

  Notebook make({bool watch = true}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 40),
      folderCheckInterval: watch ? const Duration(milliseconds: 100) : Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    opened.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File binderFile() => File('${folder.path}/$binderFileName');
  File pageFile(String id) => File('${folder.path}/$id.canvas');

  Future<void> until(bool Function() ok, {int ms = 5000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached in time');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void takeAway() => folder.renameSync(away.path);
  void bringBack() => away.renameSync(folder.path);

  // A binder with a page and a subpage; the page is open and has a box.
  Future<({Notebook nb, BinderSection s, String page, String sub})> setUpBinder() async {
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final p = await nb.createPage(binderPath: s.path);
    final sub = await nb.createPage(parentId: p);
    await nb.open(p);
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    await nb.flush();
    return (nb: nb, s: s, page: p, sub: sub);
  }

  test('removed while running: pages stay listed, read-only, nothing written', () async {
    final d = await setUpBinder();
    final nb = d.nb;
    final s = d.s;
    takeAway();
    await until(() => s.missing);

    expect(s.status, BinderStatus.unavailable);
    expect(s.tree.descendantsOf(d.page), [d.sub]);
    expect(nb.isReadOnlyPage(d.page), isTrue);
    expect(nb.currentId, d.page);
    expect(nb.current!.readOnly, isTrue);
    expect(nb.readOnlyReason, isNotNull);
    expect(readPage(File('${away.path}/${d.page}.canvas').readAsStringSync()).nodes, hasLength(1));

    final before = away.listSync().map((e) => e.path).toList()..sort();
    await expectLater(nb.createPage(binderPath: s.path), throwsA(isA<NotebookException>()));
    await expectLater(nb.createPage(parentId: d.page), throwsA(isA<NotebookException>()));
    await expectLater(nb.rename(d.sub, 'x'), throwsA(isA<NotebookException>()));
    await expectLater(nb.delete(d.sub), throwsA(isA<NotebookException>()));
    await expectLater(nb.moveToLocation(d.sub), throwsA(isA<NotebookException>()));
    await nb.updateBinder(s.path, title: 'x');
    nb.showCover(s.path);
    expect(nb.coverPath, isNull);
    await nb.flush();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(folder.existsSync(), isFalse);
    expect(away.listSync().map((e) => e.path).toList()..sort(), before);
    // Another page of the binder can't be opened while it is away.
    await expectLater(nb.open(d.sub), throwsA(isA<NotebookException>()));
  });

  test('restored: editable again, watcher and cover work', () async {
    final d = await setUpBinder();
    final nb = d.nb;
    takeAway();
    await until(() => d.s.missing);
    bringBack();
    await until(() => nb.binders.single.available);
    final back = nb.binders.single;
    expect(back.missing, isFalse);
    expect(back.tree.descendantsOf(d.page), [d.sub]);
    expect(nb.isReadOnlyPage(d.page), isFalse);
    expect(nb.current!.readOnly, isFalse);
    expect(nb.readOnlyReason, isNull);
    nb.showCover(back.path);
    expect(nb.coverPath, back.path);
    await nb.updateBinder(back.path, title: 'Back');
    expect(binderFile().readAsStringSync(), contains('Back'));

    // Editing saves again.
    nb.current!.createBoxAt(const Bounds(200, 200, 0, 0));
    await nb.flush();
    expect(readPage(pageFile(d.page).readAsStringSync()).nodes, hasLength(2));

    // The watcher is running: another instance's change merges into the open page.
    final other = make(watch: false);
    await other.load();
    await other.open(d.page);
    other.current!.createBoxAt(const Bounds(300, 300, 0, 0));
    await other.flush();
    await until(() => nb.current!.page.nodes.length == 3);
  });

  test('a change made elsewhere while away is merged into the open page', () async {
    final d = await setUpBinder();
    final nb = d.nb;
    takeAway();
    await until(() => d.s.missing);
    bringBack();
    final second = make(watch: false);
    await second.load();
    await second.open(d.page);
    second.current!.createBoxAt(const Bounds(300, 300, 0, 0));
    await second.flush();
    await until(() => nb.binders.single.available);
    await until(() => nb.current!.page.nodes.length == 2);
    expect(nb.current!.readOnly, isFalse);
  });

  test('missing at startup, then appears', () async {
    final first = make(watch: false);
    await first.load();
    final s0 = await first.addBinder(folder.path);
    final p = await first.createPage(binderPath: s0.path);
    await first.flush();
    first.dispose();
    opened.clear();
    takeAway();

    final nb = make();
    await nb.load();
    final s = nb.binders.single;
    expect(s.status, BinderStatus.unavailable);
    expect(s.missing, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(folder.existsSync(), isFalse);

    bringBack();
    await until(() => nb.binders.single.available);
    expect(nb.binders.single.tree[p], isNotNull);
    await nb.open(p);
    expect(nb.current!.readOnly, isFalse);
    nb.showCover(folder.path);
    expect(nb.coverPath, isNotNull);
  });

  test('gone while the binder file was damaged, then back with a good file', () async {
    final d = await setUpBinder();
    final nb = d.nb;
    final good = binderFile().readAsStringSync();
    binderFile().writeAsStringSync('{ not json');
    await nb.checkBinderFile(binderFile().path);
    expect(nb.binders.single.status, BinderStatus.unreadable);
    takeAway();
    await until(() => nb.binders.single.missing);
    expect(nb.binders.single.status, BinderStatus.unavailable);
    expect(nb.isReadOnlyPage(d.page), isTrue);

    // Back, still damaged: the damaged state.
    bringBack();
    await until(() => !nb.binders.single.missing);
    expect(nb.binders.single.status, BinderStatus.unreadable);
    expect(nb.current!.readOnly, isTrue);
    expect(binderFile().readAsStringSync(), '{ not json');

    takeAway();
    await until(() => nb.binders.single.missing);
    // Back with a good file.
    File('${away.path}/$binderFileName').writeAsStringSync(good);
    bringBack();
    await until(() => nb.binders.single.available);
    expect(nb.current!.readOnly, isFalse);
    expect(nb.isReadOnlyPage(d.page), isFalse);
  });

  test('moving a page into a binder that is away is refused', () async {
    final d = await setUpBinder();
    final nb = d.nb;
    final standalone = nb.tree.roots.first.id;
    takeAway();
    await until(() => d.s.missing);
    await expectLater(
      nb.moveToLocation(standalone, binderPath: d.s.path),
      throwsA(isA<NotebookException>()),
    );
    await expectLater(nb.move(standalone, parentId: d.page), throwsA(isA<NotebookException>()));
    expect(nb.tree[standalone], isNotNull);
    expect(folder.existsSync(), isFalse);
  });

  testWidgets('the sidebar says "On another device" and keeps the pages, greyed', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late ({Notebook nb, BinderSection s, String page, String sub}) d;
    await tester.runAsync(() async {
      d = await setUpBinder();
      takeAway();
      await d.nb.checkFolders();
    });
    await tester.pumpWidget(MaterialApp(home: Home(notebook: d.nb)));
    await tester.pump();

    expect(find.text('On another device'), findsOneWidget);
    final row = find.byKey(ValueKey('page-row-${d.page}'));
    expect(row, findsOneWidget);
    expect(find.byKey(ValueKey('page-row-${d.sub}')), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final nb in opened) {
        nb.dispose();
      }
      opened.clear();
    });
  });
}
