// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// App access to iCloud Drive folders and to the folders a macOS sandbox
// forgets (cloud parity R5.3, R5.4, R5.9; step 5): the channel client and its
// coordinator, `folder-access.json`, resolving bookmarks before the first
// load, registering each iCloud root's coordinator, and the self-test.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart' show AttachmentState;
import 'package:noted_core/noted_core.dart';

import 'attachment_copy.dart';

/// Which Apple (or other) platform the folder access runs on; a seam, so
/// tests choose it.
enum CloudPlatform { ios, macos, other }

/// The platform this process runs on.
CloudPlatform cloudPlatformOfThisDevice() =>
    Platform.isIOS ? CloudPlatform.ios : (Platform.isMacOS ? CloudPlatform.macos : CloudPlatform.other);

/// The name of `folder-access.json`.
const String folderAccessFileName = 'folder-access.json';

/// What the folder rows and the load say (the design's words).
class CloudFolderTexts {
  const CloudFolderTexts._();

  static const String chooseAgain = 'Choose the folder again';
  static const String anotherDevice = 'On another device';
  static const String checking = 'Checking the iCloud folder…';
  static const String busy = 'iCloud is busy; Noted will try again';
  static const String unsafe = "This iCloud folder can't be written safely on this device.";
  static const String notICloud = 'Choose a folder in iCloud Drive';
}

/// The folder picker refused the folder (iOS: it isn't in iCloud Drive).
class CloudPickRefused implements Exception {
  const CloudPickRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The channel `noted/cloud_folder`, as Dart sees it: calls out, events in.
abstract interface class CloudFolderChannel {
  /// Calls [method] with [args]; the platform's answer.
  Future<Object?> invoke(String method, [Map<String, Object?>? args]);

  /// Where the platform's calls to Dart (`go`, `pending`, `failed`,
  /// `changed`) are delivered.
  set onEvent(Future<void> Function(String method, Map<Object?, Object?> args)? handler);
}

/// The real channel.
class MethodCloudFolderChannel implements CloudFolderChannel {
  MethodCloudFolderChannel([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('noted/cloud_folder');

  final MethodChannel _channel;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? args]) => _channel.invokeMethod<Object?>(method, args);

  @override
  set onEvent(Future<void> Function(String method, Map<Object?, Object?> args)? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      final a = call.arguments;
      await handler(call.method, a is Map ? a : const {});
      return null;
    });
  }
}

// -- The coordinator (R5.4 protocol) -----------------------------------------

enum _AnswerKind { go, pending, failed }

class _Answer {
  const _Answer(this.kind, [this.paths = const []]);

  final _AnswerKind kind;
  final List<String> paths;
}

/// The [StorageCoordinator] that asks the platform for each coordinated call.
///
/// Dart sends `coordinate(id, intents)` and waits up to [timeout] for `go`. On
/// a timeout the id is abandoned, `cancel(id)` is sent and the call is a
/// [StorageBusy]. A `go` for an abandoned or unknown id is answered by `done`
/// at once and runs nothing. The body runs in `try`/`finally` and `done(id)`
/// is sent in the `finally`. `pending` is a [StorageBusy] (`versionsPending`)
/// and calls [onVersionsPending].
class ChannelCoordinator implements StorageCoordinator {
  ChannelCoordinator(this._channel, {this.timeout = coordinationStartTimeout});

  final CloudFolderChannel _channel;

  /// How long a call waits for `go`.
  final Duration timeout;

  /// Called with the paths of a `pending` answer. Step 6 fills it: it lands
  /// the iCloud versions of those files and retries. It does nothing yet.
  void Function(List<String> paths) onVersionsPending = _noLanding;

  static void _noLanding(List<String> paths) {}

  final Map<int, Completer<_Answer>> _waiting = {};
  final Set<int> _abandoned = {};
  // A random base per start, so an answer from before a reset can't match a new id.
  int _nextId = Random.secure().nextInt(1 << 31);
  Future<void> _ready = Future<void>.value();

  /// The calls wait for [ready] (the `reset` at channel start).
  set ready(Future<void> ready) => _ready = ready;

  /// How many calls wait for an answer (for tests).
  @visibleForTesting
  int get waitingCount => _waiting.length;

  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) async {
    try {
      await _ready;
    } on Object {
      // A failed reset: the call itself says whether the channel works.
    }
    final paths = [for (final i in write.intents) i.path];
    final id = ++_nextId;
    final answer = Completer<_Answer>();
    _waiting[id] = answer;
    final clock = Stopwatch()..start();
    Never abandon() {
      if (_waiting.remove(id) != null) _abandoned.add(id);
      unawaited(_send('cancel', id));
      throw StorageBusy(StorageBusyReason.coordination, paths, 'The folder did not answer in time');
    }

    try {
      await _channel
          .invoke('coordinate', {
            'id': id,
            'intents': [
              for (final i in write.intents) {'path': i.path, 'kind': i.kind.name},
            ],
          })
          .timeout(timeout);
    } on TimeoutException {
      abandon();
    } on Object catch (e) {
      _waiting.remove(id);
      throw StorageBusy(StorageBusyReason.coordination, paths, 'The folder is not available: $e');
    }
    final _Answer a;
    try {
      final left = timeout - clock.elapsed;
      a = await answer.future.timeout(left.isNegative ? Duration.zero : left);
    } on TimeoutException {
      abandon();
    }
    switch (a.kind) {
      case _AnswerKind.go:
        try {
          return await body();
        } finally {
          await _send('done', id);
        }
      case _AnswerKind.pending:
        final held = a.paths.isEmpty ? paths : a.paths;
        try {
          onVersionsPending(held);
        } on Object catch (e) {
          debugPrint('Noted: the landing could not be scheduled: $e');
        }
        throw StorageBusy(StorageBusyReason.versionsPending, held);
      case _AnswerKind.failed:
        throw StorageBusy(StorageBusyReason.coordination, paths, 'The folder could not be reached');
    }
  }

  Future<void> _send(String method, int id) async {
    try {
      await _channel.invoke(method, {'id': id});
    } on Object catch (e) {
      debugPrint('Noted: $method($id) failed: $e');
    }
  }

  /// An event from the platform: `go`, `pending` or `failed`.
  Future<void> handleEvent(String method, Map<Object?, Object?> args) async {
    final raw = args['id'];
    if (raw is! int) return;
    final waiting = _waiting.remove(raw);
    switch (method) {
      case 'go':
        if (waiting == null) {
          // Late or unknown: nothing runs, the hold is let go of at once.
          _abandoned.remove(raw);
          await _send('done', raw);
        } else {
          waiting.complete(const _Answer(_AnswerKind.go));
        }
      case 'pending':
        final p = args['paths'];
        waiting?.complete(_Answer(_AnswerKind.pending, [if (p is List) for (final x in p) '$x']));
        _abandoned.remove(raw);
      case 'failed':
        waiting?.complete(const _Answer(_AnswerKind.failed));
        _abandoned.remove(raw);
    }
  }
}

// -- folder-access.json --------------------------------------------------------

/// A probe on record: written before the probe file is published.
class CloudProbe {
  const CloudProbe(this.name, this.nonce);

  final String name;

  /// 32 bytes, base64.
  final String nonce;
}

/// One folder Noted keeps access to.
class CloudFolderEntry {
  const CloudFolderEntry(this.path, this.bookmark, [this.probe]);

  /// The folder's real path.
  final String path;

  /// The bookmark, base64.
  final String bookmark;
  final CloudProbe? probe;

  CloudFolderEntry copyWith({String? bookmark, CloudProbe? probe, bool clearProbe = false}) =>
      CloudFolderEntry(path, bookmark ?? this.bookmark, clearProbe ? null : (probe ?? this.probe));

  Map<String, Object?> toJson() => {
    'path': path,
    'bookmark': bookmark,
    if (probe != null) 'probe': {'name': probe!.name, 'nonce': probe!.nonce},
  };
}

/// What reading `folder-access.json` found.
enum CloudListState {
  /// Read (or not there yet).
  ok,

  /// It couldn't be read; its bytes were copied and a new list started. Its
  /// folders show "Choose the folder again".
  restarted,

  /// It couldn't be read and couldn't be copied: nothing is written, and its
  /// folders show "On another device".
  unavailable,
}

/// Whether the access to an entry's folder is live on this device.
enum CloudAccess { live, anotherDevice }

/// What the self-test of an iCloud root says.
enum CloudRootCheck { checking, passed, busy, unsafe }

/// What one landing of a file's iCloud versions did (R5.8).
class VersionLanding {
  VersionLanding(this.path);

  /// The file whose versions were landed (a leftover's own path for a leftover).
  final String path;

  /// The copies now holding versions (published or adopted).
  final List<String> published = [];

  /// How many versions were resolved.
  int resolved = 0;

  /// [path] is a primitive's leftover (`.cas-old`, `.cas-verified`).
  bool leftover = false;

  /// Something failed that may work later (a refused call, a failed copy).
  bool refused = false;

  /// Both copy names were taken by unequal files: the versions stay unresolved.
  bool cantKeep = false;

  /// Versions of an attachment (or template) that no page can use.
  final Set<String> others = {};

  /// Other files a leftover version temp couldn't be kept for.
  final Set<String> stuck = {};

  /// Files whose leftover temps could not be placed yet (counted as refusals).
  final Set<String> refusedTargets = {};

  /// Nothing was learned: the file is not downloaded. Its row stays as it is.
  bool skipped = false;
}

/// Why a file is listed with iCloud versions (R5.8).
enum CloudVersionIssueKind {
  /// The row `iCloud holds versions of <name> that Noted can't keep yet`.
  cantKeep,

  /// The row `iCloud holds another version of <name>`.
  otherVersion,
}

/// A row about the iCloud versions of one file.
class CloudVersionIssue {
  const CloudVersionIssue(this.path, this.kind, {this.ids = const {}, this.keepable = false});

  final String path;
  final CloudVersionIssueKind kind;

  /// The versions that make the row (an attachment's or template's other ones).
  final Set<String> ids;

  /// The row has the action "Keep it in iCloud" (an attachment's other version).
  final bool keepable;

  String get name => path.split(RegExp(r'[\\/]')).last;

  String get text => kind == CloudVersionIssueKind.cantKeep
      ? "iCloud holds versions of $name that Noted can't keep yet"
      : 'iCloud holds another version of $name';
}

/// The words of the action on an attachment's other-version row.
const String keepInICloudText = 'Keep it in iCloud';

enum _VKind { page, binder, attachment, template, other }

final RegExp _versionTemp = RegExp(r'^\.(.+)\.noted-version-[0-9a-f]{16}\.tmp$');

// The zone value that marks code running inside a landing.
final Object _landingZone = Object();

bool _isVersionTemp(String path) => _versionTemp.hasMatch(path.split(RegExp(r'[\\/]')).last);

class _Read {
  const _Read(this.entries, this.bytes, {this.refused = false});

  final List<CloudFolderEntry> entries;

  /// The bytes of the file read, or null when it isn't there.
  final Uint8List? bytes;

  /// The list can't be written (unreadable and not copied).
  final bool refused;
}

final Random _random = Random.secure();

String _hex(int bytes) => [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

final String _sep = Platform.pathSeparator;

/// [path] with its nearest existing ancestor resolved and the missing tail
/// appended; [path] itself when nothing resolves.
String _realPath(String path) {
  var cur = Directory(path).absolute.path;
  final tail = <String>[];
  for (var i = 0; i < 4096; i++) {
    if (FileSystemEntity.typeSync(cur, followLinks: false) != FileSystemEntityType.notFound) {
      try {
        final real = Directory(cur).resolveSymbolicLinksSync();
        return tail.isEmpty ? real : '${_trimEnd(real)}$_sep${tail.join(_sep)}';
      } on FileSystemException {
        // A dangling link: climb.
      }
    }
    final parent = Directory(cur).parent.path;
    if (parent == cur) break;
    final t = _trimEnd(cur);
    var cut = t.length - 1;
    while (cut >= 0 && t[cut] != '/' && t[cut] != r'\') {
      cut--;
    }
    tail.insert(0, t.substring(cut + 1));
    cur = parent;
  }
  return path;
}

String _trimEnd(String p) {
  var e = p.length;
  while (e > 1 && (p[e - 1] == '/' || p[e - 1] == r'\') && !(e == 3 && p[1] == ':')) {
    e--;
  }
  return p.substring(0, e);
}

// The comparison key of a path: real, separators as '/', no trailing one,
// lower case (an extra match only retains or coordinates more).
String _key(String path) => _trimEnd(_realPath(path)).replaceAll(r'\', '/').toLowerCase();

bool _isUnderKey(String child, String parent) => child == parent || child.startsWith(parent.endsWith('/') ? parent : '$parent/');

/// The app's access to the folders that need a bookmark or coordination.
///
/// One per process. [start] resets the channel and resolves every entry of
/// `folder-access.json`; the first load waits for [ready] (resolved, registered
/// and self-tested).
class IcloudFolders extends ChangeNotifier {
  IcloudFolders({
    required CloudFolderChannel channel,
    required this.file,
    this.platform = CloudPlatform.other,
    this.locks,
    Duration coordinationTimeout = coordinationStartTimeout,
    this.retryBusyAfter = const Duration(minutes: 1),
    this.ownFolders = const [],
    this.publishProbe = _publishProbe,
    this.versionRetryAfter = const Duration(seconds: 5),
    this.tempScanAfter = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _channel = channel,
       _now = now ?? DateTime.now {
    coordinator = ChannelCoordinator(channel, timeout: coordinationTimeout);
    // A `pending` answer lands the versions of its files, as a turn of its own
    // (R5.8); the caller's busy path retries after it.
    // A `pending` raised inside a landing never schedules another one: the
    // landing's own refusal is counted instead (it would loop).
    coordinator.onVersionsPending = (paths) {
      if (Zone.current[_landingZone] == true) return;
      unawaited(landVersions(paths));
    };
    channel.onEvent = _onEvent;
  }

  final CloudFolderChannel _channel;

  /// `folder-access.json`, beside `settings.json`.
  final File file;
  final CloudPlatform platform;

  /// The notebook's folder locks, so a probe doesn't overlap a notebook job.
  final FolderLocks? locks;

  /// The least time between two self-tests of a root that was busy.
  final Duration retryBusyAfter;

  /// Folders inside the app's own storage, which need no bookmark.
  final List<String> ownFolders;

  /// Publishes the probe file; a seam for tests (a failing publish).
  @visibleForTesting
  final Future<bool> Function(File tmp, String target) publishProbe;

  /// A test seam awaited at the start of every write of the list.
  @visibleForTesting
  Future<void> Function()? beforeListWrite;
  final DateTime Function() _now;

  late final ChannelCoordinator coordinator;

  /// Called when a root becomes writable (true) or read-only (false): the
  /// notebook keeps `_untestedRoots` from it. Called with true too when the
  /// root is gone.
  void Function(String root, bool writable)? onRootWritable;

  /// An event `changed(path, to?)` from the platform's presenter (M8). The
  /// notebook looks at both paths of a move.
  void Function(String path, String? to)? onChanged;

  /// Called after a landing published a copy or resolved a version (R5.8): the
  /// notebook looks at the new files, sweeps a leftover's folder again and
  /// retries what was `pending`.
  void Function(VersionLanding landing)? onLanded;

  /// Called when the rows of [versionIssues] change.
  void Function()? onIssuesChanged;

  /// The least time between two retries of a file whose versions can't be
  /// landed yet (a change event of it, R5.8).
  final Duration versionRetryAfter;

  /// The least time between two scans of the roots for version temps.
  final Duration tempScanAfter;

  /// A test seam awaited at each step of a landing (`copied`, `published`,
  /// `verified`, `resolved`) with the file's path; a throw there is a crash.
  @visibleForTesting
  Future<void> Function(String step, String path)? landingStep;

  /// Whether this platform has any folder access to manage.
  bool get active => platform != CloudPlatform.other;

  CloudListState _listState = CloudListState.ok;
  CloudListState get listState => _listState;

  List<CloudFolderEntry> _entries = [];
  final Map<String, CloudAccess> _access = {}; // by entry key
  final Map<String, CloudRootCheck> _checks = {}; // by entry key, iCloud roots only
  final Map<String, String> _registered = {}; // entry key -> registered real path
  final Map<String, DateTime> _lastTried = {};
  Future<void> _serial = Future<void>.value();
  Future<void>? _started;
  Future<void> _ready = Future<void>.value();
  final ValueNotifier<bool> _checkingNow = ValueNotifier<bool>(false);
  bool _disposed = false;

  /// Completes when every entry is resolved, registered and self-tested.
  Future<void> get ready => _ready;

  /// True while a self-test runs: the load shows "Checking the iCloud folder…".
  ValueListenable<bool> get checking => _checkingNow;

  /// The entries now on record.
  List<CloudFolderEntry> get entries => List.unmodifiable(_entries);

  Future<void> _onEvent(String method, Map<Object?, Object?> args) async {
    if (method == 'changed') {
      final p = args['path'];
      final to = args['to'];
      if (p is String) {
        final other = to is String ? to : null;
        if (!_isVersionTemp(p) && !(other != null && _isVersionTemp(other))) {
          onChanged?.call(p, other);
          _retryIssuesAt(p);
        }
        // A change in a busy root: try its self-test again (not more than once a minute).
        final e = _entryFor(p);
        if (e != null && _checks[_k(e.path)] == CloudRootCheck.busy) unawaited(retryBusy().whenComplete(_armRetry));
      }
      return;
    }
    await coordinator.handleEvent(method, args);
  }

  // The access of the entry covering [path] (the nearest one), or null.
  CloudFolderEntry? _entryFor(String path) {
    final k = _k(path);
    CloudFolderEntry? best;
    var bestLen = -1;
    for (final e in _entries) {
      final ek = _k(e.path);
      if (_isUnderKey(k, ek) && ek.length > bestLen) {
        best = e;
        bestLen = ek.length;
      }
    }
    return best;
  }

  /// What a location says about its access, or null: "On another device" for
  /// a folder whose access is lost, "Choose the folder again" for one with no
  /// entry on an Apple device, then the self-test's words. Meant for a
  /// location that is unavailable or read-only.
  String? statusOf(String path) {
    if (!active) return null;
    final e = _entryFor(path);
    if (e == null) {
      if (_listState == CloudListState.unavailable) return CloudFolderTexts.anotherDevice;
      final k = _k(path);
      if (ownFolders.any((o) => _isUnderKey(k, _k(o)))) return null;
      return CloudFolderTexts.chooseAgain;
    }
    final ek = _k(e.path);
    if (_access[ek] == CloudAccess.anotherDevice) return CloudFolderTexts.anotherDevice;
    return switch (_checks[ek]) {
      CloudRootCheck.checking => CloudFolderTexts.checking,
      CloudRootCheck.busy => CloudFolderTexts.busy,
      CloudRootCheck.unsafe => CloudFolderTexts.unsafe,
      _ => null,
    };
  }

  /// Whether the access to [path]'s folder was lost (resolved to another path,
  /// or failed): nothing is written there.
  bool accessLost(String path) {
    final e = _entryFor(path);
    return e != null && _access[_k(e.path)] == CloudAccess.anotherDevice;
  }

  /// The state of [path]'s entry, for tests and the rows.
  CloudAccess? accessOf(String path) => _entryFor(path) == null ? null : _access[_k(_entryFor(path)!.path)];

  /// The self-test of the iCloud root that holds [path], or null.
  CloudRootCheck? checkOf(String path) {
    final e = _entryFor(path);
    return e == null ? null : _checks[_k(e.path)];
  }

  // -- Start ---------------------------------------------------------------------

  /// Resets the channel, reads `folder-access.json` and resolves each entry
  /// (R5.3, R5.9 steps 1 and 2), then self-tests each iCloud root. Idempotent.
  Future<void> start() {
    return _started ??= () async {
      if (!active) return;
      final reset = _channel.invoke('reset').then<void>((_) {}, onError: (Object e) => debugPrint('Noted: reset failed: $e'));
      coordinator.ready = reset;
      await reset;
      final read = await _serialized(() => _readList());
      _entries = List.of(read.entries);
      final live = <CloudFolderEntry>[];
      for (final e in List.of(_entries)) {
        if (await _resolve(e)) live.add(e);
      }
      final tests = <Future<void>>[];
      for (final e in live) {
        if (await _register(e)) tests.add(_selfTest(e));
      }
      _ready = Future.wait(tests).then<void>((_) {});
      await _ready;
      _changed();
    }();
  }

  void _changed() {
    if (_disposed) return;
    _keyCache.clear();
    _checkingNow.value = _checks.values.contains(CloudRootCheck.checking);
    notifyListeners();
  }

  // Resolves [e]; false when its access is lost (another device).
  Future<bool> _resolve(CloudFolderEntry e) async {
    final ek = _k(e.path);
    try {
      final r = await _channel.invoke('resolve', {'bookmark': e.bookmark});
      if (r is! Map || r['path'] is! String) throw StateError('no path');
      final path = r['path'] as String;
      if (r['access'] == false) {
        // The platform could not start access: the folder is not ours to use.
        await _stopAccess(path);
        _access[ek] = CloudAccess.anotherDevice;
        return false;
      }
      if (_k(path) != ek) {
        // Another folder: access to it isn't ours to keep.
        await _stopAccess(path);
        _access[ek] = CloudAccess.anotherDevice;
        return false;
      }
      if (r['stale'] == true) {
        try {
          final fresh = await _channel.invoke('bookmark', {'path': path});
          if (fresh is String && fresh.isNotEmpty) {
            await _mutate((list) => [for (final x in list) _same(x.path, e.path) ? x.copyWith(bookmark: fresh) : x]);
          }
        } on Object catch (err) {
          debugPrint('Noted: renewing a bookmark failed: $err');
        }
      }
      _access[ek] = CloudAccess.live;
      return true;
    } on Object {
      _access[ek] = CloudAccess.anotherDevice;
      return false;
    }
  }

  // The comparison key of [path], resolved once until the lists change.
  final Map<String, String> _keyCache = {};

  // Bumped each time a path is picked or bookmarked: a release or prune queued
  // before that must not drop the new entry or its root.
  final Map<String, int> _generation = {};
  void _bump(String path) => _generation.update(_k(path), (v) => v + 1, ifAbsent: () => 1);
  // Not cached while the path doesn't exist yet: it may resolve differently once made.
  String _k(String path) {
    final cached = _keyCache[path];
    if (cached != null) return cached;
    final k = _key(path);
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) _keyCache[path] = k;
    return k;
  }

  bool _same(String a, String b) => _k(a) == _k(b);

  // The probe on record for [path] in [list], carried over a replaced entry.
  CloudProbe? _probeOf(List<CloudFolderEntry> list, String path) => list.where((x) => _same(x.path, path)).firstOrNull?.probe;

  Future<void> _stopAccess(String path) async {
    try {
      await _channel.invoke('stopAccess', {'path': path});
    } on Object catch (e) {
      debugPrint('Noted: stopAccess failed: $e');
    }
  }

  // Reads isUbiquitous (never stored) and registers the root. True when it is
  // an iCloud root, now untested.
  Future<bool> _register(CloudFolderEntry e) async {
    final bool ubiquitous;
    try {
      ubiquitous = (await _channel.invoke('isUbiquitous', {'path': e.path})) == true;
    } on Object {
      // Can't tell: coordinating a plain folder is safe, writing an iCloud one
      // without it is not.
      return _registerRoot(e);
    }
    if (!ubiquitous) return false;
    return _registerRoot(e);
  }

  bool _registerRoot(CloudFolderEntry e) {
    final ek = _k(e.path);
    final real = _realPath(e.path);
    registerCoordinator(real, coordinator);
    _registered[ek] = real;
    _checks[ek] = CloudRootCheck.checking;
    onRootWritable?.call(real, false);
    return true;
  }

  // -- Pick ----------------------------------------------------------------------

  /// Picks a folder. iOS: the platform's iCloud picker; a folder outside
  /// iCloud Drive is a [CloudPickRefused]. macOS: [pickDirectory] (the usual
  /// folder picker), then a bookmark. Returns the folder's real path once its
  /// self-test is over, or null if cancelled. Other platforms return what
  /// [pickDirectory] gives.
  Future<String?> pick({Future<String?> Function()? pickDirectory}) async {
    await start();
    _keyCache.clear();
    switch (platform) {
      case CloudPlatform.other:
        return pickDirectory?.call();
      case CloudPlatform.ios:
        final Object? r;
        try {
          r = await _channel.invoke('pick');
        } on PlatformException catch (e) {
          if (e.code == 'notUbiquitous') throw const CloudPickRefused(CloudFolderTexts.notICloud);
          throw CloudPickRefused('Could not choose the folder: ${e.message ?? e.code}');
        }
        if (r is! Map || r['path'] is! String) return null;
        final path = r['path'] as String;
        final bookmark = r['bookmark'];
        return _adopt(path, bookmark is String ? bookmark : null, started: true);
      case CloudPlatform.macos:
        final chosen = await pickDirectory?.call();
        if (chosen == null) return null;
        String? bookmark;
        try {
          final b = await _channel.invoke('bookmark', {'path': chosen});
          if (b is String && b.isNotEmpty) bookmark = b;
        } on Object catch (e) {
          debugPrint('Noted: making a bookmark failed: $e');
        }
        return _adopt(chosen, bookmark, started: false);
    }
  }

  Future<String> _adopt(String path, String? bookmark, {required bool started}) async {
    _bump(_realPath(path));
    var real = _realPath(path);
    if (bookmark != null && !started) {
      // Starts access and gives the real path.
      try {
        final r = await _channel.invoke('resolve', {'bookmark': bookmark});
        if (r is Map && r['path'] is String) real = r['path'] as String;
      } on Object catch (e) {
        debugPrint('Noted: resolving a new bookmark failed: $e');
      }
    }
    _bump(real);
    final entry = bookmark == null ? null : CloudFolderEntry(real, bookmark);
    var recorded = false;
    if (entry != null) {
      recorded = await _mutate((list) => [for (final x in list) if (!_same(x.path, real)) x, entry.copyWith(probe: _probeOf(list, real))]);
    }
    final e = _entries.where((x) => _same(x.path, real)).firstOrNull ?? CloudFolderEntry(real, bookmark ?? '');
    _access[_k(real)] = CloudAccess.live;
    if (await _register(e)) {
      if (recorded) {
        await _selfTest(e);
      } else {
        // The probe is recorded before it is published: with no record, the
        // root stays read-only, still coordinated.
        _setCheck(e, CloudRootCheck.unsafe);
      }
    }
    _changed();
    return real;
  }

  // -- Binders Noted creates -------------------------------------------------------

  /// A bookmark of its own for [path], a folder Noted just created, while the
  /// access of a picked folder above it is live. Written to
  /// `folder-access.json` before the caller lists the folder. Never throws; if
  /// it can't be made the folder is listed "Choose the folder again" at the
  /// next launch where access is missing.
  Future<void> bookmarkCreated(String path) async {
    if (!active) return;
    try {
      await start();
      _keyCache.clear();
      final parent = _entryFor(path);
      if (parent == null || _access[_k(parent.path)] != CloudAccess.live) return;
      if (_same(parent.path, path)) return;
      final real = _realPath(path);
      _bump(real);
      final b = await _channel.invoke('bookmark', {'path': real});
      if (b is! String || b.isEmpty) return;
      await _mutate((list) => [for (final x in list) if (!_same(x.path, real)) x, CloudFolderEntry(real, b, _probeOf(list, real))]);
      _access[_k(real)] = CloudAccess.live;
    } on Object catch (e) {
      debugPrint('Noted: no bookmark for a new folder: $e');
    }
  }

  // -- Pruning (R5.3, R-2) -----------------------------------------------------------

  /// Removes every entry that is none of [retained] (the paths of the binder
  /// folders, the standalone folders, the default page folder and the default
  /// binder folder) and not an ancestor of one, by real path. The caller calls
  /// it only once the 0164 hold lifted and `settings.json` and `binders.json`
  /// both read. Nothing is removed while `folder-access.json` is unreadable.
  Future<void> prune(Iterable<String> Function() retained) async {
    if (!active) return;
    final seen = Map<String, int>.of(_generation);
    await start();
    final gone = <CloudFolderEntry>[];
    final ok = await _mutate((list) {
      // Read inside the serialized write, so a folder added meanwhile counts.
      final keys = [for (final r in retained()) _k(r)];
      gone.clear();
      final keep = <CloudFolderEntry>[];
      for (final e in list) {
        final ek = _k(e.path);
        if (keys.any((k) => _isUnderKey(k, ek)) || (_generation[ek] ?? 0) != (seen[ek] ?? 0)) {
          keep.add(e);
        } else {
          gone.add(e);
        }
      }
      return keep;
    }, onlyIfReadable: true);
    if (!ok) return;
    for (final e in gone) {
      await _forget(e);
    }
    _changed();
  }

  /// A folder was removed from Noted: its entry goes unless [retained] still
  /// holds it (or something below it), and access to it stops. [retained] is
  /// read inside the serialized write, never earlier.
  Future<void> released(String path, Iterable<String> Function() retained) async {
    if (!active) return;
    final seen = _generation[_k(path)] ?? 0;
    await start();
    final target = _k(path);
    final gone = <CloudFolderEntry>[];
    final ok = await _mutate((list) {
      final keys = [for (final r in retained()) _k(r)];
      gone.clear();
      final keep = <CloudFolderEntry>[];
      for (final e in list) {
        final ek = _k(e.path);
        if (ek == target && !keys.any((k) => _isUnderKey(k, ek)) && (_generation[ek] ?? 0) == seen) {
          gone.add(e);
        } else {
          keep.add(e);
        }
      }
      return keep;
    }, onlyIfReadable: true);
    if (!ok) return;
    for (final e in gone) {
      await _forget(e);
    }
    _changed();
  }

  Future<void> _forget(CloudFolderEntry e) async {
    // Added again since the write (a pick of the same folder): kept.
    if (_entries.any((x) => _same(x.path, e.path))) return;
    final ek = _k(e.path);
    final real = _registered.remove(ek);
    if (real != null) {
      unregisterCoordinator(real);
      onRootWritable?.call(real, true);
    }
    _checks.remove(ek);
    _access.remove(ek);
    _lastTried.remove(ek);
    await _stopAccess(e.path);
  }

  // -- Downloads (R5.5) -------------------------------------------------------------

  /// Asks the platform to download the item at [path] (`startDownloading`).
  /// Never throws, never waits for the download.
  void startDownloading(String path) {
    if (!active) return;
    unawaited(
      _channel.invoke('startDownloading', {'path': path}).then<void>(
        (_) {},
        onError: (Object e) => debugPrint('Noted: startDownloading failed: $e'),
      ),
    );
  }

  // -- Versions (R5.8) --------------------------------------------------------

  Future<void> _landTail = Future<void>.value();
  final Set<String> _queued = {}; // keys of the files waiting for their landing
  final Map<String, CloudVersionIssue> _issues = {}; // by file key
  final Map<String, int> _refusals = {}; // landings in a row that were refused
  final Map<String, DateTime> _issueTried = {};
  final Map<String, Set<String>> _kept = {}; // "Keep it in iCloud": the versions hidden

  /// The rows about iCloud versions Noted can't land (or keeps in iCloud).
  List<CloudVersionIssue> get versionIssues => [
    for (final i in _issues.values)
      if (!_hidden(i)) i,
  ];

  bool _hidden(CloudVersionIssue i) {
    final kept = _kept[_k(i.path)];
    return kept != null && i.ids.isNotEmpty && i.ids.every(kept.contains);
  }

  /// Whether the versions of [path] can't be landed yet: its moves and deletes
  /// stay pending, and the notebook keeps edits of it in recovery.
  bool versionsStuck(String path) => _issues[_k(path)]?.kind == CloudVersionIssueKind.cantKeep;

  /// The row's text for [path] when its versions can't be landed, or null.
  String? versionRowOf(String path) {
    final i = _issues[_k(path)];
    return i != null && i.kind == CloudVersionIssueKind.cantKeep ? i.text : null;
  }

  /// "Keep it in iCloud": hides the row of [path] until its versions change.
  void keepInICloud(String path) {
    final i = _issues[_k(path)];
    if (i == null || !i.keepable) return;
    _kept[_k(path)] = {...i.ids};
    onIssuesChanged?.call();
  }

  void _setIssue(String path, CloudVersionIssue issue) {
    final k = _k(path);
    final old = _issues[k];
    _issues[k] = issue;
    if (old == null || old.kind != issue.kind || !_sameIds(old.ids, issue.ids)) {
      if (issue.kind == CloudVersionIssueKind.otherVersion && !(_kept[k]?.containsAll(issue.ids) ?? false)) _kept.remove(k);
      onIssuesChanged?.call();
    }
  }

  // Whether a version temp of [path] is still in its folder.
  bool _hasTempFor(String path) {
    final f = File(path);
    final prefix = '.${f.uri.pathSegments.last}.noted-version-';
    if (!f.parent.existsSync()) return false; // the folder is gone: no temp is there
    try {
      for (final e in f.parent.listSync(followLinks: false)) {
        final n = e.path.split(RegExp(r'[\\/]')).last;
        if (e is File && n.startsWith(prefix) && _isVersionTemp(e.path)) return true;
      }
    } on FileSystemException {
      return true;
    }
    return false;
  }

  void _clearIssue(String path) {
    // A row raised for a temp that could not be placed stays until it is gone.
    if (_hasTempFor(path)) return;
    final k = _k(path);
    _refusals.remove(k);
    _kept.remove(k);
    if (_issues.remove(k) != null) onIssuesChanged?.call();
  }

  bool _sameIds(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  /// Lands the iCloud versions of [paths] (the files a `pending` answer named,
  /// or files with versions left). Each file is its own turn of its folder's
  /// lock, started after the caller's turn; the returned future completes when
  /// they are all done. A coordinator's `pending` calls it and ignores that.
  Future<void> landVersions(Iterable<String> paths) {
    final waits = <Future<void>>[];
    for (final p in paths.toSet()) {
      if (_disposed || !_queued.add(_k(p))) continue;
      final run = _landTail
          .then((_) async {
            // Never inside the turn that was refused.
            await Future<void>.delayed(Duration.zero);
            _queued.remove(_k(p));
            if (!_disposed) await _landOne(p);
          })
          .catchError((Object e) {
            debugPrint('Noted: landing the versions of $p failed: $e');
          });
      _landTail = run;
      waits.add(run);
    }
    return Future.wait(waits).then<void>((_) {});
  }

  /// Looks for versions of every page and binder file in each iCloud root
  /// (launch): the ones left by a server write, or a crash.
  Future<void> landAllVersions() async {
    final files = <String>[];
    for (final root in _registered.values.toList()) {
      _collectVersionable(Directory(root), files, pages: true);
    }
    _lastTempScan = _now();
    await landVersions(files);
  }

  /// Places the version temps left in any folder of an iCloud root (`.assets`
  /// included), at most once in [tempScanAfter]; the notebook calls it at its
  /// folder checks.
  Future<void> landLeftoverTemps() async {
    final last = _lastTempScan;
    if (_disposed || (last != null && _now().difference(last) < tempScanAfter)) return;
    _lastTempScan = _now();
    final files = <String>[];
    for (final root in _registered.values.toList()) {
      _collectVersionable(Directory(root), files, pages: false);
    }
    await landVersions(files);
  }

  DateTime? _lastTempScan;

  // Every page and binder file ([pages]), and each folder that holds a version
  // temp (its path is landed as a folder), under [dir]; `.assets` folders are
  // looked into for temps only.
  void _collectVersionable(Directory dir, List<String> out, {required bool pages, bool assets = false}) {
    try {
      var hasTemp = false;
      for (final e in dir.listSync(followLinks: false)) {
        final name = e.path.split(RegExp(r'[\\/]')).last;
        if (e is Directory) {
          if (!name.startsWith('.')) _collectVersionable(e, out, pages: pages, assets: assets || name.endsWith('.assets'));
        } else if (e is File) {
          if (_isVersionTemp(e.path)) {
            hasTemp = true;
          } else if (pages && !assets && (name.endsWith('.canvas') || name == binderFileName) && !name.startsWith('.')) {
            out.add(e.path);
          }
        }
      }
      if (hasTemp) out.add(dir.path);
    } on FileSystemException {
      // A folder that can't be listed now is looked at at the next launch.
    }
  }

  void _retryIssuesAt(String p) {
    if (_issues.isEmpty || _disposed) return;
    final k = _k(p);
    final parentK = _k(File(p).parent.path);
    final now = _now();
    for (final i in _issues.values.toList()) {
      final ik = _k(i.path);
      final ip = _k(File(i.path).parent.path);
      if (ik != k && ip != parentK && ip != k) continue;
      final last = _issueTried[ik];
      if (last != null && now.difference(last) < versionRetryAfter) continue;
      _issueTried[ik] = now;
      unawaited(landVersions([i.path]));
    }
  }

  /// Whether [path] is in a root that may be written now: its access live and
  /// its self-test passed (R5.9). A landing writes temps and copies and
  /// resolves versions, so none runs in a root that is untested, busy, unsafe
  /// or whose access was lost; the versions stay unresolved and the rows as
  /// they are.
  bool mayLand(String path) {
    final e = _entryFor(path);
    if (e == null) return true;
    final ek = _k(e.path);
    if (_access[ek] != CloudAccess.live) return false;
    final c = _checks[ek];
    return c == null || c == CloudRootCheck.passed;
  }

  Future<void> _landOne(String path) async {
    if (!mayLand(path)) return;
    final k = _k(path);
    _issueTried[k] = _now();
    final VersionLanding l;
    final isFolder = FileSystemEntity.isDirectorySync(path);
    try {
      final dir = Directory(isFolder ? path : File(path).parent.path);
      final lock = locks;
      l = await runZoned(
        () => lock == null ? _landLocked(path) : lock.run(dir, () => _landLocked(path)),
        zoneValues: {_landingZone: true},
      );
    } on Object catch (e) {
      debugPrint('Noted: landing the versions of $path failed: $e');
      if (!isFolder) _refused(path);
      return;
    }
    final name = path.split(RegExp(r'[\\/]')).last;
    // A temp that could not be placed counts against its file (not this one).
    for (final r in l.refusedTargets) {
      if (isFolder || _k(r) != k) _refused(r);
    }
    if (isFolder || l.skipped) {
      // A folder landing only places temps; a skipped file keeps its row.
    } else if (l.cantKeep) {
      _setIssue(path, CloudVersionIssue(path, CloudVersionIssueKind.cantKeep));
    } else if (l.refused || l.refusedTargets.any((t) => _k(t) == k)) {
      _refused(path);
    } else if (l.others.isNotEmpty) {
      _refusals.remove(k);
      final t = _targetOf(name);
      _setIssue(
        path,
        CloudVersionIssue(path, CloudVersionIssueKind.otherVersion, ids: l.others, keepable: _kindOf(t.name) == _VKind.attachment),
      );
    } else {
      _clearIssue(path);
    }
    for (final s in l.stuck) {
      _setIssue(s, CloudVersionIssue(s, CloudVersionIssueKind.cantKeep));
    }
    if (l.published.isNotEmpty || l.resolved > 0) onLanded?.call(l);
  }

  // A landing that was refused or failed: the third in a row makes the row.
  void _refused(String path) {
    final k = _k(path);
    final n = (_refusals[k] ?? 0) + 1;
    _refusals[k] = n;
    if (n >= 3) _setIssue(path, CloudVersionIssue(path, CloudVersionIssueKind.cantKeep));
  }

  Future<void> _step(String step, String path) async => landingStep?.call(step, path);

  // The file name a leftover goes back to, and whether [name] is a leftover.
  ({String name, bool leftover}) _targetOf(String name) {
    for (final suffix in [asideSuffix, verifiedSuffix]) {
      if (!name.endsWith(suffix)) continue;
      final body = name.substring(0, name.length - suffix.length);
      final dot = body.lastIndexOf('.');
      if (dot > 0) return (name: body.substring(0, dot), leftover: true);
    }
    return (name: name, leftover: false);
  }

  _VKind _kindOf(String targetName) {
    if (targetName.endsWith(PageStore.extension)) return _VKind.page;
    if (targetName == binderFileName) return _VKind.binder;
    if (targetName.endsWith('.notedtemplate')) return _VKind.template;
    if (attachmentNameHash(targetName) != null) return _VKind.attachment;
    return _VKind.other;
  }

  // `<stem>-icloud-<h>.canvas` or `noted-binder-icloud-<h>.json`, with the
  // first 8 hex of the hash, then the first 16.
  List<String> _copyNames(String dir, String targetName, _VKind kind, String hash) {
    final stem = kind == _VKind.binder ? 'noted-binder' : targetName.substring(0, targetName.length - PageStore.extension.length);
    final ext = kind == _VKind.binder ? '.json' : PageStore.extension;
    return [for (final n in [8, 16]) '$dir$_sep$stem-icloud-${hash.substring(0, n)}$ext'];
  }

  Future<Uint8List?> _readOrNull(String path) async {
    try {
      if (isDataless(path)) return null;
      return await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _removeTemp(String tmp, List<int> bytes) async {
    try {
      await deleteFileIfMatches(tmp, bytes: bytes);
    } on FileSystemException catch (e) {
      debugPrint('Noted: a version temp stays for the next landing: $e');
    }
  }

  // Publishes [tmp] under the first free name that holds [bytes]: an equal
  // file already there is adopted and the temp removed; both names taken by
  // unequal files give null.
  Future<({String path, bool adopted})?> _publishCopy(File tmp, Uint8List bytes, List<String> names) async {
    for (final n in names) {
      if (await publishExclusive(tmp, n)) return (path: n, adopted: false);
      final have = await _readOrNull(n);
      if (have != null && _bytesEqual(have, bytes)) {
        await _removeTemp(tmp.path, bytes);
        return (path: n, adopted: true);
      }
    }
    return null;
  }

  Future<VersionLanding> _landLocked(String path) async {
    final k = _k(path);
    final out = VersionLanding(path);
    // Checked again now the lock turn has begun: the root may have changed.
    if (!mayLand(path)) {
      out.skipped = true;
      return out;
    }
    if (FileSystemEntity.isDirectorySync(path)) {
      // A folder: only the temps left in it are placed.
      await _landTemps(path, out);
      return out;
    }
    final dir = File(path).parent.path;
    final target = _targetOf(path.split(RegExp(r'[\\/]')).last);
    out.leftover = target.leftover;
    final kind = _kindOf(target.name);
    // Temps left by a landing that was cut short, before anything new is made.
    await _landTemps(dir, out);
    if (isDataless(path)) {
      // Not read, and its versions not asked for: it is downloaded first.
      startDownloading(path);
      out.skipped = true;
      return out;
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
      _clearIssue(path);
      return out;
    }
    final Object? raw;
    try {
      raw = await _channel.invoke('versions', {'path': path});
    } on Object catch (e) {
      debugPrint('Noted: reading the versions of $path failed: $e');
      out.refused = true;
      return out;
    }
    final list = raw is List ? raw : const [];
    if (list.isEmpty) {
      _clearIssue(path);
      return out;
    }
    for (final item in list) {
      if (item is! Map) continue;
      final id = '${item['id']}';
      final tmp = item['tmpPath'];
      if (tmp is! String || item['error'] != null) {
        out.refused = true;
        continue;
      }
      try {
        await _step('copied', path);
        switch (kind) {
          case _VKind.page:
          case _VKind.binder:
            await _landPageVersion(path, id, tmp, dir, target.name, kind, out);
          case _VKind.attachment:
            await _landAttachmentVersion(path, id, tmp, target.name, out, sole: list.length == 1);
          case _VKind.template:
          case _VKind.other:
            // Nothing to land it into: it stays unresolved in iCloud.
            final bytes = await File(tmp).readAsBytes();
            await _removeTemp(tmp, bytes);
            out.others.add(id);
        }
      } on StorageBusy catch (e) {
        debugPrint('Noted: landing a version of $path was refused: $e');
        out.refused = true;
      } on FileSystemException catch (e) {
        debugPrint('Noted: landing a version of $path failed: $e');
        out.refused = true;
      }
    }
    if (out.refused && !out.cantKeep) _issueTried[k] = _now();
    return out;
  }

  Future<void> _landPageVersion(
    String path,
    String id,
    String tmp,
    String dir,
    String targetName,
    _VKind kind,
    VersionLanding out,
  ) async {
    final bytes = await File(tmp).readAsBytes();
    final hash = contentHash(bytes);
    // Equal to the file as it is now: nothing to keep, the copy is dropped.
    final current = await _readOrNull(path);
    if (current != null && contentHash(current) == hash) {
      await _removeTemp(tmp, bytes);
      await _resolveVersion(path, id, out);
      return;
    }
    final dest = await _publishCopy(File(tmp), bytes, _copyNames(dir, targetName, kind, hash));
    if (dest == null) {
      // Both names are taken by unequal files: the version stays unresolved.
      out.cantKeep = true;
      await _removeTemp(tmp, bytes);
      return;
    }
    await _step('published', path);
    // Only a copy made by this landing is reported: an adopted one was seen
    // when it arrived (reporting it again would start a merge cycle).
    if (!dest.adopted) out.published.add(dest.path);
    // Verified by reading the copy back before the version is let go.
    final back = await _readOrNull(dest.path);
    if (back == null || !_bytesEqual(back, bytes)) {
      out.refused = true;
      return;
    }
    await _step('verified', path);
    await _resolveVersion(path, id, out);
  }

  Future<bool> _resolveVersion(String path, String id, VersionLanding out) async {
    try {
      final r = await _channel.invoke('resolveVersion', {'path': path, 'id': id});
      if (r != true) {
        // No such unresolved version: not resolved by this landing.
        out.refused = true;
        return false;
      }
      out.resolved++;
    } on Object catch (e) {
      debugPrint('Noted: resolving a version of $path failed: $e');
      out.refused = true;
      return false;
    }
    await _step('resolved', path);
    return true;
  }

  Future<void> _landAttachmentVersion(String path, String id, String tmp, String targetName, VersionLanding out, {required bool sole}) async {
    final nameHash = attachmentNameHash(targetName)!;
    final bytes = await File(tmp).readAsBytes();
    if (contentHash(bytes) != nameHash) {
      // No use to a page: it stays in iCloud (the row's action keeps it there).
      await _removeTemp(tmp, bytes);
      out.others.add(id);
      return;
    }
    await _step('verified', path);
    final ok = await _placeAttachment(File(tmp), bytes, path, nameHash, out, () => _resolveVersion(path, id, out), sole: sole);
    if (!ok) out.refused = true;
  }

  // Puts the verified bytes [bytes] (in [tmp]) where the attachment [path]
  // is: an intact file needs nothing, a missing one is published, a damaged
  // one goes through the damaged set-aside first (0132). [resolve] lets go of
  // the version once [tmp] is its durable copy.
  Future<bool> _placeAttachment(
    File tmp,
    Uint8List bytes,
    String path,
    String nameHash,
    VersionLanding out,
    Future<bool> Function() resolve, {
    bool sole = true,
  }) async {
    final f = File(path);
    final exists = FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
    if (!exists) {
      if (isDataless(path)) return false;
      if (!await publishAttachment(tmp, path)) return false;
      await _removeTemp(tmp.path, bytes);
      out.published.add(path);
      return resolve();
    }
    if (isDataless(path)) return false;
    final c = await checkAttachmentFile(f, nameHash, 0);
    switch (c.state) {
      case AttachmentState.ok:
        await _removeTemp(tmp.path, bytes);
        return resolve();
      case AttachmentState.damaged:
        // The set-aside is a move of the file: another unresolved version would
        // make it pending for good. Then nothing is resolved and the file is
        // listed; the temp goes (every version is still in iCloud).
        if (!sole) {
          out.cantKeep = true;
          await _removeTemp(tmp.path, bytes);
          return true;
        }
        // The temp is the durable copy now: the version is let go first (a crash
        // after it leaves the temp, which the launch pass and the folder tick
        // find in any folder, `.assets` included).
        if (!await resolve()) return false;
        final aside = await setAsideDamaged(f, c.found!);
        if (aside.name == null) return false;
        if (!await publishAttachment(tmp, path)) return false;
        await _removeTemp(tmp.path, bytes);
        out.published.add(path);
        return true;
      default:
        return false;
    }
  }

  // Version temps in [dir]: one equal to its copy is removed (checked), any
  // other is published under its own hash. None is deleted unverified.
  Future<void> _landTemps(String dir, VersionLanding out) async {
    final temps = <File>[];
    try {
      await for (final e in Directory(dir).list(followLinks: false)) {
        if (e is File && _isVersionTemp(e.path)) temps.add(e);
      }
    } on FileSystemException {
      return;
    }
    for (final t in temps) {
      try {
        await _landTemp(t, dir, out);
      } on StorageBusy {
        out.refused = true;
      } on FileSystemException catch (e) {
        debugPrint('Noted: a version temp could not be handled: $e');
        out.refused = true;
      }
    }
  }

  Future<void> _landTemp(File t, String dir, VersionLanding out) async {
    final m = _versionTemp.firstMatch(t.path.split(RegExp(r'[\\/]')).last);
    if (m == null) return;
    final name = m.group(1)!;
    final target = _targetOf(name);
    final kind = _kindOf(target.name);
    final Uint8List bytes;
    try {
      bytes = await t.readAsBytes();
    } on FileSystemException {
      return;
    }
    if (bytes.isEmpty) {
      await _removeTemp(t.path, bytes);
      return;
    }
    final path = '$dir$_sep$name';
    switch (kind) {
      case _VKind.page:
      case _VKind.binder:
        final hash = contentHash(bytes);
        final current = await _readOrNull(path);
        if (current != null && contentHash(current) == hash) {
          await _removeTemp(t.path, bytes);
          return;
        }
        final dest = await _publishCopy(t, bytes, _copyNames(dir, target.name, kind, hash));
        if (dest == null) {
          out.stuck.add(path);
        } else if (!dest.adopted) {
          out.published.add(dest.path);
        }
      case _VKind.attachment:
        final nameHash = attachmentNameHash(target.name)!;
        if (contentHash(bytes) != nameHash) {
          await _removeTemp(t.path, bytes);
          return;
        }
        final at = '$dir$_sep${target.name}';
        if (!await _placeAttachment(t, bytes, at, nameHash, out, () async => true)) out.refusedTargets.add(at);
      case _VKind.template:
      case _VKind.other:
        await _removeTemp(t.path, bytes);
    }
  }

  // -- Self-test (R5.9) ------------------------------------------------------------

  // The self-test of a busy root is retried on a timer of its own (R5.9: at most
  // once a minute), whether or not the notebook watches folders (iOS doesn't).
  Timer? _retryTimer;

  void _armRetry() {
    if (_disposed) return;
    if (!_checks.values.contains(CloudRootCheck.busy)) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(retryBusyAfter, () {
      _retryTimer = null;
      unawaited(retryBusy().whenComplete(_armRetry));
    });
  }

  void _setCheck(CloudFolderEntry e, CloudRootCheck c) {
    final ek = _k(e.path);
    _checks[ek] = c;
    final real = _registered[ek];
    if (real != null) onRootWritable?.call(real, c == CloudRootCheck.passed);
    _changed();
    _armRetry();
  }

  /// Runs the self-test again for every root whose last one timed out, at
  /// most once a minute each. The notebook calls it at its folder checks.
  Future<void> retryBusy() async {
    for (final e in List.of(_entries)) {
      final ek = _k(e.path);
      if (_checks[ek] != CloudRootCheck.busy) continue;
      final last = _lastTried[ek];
      if (last != null && _now().difference(last) < retryBusyAfter) continue;
      await _selfTest(e);
      // The root is tested now: the versions skipped meanwhile are landed.
      if (_checks[ek] == CloudRootCheck.passed) unawaited(landAllVersions());
    }
  }

  Future<void> _selfTest(CloudFolderEntry e) async {
    final ek = _k(e.path);
    _lastTried[ek] = _now();
    _setCheck(e, CloudRootCheck.checking);
    try {
      final dir = Directory(_registered[ek] ?? e.path);
      final lock = locks;
      final result = lock == null ? await _probe(e) : await lock.run(dir, () => _probe(e));
      _setCheck(e, result);
    } finally {
      _checkingNow.value = _checks.values.contains(CloudRootCheck.checking);
    }
  }

  Future<CloudRootCheck> _probe(CloudFolderEntry e) async {
    final root = _registered[_k(e.path)] ?? e.path;
    try {
      // A leftover probe from an earlier run: removed by its nonce only.
      final old = _entries.where((x) => _same(x.path, e.path)).firstOrNull?.probe;
      if (old != null) {
        final nonce = base64Decode(old.nonce);
        for (final name in [old.name, '${old.name}.part']) {
          final f = File('$root$_sep$name');
          Uint8List? bytes;
          try {
            bytes = await f.readAsBytes();
          } on FileSystemException {
            bytes = null;
          }
          if (bytes != null && _bytesEqual(bytes, nonce)) {
            await deleteFileIfMatches(f.path, bytes: nonce);
          }
        }
        await _mutate((list) => [for (final x in list) _same(x.path, e.path) ? x.copyWith(clearProbe: true) : x]);
      }
      final name = '.noted-probe-${_hex(8)}.tmp';
      final nonce = Uint8List.fromList([for (var i = 0; i < 32; i++) _random.nextInt(256)]);
      final recorded = await _mutate(
        (list) => [for (final x in list) _same(x.path, e.path) ? x.copyWith(probe: CloudProbe(name, base64Encode(nonce))) : x],
      );
      // On record means an entry of this folder holds this very probe (a list
      // without the entry changes nothing and records nothing).
      final on = _entries.where((x) => _same(x.path, e.path)).firstOrNull?.probe;
      if (!recorded || on == null || on.name != name) return CloudRootCheck.unsafe;
      final part = File('$root$_sep$name.part');
      final target = '$root$_sep$name';
      await part.writeAsBytes(nonce, flush: true);
      final bool published;
      try {
        published = await publishProbe(part, target);
      } on StorageBusy {
        await _dropTemp(part, nonce);
        rethrow;
      } on FileSystemException {
        await _dropTemp(part, nonce);
        return CloudRootCheck.unsafe;
      }
      if (!published) {
        await _dropTemp(part, nonce);
        return CloudRootCheck.unsafe;
      }
      // The probe is out: a vanished one (absent) still passes.
      await deleteFileIfMatches(target, bytes: nonce);
      await _mutate((list) => [for (final x in list) _same(x.path, e.path) ? x.copyWith(clearProbe: true) : x]);
      return CloudRootCheck.passed;
    } on StorageBusy {
      return CloudRootCheck.busy;
    } on Object catch (err) {
      debugPrint('Noted: the iCloud self-test failed: $err');
      return CloudRootCheck.unsafe;
    }
  }

  Future<void> _dropTemp(File f, Uint8List nonce) async {
    try {
      await deleteFileIfMatches(f.path, bytes: nonce);
    } on Object {
      // Left for the next launch's nonce check.
    }
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // -- folder-access.json ----------------------------------------------------------

  Future<T> _serialized<T>(Future<T> Function() job) {
    final run = _serial.then((_) => job());
    _serial = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Applies [change] to the list on disk and writes it with
  /// [replaceIfUnchanged]; false if nothing could be written (unreadable and
  /// not copied, or a write that failed). With [onlyIfReadable], a list that
  /// isn't readable is never replaced.
  Future<bool> _mutate(List<CloudFolderEntry> Function(List<CloudFolderEntry>) change, {bool onlyIfReadable = false}) {
    return _serialized(() async {
      await beforeListWrite?.call();
      _keyCache.clear();
      for (var attempt = 0; attempt < 4; attempt++) {
        final _Read r;
        try {
          r = await _readList(startNew: !onlyIfReadable);
        } on Object catch (e) {
          debugPrint('Noted: reading folder-access.json failed: $e');
          return false;
        }
        if (r.refused) return false;
        final next = change(List.of(r.entries));
        if (_sameEntries(next, r.entries) && r.bytes != null) {
          _entries = next;
          return true;
        }
        final bytes = utf8.encode(jsonEncode({'version': 1, 'folders': [for (final x in next) x.toJson()]}));
        final tmp = File('${file.path}.${_hex(8)}.tmp');
        try {
          await file.parent.create(recursive: true);
          await tmp.writeAsBytes(bytes, flush: true);
          if (r.bytes == null) {
            if (!await publishExclusive(tmp, file.path)) {
              await _dropTemp(tmp, Uint8List.fromList(bytes));
              continue; // it appeared meanwhile
            }
          } else {
            final res = await replaceIfUnchanged(tmp, file.path, r.bytes);
            if (res.outcome != ReplaceOutcome.replaced) {
              await _dropTemp(tmp, Uint8List.fromList(bytes));
              continue;
            }
          }
        } on Object catch (e) {
          debugPrint('Noted: writing folder-access.json failed: $e');
          await _dropTemp(tmp, Uint8List.fromList(bytes));
          return false;
        }
        _entries = next;
        return true;
      }
      return false;
    });
  }

  bool _sameEntries(List<CloudFolderEntry> a, List<CloudFolderEntry> b) => jsonEncode([for (final x in a) x.toJson()]) == jsonEncode([for (final x in b) x.toJson()]);

  // Reads the list. A missing file is an empty list. An unreadable one is
  // copied to `folder-access-unreadable-<16 hex>.json` (read back equal) and,
  // with [startNew], a new list is started against its bytes (R5.3).
  Future<_Read> _readList({bool startNew = true}) async {
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      return const _Read([], null);
    } on FileSystemException {
      _listState = CloudListState.unavailable;
      return const _Read([], null, refused: true);
    }
    final parsed = _parse(bytes);
    if (parsed != null) return _Read(parsed, bytes);
    if (!startNew) return _Read(const [], bytes, refused: true);
    final copy = File('${file.parent.path}$_sep'
        'folder-access-unreadable-${_hex(8)}.json');
    final tmp = File('${copy.path}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (!await publishExclusive(tmp, copy.path) || !_bytesEqual(await copy.readAsBytes(), bytes)) {
        await _dropTemp(tmp, bytes);
        _listState = CloudListState.unavailable;
        return _Read(const [], bytes, refused: true);
      }
    } on Object {
      await _dropTemp(tmp, bytes);
      _listState = CloudListState.unavailable;
      return _Read(const [], bytes, refused: true);
    }
    // Copied: a new list, against the unreadable bytes.
    final fresh = Uint8List.fromList(utf8.encode(jsonEncode({'version': 1, 'folders': <Object>[]})));
    final t2 = File('${file.path}.${_hex(8)}.tmp');
    try {
      await t2.writeAsBytes(fresh, flush: true);
      final res = await replaceIfUnchanged(t2, file.path, bytes);
      if (res.outcome != ReplaceOutcome.replaced) {
        await _dropTemp(t2, fresh);
        _listState = CloudListState.unavailable;
        return _Read(const [], bytes, refused: true);
      }
    } on Object {
      await _dropTemp(t2, fresh);
      _listState = CloudListState.unavailable;
      return _Read(const [], bytes, refused: true);
    }
    _listState = CloudListState.restarted;
    return _Read(const [], fresh);
  }

  // The entries of [bytes], or null if it isn't a version 1 list.
  List<CloudFolderEntry>? _parse(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map || j['version'] != 1 || j['folders'] is! List) return null;
      final out = <CloudFolderEntry>[];
      for (final f in j['folders'] as List) {
        if (f is! Map || f['path'] is! String || f['bookmark'] is! String) return null;
        CloudProbe? probe;
        final p = f['probe'];
        if (p is Map && p['name'] is String && p['nonce'] is String) {
          probe = CloudProbe(p['name'] as String, p['nonce'] as String);
        }
        out.add(CloudFolderEntry(f['path'] as String, f['bookmark'] as String, probe));
      }
      return out;
    } on FormatException {
      return null;
    }
  }

  /// Stops the roots this registered and detaches from the channel.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final real in _registered.values) {
      unregisterCoordinator(real);
    }
    _registered.clear();
    _channel.onEvent = null;
    _checkingNow.dispose();
    super.dispose();
  }
}

Future<bool> _publishProbe(File tmp, String target) => publishExclusive(tmp, target);
