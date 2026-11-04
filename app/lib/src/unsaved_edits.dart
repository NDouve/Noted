// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

import 'recovery_store.dart';

/// How one pass over a page that isn't open ended ([UnsavedEditsHost.replayPage]):
/// everything it had is saved and retired; something is left and the pass is
/// tried again later; the page's file can't be read (no retry until it can); or
/// the page is not there any more (a delete or a move took it).
enum ReplayOutcome { done, again, blocked, gone }

/// What [UnsavedEdits] needs from the notebook.
abstract interface class UnsavedEditsHost {
  /// The place (location key) page [id] is listed in, or null.
  String? locOf(String id);

  /// Whether the files of [loc] must not be written now (also: [loc] is not
  /// in the notebook).
  bool isLocked(String loc);

  /// Whether page [id] is the open page.
  bool isOpen(String id);

  /// Folds the recovery entries and the edits held in memory of page [id], which
  /// isn't open, into its file in [loc], and retires what landed. Runs on the
  /// page's queue.
  Future<ReplayOutcome> replayPage(String loc, String id);

  /// Tries again to retire the entries of [id] that landed and are waiting to
  /// be retired. Runs on the page's queue.
  Future<void> retireWaiting(String id);

  /// Writes the copy held in memory of page [id] to the recovery folder as an
  /// entry of its own. True when it is there.
  Future<bool> keepHeld(String id);

  /// Whether the open page [id] shows the copy held in memory of it (a save of it
  /// lands that copy).
  bool sessionHoldsHeld(String id);

  /// Queues a save of the open page.
  void saveOpen();

  /// Tells the user [message].
  void notify(String message);
}

/// The edits of a page that recovery could not keep, held in memory until a
/// write of the page file (or of recovery) takes them.
class HeldCopy {
  const HeldCopy(this.page, this.baseText, this.supersedes, [this.folder]);

  final NotedPage page;

  /// The folder the page belongs in, as recovery entries name it.
  final String? folder;
  final String? baseText;

  /// The generations the copy was built on.
  final List<String> supersedes;
}

// What is known of a page that has unsaved edits.
class _Kept {
  _Kept(this.loc);

  String loc;
  HeldCopy? held;

  // Entries that have landed in the page file and could not be retired yet.
  final Map<String, RecoveryEntry> waiting = {};

  // Whether the user was told about this failure streak.
  bool told = false;

  // The file can't be read: no retry until it can (see [UnsavedEdits.fileReadable]).
  bool blocked = false;
}

/// Pages with unsaved edits: whose save failed with their folder there (R-1),
/// or whose recovery entries could not be replayed yet. The edits are in
/// recovery entries (or, while writing those fails, in a [HeldCopy]); this
/// tracks which pages to try again with a growing delay, remembers entries that
/// landed and could not be retired, keeps the queue each page's folds,
/// publishes and retires run on, and counts what the quit notice must say. The
/// user is told once per failure streak.
class UnsavedEdits {
  UnsavedEdits(this.host, {required this.firstDelay, Duration maxDelay = const Duration(seconds: 30)})
    : maxDelay = maxDelay < firstDelay ? firstDelay : maxDelay;

  final UnsavedEditsHost host;

  /// The wait before the first retry; each next one waits twice as long, up
  /// to [maxDelay]. A save that lands starts again from [firstDelay].
  final Duration firstDelay;
  final Duration maxDelay;

  final Map<String, _Kept> _kept = {};
  // Pages being deleted or moved: no retry writes them.
  final Set<String> _structural = {};
  // One queue per page: every fold, publish and retire of a page runs on it.
  final Map<String, Future<void>> _queues = {};
  final Set<String> _queued = {};
  Duration? _delay;
  Timer? _timer;
  bool _disposed = false;

  /// The pages being tracked.
  Iterable<String> get ids => _kept.keys;

  bool has(String id) => _kept.containsKey(id);

  /// Whether any page has a queued or running job.
  bool get busy => _queues.isNotEmpty;

  /// The pages whose edits are held in memory only.
  Iterable<String> get heldIds => [
    for (final e in _kept.entries)
      if (e.value.held != null) e.key,
  ];

  /// How many pages have edits that are neither saved nor in the recovery
  /// folder.
  int get unsavedPageCount => heldIds.length;

  /// Whether [loc] has edits that are neither saved nor in the recovery folder.
  bool heldOnlyIn(String loc) => _kept.values.any((k) => k.loc == loc && k.held != null);

  /// The wait before the retry now scheduled, if any.
  @visibleForTesting
  Duration? get retryDelay => _delay;

  // Queues ------------------------------------------------------------------

  /// Runs [job] after every job queued for page [id] so far, and before any
  /// later one. A job on a page's queue must not wait for a queue ([idle]) or
  /// for a flush.
  Future<T> run<T>(String id, Future<T> Function() job) {
    final prev = _queues[id] ?? Future<void>.value();
    final c = Completer<T>();
    final tail = prev.then((_) async {
      try {
        c.complete(await job());
      } on Object catch (e, s) {
        c.completeError(e, s);
      }
    });
    _queues[id] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_queues[id], tail)) _queues.remove(id);
      }),
    );
    return c.future;
  }

  /// Completes when every page's queue is empty (also for jobs queued meanwhile).
  Future<void> idle() async {
    while (_queues.isNotEmpty) {
      await Future.wait(_queues.values.toList());
    }
  }

  // Replays that are running now, by page.
  final Map<String, Future<void>> _replaying = {};

  /// Runs a replay of [id] (on its queue), so a delete or a move can wait for it.
  Future<T> replaying<T>(String id, Future<T> Function() body) async {
    final done = Completer<void>();
    _replaying[id] = done.future;
    try {
      return await body();
    } finally {
      done.complete();
      if (identical(_replaying[id], done.future)) _replaying.remove(id);
    }
  }

  /// Waits for the replays of [ids] that are running now. (Not for the queues:
  /// a delete can run from inside a queued job, and a replay that starts after
  /// [hold] returns before it reads.)
  Future<void> settle(Iterable<String> ids) => Future.wait([for (final id in ids) ?_replaying[id]]);

  /// No retry or replay writes [ids] until [release]: a delete or a move takes them.
  void hold(Iterable<String> ids) => _structural.addAll(ids);

  void release(Iterable<String> ids) {
    _structural.removeAll(ids);
    _schedule(); // what is still tracked (a delete or move that failed) is tried again
  }

  bool isHeld(String id) => _structural.contains(id);

  // Tracking ----------------------------------------------------------------

  /// Page [id] of [loc] has unsaved edits (in recovery entries or held here):
  /// it is tried again with a growing delay.
  void track(String id, String loc) {
    final k = _kept[id];
    if (k == null) {
      _kept[id] = _Kept(loc);
    } else if (k.loc != loc) {
      k.loc = loc;
    }
  }

  /// Starts the wait for the next retry, if none is running.
  void schedule() => _schedule();

  /// The file of page [id] can't be read: no retry until [fileReadable].
  void markBlocked(String id) {
    final k = _kept[id];
    if (k != null) k.blocked = true;
  }

  /// A save of page [id] failed ([title]): the user is told, once per streak.
  void noteFailure(String id, String title) {
    final k = _kept[id];
    if (k == null) return;
    if (!k.told && !_disposed) {
      k.told = true;
      final t = title.trim();
      host.notify(
        "Couldn't save ${t.isEmpty ? 'this page' : '"$t"'}. "
        'Your edits are kept and will be saved when it works again.',
      );
    }
    _schedule();
  }

  /// The edits of page [id] that recovery could not take: held in memory.
  void setHeld(String id, String loc, HeldCopy copy) {
    track(id, loc);
    _kept[id]!.held = copy;
    _schedule();
  }

  HeldCopy? heldOf(String id) => _kept[id]?.held;

  void clearHeld(String id) {
    _kept[id]?.held = null;
  }

  /// Entries of [id] that landed and could not be retired: no fold uses them
  /// again, and the retire is tried again.
  void addWaiting(String id, String loc, Iterable<RecoveryEntry> entries) {
    track(id, loc);
    final k = _kept[id]!;
    for (final e in entries) {
      k.waiting[e.gen] = e;
    }
    _schedule();
  }

  /// The generations of [id]'s entries that landed and are waiting to be retired.
  Set<String> waitingGens(String id) => {...?_kept[id]?.waiting.keys};

  List<RecoveryEntry> waitingOf(String id) => [...?_kept[id]?.waiting.values];

  /// Every generation waiting to be retired, for any page.
  Set<String> get allWaitingGens => {
    for (final k in _kept.values) ...k.waiting.keys,
  };

  void removeWaiting(String id, Iterable<String> gens) {
    final k = _kept[id];
    if (k == null) return;
    gens.forEach(k.waiting.remove);
  }

  /// A save or a replay of page [id] landed everything it had: tracking ends
  /// unless something is still held or waiting. The copy held in memory is let
  /// go only if [clearHeld]: the save that landed was made from it.
  void succeeded(String id, {bool clearHeld = false}) {
    final k = _kept[id];
    if (k == null) return;
    k.told = false;
    k.blocked = false;
    if (clearHeld) k.held = null;
    _delay = null; // a save landed: the next failure starts again from the first delay
    _settled(id, k);
  }

  void _settled(String id, _Kept k) {
    if (k.held != null || k.waiting.isNotEmpty) return;
    _remove(id);
  }

  /// Page [id] is no longer tracked here; what is in recovery stays there
  /// (and is replayed like any other).
  void forget(String id) => _remove(id);

  /// [loc] leaves the notebook, or its replay takes over: edits in the
  /// recovery folder are left to it. Edits held only in memory stay unless
  /// [discard].
  void forgetPlace(String loc, {bool discard = false}) {
    _kept.removeWhere((_, k) => k.loc == loc && ((k.held == null && k.waiting.isEmpty) || discard));
    _removed();
  }

  // A page with a copy held in memory is never let go: only [clearHeld] or a
  // discard ends that.
  _Kept? _remove(String id) {
    if (_kept[id]?.held != null) return null;
    final k = _kept.remove(id);
    _removed();
    return k;
  }

  // Nothing is kept any more: the next failure starts from the first delay.
  void _removed() {
    if (_kept.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
    _delay = null;
  }

  /// The file of page [id] can be read again.
  void fileReadable(String id) {
    final k = _kept[id];
    if (k == null || !k.blocked) return;
    k.blocked = false;
    _enqueue(id);
  }

  /// Tries every tracked page again: the open one through its normal save, the
  /// others through a replay. [except] is saved already.
  void retryAll({String? except}) {
    _timer?.cancel();
    _timer = null;
    for (final id in _kept.keys.toList()) {
      if (id == except) continue;
      _enqueue(id);
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _kept.clear();
  }

  void _schedule() {
    if (_disposed || _kept.isEmpty || (_timer?.isActive ?? false)) return;
    final next = _delay == null ? firstDelay : _delay! * 2;
    _delay = next > maxDelay ? maxDelay : next;
    _timer = Timer(_delay!, retryAll);
  }

  void _enqueue(String id) {
    if (_disposed || !_queued.add(id)) return;
    unawaited(
      run(id, () async {
        _queued.remove(id);
        await _retry(id);
      }).catchError((Object e) {
        debugPrint('Trying page $id again failed: $e');
      }),
    );
  }

  // Tries the unsaved edits of page [id] again, on its queue.
  Future<void> _retry(String id) async {
    final k = _kept[id];
    if (k == null || _disposed || _structural.contains(id)) return;
    try {
      if (k.waiting.isNotEmpty) await host.retireWaiting(id);
      if (!identical(_kept[id], k)) return;
      if (host.isOpen(id)) {
        // A copy held in memory that the open page does not show waits for the page
        // to close or be replayed: saving the page again would change nothing.
        if (k.held != null && !host.sessionHoldsHeld(id)) {
          final captured = k.held; // a newer copy may arrive meanwhile
          if (await host.keepHeld(id) && identical(_kept[id], k) && identical(k.held, captured)) {
            k.held = null;
            _settled(id, k);
          } else {
            _schedule();
          }
          return;
        }
        // The open page's own save lands the edits (and retires its entries).
        host.saveOpen();
        _schedule();
        return;
      }
      if (host.isLocked(k.loc)) {
        // Its place can't be written now; wait for it.
        _schedule();
        return;
      }
      if (host.locOf(id) != k.loc) {
        // Gone from its place (deleted or moved on another device): its entries
        // stay, and bring the page back at the next start (0070). A copy held in
        // memory is written to recovery as an entry of its own, or, while that
        // fails, stays held and counted.
        if (k.held != null) {
          final captured = k.held; // a newer copy may arrive meanwhile
          if (await host.keepHeld(id) && identical(_kept[id], k) && identical(k.held, captured)) {
            k.held = null;
          } else {
            _schedule();
            return;
          }
        }
        _remove(id);
        return;
      }
      if (k.blocked) {
        // Nothing to replay until the file can be read, but a copy held in memory
        // is still written to recovery as soon as that works.
        if (k.held != null) {
          final captured = k.held; // a newer copy may arrive meanwhile
          if (await host.keepHeld(id) && identical(_kept[id], k) && identical(k.held, captured)) {
            k.held = null;
            _settled(id, k);
          } else {
            _schedule();
          }
        }
        return;
      }
      switch (await host.replayPage(k.loc, id)) {
        case ReplayOutcome.done:
          if (identical(_kept[id], k)) succeeded(id);
        case ReplayOutcome.gone:
          if (identical(_kept[id], k)) _remove(id);
        case ReplayOutcome.blocked:
          k.blocked = true;
        case ReplayOutcome.again:
          _schedule();
      }
    } on Exception catch (e) {
      // Reading or writing failed (Errors, which are bugs, are not retried).
      debugPrint('Saving page $id again failed: $e');
      _schedule();
    }
  }
}
