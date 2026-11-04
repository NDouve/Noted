// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

import 'recovery_store.dart';

/// How a save of a page that isn't open ended (see [UnsavedEditsHost.saveClosed]):
/// written; the page is not in its place any more (or `proceed` stopped it);
/// the file kept changing; the file can't be read as this page (left alone);
/// the folder vanished (the save went to recovery); any other failure.
enum ClosedSaveResult { saved, gone, busy, unreadable, folderGone, failed }

/// The outcome of [UnsavedEditsHost.saveClosed]: the page written and the file
/// it was merged with ([theirs], null if none), or why not ([why]).
typedef ClosedSave = ({ClosedSaveResult result, NotedPage? page, NotedPage? theirs, String? why});

/// What [UnsavedEdits] needs from the notebook.
abstract interface class UnsavedEditsHost {
  /// The recovery folder, or null if nothing can be kept.
  RecoveryStore? get recovery;

  /// The place (location key) page [id] is listed in, or null.
  String? locOf(String id);

  /// Whether the files of [loc] must not be written now (also: [loc] is not
  /// in the notebook).
  bool isLocked(String loc);

  /// Whether page [id] is the open page.
  bool isOpen(String id);

  /// Writes [page] (made on [baseText]) to the recovery folder, as belonging in
  /// [folder]. True when it is there.
  Future<bool> keepForRecovery(String folder, NotedPage page, String? baseText);

  /// Saves [mine], made on [base], into the file of a page that isn't open,
  /// merged with whatever is there (0124). [proceed] is asked just before the
  /// write; false stops it ([ClosedSaveResult.gone]).
  Future<ClosedSave> saveClosed(String loc, NotedPage base, NotedPage mine, bool Function() proceed);

  /// The text of page [id]'s file in [loc].
  Future<String> readText(String loc, String id);

  /// The three-way merge of [mine] and [theirs] from [base] (0051).
  NotedPage merge(NotedPage base, NotedPage mine, NotedPage theirs);

  /// A retry wrote [page] into [loc]: the sidebar takes its header.
  void landed(String loc, NotedPage page);

  /// The file of page [id] in [loc] can't be read ([why]): it is listed under
  /// "Can't open".
  void unreadable(String loc, String id, String why);

  /// Queues a save of the open page.
  void saveOpen();

  /// Runs [job] on the save queue.
  void enqueue(String what, Future<void> Function() job);

  /// Tells the user [message].
  void notify(String message);
}

// What is known of a page whose save failed with its folder there. The
// recovery entry of [folder] and the page owns the edits; [page] and
// [baseText] are held only while writing that entry has failed.
class _Kept {
  _Kept(this.loc, this.folder, this.title);

  final String loc;
  final String folder;
  String title;
  NotedPage? page;
  String? baseText;

  // When [page] was taken: a recovery entry written after that (the open
  // page blocked, a save whose folder vanished) is newer, and replaces it.
  DateTime? heldAt;

  // The page text of the recovery entry that holds the edits (written here,
  // or read from it); a newer edit replaces it.
  String? entryText;

  // Whether the user was told about this failure streak.
  bool told = false;

  // The file can't be read: no retry until it can (see [UnsavedEdits.fileReadable]).
  bool blocked = false;
}

/// Pages whose save failed while their folder was there (R-1): their edits are
/// kept in the recovery folder (or in memory while that fails), tried again
/// with a growing delay through the closed-page save, folded into a delete's
/// or a move's copy, and counted for the quit notice. The user is told once
/// per failure streak.
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
  // Retries that are running, and those waiting in the save queue.
  final Map<String, Future<void>> _writing = {};
  final Set<String> _queued = {};
  Duration? _delay;
  Timer? _timer;
  bool _disposed = false;

  /// The pages with kept edits.
  Iterable<String> get ids => _kept.keys;

  bool has(String id) => _kept.containsKey(id);

  /// How many pages have edits that are neither saved nor in the recovery
  /// folder.
  int get unsavedPageCount => _kept.values.where((k) => k.page != null).length;

  /// Whether [loc] has edits that are neither saved nor in the recovery folder.
  bool heldOnlyIn(String loc) => _kept.values.any((k) => k.loc == loc && k.page != null);

  /// The wait before the retry now scheduled, if any.
  @visibleForTesting
  Duration? get retryDelay => _delay;

  /// A save of [page] into [loc] (its folder [folder], there) failed with an
  /// I/O error. [baseText] is the file the page was made on.
  Future<void> onSaveFailed(String loc, String folder, NotedPage page, String? baseText) async {
    var k = _kept[page.id];
    if (k == null || k.loc != loc) k = _kept[page.id] = _Kept(loc, folder, page.meta.title);
    await _keep(page.id, k, page, baseText);
    if (!k.told && !_disposed) {
      k.told = true;
      final title = page.meta.title.trim();
      host.notify(
        "Couldn't save ${title.isEmpty ? 'this page' : '"$title"'}. "
        'Your edits are kept and will be saved when it works again.',
      );
    }
    _schedule();
  }

  /// The open page [saved] landed in [loc]: if it holds kept edits and reads
  /// back as written, they are safe.
  Future<void> onSaved(String loc, NotedPage saved) async {
    final k = _kept[saved.id];
    if (k == null || k.loc != loc) return;
    try {
      if (await host.readText(loc, saved.id) != writePage(saved)) return _schedule();
    } on IOException {
      return _schedule();
    }
    // The open page holds every kept edit: all entries of the page go.
    if (identical(_kept[saved.id], k)) await _retire(saved.id, k, all: true);
  }

  /// The kept edits of page [id] in [loc], to show when it is opened: the page
  /// and the page it was made on. Null if there are none.
  Future<({NotedPage mine, NotedPage base})?> edits(String id, String loc) async {
    final k = _kept[id];
    if (k == null || k.loc != loc) return null;
    final e = await _edits(id, k);
    if (e == null) _remove(id); // its entry was replayed meanwhile
    return e;
  }

  /// [onDisk] (page [id] as read from [loc]) with the kept edits merged in, for
  /// the copy a delete or a move keeps.
  Future<NotedPage> foldInto(String id, String loc, NotedPage onDisk) async {
    final k = _kept[id];
    final e = k == null || k.loc != loc ? null : await _edits(id, k);
    return e == null ? onDisk : host.merge(e.base, e.mine, onDisk);
  }

  /// No retry writes [ids] until [release]: a delete or a move takes them.
  void hold(Iterable<String> ids) => _structural.addAll(ids);

  void release(Iterable<String> ids) {
    _structural.removeAll(ids);
    _schedule(); // what is still kept (a delete or move that failed) is tried again
  }

  /// Waits for retries of [ids] that are writing now. (Not for the whole save
  /// queue: a delete can run from inside a queued job.)
  Future<void> settle(Iterable<String> ids) => Future.wait([for (final id in ids) ?_writing[id]]);

  /// The user deleted [ids], or moved them elsewhere with the edits: what was
  /// kept for them goes, with the recovery entries for their old place.
  Future<void> drop(Iterable<String> ids) async {
    final rec = host.recovery;
    for (final id in ids) {
      final k = _remove(id);
      if (k == null || rec == null) continue;
      try {
        for (final e in (await rec.list()).entries) {
          if (e.folder == k.folder && e.pageId == id) await rec.delete(e);
        }
      } on Object catch (e) {
        debugPrint('Dropping the recovery entry of page $id failed: $e');
      }
    }
  }

  /// Page [id] is no longer tracked here; a recovery entry stays (and is
  /// replayed like any other).
  void forget(String id) => _remove(id);

  /// [loc] leaves the notebook, or its replay takes over: edits in the
  /// recovery folder are left to it. Edits held only in memory stay unless
  /// [discard].
  void forgetPlace(String loc, {bool discard = false}) {
    _kept.removeWhere((_, k) => k.loc == loc && (k.page == null || discard));
    _removed();
  }

  /// Whether page [id] of [folder] has newer edits held here than its recovery
  /// entry: replay leaves that entry alone, the retry retires it.
  bool holdsInMemory(String folder, String id) {
    final k = _kept[id];
    return k != null && k.page != null && k.folder == folder;
  }

  _Kept? _remove(String id) {
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

  /// Tries every kept page again: the open one through its normal save, the
  /// others through the closed-page save. [except] is saved already.
  void retryAll({String? except}) {
    _timer?.cancel();
    _timer = null;
    for (final id in _kept.keys.toList()) {
      if (id == except) continue;
      if (host.isOpen(id)) {
        host.saveOpen();
      } else {
        _enqueue(id);
      }
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
    if (!_queued.add(id)) return;
    host.enqueue('retry of page $id', () async {
      _queued.remove(id);
      final run = _retry(id);
      _writing[id] = run;
      try {
        await run;
      } finally {
        if (identical(_writing[id], run)) _writing.remove(id);
      }
    });
  }

  // Writes the edits to recovery; they are held in memory only while that
  // fails. True when they are in recovery.
  Future<bool> _keep(String id, _Kept k, NotedPage page, String? baseText) async {
    final ok = await host.keepForRecovery(k.folder, page, baseText);
    k.title = page.meta.title;
    if (ok) {
      k
        ..page = null
        ..baseText = null
        ..entryText = writePage(page);
    } else {
      k
        ..page = page
        ..baseText = baseText
        ..heldAt = DateTime.now();
    }
    return ok;
  }

  // Writes the copy held in memory to recovery (merged with a newer entry
  // first). True when recovery holds them.
  Future<bool> _keepHeld(String id, _Kept k) async {
    await _mergeNewer(id, k);
    final page = k.page;
    return page == null || await _keep(id, k, page, k.baseText);
  }

  // An entry of the page written after the copy in memory was taken holds
  // other edits: the open page's (made on that copy) or a save's whose folder
  // vanished (an AI write, made on the file without that copy). Neither may
  // replace the copy: the two are merged and kept as the entry, which is
  // never written over with the copy alone. If listing fails, the copy in
  // memory stays as it is.
  Future<void> _mergeNewer(String id, _Kept k) async {
    final at = k.heldAt;
    final held = k.page;
    final rec = host.recovery;
    if (held == null || at == null || rec == null) return;
    final RecoveryEntry? newer;
    try {
      newer = (await rec.list()).entries
          .where((e) => e.folder == k.folder && e.pageId == id && e.time.isAfter(at))
          .fold<RecoveryEntry?>(null, (a, e) => a == null || e.time.isAfter(a.time) ? e : a);
    } on Object catch (e) {
      debugPrint('Listing the recovery entries of page $id failed: $e');
      return;
    }
    if (newer == null || !identical(_kept[id], k)) return;
    final merged = host.merge(_baseOf(k.baseText, held), held, newer.page);
    await _keep(id, k, merged, newer.baseText);
  }

  static NotedPage _baseOf(String? text, NotedPage mine) => text == null ? NotedPage.create(mine.meta) : readPage(text);

  // The kept page and its base: from memory, or from the recovery entry (null
  // if it is not there any more).
  Future<({NotedPage mine, NotedPage base})?> _edits(String id, _Kept k) async {
    await _mergeNewer(id, k);
    var mine = k.page;
    var baseText = k.baseText;
    if (mine == null) {
      final e = await _entryOf(id, k);
      if (e == null) return null;
      k.entryText = e.pageText;
      mine = e.page;
      baseText = e.baseText;
    }
    return (mine: mine, base: _baseOf(baseText, mine));
  }

  Future<RecoveryEntry?> _entryOf(String id, _Kept k) async {
    final rec = host.recovery;
    if (rec == null) return null;
    return (await rec.list()).entries.where((e) => e.folder == k.folder && e.pageId == id).firstOrNull;
  }

  // The edits are in the file: the entry that held them goes ([all]: every
  // entry of the page, after the open page, the newest copy, was saved).
  Future<void> _retire(String id, _Kept k, {bool all = false}) async {
    _remove(id);
    _delay = null; // a save landed: the next failure starts again from the first delay
    final rec = host.recovery;
    final text = k.entryText;
    // A copy held in memory is newer than the entries of the page written
    // before it was taken: they go too, or a later replay would bring back
    // what was deleted since. One written after it is never deleted here.
    final heldAt = k.page == null ? null : k.heldAt;
    if (rec == null || (text == null && heldAt == null && !all)) return;
    try {
      for (final e in (await rec.list()).entries) {
        if (e.folder != k.folder || e.pageId != id) continue;
        if (all || e.pageText == text || (heldAt != null && !e.time.isAfter(heldAt))) await rec.delete(e);
      }
    } on Object catch (e) {
      debugPrint('Dropping the recovery entry of page $id failed: $e');
    }
  }

  // The page is gone from its place (deleted or moved on another device): its
  // entry stays, and restores it at the next start (0070).
  Future<void> _gone(String id, _Kept k) async {
    if (!await _keepHeld(id, k)) return _schedule();
    if (!identical(_remove(id), k) || _disposed) return;
    final title = k.title.trim();
    host.notify(
      '${title.isEmpty ? 'A page' : '"$title"'} was deleted or moved on another device; '
      'your unsaved edits are kept and it will be restored next time Noted starts.',
    );
  }

  // Tries the kept edits of page [id], which isn't open, again: merged into
  // its file as it is now, never written over it.
  Future<void> _retry(String id) async {
    final k = _kept[id];
    if (k == null || k.blocked || _disposed || _structural.contains(id) || host.isOpen(id)) return;
    try {
      if (host.isLocked(k.loc)) {
        // Its place can't be written now; wait for it.
        await _keepHeld(id, k);
        return _schedule();
      }
      if (host.locOf(id) != k.loc) return await _gone(id, k);
      final e = await _edits(id, k);
      if (e == null) {
        _remove(id); // its entry was replayed meanwhile
        return;
      }
      var stopped = false;
      final out = await host.saveClosed(k.loc, e.base, e.mine, () {
        stopped = _structural.contains(id) || !identical(_kept[id], k);
        return !stopped;
      });
      if (!identical(_kept[id], k)) return;
      switch (out.result) {
        case ClosedSaveResult.saved:
          // Checked like a replay: every edit must be in what reads back.
          final back = await host.readText(k.loc, id);
          final written = out.page!;
          if (back != writePage(written) ||
              verifyRecoveredPage(base: e.base, mine: e.mine, theirs: out.theirs, result: readPage(back)) != null) {
            return _schedule();
          }
          if (!_structural.contains(id)) host.landed(k.loc, written);
          if (identical(_kept[id], k)) await _retire(id, k);
        case ClosedSaveResult.gone:
          // A delete or a move stopped it: that takes the edits. A place that
          // became unusable meanwhile (its binder file went) is waited for.
          if (stopped) break;
          if (host.isLocked(k.loc)) {
            _schedule();
          } else {
            await _gone(id, k);
          }
        case ClosedSaveResult.unreadable:
          // Never written over: the edits stay in recovery until a readable
          // version is there (0124).
          await _keepHeld(id, k);
          k.blocked = true;
          host.unreadable(k.loc, id, out.why ?? "it couldn't be read");
        case ClosedSaveResult.folderGone:
          // The save wrote its own entry, which the next retry reads; edits
          // held in memory are kept there too.
          await _keepHeld(id, k);
          _schedule();
        case ClosedSaveResult.busy || ClosedSaveResult.failed:
          _schedule();
      }
    } on Exception catch (e) {
      // Reading or writing failed (Errors, which are bugs, are not retried).
      debugPrint('Saving page $id again failed: $e');
      _schedule();
    }
  }
}
