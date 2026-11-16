// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:noted_auth/noted_auth.dart' show AuthErrorKind, AuthException, AuthState;
import 'package:noted_sync/noted_sync.dart';

import 'cloud_sync.dart';
import 'device_storage.dart';
import 'microsoft_account.dart';
import 'notebook.dart';

export 'cloud_sync.dart' show EngineRunner, SyncRunner;

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

/// The folder browser's view of a provider's folders ([GraphClient] behind it
/// for OneDrive, a [RemoteDriver] for WebDAV).
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
const Duration oneDrivePollOpen = cloudPollOpen;

/// Foreground polling interval otherwise (G14).
const Duration oneDrivePollIdle = cloudPollIdle;

/// The OneDrive pull on a phone or tablet (sync stage 3): holds the chosen
/// folder, keeps it listed in the notebook, polls while the app is in front
/// and tells the notebook what each round changed (the shared part is
/// [CloudSync]). Built only on mobile and in a build with a client id; nothing
/// else touches it.
class OneDriveSync extends CloudSync {
  OneDriveSync({
    required super.notebook,
    required this.microsoft,
    required super.workingRoot,
    required super.support,
    required this.folders,
    required this.runnerFactory,
    super.now,
    super.pollOpen = oneDrivePollOpen,
    super.pollIdle = oneDrivePollIdle,
  });

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
          driver: GraphDriver(graph: graph, driveId: driveId, rootItemId: rootItemId),
          clock: clock,
        ),
      ),
    );
  }

  final MicrosoftAccount microsoft;
  final FolderSource folders;
  final RunnerFactory runnerFactory;

  ChosenRoot? _chosen;
  bool _unreadable = false;
  String? _accountKey;
  bool _wasSignedIn = false;

  /// The folder this account chose, if any.
  ChosenRoot? get chosen => _chosen;

  /// `chosen.json` exists and can't be read: sync is paused and the file is
  /// left alone.
  bool get chosenUnreadable => _unreadable;

  /// Whether this account can choose a folder now.
  bool get canChoose => microsoft.state == AuthState.signedIn && _accountKey != null && _chosen == null && !_unreadable;

  @override
  Directory? get workingCopy {
    final c = _chosen;
    final k = _accountKey;
    return c == null || k == null ? null : oneDriveWorkingCopy(workingRoot, k, c.itemId);
  }

  @override
  String get providerName => 'OneDrive';

  @override
  bool get canPoll => microsoft.state == AuthState.signedIn;

  @override
  String? get blockedLine {
    final state = microsoft.state;
    if (state == AuthState.signInAgain) return 'Sign in again to continue';
    if (state == AuthState.signedOut) return 'Signed out';
    if (_unreadable) return "Paused: the saved folder choice can't be read";
    return null;
  }

  // --- Start and account changes -------------------------------------------

  @override
  void attachAccount() => microsoft.addListener(_accountChanged);

  @override
  void detachAccount() => microsoft.removeListener(_accountChanged);

  void _accountChanged() {
    if (disposed) return;
    notifyListeners();
    unawaited(evaluate());
  }

  @override
  Future<void> doEvaluate() async {
    if (disposed || !loaded) return;
    final signedIn = microsoft.state == AuthState.signedIn;
    if (!signedIn) {
      _wasSignedIn = false;
      reschedule();
      notifyListeners();
      return;
    }
    // A sign-in (or a restored one) polls at once, like a launch.
    if (!_wasSignedIn) wantPoll = true;
    _wasSignedIn = true;
    final key = microsoft.session.accountKey;
    if (key == null) return;
    if (_accountKey != key) {
      _teardown();
      _accountKey = key;
      await _loadChosen(key);
    }
    final c = _chosen;
    if (c != null && !_unreadable && runner == null) {
      await _setup(key, c);
      if (runner != null) wantPoll = true;
    }
    if (disposed) return;
    reschedule();
    notifyListeners();
    pollIfWanted();
  }

  void _teardown() {
    teardownRunner();
    _chosen = null;
    _unreadable = false;
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

  // Makes sure the folder exists and is listed, then builds the runner.
  Future<void> _setup(String key, ChosenRoot c) async {
    final stateDir = oneDriveStateDir(support, key, c.itemId);
    if (!await prepareFolder(oneDriveWorkingCopy(workingRoot, key, c.itemId), stateDir)) return;
    attachRunner(
      runnerFactory(
        workingCopy: oneDriveWorkingCopy(workingRoot, key, c.itemId),
        stateDir: stateDir,
        driveId: c.driveId,
        rootItemId: c.itemId,
      ),
    );
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
      problem = "the folder choice couldn't be saved";
      notifyListeners();
      return;
    }
    _chosen = root;
    problem = null;
    notifyListeners();
    await evaluate();
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
