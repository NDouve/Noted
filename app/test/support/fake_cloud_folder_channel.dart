// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

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

  /// `versions` throws (the platform could not be reached).
  bool versionsFails = false;

  /// `resolveVersion` throws the error code `coordination`.
  bool resolveFails = false;

  /// A `move` or `delete` intent on a file with unresolved versions is answered
  /// by `pending` instead of `go`, as Swift does (R5.8).
  bool gateVersions = true;

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
        final f = File(path);
        final out = <Map<String, Object?>>[];
        final temps = <String>[];
        for (final v in unresolvedOf(path)) {
          if (v.copyFails) {
            out.add({'id': v.id, 'error': 'The copy failed.'});
            continue;
          }
          final hex = [for (var i = 0; i < 8; i++) (_versionCounter++ * 37 % 256).toRadixString(16).padLeft(2, '0')].join();
          final tmp = '${f.parent.path}${Platform.pathSeparator}.${f.uri.pathSegments.last}.noted-version-$hex.tmp';
          File(tmp).writeAsBytesSync(v.bytes, mode: FileMode.writeOnly, flush: true);
          temps.add(tmp);
          out.add({'id': v.id, 'tmpPath': tmp});
        }
        onVersions?.call(path, temps);
        return out;
      case 'resolveVersion':
        if (resolveFails) throw PlatformException(code: 'coordination');
        final id = a['id']! as String;
        for (final v in unresolvedOf(a['path']! as String)) {
          if (v.id == id) {
            v.resolved = true;
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
