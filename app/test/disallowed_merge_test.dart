// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Run 2026-11-14-02, task 3. A box whose type is disallowed on its page (by its
// header, a parent, the binder, or any version a merge reads) is merged as a
// switched-off module's box: never decoded, kept as this device has it, the
// other version recorded in its conflicts (0111).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';
import 'support/spy_modules.dart';

void main() {
  late Directory root;
  late Directory dir;
  late Directory binderDir;
  late Notebook nb;
  late PageStore other;
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('noted_disallowed_merge');
    dir = await Directory('${root.path}${sep}pages').create();
    binderDir = await Directory('${root.path}${sep}Work').create();
    modules = spyModules();
    nb = Notebook(
      PageStore(dir),
      modules,
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}${sep}binders.json'),
    );
    other = PageStore(dir);
    await nb.load();
    await other.scan();
    SpyCalls.reset();
  }

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  String pathIn(Directory d, String id) => '${d.path}$sep$id.canvas';
  NotedPage readFile(String path) => readPage(File(path).readAsStringSync());
  List<int> bytes(NotedPage p) => utf8.encode(writePage(p));
  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

  const boxId = 'd000000000000001';
  final s0 = spyStroke('s0', 30, t0: 1);
  final s1 = spyStroke('s1', 60, t0: 2);
  final s2 = spyStroke('s2', 90, t0: 3);

  BoxRecord boxOf(NotedPage p) => p.node(boxId)! as BoxRecord;

  /// The box is conflicted, holds mine's data, version, snapshot and revision
  /// as they were, and records [theirs] verbatim.
  void expectKeptMine(NotedPage page, BoxRecord mine, BoxRecord theirs, {String? why}) {
    final b = boxOf(page);
    expect(b.isConflicted, isTrue, reason: '$why: the box is conflicted');
    expect(b.data!.text, mine.data!.text, reason: '$why: data is mine');
    expect(b.dataVersion, mine.dataVersion, reason: '$why: v');
    expect(b.snapshotText, mine.snapshotText, reason: '$why: snapshot');
    expect(b.rev, mine.rev, reason: '$why: rev');
    expect(b.conflicts.single.node!.text, theirs.toRaw().text, reason: '$why: theirs verbatim');
  }

  // ------------------------------------------------------------------------
  // 0. The regression guard: with a type a module can switch off, strokes added
  // on both sides to a page that allows the type merge through the codec.

  test('0 (guard) with the type allowed, strokes added on both sides merge through the codec', () async {
    await start();
    final id = nb.currentId!;
    final c = nb.current!;
    c.insertBox(spyDrawingBox(boxId, [s0]));
    await nb.flush();
    final base = readFile(pathIn(dir, id));
    c.editBox(boxId, DrawingData(strokes: [s0, s1]));
    final theirs = base.replaceNode(withStrokes(boxOf(base), [s0, s2]));
    await busyRetry(() => other.save(theirs));
    SpyCalls.reset();
    await nb.checkFile(pathIn(dir, id));
    await pump();
    final merged = nb.current!.page;
    expect(boxOf(merged).isConflicted, isFalse);
    final ids = [for (final s in const DrawingCodec().decode(boxOf(merged).data!.decode(), 1).strokes) s.id];
    expect(ids, unorderedEquals(['s0', 's1', 's2']));
    expect(SpyCalls.of(spyDrawing, 'merge'), greaterThan(0), reason: 'the spy sees the merge');
  });

  // ------------------------------------------------------------------------
  // 1. The open page, the type disallowed by the page, a parent or the binder.

  for (final by in ['the page header', 'a parent page', 'the binder']) {
    test('1 the open page: a box of a type disallowed by $by is conflicted, never decoded', () async {
      await start();
      late String id;
      late Directory home;
      late Future<void> Function() disallow;
      switch (by) {
        case 'the page header':
          id = nb.currentId!;
          home = dir;
          disallow = () => nb.setBoxType(id, spyDrawing, false);
        case 'a parent page':
          final parent = await nb.createPage();
          id = await nb.createPage(parentId: parent);
          home = dir;
          disallow = () => nb.setBoxType(parent, spyDrawing, false);
        default:
          final section = await nb.addBinder(binderDir.path);
          id = await nb.createPage(binderPath: section.path);
          home = binderDir;
          disallow = () => nb.setBinderBoxType(section.path, spyDrawing, false);
      }
      expect(nb.currentId, id);
      final c = nb.current!;
      c.insertBox(spyDrawingBox(boxId, [s0]));
      await nb.flush();
      final path = pathIn(home, id);
      final base = readFile(path);
      // An unsaved stroke, then the disallow, then an external write.
      c.editBox(boxId, DrawingData(strokes: [s0, s1]));
      final mine = boxOf(c.page);
      await disallow();
      final until = DateTime.now().add(const Duration(seconds: 10));
      while (nb.boxTypeAvailabilityFor(id, spyDrawing).allowed && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(nb.boxTypeAvailabilityFor(id, spyDrawing).allowed, isFalse, reason: 'the disallow took effect');
      expect(c.disallowedTypes, contains(spyDrawing), reason: 'the controller was told');
      final theirsBox = withStrokes(boxOf(base), [s0, s2]);
      await busyRetry(() => PageStore(home).save(base.replaceNode(theirsBox)));
      SpyCalls.reset();
      await nb.checkFile(path);
      await pump();
      expectKeptMine(nb.current!.page, mine, theirsBox, why: by);
      expect(SpyCalls.total(spyDrawing), 0);
    });
  }

  // ------------------------------------------------------------------------
  // 2. The allow-list changed on one side: memory allows the type, the other
  // version's header disallows it.

  group('2 the other version disallows the type', () {
    late String id;
    late NotedPage base;
    late NotedPage theirsPage;
    late BoxRecord theirsBox;

    NotedPage withDisallow(NotedPage p) => p.withMeta(p.meta.withBoxType(spyDrawing, false));

    void expectMergedHeader(NotedPage p) {
      expect(p.meta.boxTypeChoice(spyDrawing), isFalse, reason: 'the merged header disallows the type');
    }

    Future<void> prepare({required bool open}) async {
      await start();
      id = nb.currentId!;
      nb.current!.insertBox(spyDrawingBox(boxId, [s0]));
      await nb.flush();
      base = readFile(pathIn(dir, id));
      theirsBox = withStrokes(boxOf(base), [s0, s2]);
      theirsPage = withDisallow(base.replaceNode(theirsBox));
      if (!open) {
        await nb.createPage(); // id is closed now
        await nb.checkFile(pathIn(dir, id));
        await pump();
      }
    }

    test('through the watcher, on the open page', () async {
      await prepare(open: true);
      nb.current!.editBox(boxId, DrawingData(strokes: [s0, s1]));
      final mine = boxOf(nb.current!.page);
      await busyRetry(() => other.save(theirsPage));
      SpyCalls.reset();
      await nb.checkFile(pathIn(dir, id));
      await pump();
      expectKeptMine(nb.current!.page, mine, theirsBox);
      expectMergedHeader(nb.current!.page);
      expect(SpyCalls.total(spyDrawing), 0);
      await nb.flush();
      expectMergedHeader(readFile(pathIn(dir, id)));
    });

    test('through mergeRemote, on the open page', () async {
      await prepare(open: true);
      nb.current!.editBox(boxId, DrawingData(strokes: [s0, s1]));
      final mine = boxOf(nb.current!.page);
      SpyCalls.reset();
      final r = await nb.mergeRemote(pathIn(dir, id), bytes(base), bytes(theirsPage));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expectKeptMine(nb.current!.page, mine, theirsBox);
      expectMergedHeader(nb.current!.page);
      expect(SpyCalls.total(spyDrawing), 0);
    });

    test('through mergeRemote, on a closed page', () async {
      await prepare(open: false);
      final mineBox = withStrokes(boxOf(base), [s0, s1]);
      await busyRetry(() => other.save(base.replaceNode(mineBox)));
      SpyCalls.reset();
      final r = await nb.mergeRemote(pathIn(dir, id), bytes(base), bytes(theirsPage));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      final saved = readFile(pathIn(dir, id));
      expectKeptMine(saved, mineBox, theirsBox);
      expectMergedHeader(saved);
      expect(SpyCalls.total(spyDrawing), 0);
    });
  });

  // ------------------------------------------------------------------------
  // 6. Conflict copies never merge content through a codec (guard, against a
  // future codec merge).

  for (final open in [true, false]) {
    test('6 (guard) a conflict copy merged into the ${open ? 'open' : 'closed'} page makes no codec call', () async {
      await start();
      final id = nb.currentId!;
      nb.current!.insertBox(spyDrawingBox(boxId, [s0]));
      await nb.flush();
      final original = readFile(pathIn(dir, id));
      if (!open) {
        await nb.createPage();
        await nb.checkFile(pathIn(dir, id));
        await pump();
      } else {
        nb.current!.editBox(boxId, DrawingData(strokes: [s0, s1]));
        await nb.flush();
      }
      final copy = original.replaceNode(withStrokes(boxOf(original), [s0, s2]));
      final copyPath = '${dir.path}$sep$id-DESKTOP-9.canvas';
      File(copyPath).writeAsStringSync(writePage(copy));
      SpyCalls.reset();
      await nb.checkFile(copyPath);
      await pump();
      expect(SpyCalls.total(spyDrawing), 0);
    });
  }

  // ------------------------------------------------------------------------
  // 14. The notebook is the one pusher of the controller's set: with no canvas
  // mounted, it is current before the notebook's own listeners run.

  group('14 the controller holds the set before the notebook notifies', () {
    late CanvasController c;
    late String id;
    final atNotebook = <bool>[];
    var controllerNotified = 0;

    Future<void> watchOpenPage() async {
      c = nb.current!;
      id = nb.currentId!;
      atNotebook.clear();
      controllerNotified = 0;
      c.addListener(() => controllerNotified++);
      nb.addListener(() => atNotebook.add(c.disallowedTypes.contains(spyDrawing)));
      expect(c.disallowedTypes, isEmpty);
    }

    void expectPushed(String source, {bool has = true}) {
      expect(controllerNotified, greaterThan(0), reason: '$source: the controller notified');
      expect(c.disallowedTypes.contains(spyDrawing), has, reason: '$source: the set');
      expect(atNotebook, isNotEmpty, reason: '$source: the notebook notified');
      expect(atNotebook.last, has, reason: '$source: current when the notebook\'s listeners ran');
      // The first notebook notify after the change already saw it.
      expect(atNotebook.contains(has), isTrue, reason: source);
    }

    test('the page header', () async {
      await start();
      await watchOpenPage();
      await nb.setBoxType(id, spyDrawing, false);
      expectPushed('page header');
      await nb.setBoxType(id, spyDrawing, null);
      expect(c.disallowedTypes, isEmpty, reason: 'allowed again');
    });

    test('a parent page header', () async {
      await start();
      final parent = await nb.createPage();
      await nb.createPage(parentId: parent);
      await watchOpenPage();
      await nb.setBoxType(parent, spyDrawing, false);
      expectPushed('parent header');
    });

    test('the binder (a change made through the notebook)', () async {
      await start();
      final section = await nb.addBinder(binderDir.path);
      await nb.createPage(binderPath: section.path);
      await watchOpenPage();
      await nb.setBinderBoxType(section.path, spyDrawing, false);
      await _until(() => c.disallowedTypes.contains(spyDrawing), 'the binder write');
      expectPushed('binder');
    });

    test('the binder file, changed by another device', () async {
      await start();
      final section = await nb.addBinder(binderDir.path);
      await nb.createPage(binderPath: section.path);
      await watchOpenPage();
      final file = File('${binderDir.path}${Platform.pathSeparator}$binderFileName');
      file.writeAsStringSync(Binder.parse(file.readAsStringSync()).withBoxType(spyDrawing, false).write());
      await nb.checkBinderFile(file.path);
      await _until(() => c.disallowedTypes.contains(spyDrawing), 'the binder file was read');
      expectPushed('binder file');
    });

    test('a move to another binder', () async {
      await start();
      final section = await nb.addBinder(binderDir.path);
      await nb.setBinderBoxType(section.path, spyDrawing, false);
      await _until(() => nb.binderBoxType(section.path, spyDrawing) == false, 'the binder write');
      await watchOpenPage();
      expect(c.disallowedTypes, isEmpty, reason: 'the page is in no binder');
      expect(await nb.moveToLocation(id, binderPath: section.path), isTrue);
      // The page is installed again: the new controller holds the set.
      expect(nb.current!.disallowedTypes, contains(spyDrawing), reason: 'move');
      expect(nb.currentId, id);
    });

    test('a module switched on again', () async {
      await start();
      await watchOpenPage();
      await nb.setBoxType(id, spyDrawing, false);
      modules.setEnabled(spyDrawing, false);
      await nb.setAiAccess(id, AiAccess.open); // any notify
      expect(c.disallowedTypes, isEmpty, reason: 'a module that is off is not a disallowed type');
      modules.setEnabled(spyDrawing, true);
      atNotebook.clear();
      await nb.setAiAccess(id, AiAccess.guarded);
      expectPushed('module on');
    });
  });
}

Future<void> _until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
