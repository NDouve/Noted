// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:noted_sync/noted_sync.dart';

import 'notebook.dart';

/// What the controller needs from the pull engine ([PullEngine] is wrapped
/// by [EngineRunner]); a test passes its own.
abstract class SyncRunner {
  SyncStatus get status;
  GuardQuestion? get guardQuestion;
  List<SyncIssue> get issues;
  Stream<void> get changes;

  /// One round; never throws.
  Future<RoundResult> runRound();
  Future<RoundResult?> answerGuard(GuardQuestion q, {required bool remove});
  void dispose();
}

class EngineRunner implements SyncRunner {
  EngineRunner(this.engine);

  final PullEngine engine;

  @override
  SyncStatus get status => engine.status;
  @override
  GuardQuestion? get guardQuestion => engine.guardQuestion;
  @override
  List<SyncIssue> get issues => engine.issues;
  @override
  Stream<void> get changes => engine.changes;
  @override
  Future<RoundResult> runRound() => engine.runRound();
  @override
  Future<RoundResult?> answerGuard(GuardQuestion q, {required bool remove}) =>
      engine.answerGuard(q, remove: remove);
  @override
  void dispose() => engine.dispose();
}

/// Foreground polling interval with a page of the folder open (G14).
const Duration cloudPollOpen = Duration(seconds: 10);

/// Foreground polling interval otherwise (G14).
const Duration cloudPollIdle = Duration(minutes: 5);

/// What every pull on a phone or tablet shares (sync stage 3, 0154): the
/// folder kept listed in the notebook, polling while the app is in front, the
/// notebook told what each round changed, and the guard's question. A provider
/// ([OneDriveSync], [WebDavSync]) says when it may poll and how its folder is
/// found and its runner built; the rest is here.
abstract class CloudSync extends ChangeNotifier with WidgetsBindingObserver {
  CloudSync({
    required this.notebook,
    required this.workingRoot,
    required this.support,
    required this.pollOpen,
    required this.pollIdle,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Notebook notebook;

  /// The provider's folder of working copies, below it one per account and folder.
  final Directory workingRoot;

  /// [deviceSupportDirectory]: the choice and the journals are below it.
  final Directory support;
  final Duration pollOpen;
  final Duration pollIdle;
  final DateTime Function() _now;

  SyncRunner? _runner;
  StreamSubscription<void>? _runnerSub;
  Timer? _timer;
  bool _timerOpen = false;
  bool _wantPoll = false;
  bool _loaded = false;
  bool _foreground = true;
  Future<void>? _current;
  bool _lastFailed = false;
  bool _disposed = false;
  DateTime? _lastChecked;
  String? _problem;
  Future<void> _queue = Future<void>.value();

  // --- What a provider says -------------------------------------------------

  /// For messages and logs: `OneDrive`, `WebDAV`.
  String get providerName;

  /// Whether the credentials are usable now: polling runs only then.
  @protected
  bool get canPoll;

  /// Whether a guard answer may go to the runner now. OneDrive saves an answer
  /// while signed out (it is applied after sign-in); WebDAV sends nothing while
  /// its password is refused.
  @protected
  bool get canAnswerGuard => true;

  /// The reason nothing runs (signed out, a choice that can't be read), as a
  /// status line; null when nothing blocks.
  @protected
  String? get blockedLine;

  /// The status line when the engine says it is signed out.
  @protected
  String get signedOutLine => 'Signed out';

  /// Starts watching the provider's account (a listener); [evaluate] runs next.
  @protected
  void attachAccount();

  @protected
  void detachAccount();

  /// Decides what to run: finds the choice, builds the runner, polls. Called
  /// through [evaluate], never twice at once.
  @protected
  Future<void> doEvaluate();

  /// The working copy of the chosen folder, once there is one.
  Directory? get workingCopy;

  // --- State ----------------------------------------------------------------

  @protected
  SyncRunner? get runner => _runner;
  @protected
  bool get loaded => _loaded;
  @protected
  bool get disposed => _disposed;
  @protected
  bool get foreground => _foreground;
  @protected
  set wantPoll(bool v) => _wantPoll = v;
  @protected
  bool get wantPoll => _wantPoll;
  @protected
  set problem(String? v) => _problem = v;
  @protected
  String? get problemText => _problem;

  /// Something stopped the setup (the folder choice could not be saved, or its folder not listed).
  bool get hasProblem => _problem != null;

  /// A round is running.
  bool get checking =>
      _current != null || _runner?.status.state == SyncState.running;

  GuardQuestion? get guardQuestion => _runner?.guardQuestion;
  List<SyncIssue> get issues => _runner?.issues ?? const [];
  SyncStatus? get engineStatus => _runner?.status;

  /// One line for the status of the pull.
  String get statusLine {
    final blocked = blockedLine;
    if (blocked != null) return blocked;
    final problem = _problem;
    if (problem != null) return 'Paused: $problem';
    final s = _runner?.status;
    if (checking) return 'Checking…';
    if (s == null) return 'Not checked yet';
    switch (s.state) {
      case SyncState.idle:
        final at = _lastChecked;
        return at == null
            ? 'Not checked yet'
            : 'Up to date, checked ${_hhmm(at)}';
      case SyncState.running:
        return 'Checking…';
      case SyncState.paused:
        return 'Paused: ${s.reason ?? '$providerName could not be reached'}';
      case SyncState.signedOut:
        return signedOutLine;
      case SyncState.rootGone:
        return 'Paused: the $providerName folder is gone';
      case SyncState.journalUnreadable:
        return "Paused: the sync record on this device can't be read";
      case SyncState.guardWaiting:
        return 'Waiting for your answer about removed pages';
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // --- Start ----------------------------------------------------------------

  /// Call after `notebook.load()`. Starts polling if the account is usable and
  /// has chosen a folder; otherwise waits for either.
  Future<void> start() {
    if (_loaded || _disposed) return _queue;
    _loaded = true;
    WidgetsBinding.instance.addObserver(this);
    notebook.addListener(reschedule);
    attachAccount();
    return evaluate();
  }

  @protected
  Future<void> evaluate() => _queue = _queue.then((_) => doEvaluate());

  /// Stops the runner and its timer; what the choice held is the provider's to clear.
  @protected
  void teardownRunner() {
    _timer?.cancel();
    _timer = null;
    unawaited(_runnerSub?.cancel());
    _runnerSub = null;
    _runner?.dispose();
    _runner = null;
    _problem = null;
    _lastChecked = null;
    _lastFailed = false;
  }

  /// Makes sure the folder exists and is listed. The engine starts on the
  /// folder only after the notebook scanned it (B4): addStandaloneFolder has
  /// finished its scan when it returns. False, with [problem] set, when the
  /// folder can't be made ready.
  @protected
  Future<bool> prepareFolder(Directory dir, Directory stateDir) async {
    _problem = null;
    try {
      // The folder is made only before the pull has ever run (the first choice,
      // or a kill before the first round). Once the journal exists a folder
      // that is gone was removed on this device, and is not made again (G11).
      final journal = syncJournalFile(stateDir);
      if (!await dir.exists()) {
        if (await journal.exists()) {
          _problem = 'the $providerName folder is missing on this device';
          return false;
        }
        await dir.create(recursive: true);
      }
      // A folder that was listed while it was missing comes back with a folder check.
      await notebook.checkFolders();
      await notebook.addStandaloneFolder(dir.path);
    } on NotebookException catch (e) {
      _problem = e.message;
      return false;
    } on Object {
      _problem = "the folder couldn't be set up on this device";
      return false;
    }
    return true;
  }

  @protected
  void attachRunner(SyncRunner runner) {
    _runner = runner;
    _runnerSub = runner.changes.listen((_) {
      if (!_disposed) notifyListeners();
    });
  }

  /// A poll that was wanted, when there is something to poll and the app is in front.
  @protected
  void pollIfWanted() {
    if (_wantPoll && _runner != null && _foreground) unawaited(poll());
  }

  // --- Polling --------------------------------------------------------------

  // A page of this provider's folder is open (a pull-only page under its root).
  bool get _openOwnPage {
    final id = notebook.currentId;
    if (id == null || !notebook.isPullOnlyPage(id)) return false;
    final folder = notebook.folderOfPage(id);
    return folder == null || _under(folder, workingRoot.path);
  }

  static bool _under(String path, String root) {
    String norm(String p) {
      var s = p.replaceAll(r'\', '/');
      while (s.length > 1 && s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      return Platform.isWindows ? s.toLowerCase() : s;
    }

    final p = norm(path);
    final r = norm(root);
    return p == r || p.startsWith('$r/');
  }

  /// Keeps one periodic timer matching the situation: none in the background,
  /// signed out or without a folder; 10 s with a page of the folder open, else
  /// 5 min.
  @protected
  void reschedule() {
    if (_disposed) return;
    final active = _runner != null && _foreground && _loaded && canPoll;
    final open = active && _openOwnPage;
    final want = !active ? null : (open ? pollOpen : pollIdle);
    if (active == (_timer != null) && open == _timerOpen) return;
    _timer?.cancel();
    _timer = null;
    _timerOpen = open;
    if (want != null) {
      _timer = Timer.periodic(want, (_) => unawaited(poll(idleTick: !open)));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final front =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (front == _foreground) return;
    _foreground = front;
    if (!front) {
      reschedule();
      return;
    }
    // Back in front: poll now and start the timer again.
    _wantPoll = true;
    reschedule();
    unawaited(evaluate());
  }

  /// Runs a round now (the *Check now* button). Skipped during a round. With
  /// no runner (the folder was missing) it looks for the folder again.
  Future<void> checkNow() {
    if (_runner == null) return evaluate();
    return poll();
  }

  /// Whether a round or an answer is running.
  bool get _working => _current != null;

  /// The source of the question, so a dialog can tell which pull asked.
  Object? get guardSource => _runner;

  /// One round, then what the notebook needs to see its result (G3): the
  /// changed files, in a `finally` so a round that fails part-way still
  /// reports what it applied; after a round that applied something, and on the
  /// 5-minute tick after a failed round, a folder check and then binder
  /// discovery. Never overlaps itself or an answer: a call during one is
  /// skipped, and a poll that was wanted (a resume, a sign-in) is run when the
  /// round ends.
  @protected
  Future<void> poll({bool idleTick = false}) {
    final runner = _runner;
    if (runner == null || _working || _disposed) return Future<void>.value();
    if (!canPoll) return Future<void>.value();
    _wantPoll = false;
    return _begin(() => _round(runner, idleTick));
  }

  // Marks the controller busy for [job]; when it ends, a wanted poll goes.
  Future<void> _begin(Future<void> Function() job) {
    final done = job().whenComplete(() {
      _current = null;
      if (_disposed) return;
      notifyListeners();
      pollIfWanted();
    });
    _current = done;
    notifyListeners();
    return done;
  }

  Future<void> _round(SyncRunner runner, bool idleTick) async {
    RoundResult? result;
    var failed = false;
    try {
      try {
        result = await runner.runRound();
      } on Object {
        failed = true;
      }
    } finally {
      if (result != null) {
        failed = result.error != null;
        await _tell(result);
      }
    }
    try {
      final applied = result != null && result.changedPaths.isNotEmpty;
      if (!_disposed && (applied || (idleTick && _lastFailed))) {
        await _lookAgain();
      }
    } finally {
      _lastFailed = failed;
      if (runner.status.state == SyncState.idle) _lastChecked = _now();
    }
  }

  // The folder check, then discovery, in that order.
  Future<void> _lookAgain() async {
    try {
      await notebook.checkFolders();
    } on Object catch (e) {
      debugPrint('$providerName: the folder check failed: ${e.runtimeType}');
    }
    if (_disposed) return;
    try {
      await notebook.discoverBinders();
    } on Object catch (e) {
      debugPrint('$providerName: binder discovery failed: ${e.runtimeType}');
    }
  }

  /// Answers the guard's question: remove the listed pages here too, or keep
  /// them. [source] is the [guardSource] the question came from; an answer for
  /// another pull (the account changed) is refused. Waits for a round that is
  /// running. The round that follows is reported like any other: its changed
  /// files go to the notebook in a `finally`, then the folder check and
  /// discovery if it applied something. False when the answer was refused or
  /// could not be saved (the question stays).
  Future<bool> answerGuard(
    GuardQuestion q, {
    required bool remove,
    Object? source,
  }) async {
    while (_current != null) {
      await _current;
    }
    final runner = _runner;
    if (runner == null || _disposed || !canAnswerGuard) return false;
    if (source != null && !identical(source, runner)) return false;
    var saved = false;
    await _begin(() async {
      RoundResult? result;
      try {
        try {
          // A round just before may have been refused (a 401): nothing is sent.
          if (!canAnswerGuard || !identical(_runner, runner)) return;
          result = await runner.answerGuard(q, remove: remove);
          saved = true;
        } finally {
          if (result != null) await _tell(result);
        }
        if (result != null && result.changedPaths.isNotEmpty && !_disposed) {
          await _lookAgain();
        }
      } on Object catch (e) {
        debugPrint(
          '$providerName: the answer could not be saved: ${e.runtimeType}',
        );
      }
    });
    return saved;
  }

  // The notebook hears what a round changed.
  Future<void> _tell(RoundResult result) async {
    if (_disposed) return;
    try {
      await notebook.filesChanged(result.changedPaths);
    } on Object catch (e) {
      debugPrint(
        '$providerName: telling the notebook failed: ${e.runtimeType}',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_loaded) {
      WidgetsBinding.instance.removeObserver(this);
      notebook.removeListener(reschedule);
      detachAccount();
    }
    _timer?.cancel();
    unawaited(_runnerSub?.cancel());
    _runner?.dispose();
    super.dispose();
  }
}
