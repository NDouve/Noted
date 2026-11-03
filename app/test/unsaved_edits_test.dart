// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/unsaved_edits.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _folder = '/pages';
const _loc = '';

/// A notebook stand-in: page files in memory, a real recovery folder, and a
/// save queue that runs one job after another.
class _Host implements UnsavedEditsHost {
  _Host(this.recovery);

  @override
  final RecoveryStore? recovery;

  final Map<String, String> files = {};
  final Map<String, String> locs = {};
  final Set<String> locked = {};
  String? open;
  bool keepFails = false;

  /// Written saves lose the boxes (and report what they wrote).
  bool lossy = false;

  /// Runs as a closed save starts.
  void Function()? duringSave;

  /// What the next closed saves end with; empty: they are written.
  final List<ClosedSaveResult> plan = [];

  /// A closed save that is written completes [writing], then waits here.
  Completer<void>? gate;
  Completer<void>? writing;
  final List<String> saved = [];
  final List<String> notices = [];
  final List<String> unreadables = [];
  int openSaves = 0;
  Future<void> _queue = Future.value();

  Future<void> drain() async {
    // Jobs queued by jobs run too.
    for (var q = _queue; ; q = _queue) {
      await q;
      if (identical(q, _queue)) return;
    }
  }

  @override
  String? locOf(String id) => locs[id];

  @override
  bool isLocked(String loc) => locked.contains(loc);

  @override
  bool isOpen(String id) => open == id;

  @override
  Future<bool> keepForRecovery(String folder, NotedPage page, String? baseText) async {
    if (keepFails) return false;
    await recovery!.write(folder: folder, page: page, baseText: baseText, time: DateTime.now());
    return true;
  }

  @override
  Future<ClosedSave> saveClosed(String loc, NotedPage base, NotedPage mine, bool Function() proceed) async {
    ClosedSave not(ClosedSaveResult r) => (result: r, page: null, theirs: null, why: 'why');
    duringSave?.call();
    if (plan.isNotEmpty) return not(plan.removeAt(0));
    if (!proceed()) return not(ClosedSaveResult.gone);
    final w = writing;
    writing = null;
    w?.complete();
    await gate?.future;
    final t = files[mine.id];
    final theirs = t == null ? null : readPage(t);
    final merged = theirs == null ? mine : merge(base, mine, theirs);
    final page = lossy ? NotedPage.create(merged.meta) : merged;
    files[mine.id] = writePage(page);
    saved.add(mine.id);
    return (result: ClosedSaveResult.saved, page: page, theirs: theirs, why: null);
  }

  @override
  Future<String> readText(String loc, String id) async => files[id] ?? (throw const FileSystemException('not there'));

  @override
  NotedPage merge(NotedPage base, NotedPage mine, NotedPage theirs) =>
      mergePage(base, mine, theirs, buildModules().codecs, theirsTime: 0).page;

  @override
  void landed(String loc, NotedPage page) {}

  @override
  void unreadable(String loc, String id, String why) => unreadables.add(id);

  @override
  void saveOpen() => openSaves++;

  @override
  void enqueue(String what, Future<void> Function() job) => _queue = _queue.then((_) => job());

  @override
  void notify(String message) => notices.add(message);
}

void main() {
  late Directory root;
  late _Host host;
  late UnsavedEdits unsaved;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_unsaved');
    host = _Host(RecoveryStore(Directory('${root.path}/rec')));
    unsaved = UnsavedEdits(host, firstDelay: const Duration(hours: 1)); // retried only when asked
  });

  tearDown(() async {
    unsaved.dispose();
    await host.drain();
    await root.delete(recursive: true);
  });

  // Page [id] as saved, and the same page with [boxes] new boxes.
  (NotedPage, NotedPage) page(String id, {int boxes = 1}) {
    final base = NotedPage.create(PageMeta.create(id: id, title: 'Page $id', order: 0));
    final c = CanvasController(base, buildModules());
    for (var i = 0; i < boxes; i++) {
      c.createBoxAt(Bounds(40.0 + 100 * i, 40, 0, 0));
    }
    final mine = c.page;
    c.dispose();
    return (base, mine);
  }

  // Page [id] saved in its file, then a failed save of an edit.
  Future<NotedPage> failed(String id, {int boxes = 1}) async {
    final (base, mine) = page(id, boxes: boxes);
    host.files[id] = writePage(base);
    host.locs[id] = _loc;
    await unsaved.onSaveFailed(_loc, _folder, mine, writePage(base));
    return mine;
  }

  Future<List<RecoveryEntry>> entries() async => (await host.recovery!.list()).entries;

  Future<void> retry() async {
    unsaved.retryAll();
    await host.drain();
  }

  test('a failed save is kept in recovery, told once, and lands on a retry, which retires the entry', () async {
    final mine = await failed('a');
    expect(unsaved.has('a'), isTrue);
    expect(unsaved.unsavedPageCount, 0, reason: 'recovery holds them');
    expect((await entries()).single.pageText, writePage(mine));
    await unsaved.onSaveFailed(_loc, _folder, mine, null);
    expect(host.notices, hasLength(1), reason: 'once for the streak');

    await retry();
    expect(readPage(host.files['a']!).nodes, hasLength(1));
    expect(unsaved.has('a'), isFalse);
    expect(await entries(), isEmpty);
  });

  test('while recovery fails the edits are held in memory and counted; the retry writes them', () async {
    host.keepFails = true;
    await failed('a');
    expect(unsaved.unsavedPageCount, 1);
    expect(unsaved.heldOnlyIn(_loc), isTrue);
    await retry();
    expect(readPage(host.files['a']!).nodes, hasLength(1));
    expect(unsaved.unsavedPageCount, 0);
  });

  test('the recovery entry owns the edits: a retry lands what the entry holds now', () async {
    await failed('a');
    // A save of the page that went to recovery itself (its folder vanished
    // during a retry) holds more edits now.
    final (base, two) = page('a', boxes: 2);
    host.plan.add(ClosedSaveResult.folderGone);
    await host.recovery!.write(folder: _folder, page: two, baseText: writePage(base), time: DateTime.now());
    await retry();
    expect(unsaved.has('a'), isTrue);
    await retry();
    expect(readPage(host.files['a']!).nodes, hasLength(2));
    expect(await entries(), isEmpty, reason: 'that entry is retired, not left to be replayed again');
  });

  test('the retry delay doubles up to the cap and starts again after a success', () async {
    unsaved = UnsavedEdits(host, firstDelay: const Duration(hours: 1), maxDelay: const Duration(hours: 3));
    await failed('a');
    expect(unsaved.retryDelay, const Duration(hours: 1));
    final delays = <Duration?>[];
    for (var i = 0; i < 3; i++) {
      host.plan.add(ClosedSaveResult.failed);
      await retry();
      delays.add(unsaved.retryDelay);
    }
    expect(delays, const [Duration(hours: 2), Duration(hours: 3), Duration(hours: 3)]);
    await retry(); // lands
    expect(unsaved.retryDelay, isNull);
    await failed('b');
    expect(unsaved.retryDelay, const Duration(hours: 1));
  });

  test('a retry runs by its timer, without anyone asking', () async {
    unsaved = UnsavedEdits(host, firstDelay: const Duration(milliseconds: 10));
    await failed('a');
    for (var i = 0; i < 100 && unsaved.has('a'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(readPage(host.files['a']!).nodes, hasLength(1));
  });

  test('busy and other failures keep the edits and retry; a locked place waits', () async {
    await failed('a');
    host.plan.addAll([ClosedSaveResult.busy, ClosedSaveResult.failed]);
    for (var i = 0; i < 2; i++) {
      await retry();
      expect(unsaved.has('a'), isTrue);
    }
    host.locked.add(_loc);
    await retry();
    expect(host.saved, isEmpty);
    host.locked.clear();
    await retry();
    expect(host.saved, ['a']);
  });

  test('an unreadable file stops the retries, lists it and keeps the entry until it is readable', () async {
    await failed('a');
    host.plan.add(ClosedSaveResult.unreadable);
    await retry();
    expect(host.unreadables, ['a']);
    await retry();
    expect(host.saved, isEmpty, reason: 'no retry while it is unreadable');
    expect(await entries(), hasLength(1));
    unsaved.fileReadable('a');
    await host.drain();
    expect(host.saved, ['a']);
    expect(await entries(), isEmpty);
  });

  test('a page gone from its place is told, and its entry stays for the next start', () async {
    await failed('a');
    host.locs.remove('a');
    await retry();
    expect(unsaved.has('a'), isFalse);
    expect(host.notices.last, contains('deleted or moved on another device'));
    expect(await entries(), hasLength(1));
  });

  test('a held page is not written; settle waits for a retry that is writing it', () async {
    await failed('a');
    unsaved.hold(['a']);
    await retry();
    expect(host.saved, isEmpty);
    unsaved.release(['a']);

    host
      ..gate = Completer<void>()
      ..writing = Completer<void>();
    unsaved.retryAll();
    final started = host.writing!.future;
    await started;
    unsaved.hold(['a']);
    var settled = false;
    final s = unsaved.settle(['a']).then((_) => settled = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse);
    host.gate!.complete();
    await s;
    expect(host.saved, ['a']);
    expect(await unsaved.settle(['b']).then((_) => true), isTrue, reason: 'nothing to wait for');
    unsaved.release(['a']);
  });

  test('foldInto merges the edits into a copy; drop forgets them with their entries', () async {
    final mine = await failed('a');
    final (_, theirs) = page('a', boxes: 2); // two other boxes on disk
    final folded = await unsaved.foldInto('a', _loc, theirs);
    expect(folded.nodes.map((n) => n.id), containsAll(mine.nodes.map((n) => n.id)));
    expect(folded.nodes, hasLength(3));
    expect(await unsaved.foldInto('a', 'elsewhere', theirs), same(theirs));
    await unsaved.drop(['a']);
    expect(unsaved.has('a'), isFalse);
    expect(await entries(), isEmpty);
  });

  test('forgetPlace leaves edits in recovery to it and keeps those held only here unless discarded', () async {
    await failed('a');
    host.keepFails = true;
    await failed('b');
    unsaved.forgetPlace(_loc);
    expect(unsaved.has('a'), isFalse);
    expect(unsaved.has('b'), isTrue);
    expect(await entries(), hasLength(1), reason: 'the entry of a stays');
    unsaved.forgetPlace(_loc, discard: true);
    expect(unsaved.has('b'), isFalse);
  });

  test('the open page is retried through its own save, and edits() gives it the kept page', () async {
    final mine = await failed('a');
    host.open = 'a';
    await retry();
    expect(host.openSaves, 1);
    expect(host.saved, isEmpty);
    final e = await unsaved.edits('a', _loc);
    expect(writePage(e!.mine), writePage(mine));
    host.files['a'] = writePage(mine);
    await unsaved.onSaved(_loc, mine);
    expect(unsaved.has('a'), isFalse);
    expect(await entries(), isEmpty);
  });

  test('a retry whose result lacks an edit is not taken as landed, like a replay', () async {
    await failed('a');
    host.lossy = true;
    await retry();
    expect(host.saved, ['a']);
    expect(unsaved.has('a'), isTrue, reason: 'verifyRecoveredPage refused it');
    expect(await entries(), hasLength(1));
    host.lossy = false;
    await retry();
    expect(unsaved.has('a'), isFalse);
  });

  test('a page that left its place because the place became unusable meanwhile is waited for, not told gone', () async {
    await failed('a');
    host
      ..plan.add(ClosedSaveResult.gone)
      ..duringSave = () => host.locked.add(_loc); // its binder file went while the save ran
    await retry();
    expect(unsaved.has('a'), isTrue);
    expect(host.notices.where((n) => n.contains('deleted or moved')), isEmpty);
    host
      ..duringSave = null
      ..locked.clear();
    await retry();
    expect(host.saved, ['a']);
  });

  test('the retry delay starts again once nothing is kept, however the last page went', () async {
    unsaved = UnsavedEdits(host, firstDelay: const Duration(hours: 1), maxDelay: const Duration(hours: 3));
    await failed('a');
    host.plan.add(ClosedSaveResult.failed);
    await retry();
    expect(unsaved.retryDelay, const Duration(hours: 2));
    unsaved.forget('a');
    expect(unsaved.retryDelay, isNull);
    await failed('b');
    expect(unsaved.retryDelay, const Duration(hours: 1));
  });

  test('an entry replayed by someone else ends the tracking', () async {
    await failed('a');
    for (final e in await entries()) {
      await host.recovery!.delete(e);
    }
    expect(await unsaved.edits('a', _loc), isNull);
    expect(unsaved.has('a'), isFalse);
  });
}
