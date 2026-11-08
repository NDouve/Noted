// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shared pieces of the OneDrive stage 3 app tests: a signed-in account, a
// fake runner and folder source, a notebook that records what it is told, and
// a world (folders, notebook, controller) built on real files.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noted/main.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/microsoft_account.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/onedrive_sync.dart';
import 'package:noted_auth/noted_auth.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

String _jwt(Map<String, Object?> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}

/// A token endpoint that says yes (the access token is `A`) until [refreshError]
/// is set; with a short [expiresIn] every token request refreshes.
class TestTokens extends TokenClient {
  TestTokens(super.config, {this.expiresIn = const Duration(hours: 1)});

  final Duration expiresIn;
  AuthException? refreshError;

  TokenResponse get _ok => TokenResponse(
    accessToken: 'A',
    refreshToken: 'R',
    idToken: _jwt({'tid': 't', 'oid': 'o', 'name': 'Ada Test'}),
    expiresIn: expiresIn,
  );

  @override
  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async => _ok;

  @override
  Future<TokenResponse> refresh(String refreshToken) async {
    final e = refreshError;
    if (e != null) throw e;
    return _ok;
  }
}

/// An account over a real session with a fake token endpoint, signed in.
Future<MicrosoftAccount> signedInAccount({TestTokens Function(AuthConfig)? tokens}) async {
  const config = AuthConfig(clientId: 'test-client');
  final account = MicrosoftAccount(
    config: config,
    session: AuthSession(tokens: (tokens ?? TestTokens.new)(config), store: MemoryTokenStore()),
    flow: (_) async => const AuthGrant(code: 'c', codeVerifier: 'v', redirectUri: 'r'),
  );
  await account.signIn();
  return account;
}

/// A runner whose rounds, answers and status the test controls.
class FakeRunner implements SyncRunner {
  @override
  SyncStatus status = const SyncStatus(SyncState.idle);
  @override
  GuardQuestion? guardQuestion;
  @override
  List<SyncIssue> issues = [];

  final StreamController<void> _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _changes.stream;

  int rounds = 0;
  final List<(GuardQuestion, bool)> answers = [];

  /// What the next round returns.
  RoundResult Function() next = RoundResult.new;

  /// Thrown by the next answer (a journal that can't be saved).
  Object? answerError;

  /// What answering the guard returns (the round that follows).
  RoundResult? answerResult = RoundResult();

  /// While set, a round waits for it.
  Completer<void>? hold;

  void changed() => _changes.add(null);

  @override
  Future<RoundResult> runRound() async {
    rounds++;
    final h = hold;
    if (h != null) await h.future;
    return next();
  }

  @override
  Future<RoundResult?> answerGuard(GuardQuestion q, {required bool remove}) async {
    final err = answerError;
    if (err != null) throw err;
    answers.add((q, remove));
    guardQuestion = null;
    changed();
    return answerResult;
  }

  @override
  void dispose() => unawaited(_changes.close());
}

/// A folder source over a small tree: [children] by parent item id (null is
/// the drive's root), [hints] by folder id.
class FakeFolders implements FolderSource {
  final Map<String?, List<RemoteItem>> children = {};
  final Map<String, FolderHint> hints = {};
  final List<String?> listed = [];

  static RemoteItem folder(String id, String name, {String? driveId = 'drv1'}) =>
      RemoteItem(id: id, name: name, isFolder: true, driveId: driveId);

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) async {
    listed.add(parentItemId);
    return children[parentItemId] ?? const [];
  }

  @override
  Future<FolderHint> folderHint(String itemId, {String? driveId}) async =>
      hints[itemId] ?? const FolderHint(canvasCount: 0, binderCount: 0, holdsBinderFile: false);
}

/// A notebook that records what the controller tells it, in order, and does
/// no file work for it (so a test on the fake clock needs no real IO).
class SpyNotebook extends Notebook {
  SpyNotebook(
    super.store,
    super.modules, {
    super.saveDelay,
    super.bindersFile,
    super.readOnlyRoots,
    super.watchFiles,
    super.folderCheckInterval,
  });

  /// Also do what the real notebook does for the changed files.
  bool passThrough = false;

  /// Made to throw by the next call of that name.
  final Set<String> failing = {};

  /// Called with the path before a standalone folder is added.
  void Function(String path)? onAddFolder;

  @override
  Future<String> addStandaloneFolder(String path) {
    onAddFolder?.call(path);
    return super.addStandaloneFolder(path);
  }

  final List<String> log = [];
  final List<List<String>> changedPaths = [];

  @override
  Future<void> filesChanged(Iterable<String> paths) async {
    changedPaths.add(paths.toList());
    log.add('filesChanged');
    if (failing.contains('filesChanged')) throw StateError('filesChanged');
    if (passThrough) await super.filesChanged(paths);
  }

  @override
  Future<void> load() {
    log.add('load');
    return super.load();
  }

  @override
  Future<void> checkFolders() async {
    log.add('checkFolders');
    if (failing.contains('checkFolders')) throw StateError('checkFolders');
  }

  @override
  Future<void> discoverBinders() async {
    log.add('discoverBinders');
  }
}

/// A page id used for the page that sits in the OneDrive folder.
const String oneDrivePageId = 'cccc000000000001';

/// The OneDrive folder item id of the world.
const String oneDriveRootId = 'ROOT1';

/// Folders, a notebook and a controller on real files. Build it inside
/// `tester.runAsync` in a widget test.
class OneDriveWorld {
  OneDriveWorld._();

  late final Directory top;
  late final Directory workingRoot;
  late final Directory support;
  late final Directory pages;
  late final MicrosoftAccount account;
  late final String accountKey;
  late final SpyNotebook nb;
  late final OneDriveSync sync;
  final FakeRunner runner = FakeRunner();
  final FakeFolders folders = FakeFolders();

  Directory get workingCopy => oneDriveWorkingCopy(workingRoot, accountKey, oneDriveRootId);
  File get chosenFile => oneDriveChosenFile(support, accountKey);

  /// [chosen]: the account has chosen its folder; [pageInFolder]: a page file
  /// is in it; [chosenText]: the content of `chosen.json` instead.
  static Future<OneDriveWorld> create({
    bool chosen = true,
    bool pageInFolder = false,
    String? chosenText,
    Duration pollOpen = oneDrivePollOpen,
    Duration pollIdle = oneDrivePollIdle,
    DateTime Function()? now,
  }) async {
    final w = OneDriveWorld._();
    w.top = await Directory.systemTemp.createTemp('noted_onedrive');
    w.workingRoot = await Directory('${w.top.path}/onedrive').create();
    w.support = await Directory('${w.top.path}/support').create();
    w.pages = await Directory('${w.top.path}/pages').create();
    w.account = await signedInAccount();
    w.accountKey = w.account.session.accountKey!;
    if (chosen || chosenText != null) {
      await w.chosenFile.parent.create(recursive: true);
      await w.chosenFile.writeAsString(
        chosenText ??
            jsonEncode(const ChosenRoot(driveId: 'drv1', itemId: oneDriveRootId, path: 'Documents/Notes').toJson()),
      );
    }
    if (pageInFolder) {
      await w.workingCopy.create(recursive: true);
      final page = NotedPage.create(PageMeta.create(id: oneDrivePageId, title: 'From OneDrive', order: 1));
      await File('${w.workingCopy.path}/$oneDrivePageId.canvas').writeAsString(writePage(page));
    }
    w.nb = SpyNotebook(
      PageStore(w.pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${w.top.path}/app/binders.json'),
      readOnlyRoots: [w.workingRoot.path],
      watchFiles: false,
      folderCheckInterval: Duration.zero,
    );
    await w.nb.load();
    w.sync = OneDriveSync(
      notebook: w.nb,
      microsoft: w.account,
      workingRoot: w.workingRoot,
      support: w.support,
      folders: w.folders,
      now: now,
      pollOpen: pollOpen,
      pollIdle: pollIdle,
      runnerFactory: ({required workingCopy, required stateDir, required driveId, required rootItemId}) => w.runner,
    );
    return w;
  }

  Future<void> close() async {
    sync.dispose();
    nb.dispose();
    await top.delete(recursive: true);
  }
}

/// A `MaterialApp` that gives [sync] to its routes, as the app does.
Widget oneDriveApp(OneDriveSync? sync, Widget home) => MaterialApp(
  builder: (context, child) => OneDriveScope(sync: sync, child: child!),
  home: home,
);
