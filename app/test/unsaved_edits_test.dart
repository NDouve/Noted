// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/unsaved_edits.dart';
import 'package:noted_core/noted_core.dart';

class _Host implements UnsavedEditsHost {
  final Map<String, String> places = {'a': 'loc', 'b': 'loc'};
  final Set<String> locked = {};
  final Set<String> open = {};
  final List<String> replays = [];
  final List<String> saves = [];
  final List<String> notices = [];
  final List<String> waitingRetired = [];
  ReplayOutcome Function(String id) outcome = (_) => ReplayOutcome.done;
  Future<void> Function(String id)? gate;

  @override
  String? locOf(String id) => places[id];

  @override
  bool isLocked(String loc) => locked.contains(loc);

  @override
  bool isOpen(String id) => open.contains(id);

  @override
  Future<ReplayOutcome> replayPage(String loc, String id) async {
    replays.add(id);
    await gate?.call(id);
    return outcome(id);
  }

  @override
  Future<void> retireWaiting(String id) async => waitingRetired.add(id);

  @override
  void saveOpen() => saves.add('open');

  @override
  void notify(String message) => notices.add(message);
}

NotedPage _page(String id) => NotedPage.create(PageMeta.create(id: id, title: 'T', order: 0));

void main() {
  late _Host host;
  late UnsavedEdits unsaved;

  setUp(() {
    host = _Host();
    unsaved = UnsavedEdits(host, firstDelay: const Duration(milliseconds: 30), maxDelay: const Duration(milliseconds: 100));
  });

  tearDown(() => unsaved.dispose());

  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a tracked page is tried again with a delay that doubles up to the maximum, and starts over after a success', () async {
    host.outcome = (_) => ReplayOutcome.again;
    unsaved.track('a', 'loc');
    unsaved.noteFailure('a', 'T');
    expect(unsaved.retryDelay, const Duration(milliseconds: 30));
    await until(() => host.replays.length >= 3);
    expect(unsaved.retryDelay, const Duration(milliseconds: 100), reason: '30, 60, then capped');
    host.outcome = (_) => ReplayOutcome.done;
    await until(() => !unsaved.has('a'));
    expect(unsaved.retryDelay, isNull);
    unsaved.track('a', 'loc');
    unsaved.noteFailure('a', 'T');
    expect(unsaved.retryDelay, const Duration(milliseconds: 30));
  });

  test('the user is told once per failure streak', () {
    unsaved.track('a', 'loc');
    unsaved.noteFailure('a', 'T');
    unsaved.noteFailure('a', 'T');
    expect(host.notices, hasLength(1));
    unsaved.succeeded('a');
    unsaved.track('a', 'loc');
    unsaved.noteFailure('a', 'T');
    expect(host.notices, hasLength(2));
  });

  test('the open page is retried through its own save, not a replay', () async {
    host.open.add('a');
    unsaved.track('a', 'loc');
    unsaved.noteFailure('a', 'T');
    await until(() => host.saves.isNotEmpty);
    expect(host.replays, isEmpty);
  });

  test('a held page is not replayed, and is tried again once released', () async {
    host.outcome = (_) => ReplayOutcome.done;
    unsaved.track('a', 'loc');
    unsaved.hold(['a']);
    unsaved.retryAll();
    await unsaved.idle();
    expect(host.replays, isEmpty);
    unsaved.release(['a']);
    unsaved.retryAll();
    await until(() => host.replays.isNotEmpty);
  });

  test('settle waits for a replay that is running, not for the queue', () async {
    final gate = Completer<void>();
    host.gate = (_) => gate.future;
    unsaved.track('a', 'loc');
    final replay = unsaved.run('a', () => unsaved.replaying('a', () => host.replayPage('loc', 'a')));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    var settled = false;
    final settle = unsaved.settle(['a']).then((_) => settled = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(settled, isFalse);
    gate.complete();
    await settle;
    await replay;
    // A job on a page's queue may start a delete that settles its own page.
    await unsaved.run('a', () => unsaved.settle(['a'])).timeout(const Duration(seconds: 2));
  });

  test('a page\'s queue runs its jobs in order, and idle waits for all of them', () async {
    final order = <int>[];
    unawaited(unsaved.run('a', () async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      order.add(1);
    }));
    unawaited(unsaved.run('a', () async => order.add(2)));
    unawaited(unsaved.run('b', () async => order.add(3)));
    await unsaved.idle();
    expect(order, [3, 1, 2]);
    expect(unsaved.busy, isFalse);
  });

  test('a page whose file can not be read waits until it can', () async {
    host.outcome = (_) => ReplayOutcome.blocked;
    unsaved.track('a', 'loc');
    unsaved.retryAll();
    await until(() => host.replays.length == 1);
    unsaved.markBlocked('a');
    unsaved.retryAll();
    await unsaved.idle();
    expect(host.replays, hasLength(1));
    host.outcome = (_) => ReplayOutcome.done;
    unsaved.fileReadable('a');
    await until(() => host.replays.length == 2);
  });

  test('a page that is gone from its place is let go', () async {
    unsaved.track('a', 'loc');
    host.places['a'] = 'elsewhere';
    unsaved.retryAll();
    await until(() => !unsaved.has('a'));
    expect(host.replays, isEmpty);
  });

  test('edits held in memory are counted, belong to their place, and survive its replay taking over', () {
    unsaved.setHeld('a', 'loc', HeldCopy(_page('a'), null, const []));
    expect(unsaved.unsavedPageCount, 1);
    expect(unsaved.heldOnlyIn('loc'), isTrue);
    expect(unsaved.heldOnlyIn('other'), isFalse);
    unsaved.forgetPlace('loc');
    expect(unsaved.has('a'), isTrue, reason: 'only memory holds them');
    unsaved.forgetPlace('loc', discard: true);
    expect(unsaved.has('a'), isFalse);
    expect(unsaved.unsavedPageCount, 0);
  });

}
