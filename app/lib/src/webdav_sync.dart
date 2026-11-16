// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:noted_auth/noted_auth.dart' show TokenStore;
import 'package:noted_core/noted_core.dart' show contentHash;
import 'package:noted_sync/noted_sync.dart';

import 'cloud_sync.dart';
import 'device_storage.dart';
import 'notebook.dart' show Notebook;
import 'onedrive_sync.dart' show ChosenRoot, FolderSource;
import 'secure_token_store.dart';

/// The `driveId` WebDAV items carry in the folder picker, which wants one.
const String webDavPickerDriveId = 'webdav';

/// A WebDAV connection: what `connection.json` holds in the state folder.
/// Never the password, which is in the keychain or keystore.
class WebDavConnection {
  const WebDavConnection({
    required this.url,
    required this.user,
    required this.idKind,
    required this.rootId,
    required this.path,
  });

  /// The chosen folder, normalised ([normalizeWebDavUrl]).
  final String url;
  final String user;

  /// What an item's id is on this server, fixed at connect.
  final DavIdKind idKind;

  /// The chosen folder's id.
  final String rootId;

  /// The path shown to the user, such as `Documents/Notes`.
  final String path;

  Uri get uri => Uri.parse(url);

  /// SHA-256 of the origin and the user name (N8: a URL can hold a user name).
  String get accountKey => contentHash(utf8.encode('${_origin(uri)}\n$user'));

  /// SHA-256 of the normalised root URL.
  String get rootKey => contentHash(utf8.encode(url));

  /// Where the password is kept.
  String get passwordKey => 'webdav.password.$accountKey';

  Map<String, Object?> toJson() => {
    'url': url,
    'user': user,
    'idKind': idKind.wire,
    'rootId': rootId,
    'path': path,
  };

  /// Null if [json] isn't a connection.
  static WebDavConnection? fromJson(Object? json) {
    if (json is! Map) return null;
    final u = json['url'];
    final user = json['user'];
    final kind = DavIdKind.parse(
      json['idKind'] is String ? json['idKind'] as String : null,
    );
    final root = json['rootId'];
    final path = json['path'];
    if (u is! String || user is! String || user.isEmpty || kind == null) {
      return null;
    }
    if (root is! String || root.isEmpty || path is! String) return null;
    final uri = Uri.tryParse(u);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        normalizeWebDavUrl(uri) != u) {
      return null;
    }
    return WebDavConnection(
      url: u,
      user: user,
      idKind: kind,
      rootId: root,
      path: path,
    );
  }
}

String _origin(Uri u) {
  final defaultPort = u.scheme == 'https' ? 443 : 80;
  return '${u.scheme}://${u.host}${u.port == defaultPort ? '' : ':${u.port}'}';
}

/// [u] in one form for one folder: scheme and host lower case, no default port,
/// no query or fragment, each path part encoded once, a trailing `/`.
String normalizeWebDavUrl(Uri u) {
  final parts = [
    for (final s in u.pathSegments)
      if (s.isNotEmpty) Uri.encodeComponent(s),
  ];
  return '${_origin(u)}/${parts.join('/')}${parts.isEmpty ? '' : '/'}';
}

/// Why the form's server, user or password was not accepted, in plain words.
class WebDavLoginException implements Exception {
  const WebDavLoginException(this.message);
  final String message;
  @override
  String toString() => 'WebDavLoginException: $message';
}

/// [e], what a WebDAV call threw, as one sentence for the user. Nothing in it
/// holds an address.
String explainWebDavError(Object e) {
  String sentence(String s) => s.endsWith('.') ? s : '$s.';
  if (e is RemoteUnauthorized) {
    return 'WebDAV refused the user name or password.';
  }
  if (e is RemoteRefused || e is RemoteNotSupported) {
    return sentence((e as RemoteException).message);
  }
  if (e is RemoteNotFound) return 'The server has nothing at this address.';
  if (e is RemoteTransport) return "WebDAV couldn't be reached.";
  if (e is RemoteThrottled) return 'The server is busy. Try again later.';
  if (e is WebDavIncomplete) {
    return e.message.startsWith('Too large')
        ? sentence(e.message)
        : "The server's answer couldn't be used.";
  }
  return "WebDAV couldn't be used.";
}

/// A server, user and password that passed the first checks (the server speaks
/// WebDAV, the address is a folder, the password is accepted), with the browser
/// of its folders. Close it when the choice is over.
class WebDavLogin {
  WebDavLogin._(this.user, this.password, this._client, this.driver);

  final String user;
  final String password;
  final WebDavClient _client;

  /// Lists folders by path, for choosing one.
  final WebDavDriver driver;

  late final FolderSource source = WebDavFolderSource(driver);

  void close() => _client.close();
}

/// The folder picker's view of a WebDAV server.
class WebDavFolderSource implements FolderSource {
  WebDavFolderSource(this.driver);

  final RemoteDriver driver;

  RemoteItem _tag(RemoteItem i) => RemoteItem(
    id: i.id,
    name: i.name,
    parentId: i.parentId,
    driveId: webDavPickerDriveId,
    isFolder: i.isFolder,
  );

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) async => [
    for (final i in await driver.listFolders(parentItemId: parentItemId))
      _tag(i),
  ];

  @override
  Future<FolderHint> folderHint(String itemId, {String? driveId}) =>
      driver.folderHint(itemId);
}

/// Builds the client of one folder; the app never lets it use plain http (a
/// test passes its own factory for a local server).
typedef WebDavClientFactory = WebDavClient Function(
  Uri root,
  String user,
  String password,
);

typedef WebDavRunnerFactory = SyncRunner Function({
  required Directory workingCopy,
  required Directory stateDir,
  required WebDavConnection connection,
  required String password,
});

class _WebDavRunner extends EngineRunner {
  _WebDavRunner(super.engine, this.client);

  final WebDavClient client;

  @override
  void dispose() {
    super.dispose();
    client.close();
  }
}

/// The WebDAV pull on a phone or tablet (run 2026-11-15-02, task 4): one
/// connection with a folder chosen on the server, pulled into a read-only
/// working copy as OneDrive's is (the shared part is [CloudSync]).
///
/// The password is in [store]; the address, user and id kind are in
/// `connection.json` in the state folder, written (atomically) after the
/// password. [keychainReady] is the app's keychain clean-up step (N6): nothing
/// is read from or written to [store] until it returns true.
class WebDavSync extends CloudSync {
  WebDavSync({
    required super.notebook,
    required super.workingRoot,
    required super.support,
    required this.store,
    required this.keychainReady,
    required this.clientFactory,
    required this.runnerFactory,
    super.now,
    super.pollOpen = cloudPollOpen,
    super.pollIdle = cloudPollIdle,
  });

  /// The controller with the real engine and client of this build. [store],
  /// [clientFactory] and [clock] are for tests.
  factory WebDavSync.create({
    required Notebook notebook,
    required Directory workingRoot,
    required Directory support,
    required Future<bool> Function() keychainReady,
    TokenStore? store,
    WebDavClientFactory? clientFactory,
    Clock? clock,
    DateTime Function()? now,
    Duration pollOpen = cloudPollOpen,
    Duration pollIdle = cloudPollIdle,
  }) {
    final make =
        clientFactory ??
        (root, user, password) => WebDavClient(
          root: root,
          user: user,
          password: password,
          clock: clock,
        );
    return WebDavSync(
      notebook: notebook,
      workingRoot: workingRoot,
      support: support,
      store: store ?? SecureTokenStore(),
      keychainReady: keychainReady,
      clientFactory: make,
      now: now,
      pollOpen: pollOpen,
      pollIdle: pollIdle,
      runnerFactory:
          ({
            required workingCopy,
            required stateDir,
            required connection,
            required password,
          }) {
            final client = make(connection.uri, connection.user, password);
            return _WebDavRunner(
              PullEngine(
                workingCopy: workingCopy,
                stateDir: stateDir,
                // The notebook's lock, so a pull and the notebook never write one folder together.
                locks: notebook.folderLocks,
                driver: WebDavDriver(
                  client: client,
                  idKind: connection.idKind,
                  rootId: connection.rootId,
                ),
                clock: clock,
              ),
              client,
            );
          },
    );
  }

  final TokenStore store;
  final Future<bool> Function() keychainReady;
  final WebDavClientFactory clientFactory;
  final WebDavRunnerFactory runnerFactory;

  WebDavConnection? _conn;
  String? _password;
  bool _scanned = false;
  bool _unreadable = false;
  bool _signedOut = false;

  /// The folder this device is connected to, if any.
  WebDavConnection? get connection => _conn;

  /// A `connection.json` exists and can't be read: sync is paused and the file
  /// is left alone.
  bool get connectionUnreadable => _unreadable;

  /// Whether a server can be connected now.
  bool get canConnect => _conn == null && !_unreadable;

  @override
  Directory? get workingCopy {
    final c = _conn;
    return c == null
        ? null
        : webDavWorkingCopy(workingRoot, c.accountKey, c.rootKey);
  }

  @override
  String get providerName => 'WebDAV';

  @override
  bool get canPoll =>
      _conn != null &&
      !_unreadable &&
      !_signedOut &&
      _password != null &&
      // A refused password is not sent again: only a new connect resumes.
      runner?.status.state != SyncState.signedOut;

  @override
  String get signedOutLine =>
      'Paused: WebDAV refused the password. Disconnect and connect again.';

  @override
  String? get blockedLine {
    if (_unreadable) return "Paused: the saved connection can't be read";
    if (_signedOut) {
      return 'Paused: the password is missing. Disconnect and connect again.';
    }
    return null;
  }

  @override
  void attachAccount() {}

  @override
  void detachAccount() {}

  // --- Connect --------------------------------------------------------------

  /// The first checks of a connection: the address is https (through the
  /// client), the server lists class 1 in `DAV:`, the address is a folder and
  /// the password is accepted. Throws [WebDavLoginException] with the words to
  /// show. The caller picks a folder with [WebDavLogin.source], then calls
  /// [connect], then [WebDavLogin.close].
  Future<WebDavLogin> checkLogin({
    required String address,
    required String user,
    required String password,
  }) async {
    final a = address.trim();
    final u = Uri.tryParse(a);
    if (a.isEmpty || u == null || !u.hasScheme || u.host.isEmpty) {
      throw const WebDavLoginException(
        'Enter the server address, starting with https://',
      );
    }
    if (u.userInfo.isNotEmpty) {
      throw const WebDavLoginException(
        'The address must not hold a user name.',
      );
    }
    final name = user.trim();
    if (name.isEmpty) throw const WebDavLoginException('Enter the user name.');
    if (password.isEmpty) {
      throw const WebDavLoginException('Enter the app password.');
    }
    if (!await _keychainOk()) {
      throw const WebDavLoginException(
        "Noted couldn't prepare the secure storage. Try again.",
      );
    }
    final WebDavClient client;
    try {
      client = clientFactory(Uri.parse(normalizeWebDavUrl(u)), name, password);
    } on Object catch (e) {
      throw WebDavLoginException(explainWebDavError(e));
    }
    try {
      await client.checkDav();
      final top = await client.stat(client.root);
      if (!top.folder) throw RemoteNotSupported('This address is not a folder');
    } on Object catch (e) {
      client.close();
      throw WebDavLoginException(explainWebDavError(e));
    }
    // Browsing is by path, whatever ids the server has: they only name a
    // folder while it is being chosen.
    return WebDavLogin._(
      name,
      password,
      client,
      WebDavDriver(client: client, idKind: DavIdKind.path, rootId: '/'),
    );
  }

  Future<bool> _keychainOk() async {
    try {
      return await keychainReady();
    } on Object {
      return false;
    }
  }

  /// Connects to the folder [picked] from [login]: a first full walk must give
  /// every file a version (else "This server doesn't report file versions"),
  /// the id kind is fixed, the password is saved, then `connection.json`
  /// (atomically), then the folder is added to the notebook and pulled.
  /// Returns what to show when it could not be done, null when it was.
  Future<String?> connect(WebDavLogin login, ChosenRoot picked) async {
    if (!_scanned) await _scan();
    if (!canConnect) {
      return _unreadable
          ? "The saved connection can't be read."
          : 'WebDAV is connected already.';
    }
    final at = login.driver.urlOf(picked.itemId);
    if (at == null) return "That folder couldn't be found.";
    final url = normalizeWebDavUrl(at);
    final client = clientFactory(Uri.parse(url), login.user, login.password);
    final WebDavDriver found;
    try {
      found = await WebDavDriver.connect(client);
    } on Object catch (e) {
      return explainWebDavError(e);
    } finally {
      client.close();
    }
    if (!await _keychainOk()) {
      return "Noted couldn't prepare the secure storage. Try again.";
    }
    final conn = WebDavConnection(
      url: url,
      user: login.user,
      idKind: found.idKind,
      rootId: found.rootId,
      path: picked.path,
    );
    final file = webDavConnectionFile(
      webDavStateDir(support, conn.accountKey, conn.rootKey),
    );
    try {
      await store.write(conn.passwordKey, login.password);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(conn.toJson()), flush: true);
      await tmp.rename(file.path);
    } on Object {
      try {
        await store.delete(conn.passwordKey);
      } on Object {
        // Only the clean-up of a connection that wasn't made.
      }
      return "The connection couldn't be saved on this device.";
    }
    _conn = conn;
    _password = login.password;
    _signedOut = false;
    problem = null;
    notifyListeners();
    await evaluate();
    return null;
  }

  /// Forgets the connection on this device: the password and `connection.json`
  /// go, the working copy and the sync record stay, and nothing on the server
  /// is touched.
  Future<void> disconnect() async {
    final c = _conn;
    if (c == null) return;
    teardownRunner();
    _conn = null;
    _password = null;
    _signedOut = false;
    reschedule();
    notifyListeners();
    try {
      await store.delete(c.passwordKey);
    } on Object {
      // The next connect writes it again.
    }
    try {
      final file = webDavConnectionFile(
        webDavStateDir(support, c.accountKey, c.rootKey),
      );
      if (await file.exists()) await file.delete();
    } on Object {
      // Found again at the next start; Disconnect again.
    }
    notifyListeners();
  }

  // --- Start ----------------------------------------------------------------

  @override
  Future<void> doEvaluate() async {
    if (disposed || !loaded) return;
    if (!_scanned) await _scan();
    final c = _conn;
    if (c != null && !_unreadable && runner == null) {
      await _restore(c);
      if (runner != null) wantPoll = true;
    }
    if (disposed) return;
    reschedule();
    notifyListeners();
    pollIfWanted();
  }

  // Finds the connection a former run saved. One only: a second file is left
  // alone. A file that can't be read pauses the sync and is never rewritten.
  Future<void> _scan() async {
    _scanned = true;
    final top = Directory('${support.path}${Platform.pathSeparator}webdav');
    final files = <File>[];
    try {
      if (!await top.exists()) return;
      await for (final account in top.list(followLinks: false)) {
        if (account is! Directory) continue;
        await for (final root in account.list(followLinks: false)) {
          if (root is! Directory) continue;
          final f = webDavConnectionFile(root);
          if (await f.exists()) files.add(f);
        }
      }
    } on Object {
      _unreadable = true;
      return;
    }
    if (files.isEmpty) return;
    files.sort((a, b) => a.path.compareTo(b.path));
    try {
      final c = WebDavConnection.fromJson(
        jsonDecode(await files.first.readAsString()),
      );
      // It must sit where its own keys say, or it is not ours.
      if (c == null ||
          webDavConnectionFile(webDavStateDir(support, c.accountKey, c.rootKey))
                  .path !=
              files.first.path) {
        _unreadable = true;
      } else {
        _conn = c;
      }
    } on Object {
      _unreadable = true;
    }
  }

  // The password, once the keychain step has succeeded, then the folder and the
  // runner. A problem is retried by the next evaluation (Check now, a resume).
  Future<void> _restore(WebDavConnection c) async {
    problem = null;
    _signedOut = false;
    if (!await _keychainOk()) {
      problem = "the secure storage isn't ready";
      return;
    }
    String? pw;
    try {
      pw = await store.read(c.passwordKey);
    } on Object {
      problem = "the saved password can't be read";
      return;
    }
    if (pw == null || pw.isEmpty) {
      _signedOut = true;
      return;
    }
    // A Disconnect while the password was read: nothing more is started.
    if (!identical(_conn, c) || disposed) return;
    _password = pw;
    final stateDir = webDavStateDir(support, c.accountKey, c.rootKey);
    final dir = webDavWorkingCopy(workingRoot, c.accountKey, c.rootKey);
    if (!await prepareFolder(dir, stateDir)) return;
    if (!identical(_conn, c) || disposed) return;
    try {
      attachRunner(
        runnerFactory(
          workingCopy: dir,
          stateDir: stateDir,
          connection: c,
          password: pw,
        ),
      );
    } on Object {
      problem = "the sync couldn't be started";
    }
  }
}

/// Gives the About dialog and `Home`, which sit in different routes, the
/// WebDAV controller. Null above it on desktop.
class WebDavScope extends InheritedWidget {
  const WebDavScope({super.key, required this.sync, required super.child});

  final WebDavSync? sync;

  static WebDavSync? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WebDavScope>()?.sync;

  @override
  bool updateShouldNotify(WebDavScope old) => old.sync != sync;
}
