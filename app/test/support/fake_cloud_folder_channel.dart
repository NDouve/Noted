// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:noted/src/icloud_folders.dart';

/// How the fake answers `coordinate`.
enum CoordinateMode {
  /// `go` at once.
  go,

  /// No answer (the platform is slow); [FakeCloudFolderChannel.answer] sends
  /// one later.
  silent,

  /// `pending` with the paths of the call.
  pending,

  /// `failed`.
  failed,
}

/// One iCloud version of a file, as the fake keeps it.
class FakeVersion {
  FakeVersion(this.id, this.bytes);

  final String id;
  final List<int> bytes;
  bool resolved = false;

  /// `versions` reports this one as `{id, error}` (the copy failed).
  bool copyFails = false;

  /// The version has no identifier: `versions` and `withVersions` report it as
  /// `""`, and `resolveVersion` can't name it.
  bool nilIdentifier = false;
}

/// A stand-in for the Swift side of `noted/cloud_folder`: it keeps the
/// bookmarks it made, answers each method as the Swift file documents, and
/// records every call.
class FakeCloudFolderChannel implements CloudFolderChannel {
  FakeCloudFolderChannel({this.platformIsIos = false});

  final bool platformIsIos;

  /// Every call Dart made: method and arguments.
  final List<({String method, Map<String, Object?> args})> calls = [];

  Future<void> Function(String method, Map<Object?, Object?> args)? _handler;

  final Map<String, String> _bookmarks = {}; // bookmark -> real path
  int _counter = 0;

  /// Paths (real) that report `isUbiquitousItemKey` true.
  final Set<String> ubiquitous = {};

  /// Bookmarks that resolve as stale.
  final Set<String> stale = {};

  /// Bookmarks that resolve to another folder than the one they were made for.
  final Map<String, String> movedTo = {};

  /// Bookmarks whose resolve fails.
  final Set<String> failing = {};

  /// What `pick` returns (a real path); null is a cancelled pick.
  String? picked;

  /// `pick` fails with the error code `notUbiquitous`.
  bool pickRefused = false;

  /// Bookmarks whose resolve says access could not be started.
  final Set<String> noAccess = {};

  /// `pick` fails with this error code (other than `notUbiquitous`).
  String? pickErrorCode;

  /// `coordinate` never returns (the platform hangs).
  bool coordinateHangs = false;

  /// `bookmark` fails.
  bool bookmarkFails = false;

  /// `coordinate` itself throws (the channel is unavailable).
  bool coordinateThrows = false;

  CoordinateMode mode = CoordinateMode.go;

  /// Holds that are open: ids answered `go` and not yet `done` or `cancel`ed.
  final Set<int> held = {};

  /// Ids and paths of the calls so far.
  final Map<int, List<Map<Object?, Object?>>> intentsById = {};

  /// Called with each `coordinate` (id, intents) before it answers.
  void Function(int id, List<Map<Object?, Object?>> intents)? onCoordinate;

  // -- Versions (R5.8): associated with file paths --------------------------

  final Map<String, List<FakeVersion>> _versions = {};
  int _versionCounter = 0;
  final Random _random = Random.secure();

  /// `versions` throws (the platform could not be reached).
  bool versionsFails = false;

  /// `resolveVersion` throws the error code `coordination`.
  bool resolveFails = false;

  /// `resolveVersion` marks the version resolved, then throws `coordination`
  /// (a call that timed out after it resolved).
  bool resolveThenThrows = false;

  /// Run by `resolveVersion` before it marks the version resolved (it may write
  /// files: a daemon or another device acting inside the call).
  void Function(String path, String id)? onResolve;

  /// A `resolveVersion` with no version temp of the file, in its folder,
  /// holding the version's bytes is recorded in [resolveViolations] (a throw
  /// would be swallowed by the landing's catch).
  bool tempHeldAtResolve = false;

  /// The resolves made while no version temp held the version's bytes.
  final List<String> resolveViolations = [];

  // A temp that can not be read at the moment (a sharing violation) is not
  // proof that none holds the bytes: it counts as holding them.
  bool _tempHolds(String path, List<int> bytes) {
    final f = File(path);
    final prefix = '.${f.uri.pathSegments.last}.noted-version-';
    final List<FileSystemEntity> listed;
    try {
      listed = f.parent.listSync(followLinks: false);
    } on FileSystemException {
      return true;
    }
    for (final e in listed) {
      final n = e.uri.pathSegments.last;
      if (e is! File || !n.startsWith(prefix) || !n.endsWith('.tmp')) continue;
      for (var attempt = 0; ; attempt++) {
        try {
          final have = e.readAsBytesSync();
          if (have.length == bytes.length && [for (var i = 0; i < have.length; i++) have[i] == bytes[i]].every((x) => x)) return true;
          break;
        } on FileSystemException {
          if (!e.existsSync()) break; // removed meanwhile: not a holder
          if (attempt >= 20) return true;
          sleep(const Duration(milliseconds: 5));
        }
      }
    }
    return false;
  }

  /// A `move` or `delete` intent on a file with unresolved versions is answered
  /// by `pending` instead of `go`, as Swift does (R5.8).
  bool gateVersions = true;

  /// `withVersions` throws (the platform could not be reached).
  bool withVersionsFails = false;

  /// The paths of each `withVersions` call.
  final List<List<String>> withVersionsCalls = [];

  /// Run after `withVersions` computed its answer, before it is returned (the
  /// versions can change between the answer and what is done with it).
  void Function(List<String> paths)? onWithVersions;

  /// The ids the platform reports for a version change on every call (the
  /// strings differ, the version is the same): only `known` matching by
  /// identity filters them.
  bool idsChange = false;
  int _idCalls = 0;

  String _reportedId(FakeVersion v) => v.nilIdentifier ? '' : (idsChange ? '${v.id}#${++_idCalls}' : v.id);

  // The match of `resolveVersion`: the reported string, or the version it names;
  // "" matches only a version with no identifier.
  bool _matches(FakeVersion v, String id) =>
      id.isEmpty ? v.nilIdentifier : (!v.nilIdentifier && (id == v.id || id.startsWith('${v.id}#')));

  // A list of strings in [args] under [key], none when absent; anything else is
  // an `arguments` error, as in Swift.
  List<String> _stringList(Map<String, Object?> args, String key, String what) {
    if (!args.containsKey(key)) {
      if (what == 'items') throw PlatformException(code: 'arguments', message: what);
      return const [];
    }
    final v = args[key];
    if (v is! List || v.any((x) => x is! String)) throw PlatformException(code: 'arguments', message: what);
    return v.cast<String>();
  }

  /// Called after `versions` made the temps of a call.
  void Function(String path, List<String> temps)? onVersions;

  static String _vkey(String path) {
    final f = File(path);
    final parent = f.parent;
    final dir = parent.existsSync() ? parent.resolveSymbolicLinksSync() : parent.absolute.path;
    return '$dir/${f.uri.pathSegments.last}'.replaceAll(r'\', '/').toLowerCase();
  }

  /// Gives the file at [path] an unresolved version holding [bytes]; its id.
  String addVersion(String path, List<int> bytes) {
    final v = FakeVersion('v${++_versionCounter}', bytes);
    (_versions[_vkey(path)] ??= []).add(v);
    return v.id;
  }

  /// The versions of [path], resolved or not.
  List<FakeVersion> versionsOf(String path) => List.unmodifiable(_versions[_vkey(path)] ?? const []);

  /// The versions of [path] that are not resolved.
  List<FakeVersion> unresolvedOf(String path) => [for (final v in versionsOf(path)) if (!v.resolved) v];

  /// The files with unresolved versions anywhere under the files [paths] name.
  bool hasUnresolved(String path) => unresolvedOf(path).isNotEmpty;

  List<String> get methods => [for (final c in calls) c.method];

  Iterable<({String method, Map<String, Object?> args})> callsOf(String m) =>
      calls.where((c) => c.method == m);

  @override
  set onEvent(Future<void> Function(String method, Map<Object?, Object?> args)? handler) =>
      _handler = handler;

  /// Sends an event to Dart, as Swift would.
  Future<void> emit(String method, [Map<Object?, Object?> args = const {}]) async =>
      _handler?.call(method, args);

  /// The answer to a silent `coordinate`.
  Future<void> answer(int id, String method, [List<String> paths = const []]) =>
      emit(method, {'id': id, if (paths.isNotEmpty) 'paths': paths});

  /// A bookmark for [path], as `bookmark` makes it.
  String bookmarkFor(String path) {
    final b = 'bm${++_counter}';
    _bookmarks[b] = Directory(path).resolveSymbolicLinksSync();
    return b;
  }

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? args]) async {
    final a = args ?? const <String, Object?>{};
    calls.add((method: method, args: a));
    switch (method) {
      case 'reset':
        held.clear();
        return null;
      case 'pick':
        if (pickRefused) throw PlatformException(code: 'notUbiquitous');
        if (pickErrorCode != null) throw PlatformException(code: pickErrorCode!, message: 'it broke');
        final p = picked;
        if (p == null) return null;
        final real = Directory(p).resolveSymbolicLinksSync();
        return {'path': real, 'bookmark': bookmarkFor(real)};
      case 'bookmark':
        if (bookmarkFails) throw PlatformException(code: 'bookmark');
        return bookmarkFor(a['path']! as String);
      case 'resolve':
        final b = a['bookmark']! as String;
        if (failing.contains(b) || !_bookmarks.containsKey(b)) {
          throw PlatformException(code: 'resolve');
        }
        return {'path': movedTo[b] ?? _bookmarks[b], 'stale': stale.contains(b), 'access': !noAccess.contains(b)};
      case 'isUbiquitous':
        final p = a['path']! as String;
        return ubiquitous.contains(Directory(p).existsSync() ? Directory(p).resolveSymbolicLinksSync() : p);
      case 'stopAccess':
        return null;
      case 'coordinate':
        if (coordinateThrows) throw PlatformException(code: 'unavailable');
        if (coordinateHangs) return Completer<Object?>().future;
        final id = a['id']! as int;
        final intents = [for (final i in (a['intents']! as List)) (i as Map).cast<Object?, Object?>()];
        intentsById[id] = intents;
        onCoordinate?.call(id, intents);
        if (mode == CoordinateMode.go && gateVersions) {
          final withVersions = [
            for (final i in intents)
              if ((i['kind'] == 'move' || i['kind'] == 'delete') && hasUnresolved(i['path']! as String)) i['path']! as String,
          ];
          if (withVersions.isNotEmpty) {
            unawaited(Future<void>(() => emit('pending', {'id': id, 'paths': withVersions})));
            return null;
          }
        }
        switch (mode) {
          case CoordinateMode.go:
            held.add(id);
            unawaited(Future<void>(() => emit('go', {'id': id})));
          case CoordinateMode.silent:
            break;
          case CoordinateMode.pending:
            unawaited(Future<void>(() => emit('pending', {'id': id, 'paths': [for (final i in intents) i['path']]})));
          case CoordinateMode.failed:
            unawaited(Future<void>(() => emit('failed', {'id': id})));
        }
        return null;
      case 'versions':
        if (versionsFails) throw PlatformException(code: 'versions');
        final path = a['path']! as String;
        final known = _stringList(a, 'known', 'known');
        final f = File(path);
        final out = <Map<String, Object?>>[];
        final temps = <String>[];
        for (final v in unresolvedOf(path)) {
          // As Swift does: a known version is not copied; the known match runs
          // before the nil identifier is looked at.
          final k = known.where((x) => _matches(v, x)).firstOrNull;
          if (k != null) {
            out.add({'id': k, 'known': true});
            continue;
          }
          if (v.nilIdentifier) {
            out.add({'id': '', 'error': 'The version has no identifier.'});
            continue;
          }
          if (v.copyFails) {
            out.add({'id': _reportedId(v), 'error': 'The copy failed.'});
            continue;
          }
          // As Swift does: 16 random hex, created exclusively.
          late String tmp;
          while (true) {
            final hex = [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
            tmp = '${f.parent.path}${Platform.pathSeparator}.${f.uri.pathSegments.last}.noted-version-$hex.tmp';
            try {
              File(tmp).createSync(exclusive: true);
              break;
            } on FileSystemException {
              if (!File(tmp).existsSync()) rethrow;
            }
          }
          File(tmp).writeAsBytesSync(v.bytes, flush: true);
          temps.add(tmp);
          out.add({'id': _reportedId(v), 'tmpPath': tmp});
        }
        onVersions?.call(path, temps);
        return out;
      case 'withVersions':
        withVersionsCalls.add([for (final i in (a['items'] as List? ?? const [])) '${(i as Map)['path']}']);
        if (withVersionsFails) throw PlatformException(code: 'withVersions');
        final items = a['items'];
        if (items is! List) throw PlatformException(code: 'arguments', message: 'items');
        final answer = <String, Object?>{};
        for (final item in items) {
          if (item is! Map || item['path'] is! String) throw PlatformException(code: 'arguments', message: 'items');
          final wanted = _stringList(item.cast<String, Object?>(), 'known', 'items');
          final versions = unresolvedOf(item['path']! as String);
          final fresh = [
            for (final v in versions)
              if (!wanted.any((x) => _matches(v, x))) _reportedId(v),
          ];
          final shrank = wanted.any((x) => !versions.any((v) => _matches(v, x)));
          if (fresh.isNotEmpty || shrank) answer[item['path']! as String] = {'fresh': fresh, 'shrank': shrank};
        }
        onWithVersions?.call(withVersionsCalls.last);
        return answer;
      case 'resolveVersion':
        if (resolveFails) throw PlatformException(code: 'coordination');
        final id = a['id']! as String;
        if (id.isEmpty) return false; // nothing names a version with no identifier
        final rpath = a['path']! as String;
        for (final v in unresolvedOf(rpath)) {
          if (_matches(v, id)) {
            if (tempHeldAtResolve && !_tempHolds(rpath, v.bytes)) resolveViolations.add('$rpath $id');
            onResolve?.call(rpath, id);
            v.resolved = true;
            if (resolveThenThrows) throw PlatformException(code: 'coordination');
            return true;
          }
        }
        return false;
      case 'done':
      case 'cancel':
        held.remove(a['id']);
        return null;
    }
    return null;
  }
}
