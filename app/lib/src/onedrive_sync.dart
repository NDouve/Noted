// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:noted_auth/noted_auth.dart' show AuthErrorKind, AuthException, AuthState;
import 'package:noted_sync/noted_sync.dart';

import 'device_storage.dart';
import 'microsoft_account.dart';
import 'notebook.dart';

/// The OneDrive folder an account chose: what `chosen.json` holds.
class ChosenRoot {
  const ChosenRoot({required this.driveId, required this.itemId, required this.path});

  final String driveId;
  final String itemId;

  /// The path shown to the user, such as `Documents/Notes`.
  final String path;

  Map<String, Object?> toJson() => {'driveId': driveId, 'itemId': itemId, 'path': path};

  /// Null if [json] isn't a chosen folder.
  static ChosenRoot? fromJson(Object? json) {
    if (json is! Map) return null;
    final d = json['driveId'];
    final i = json['itemId'];
    final p = json['path'];
    if (d is! String || i is! String || p is! String || d.isEmpty || i.isEmpty) return null;
    return ChosenRoot(driveId: d, itemId: i, path: p);
  }
}

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
  Future<RoundResult?> answerGuard(GuardQuestion q, {required bool remove}) => engine.answerGuard(q, remove: remove);
  @override
  void dispose() => engine.dispose();
}

/// The folder browser's view of OneDrive ([GraphClient] behind it).
abstract class FolderSource {
  /// The folders in [parentItemId], the drive's root when null.
  Future<List<RemoteItem>> listFolders({String? parentItemId});

  /// What Noted would find in the folder [itemId].
  Future<FolderHint> folderHint(String itemId, {String? driveId});
}

class GraphFolderSource implements FolderSource {
  GraphFolderSource(this.graph);

  final GraphClient graph;

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) => graph.listFolders(parentItemId: parentItemId);

  @override
  Future<FolderHint> folderHint(String itemId, {String? driveId}) => graph.folderHint(itemId, driveId: driveId);
}

typedef RunnerFactory =
    SyncRunner Function({
      required Directory workingCopy,
      required Directory stateDir,
      required String driveId,
      required String rootItemId,
    });

/// Foreground polling interval with a page of the OneDrive folder open (G14).
const Duration oneDrivePollOpen = Duration(seconds: 10);

/// Foreground polling interval otherwise (G14).
const Duration oneDrivePollIdle = Duration(minutes: 5);

/// The OneDrive pull on a phone or tablet (sync stage 3): holds the chosen
/// folder, keeps it listed in the notebook, polls while the app is in front
/// and tells the notebook what each round changed. Built only on mobile and in
/// a build with a client id; nothing else touches it.
class OneDriveSync extends ChangeNotifier with WidgetsBindingObserver {
  OneDriveSync({
    required this.notebook,
    required this.microsoft,
    required this.workingRoot,
    required this.support,
    required this.folders,
    required this.runnerFactory,
    DateTime Function()? now,
    this.pollOpen = oneDrivePollOpen,
    this.pollIdle = oneDrivePollIdle,
  }) : _now = now ?? DateTime.now;

  /// The controller with the real engine and Graph client of this build.
  /// [graphOrigin] and [clock] are for tests.
  factory OneDriveSync.create({
    required Notebook notebook,
    required MicrosoftAccount microsoft,
    required Directory workingRoot,
    required Directory support,
    Uri? graphOrigin,
    Clock? clock,
    DateTime Function()? now,
    Duration pollOpen = oneDrivePollOpen,
    Duration pollIdle = oneDrivePollIdle,
  }) {
    String? last;
    Future<String> token({bool forceRefresh = false}) async {
      try {
        final session = microsoft.session;
        final rejected = last;
        final t = forceRefresh && rejected != null
            ? await session.tokenAfterRejection(rejected)
            : await session.accessToken();
        last = t;
        return t;
      } on AuthException catch (e) {
        // Only a lost sign-in is "signed out"; an unreachable endpoint or an
        // unreadable store pauses the round.
        if (e.kind == AuthErrorKind.signInRequired || e.kind == AuthErrorKind.invalidGrant) {
          throw const SignedOutException();
        }
        throw GraphException(e.message);
      }
    }

    final graph = GraphClient(token: token, origin: graphOrigin, clock: clock);
    return OneDriveSync(
      notebook: notebook,
      microsoft: microsoft,
      workingRoot: workingRoot,
      support: support,
      folders: GraphFolderSource(graph),
      now: now,
      pollOpen: pollOpen,
      pollIdle: pollIdle,
      runnerFactory: ({required workingCopy, required stateDir, required driveId, required rootItemId}) => EngineRunner(
        PullEngine(
          workingCopy: workingCopy,
          stateDir: stateDir,
          // The notebook's lock, so a pull and the notebook never write one folder together.
          locks: notebook.folderLocks,
          graph: graph,
          driveId: driveId,
          rootItemId: rootItemId,
          clock: clock,
        ),
      ),
    );
  }

  final Notebook notebook;
  final MicrosoftAccount microsoft;

  /// [deviceOneDriveRoot]: the working copies are below it.
  final Directory workingRoot;

  /// [deviceSupportDirectory]: the chosen folder and the journals are below it.
  final Directory support;
  final FolderSource folders;
  final RunnerFactory runnerFactory;
  final Duration pollOpen;
  final Duration pollIdle;
  final DateTime Function() _now;

  ChosenRoot? _chosen;
  bool _unreadable = false;
  String? _problem;
  String? _accountKey;
  SyncRunner? _runner;
  StreamSubscription<void>? _runnerSub;
  Timer? _timer;
  bool _timerOpen = false;
  bool _wantPoll = false;
  bool _wasSignedIn = false;
  bool _loaded = false;
  bool _foreground = true;
  Future<void>? _current;
  bool _lastFailed = false;
  bool _disposed = false;
  DateTime? _lastChecked;
  Future<void> _queue = Future<void>.value();

  /// The folder this account chose, if any.
  ChosenRoot? get chosen => _chosen;

  /// `chosen.json` exists and can't be read: sync is paused and the file is
  /// left alone.
  bool get chosenUnreadable => _unreadable;

  /// Whether this account can choose a folder now.
  bool get canChoose => microsoft.state == AuthState.signedIn && _accountKey != null && _chosen == null && !_unreadable;

  /// Something stopped the setup (the folder choice could not be saved, or its folder not listed).
  bool get hasProblem => _problem != null;

  /// A round is running.
  bool get checking => _current != null || _runner?.status.state == SyncState.running;

  GuardQuestion? get guardQuestion => _runner?.guardQuestion;
  List<SyncIssue> get issues => _runner?.issues ?? const [];
  SyncStatus? get engineStatus => _runner?.status;

  /// The working copy of the chosen folder, once there is one.
  Directory? get workingCopy {
    final c = _chosen;
    final k = _accountKey;
    return c == null || k == null ? null : oneDriveWorkingCopy(workingRoot, k, c.itemId);
  }

  /// One line for the status of the pull.
  String get statusLine {
    final state = microsoft.state;
    if (state == AuthState.signInAgain) return 'Sign in again to continue';
    if (state == AuthState.signedOut) return 'Signed out';
    if (_unreadable) return "Paused: the saved folder choice can't be read";
    final problem = _problem;
    if (problem != null) return 'Paused: $problem';
    final s = _runner?.status;
    if (checking) return 'Checking…';
    if (s == null) return 'Not checked yet';
    switch (s.state) {
      case SyncState.idle:
        final at = _lastChecked;
        return at == null ? 'Not checked yet' : 'Up to date, checked ${_hhmm(at)}';
      case SyncState.running:
        return 'Checking…';
      case SyncState.paused:
        return 'Paused: ${s.reason ?? 'OneDrive could not be reached'}';
      case SyncState.signedOut:
        return 'Signed out';
      case SyncState.rootGone:
        return 'Paused: the OneDrive folder is gone';
      case SyncState.journalUnreadable:
        return "Paused: the sync record on this device can't be read";
      case SyncState.guardWaiting:
        return 'Waiting for your answer about removed pages';
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // --- Start and account changes -------------------------------------------

  /// Call after `notebook.load()`. Starts polling if an account is signed in
  /// and has chosen a folder; otherwise waits for either.
  Future<void> start() {
    if (_loaded || _disposed) return _queue;
    _loaded = true;
    WidgetsBinding.instance.addObserver(this);
    notebook.addListener(_reschedule);
    microsoft.addListener(_accountChanged);
    return _evaluate();
  }

  void _accountChanged() {
    if (_disposed) return;
    notifyListeners();
    unawaited(_evaluate());
  }

  Future<void> _evaluate() => _queue = _queue.then((_) => _doEvaluate());

  Future<void> _doEvaluate() async {
    if (_disposed || !_loaded) return;
    final signedIn = microsoft.state == AuthState.signedIn;
    if (!signedIn) {
      _wasSignedIn = false;
      _reschedule();
      notifyListeners();
      return;
    }
    // A sign-in (or a restored one) polls at once, like a launch.
    if (!_wasSignedIn) _wantPoll = true;
    _wasSignedIn = true;
    final key = microsoft.session.accountKey;
    if (key == null) return;
    if (_accountKey != key) {
      _teardown();
      _accountKey = key;
      await _loadChosen(key);
    }
    final c = _chosen;
    if (c != null && !_unreadable && _runner == null) {
      await _setup(key, c);
      if (_runner != null) _wantPoll = true;
    }
    if (_disposed) return;
    _reschedule();
    notifyListeners();
    if (_wantPoll && _runner != null && _foreground) unawaited(_poll());
  }

  void _teardown() {
    _timer?.cancel();
    _timer = null;
    unawaited(_runnerSub?.cancel());
    _runnerSub = null;
    _runner?.dispose();
    _runner = null;
    _chosen = null;
    _unreadable = false;
    _problem = null;
    _lastChecked = null;
    _lastFailed = false;
  }

  Future<void> _loadChosen(String key) async {
    final file = oneDriveChosenFile(support, key);
    try {
      if (!await file.exists()) return;
      final c = ChosenRoot.fromJson(jsonDecode(await file.readAsString()));
      if (c == null) {
        _unreadable = true;
      } else {
        _chosen = c;
      }
    } on Object {
      // Never overwritten: the file may be fine and the disk briefly not.
      _unreadable = true;
    }
  }

  // Makes sure the folder exists and is listed, then builds the runner. The
  // engine starts on the folder only after the notebook scanned it (B4):
  // addStandaloneFolder has finished its scan when it returns.
  Future<void> _setup(String key, ChosenRoot c) async {
    _problem = null;
    try {
      final dir = oneDriveWorkingCopy(workingRoot, key, c.itemId);
      // The folder is made only before the pull has ever run (the first choice,
      // or a kill before the first round). Once the journal exists a folder
      // that is gone was removed on this device, and is not made again (G11).
      final journal = File('${oneDriveStateDir(support, key, c.itemId).path}${Platform.pathSeparator}journal.json');
      if (!await dir.exists()) {
        if (await journal.exists()) {
          _problem = 'the OneDrive folder is missing on this device';
          return;
        }
        await dir.create(recursive: true);
      }
      await notebook.addStandaloneFolder(dir.path);
    } on NotebookException catch (e) {
      _problem = e.message;
      return;
    } on Object {
      _problem = "the folder couldn't be set up on this device";
      return;
    }
    final runner = runnerFactory(
      workingCopy: oneDriveWorkingCopy(workingRoot, key, c.itemId),
      stateDir: oneDriveStateDir(support, key, c.itemId),
      driveId: c.driveId,
      rootItemId: c.itemId,
    );
    _runner = runner;
    _runnerSub = runner.changes.listen((_) {
      if (!_disposed) notifyListeners();
    });
  }

  /// Stores [root] for the signed-in account, adds its folder to the notebook
  /// and starts pulling. The file is written (atomically) before the folder is
  /// added. Does nothing when a folder is chosen already or its file can't be
  /// read.
  Future<void> choose(ChosenRoot root) async {
    final key = _accountKey;
    if (key == null || !canChoose) return;
    final file = oneDriveChosenFile(support, key);
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(root.toJson()), flush: true);
      await tmp.rename(file.path);
    } on Object {
      _problem = "the folder choice couldn't be saved";
      notifyListeners();
      return;
    }
    _chosen = root;
    _problem = null;
    notifyListeners();
    await _evaluate();
  }

  // --- Polling ---------------------------------------------------------------

  bool get _openOneDrivePage {
    final id = notebook.currentId;
    return id != null && notebook.isPullOnlyPage(id);
  }

  // Keeps one periodic timer matching the situation: none in the background,
  // signed out or without a folder; 10 s with a OneDrive page open, else 5 min.
  void _reschedule() {
    if (_disposed) return;
    final active = _runner != null && _foreground && _loaded && microsoft.state == AuthState.signedIn;
    final open = active && _openOneDrivePage;
    final want = !active ? null : (open ? pollOpen : pollIdle);
    if (active == (_timer != null) && open == _timerOpen) return;
    _timer?.cancel();
    _timer = null;
    _timerOpen = open;
    if (want != null) {
      _timer = Timer.periodic(want, (_) => unawaited(_poll(idleTick: !open)));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final front = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (front == _foreground) return;
    _foreground = front;
    if (!front) {
      _reschedule();
      return;
    }
    // Back in front: poll now and start the timer again.
    _wantPoll = true;
    _reschedule();
    unawaited(_evaluate());
  }

  /// Runs a round now (the *Check now* button). Skipped during a round. With
  /// no runner (the folder was missing) it looks for the folder again.
  Future<void> checkNow() {
    if (_runner == null) return _evaluate();
    return _poll();
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
  Future<void> _poll({bool idleTick = false}) {
    final runner = _runner;
    if (runner == null || _working || _disposed) return Future<void>.value();
    if (microsoft.state != AuthState.signedIn) return Future<void>.value();
    _wantPoll = false;
    return _begin(() => _round(runner, idleTick));
  }

  // Marks the controller busy for [job]; when it ends, a wanted poll goes.
  Future<void> _begin(Future<void> Function() job) {
    final done = job().whenComplete(() {
      _current = null;
      if (_disposed) return;
      notifyListeners();
      if (_wantPoll && _runner != null && _foreground) unawaited(_poll());
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
      if (!_disposed && (applied || (idleTick && _lastFailed))) await _lookAgain();
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
      debugPrint('OneDrive: the folder check failed: ${e.runtimeType}');
    }
    if (_disposed) return;
    try {
      await notebook.discoverBinders();
    } on Object catch (e) {
      debugPrint('OneDrive: binder discovery failed: ${e.runtimeType}');
    }
  }

  /// Answers the guard's question: remove the listed pages here too, or keep
  /// them. [source] is the [guardSource] the question came from; an answer for
  /// another pull (the account changed) is refused. Waits for a round that is
  /// running. The round that follows is reported like any other: its changed
  /// files go to the notebook in a `finally`, then the folder check and
  /// discovery if it applied something. False when the answer was refused or
  /// could not be saved (the question stays).
  Future<bool> answerGuard(GuardQuestion q, {required bool remove, Object? source}) async {
    while (_current != null) {
      await _current;
    }
    final runner = _runner;
    if (runner == null || _disposed) return false;
    if (source != null && !identical(source, runner)) return false;
    var saved = false;
    await _begin(() async {
      RoundResult? result;
      try {
        try {
          result = await runner.answerGuard(q, remove: remove);
          saved = true;
        } finally {
          if (result != null) await _tell(result);
        }
        if (result != null && result.changedPaths.isNotEmpty && !_disposed) await _lookAgain();
      } on Object catch (e) {
        debugPrint('OneDrive: the answer could not be saved: ${e.runtimeType}');
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
      debugPrint('OneDrive: telling the notebook failed: ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_loaded) {
      WidgetsBinding.instance.removeObserver(this);
      notebook.removeListener(_reschedule);
      microsoft.removeListener(_accountChanged);
    }
    _timer?.cancel();
    unawaited(_runnerSub?.cancel());
    _runner?.dispose();
    super.dispose();
  }
}

/// Gives the About dialog and `Home`, which sit in different routes, the
/// controller. Null above it on desktop and in a build without a client id.
class OneDriveScope extends InheritedWidget {
  const OneDriveScope({super.key, required this.sync, required super.child});

  final OneDriveSync? sync;

  static OneDriveSync? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OneDriveScope>()?.sync;

  @override
  bool updateShouldNotify(OneDriveScope old) => old.sync != sync;
}
