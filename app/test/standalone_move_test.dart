// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose [corruptAt]th write is damaged after it lands.
class CorruptingStore extends PageStore {
  CorruptingStore(super.directory, {required this.corruptAt});

  final int corruptAt;
  int saves = 0;

  @override
  Future<void> save(NotedPage page) async {
    await super.save(page);
    if (++saves == corruptAt) {
      final f = File('${directory.path}${Platform.pathSeparator}${page.id}.canvas');
      await f.writeAsString(' ', mode: FileMode.append);
    }
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_standalone_move');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
  });

  Notebook make({PageStore Function(Directory)? factory}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      storeFactory: factory ?? PageStore.new,
    );
    opened.add(nb);
    return nb;
  }

  Future<void> cleanUp() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  }

  String read(Directory d, String id) => File('${d.path}/$id.canvas').readAsStringSync();
  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  group('model', () {
    tearDown(cleanUp);

    test('nesting under a page in another folder moves it and its subpages', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final ca = await nb.createPage(parentId: a);
      final ga = await nb.createPage(parentId: ca);
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final before = {for (final id in [a, ca, ga]) id: read(pages, id)};

      expect(await nb.move(a, parentId: x), isTrue);
      await nb.flush();

      for (final id in [a, ca, ga]) {
        expect(has(extra, id), isTrue, reason: '$id moved');
        expect(has(pages, id), isFalse, reason: '$id source deleted');
      }
      // Byte-identical apart from the moved page's parent and order.
      expect(read(extra, ca), before[ca]);
      expect(read(extra, ga), before[ga]);
      final moved = readPage(read(extra, a));
      expect(moved.meta.parentId, x);
      expect(writePage(moved.withMeta(readPage(before[a]!).meta)), before[a]);
      expect(nb.tree.childrenOf(x).map((p) => p.id), [a]);
      expect(nb.tree.descendantsOf(x), [a, ca, ga]);

      // A new Notebook sees the same tree.
      final again = make();
      await again.load();
      expect(again.tree.descendantsOf(x), [a, ca, ga]);
    });

    test('the open page moves with its subpages and stays open', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final x = await nb.createPage(folderPath: extra.path);
      await nb.open(a);
      expect(await nb.move(a, parentId: x), isTrue);
      expect(nb.currentId, a);
      expect(has(extra, a), isTrue);
      expect(has(pages, a), isFalse);
    });

    test('dropping before or after a page in another folder moves it there', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final b = await nb.createPage();
      final x = await nb.createPage(folderPath: extra.path);
      final y = await nb.createPage(folderPath: extra.path);
      await nb.flush();

      expect(await nb.moveRelative(a, y, after: false), isTrue);
      expect(has(extra, a), isTrue);
      expect(has(pages, a), isFalse);
      var order = nb.tree.roots.map((p) => p.id).toList();
      expect(order.indexOf(a), lessThan(order.indexOf(y)));
      expect(order.indexOf(a), greaterThan(order.indexOf(x)));

      expect(await nb.moveRelative(b, x, after: true), isTrue);
      expect(has(extra, b), isTrue);
      expect(has(pages, b), isFalse);
      order = nb.tree.roots.map((p) => p.id).toList();
      expect(order.indexOf(b), order.indexOf(x) + 1);
    });

    test('a page cannot move under its own descendant in another folder', () async {
      final nb = make();
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      final kid = await nb.createPage(parentId: x);
      expect(await nb.move(x, parentId: kid), isFalse);
      expect(has(extra, x), isTrue);
    });

    test('a failed verification keeps the sources and removes the copies', () async {
      // Writes to the extra folder: creating x is #1, then the move's two copies.
      final nb = make(factory: (d) => CorruptingStore(d, corruptAt: 3));
      await nb.load();
      final a = nb.currentId!;
      final ca = await nb.createPage(parentId: a);
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final before = {for (final id in [a, ca]) id: read(pages, id)};

      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('not copied'))),
      );
      for (final id in [a, ca]) {
        expect(read(pages, id), before[id]);
        expect(has(extra, id), isFalse);
      }
      expect(nb.tree.descendantsOf(a), [ca]);
      expect(nb.tree.childrenOf(x), isEmpty);
    });
  });

  group('sidebar', () {
    late Notebook nb;
    late String a;
    late String x;

    Finder row(String id) => find.byKey(ValueKey('page-row-$id'));

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pumpAndSettle();
    }

    Future<void> start(WidgetTester tester) async {
      await tester.runAsync(() async {
        nb = make();
        await nb.load();
        a = nb.currentId!;
        x = await nb.createPage(folderPath: extra.path);
        await nb.rename(a, 'Alpha');
        await nb.rename(x, 'Xray');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 600,
              child: ListenableBuilder(
                listenable: nb,
                builder: (context, _) => PageTreeView(notebook: nb),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(cleanUp);
    }

    testWidgets('dragging a page into a page of another folder moves its file', (tester) async {
      await start(tester);
      final from = tester.getTopLeft(row(a)) + const Offset(60, 18);
      final r = tester.getRect(row(x));
      final target = Offset(r.left + 80, r.top + r.height * 0.5);
      final g = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.moveTo(from + const Offset(0, 4));
      await tester.pump();
      await g.moveTo(target);
      await tester.pump();
      await g.moveTo(target + const Offset(0, 0.5));
      await tester.pump();
      await tester.runAsync(() => g.up());
      await settle(tester);

      expect(nb.tree.childrenOf(x).map((p) => p.id), [a]);
      expect(has(extra, a), isTrue);
      expect(has(pages, a), isFalse);
      await finish(tester);
    });
  });
}
