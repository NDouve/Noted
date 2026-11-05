// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

/// The pieces of R-1 v5 (failed saves never lose edits) that don't need the
/// notebook: the save chain (L1), the open page's session, the outcome of a
/// recovery write, the retry backoff, error classification and the state the
/// bar shows.

// Errors -----------------------------------------------------------------------

/// Whether [e] says a file is busy for now: held by another program (a sync
/// client, an antivirus scan) or locked. Windows 32 (sharing violation) and 33
/// (lock violation); POSIX EAGAIN and EBUSY. [os] is for tests (`windows`,
/// `macos`, `linux`); it defaults to the platform the app runs on.
bool isBusyError(Object e, {String? os}) {
  if (e is! FileSystemException) return false;
  final code = e.osError?.errorCode;
  if (code == null) return false;
  final platform = os ?? Platform.operatingSystem;
  if (platform == 'windows') return code == 32 || code == 33;
  if (code == 16) return true; // EBUSY
  return code == (platform == 'macos' ? 35 : 11); // EAGAIN
}

/// A plain reason for [e], fit to show the user: the operating system's own
/// words when it has them.
String describeError(Object e) {
  if (e is FileSystemException) {
    final os = e.osError?.message.trim();
    if (os != null && os.isNotEmpty)
      return os.endsWith('.') ? os.substring(0, os.length - 1) : os;
    if (e.message.isNotEmpty) return e.message;
  }
  return 'an unexpected error';
}

// The save chain (L1) ----------------------------------------------------------

class _Job {
  _Job(this.pages);
  final Set<String> pages;
}

class _Root {
  Future<void> tail = Future<void>.value();
  final Set<_Job> live = {};
  bool detached = false;
  final Completer<void> detachedSignal = Completer<void>();
}

/// Saves and other writes run one after another, so an older version never
/// lands last (L1). A job that hangs can be left behind with [detach]: later
/// jobs then wait only on a new chain, and everything that waited for the old
/// one is released.
class SaveChain {
  _Root _root = _Root();

  /// Called when a job of a detached chain ends, with the pages it declared.
  /// Not called for a job that ended before the chain was detached.
  void Function(Set<String> pages)? onDetachedJobEnded;

  /// Runs [job] after the jobs queued so far and before any later one. [pages]
  /// are the pages it works on, for [detach].
  Future<T> run<T>(Future<T> Function() job, {Set<String> pages = const {}}) {
    final root = _root;
    final j = _Job(pages);
    root.live.add(j);
    final c = Completer<T>();
    root.tail = root.tail.then((_) async {
      try {
        c.complete(await job());
      } on Object catch (e, s) {
        c.completeError(e, s);
      } finally {
        root.live.remove(j);
        if (root.detached && pages.isNotEmpty) onDetachedJobEnded?.call(pages);
      }
    });
    return c.future;
  }

  /// Completes when everything queued so far has finished, or when the chain
  /// is detached.
  Future<void> get idle {
    final r = _root;
    return Future.any([r.tail, r.detachedSignal.future]);
  }

  /// Whether no job is queued or running.
  bool get isIdle => _root.live.isEmpty;

  /// Leaves the jobs on the chain behind: [idle] of the old chain completes,
  /// and later jobs run on a new one. Returns, for each page the old jobs
  /// still working declared, how many of them declared it.
  Map<String, int> detach() {
    final r = _root;
    final pages = <String, int>{};
    for (final j in r.live) {
      for (final p in j.pages) {
        pages[p] = (pages[p] ?? 0) + 1;
      }
    }
    r.detached = true;
    if (!r.detachedSignal.isCompleted) r.detachedSignal.complete();
    _root = _Root();
    return pages;
  }
}

// The open page's session ------------------------------------------------------

/// What one opening of a page keeps about its saves. Every L1 job and every
/// recovery write carries its session; a result is applied to the session it
/// came from, never by page id.
class SaveSession {
  SaveSession(this.pageId);

  final String pageId;

  /// Incremented on each change of the page.
  int seq = 0;

  /// Raised by Discard: a write of an older snapshot is dropped.
  int floor = 0;

  /// The newest snapshot a kept write holds.
  int newestWritten = 0;

  /// The recovery generations this session wrote, by the snapshot they hold.
  final Map<String, int> own = {};

  /// Set when the session is over (the page was closed).
  bool ended = false;
}

// Recovery outcomes -------------------------------------------------------------

enum KeepKind {
  /// The edits are in the recovery folder.
  kept,

  /// The recovery write failed.
  failed,

  /// Nothing was written: a merge would have lost an edit, an entry that isn't
  /// ours is in the way, or recovery isn't usable.
  refused,

  /// A newer snapshot is already kept (or Discard overtook this one).
  dropped,
}

class KeepOutcome {
  const KeepOutcome(this.kind, {this.cause, this.why, this.gen});

  final KeepKind kind;

  /// The generation written, for [KeepKind.kept].
  final String? gen;

  /// The error behind [KeepKind.failed].
  final Object? cause;

  /// A plain reason for [KeepKind.refused] and [KeepKind.failed].
  final String? why;

  /// Whether the edits are safe: kept, or a newer kept write holds them.
  bool get safe => kind == KeepKind.kept || kind == KeepKind.dropped;

  static const kept = KeepOutcome(KeepKind.kept);
  static const dropped = KeepOutcome(KeepKind.dropped);
}

/// How a save of the open page ended.
enum SaveEnd { landed, failed, blocked, skipped }

class SaveResult {
  const SaveResult(this.end, [this.keep]);

  final SaveEnd end;

  /// What happened to the edits when [end] is [SaveEnd.failed] or blocked.
  final KeepOutcome? keep;
}

// Backoff -----------------------------------------------------------------------

/// Tries again after a growing wait: [first], then twice as long each time, up
/// to [max]. [reset] starts over (a save landed).
class SaveBackoff {
  SaveBackoff({
    this.first = const Duration(seconds: 2),
    Duration max = const Duration(seconds: 30),
    required this.onTick,
  }) : max = max < first ? first : max;

  final Duration first;
  final Duration max;
  final void Function() onTick;

  Timer? _timer;
  Duration? _delay;

  /// The wait now scheduled or last used; null after [reset].
  Duration? get delay => _delay;

  bool get scheduled => _timer?.isActive ?? false;

  /// Starts the wait for the next try, if none is running.
  void schedule() {
    if (scheduled) return;
    final next = _delay == null ? first : _delay! * 2;
    _delay = next > max ? max : next;
    _timer = Timer(_delay!, () {
      _timer = null;
      onTick();
    });
  }

  /// Forgets the growth and any wait.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _delay = null;
  }

  /// Cancels the wait but keeps the growth (a try is being made now).
  void cancelWait() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => reset();
}

// What the bar shows ------------------------------------------------------------

enum TroubleKind {
  /// Nothing to show.
  saved,

  /// The save failed; the edits are kept in recovery (state 2).
  failing,

  /// The save and the recovery write both failed (state 4).
  recoveryFailing,

  /// The page is a read-only preview of kept changes that can't be saved yet.
  preview,
}

/// The state of the open page's saves, for the bar (an immutable snapshot).
class TroubleState {
  const TroubleState(
    this.kind, {
    this.pageId,
    this.title = '',
    this.reason = '',
    this.advice = '',
    this.canDiscardKept = false,
    this.canSaveCopy = true,
  });

  static const saved = TroubleState(TroubleKind.saved);

  final TroubleKind kind;
  final String? pageId;
  final String title;

  /// Why, in plain words.
  final String reason;

  /// What to do about the cause (state 4), or empty.
  final String advice;

  /// A preview that can't land offers "Discard kept changes".
  final bool canDiscardKept;

  /// False where there is no folder picker (mobile).
  final bool canSaveCopy;

  bool get isTrouble => kind != TroubleKind.saved;

  @override
  bool operator ==(Object other) =>
      other is TroubleState &&
      other.kind == kind &&
      other.pageId == pageId &&
      other.reason == reason &&
      other.advice == advice &&
      other.canDiscardKept == canDiscardKept &&
      other.title == title;

  @override
  int get hashCode =>
      Object.hash(kind, pageId, reason, advice, canDiscardKept, title);
}

/// A question the notebook asks the user, answered by the window.
enum UserQuestion {
  /// Leaving a page whose edits aren't safe anywhere ("Your changes will be
  /// lost"). True: leave anyway.
  leaveAndLose,

  /// Deleting a page that has changes that couldn't be saved. True: delete
  /// them too.
  deleteKept,

  /// Discarding the changes kept for a page that can't be saved. True: discard.
  discardKept,
}

/// A page whose edits were put in recovery on leaving it: the window shows a
/// notice for about 30 seconds, with Show.
class KeptNotice {
  const KeptNotice({
    required this.pageId,
    required this.title,
    required this.reason,
  });

  final String pageId;
  final String title;
  final String reason;
}
