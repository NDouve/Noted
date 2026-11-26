// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Reload equivalence for an iCloud folder (cloud parity step 7, design R5.13),
// and the Windows-folder test.
//
// A notebook on a temp folder registered as an iCloud root (the fake channel,
// with a coordinator that records every call and marks the zone its body runs
// in), a fake daemon and the closed-app server (`ClosedWriter`, the server's
// only page writer). Seeded sequences of app edits, page creation, daemon
// edits, conflict versions, evictions (a `.<name>.icloud` stub, as the dataless
// seam sees it on Windows), materialisations, leftovers of crashed replaces
// (some with versions: R-4), server writes and restarts. One kill is planned per
// sequence, at an R5.11 step or a primitive hook: at that point the folders and
// the app's data are copied, and when the step is over the live notebook is
// dropped and the copy put back (a crash leaves exactly what was on disk at
// that moment), then a new launch.
//
// Every box added by anyone carries a marker in its snapshot text. What is
// checked at the end of each sequence, after the daemon has materialised every
// stub and the app has landed every version:
//  1. a fresh notebook loaded from disk lists the same pages, copies and
//     unreadable files as the live one, and shows the same boxes on each page;
//  2. every marker the sequence made durable (a daemon write, a server write,
//     a conflict version, an app edit whose save returned with no crash during
//     it) is in some file of the folder or of the app's recovery store: every
//     version is a page or a listed copy; no version is left unresolved;
//  3. every page that was known is listed: nothing treated as absent;
//  4. no dataless file (a stub with no file) was read, written or published
//     onto by the app (an IO seam, `IOOverrides`);
//  5. the coordinator was called once per outermost call (no call made inside
//     another's body) and every write of the app in the folder happened inside
//     one (the zone value), except temp files; the same seam records it. The
//     primitives' FFI calls bypass the seam and are covered by the hook tests.
//
// Seeds 1-40 are fixed; `--dart-define=ICLOUD_SEEDS=200` adds more.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessKey, debugDatalessPaths, debugMarkDataless, debugUnmarkDataless;
import 'package:noted_core/src/storage/folder_walk.dart' show debugAppleMode;

// The server's closed writer, as the other reload-equivalence tests use it
// (they run the whole server in a child process; this is its page writer).
// ignore: avoid_relative_lib_imports
import '../../packages/noted_mcp/lib/src/closed_writer.dart';

import 'support/busy_retry.dart';
import 'support/icloud_world.dart';
import 'support/io_trace.dart' show IoTrace, TracingIoOverrides;
import 'support/notebook_folder.dart' show deleteTestFolder, inFlightOf;

const int _extraSeeds = int.fromEnvironment('ICLOUD_SEEDS', defaultValue: 0);
const int _fixedSeeds = 40;
const int _steps = 26;

/// The kill points: R5.11's steps and the primitives' hooks.
const List<String> _killKinds = [
  'coordinate', // the call sent, no go yet
  'versionTemp', // a version copied to a temp, not published
  'landing:copied',
  'landing:published', // published, not verified
  'landing:verified',
  'landing:resolved',
  'replace:beforeMoveAside',
  'replace:beforePublish',
  'replace:beforeAsideDelete',
  'replace:beforeFinalCheck',
  'saveNew:beforePublish',
  'server:beforePublish',
  'server:beforeAsideDelete',
  'landing:equal', // a version equal to the file, not yet resolved
  'landing:reread', // resolved, the holder not yet read again
];

/// What each kill kind needs to happen at least once in a sequence.
const Map<String, List<String>> _feeders = {
  'coordinate': ['appEdit'],
  'versionTemp': ['daemonConflict', 'appCheck'],
  'landing:copied': ['daemonConflict', 'appCheck'],
  'landing:published': ['daemonConflict', 'appCheck'],
  'landing:verified': ['daemonConflict', 'appCheck'],
  'landing:resolved': ['daemonConflict', 'appCheck'],
  'landing:equal': ['daemonEqualConflict', 'appCheck'],
  'landing:reread': ['daemonConflict', 'daemonConflict', 'daemonConflict'],
  'replace:beforeMoveAside': ['appEdit', 'appEdit'],
  'replace:beforePublish': ['appEdit', 'appEdit'],
  'replace:beforeAsideDelete': ['appEdit', 'appEdit'],
  'replace:beforeFinalCheck': ['appEdit', 'appEdit'],
  'saveNew:beforePublish': ['appCreate'],
  'server:beforePublish': ['serverWrite'],
  'server:beforeAsideDelete': ['serverWrite'],
};

final Set<String> _killed = {};
final Set<int> _ranSeeds = {};

/// A page store whose primitives call the sequence's kill points.
class _Store extends PageStore {
  _Store(super.directory, this.sim);

  final _Sim sim;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
    void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: () {
        sim.replaceTarget = pathFor(page.id);
        sim.point('replace:beforeMoveAside');
        beforeMoveAside?.call();
      },
      afterRead: afterRead,
      beforePublish: () {
        sim.note('ffiPublish', pathFor(page.id), null, track: false);
        sim.point('replace:beforePublish');
        beforePublish?.call();
      },
      beforeRestore: () {
        sim.note('ffiRestore', pathFor(page.id), null, track: false);
        beforeRestore?.call();
      },
      onPublishStamp: onPublishStamp,
      beforeAsideDelete: (p) async {
        sim.point('replace:beforeAsideDelete');
        await beforeAsideDelete?.call(p);
      },
      beforeFinalCheck: (p) async {
        sim.point('replace:beforeFinalCheck');
        await beforeFinalCheck?.call(p);
      },
      afterFinalRead: afterFinalRead,
    );
  }

  @override
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
    void Function(FileStamp?)? onPublishStamp,
  }) {
    return super.saveNewText(
      page,
      text,
      beforePublish: () async {
        sim.note('ffiPublish', pathFor(page.id), null, track: false);
        sim.point('saveNew:beforePublish');
        await beforePublish?.call();
      },
      onPublishStamp: onPublishStamp,
    );
  }
}

/// Whether the body of a coordinated call is still running.
class _Flag {
  bool on = true;
}

/// The pass-through coordinator: the real channel coordinator underneath, each
/// call counted, its body run in a zone that says "coordinated".
class _Coord implements StorageCoordinator {
  _Coord(this.inner, this.sim);

  final StorageCoordinator inner;
  final _Sim sim;

  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) {
    sim.coordCalls++;
    if ((Zone.current[#coordinated] as _Flag?)?.on == true) {
      sim.violations.add('a coordinated call inside another: ${write.intents}');
    }
    sim.point('coordinate');
    return inner.coordinate<T>(write, () {
      // The flag is cleared when the body is over: a task the body left behind
      // does not count as coordinated.
      final flag = _Flag();
      return runZoned(
        body,
        zoneValues: {#coordinated: flag},
      ).whenComplete(() => flag.on = false);
    });
  }
}

/// Records the writes and reads of the app in the folder, through the `File`
/// seam (`IOOverrides`), with the zone each ran in.
class _Recorder extends IoTrace {
  _Recorder(this.sim);

  final _Sim sim;

  @override
  int begin(String op, String path, {String? to}) {
    try {
      sim.io(op, path, to);
    } catch (_) {
      sim.note(op, path, to, refused: true);
      rethrow;
    }
    return sim.note(op, path, to);
  }

  @override
  void end(int id, [Object? error]) => sim.ended(id);

  @override
  void failed(int id, String op, String path, Object error, {String? to}) =>
      sim.ended(id, error);
}

/// The harness itself failed (not the app): a snapshot that could not be taken.
final class _HarnessError implements Exception {
  _HarnessError(this.message);
  final String message;
  @override
  String toString() => message;
}

final class _Snapshot {
  _Snapshot(this.dir, this.resolved);

  final Directory dir;
  final Map<String, bool> resolved; // version id -> resolved
}

class _Sim {
  _Sim(this.seed) : rnd = Random(seed * 7919 + 13) {
    killKind = _killKinds[(seed - 1) % _killKinds.length];
    killNth = 1 + rnd.nextInt(3);
  }

  final int seed;
  final Random rnd;
  final IcloudWorld w = IcloudWorld();
  late String killKind;
  late int killNth;
  int _killSeen = 0;
  bool armed = false;
  bool killDone = false;
  _Snapshot? snapshot;
  late Directory snapRoot;

  late IcloudFolders f;
  late Notebook nb;

  /// What the sequence claims is kept: marker -> what it was.
  final Map<String, String> durable = {};
  final Set<String> pageIds = {};
  // What the daemon kept of each page it evicted; a page is evicted while its stub is there.
  final Map<String, String> evictedText = {};
  // The evictions whose first read has not come yet.
  final Set<String> evictExcuse = {};

  // t3a (R-2): the files evicted through the dataless seam: present, not
  // downloaded. [evictMode] says how the pinned scenario evicts: `stub` (the
  // file goes and its stub stands) or `dataless` (the file stays).
  final Set<String> seamed = {};
  String evictMode = 'stub';
  String? consumedPath; // the page with the consumed copy
  String? consumedId;
  String? consumedBefore; // its text before the merge

  void unseam(String path) {
    if (seamed.remove(path)) debugUnmarkDataless(path);
  }

  // The app checks `isDataless` and then reads, and the file can go in between
  // (a job waiting for the folder's lock): the first read of a file after its
  // eviction is excused, the next is not.
  bool _justEvicted(String p) => evictExcuse.remove(_norm(p));

  Map<String, String> get evicted => {
    for (final e in evictedText.entries)
      if (File(_stubOf(e.key)).existsSync() || seamed.contains(e.key)) e.key: e.value,
  };
  final List<({String path, String id})> versions = [];
  final Map<String, ({String path, String id})> versionOfMarker = {};
  final Set<String> reportedMissing = {};
  final List<String> violations = [];
  final List<String> log = [];

  // What the app, the daemon, the snapshot and the server did to the world's
  // files, in order (the last [_trailKeep] lines), and the operations started
  // and not finished yet: when a marker is lost, what touched its file is in
  // the failure's text. It sees what goes through `IOOverrides` (`File` and
  // `Directory` calls) and the primitives' FFI publishes and restores (noted by
  // `_Store`'s hooks); it does not see the FFI calls of `_keepAsConflictCopy`,
  // `_keepForDelete` and the sweep's `_sweepNamed`, nor `stat`, `exists`,
  // `typeSync`, `length`, `setLastModified`, `Directory.create`, writes through
  // a `RandomAccessFile` or listings of a plain directory.
  final Queue<({int id, String line})> trail = Queue();
  final Map<int, String> inflight = {};
  final Stopwatch _clock = Stopwatch()..start();
  int _noteId = 0;
  static const int _trailKeep = 6000;
  String? _rootNorm, _driveNorm;

  /// [p] relative to the world's root or to its drive (the drive is resolved
  /// through links: 8.3 temp names on Windows, `/private/var` on macOS), else
  /// null.
  String? _relOf(String p) {
    _rootNorm ??= _norm(w.root.path);
    _driveNorm ??= _norm(w.drive.path);
    final n = _norm(p);
    if (n.startsWith('$_driveNorm/')) return 'Drive${p.substring(_driveNorm!.length)}';
    if (n.startsWith('$_rootNorm/')) return p.substring(_rootNorm!.length + 1);
    return null;
  }

  // Outside the world: the last two segments only.
  String _short(String p) {
    final parts = p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    return parts.length <= 2 ? p : '.../${parts.sublist(parts.length - 2).join('/')}';
  }

  String _show(String p) => _relOf(p)?.replaceAll(r'\', '/') ?? _short(p);

  void _add(int id, String line) {
    trail.add((id: id, line: line));
    while (trail.length > _trailKeep) {
      trail.removeFirst();
    }
  }

  /// Notes an operation on [path]; returns its id. [track] false: not an
  /// operation with an end (an FFI call, made at once).
  int note(String op, String path, String? to, {bool track = true, bool refused = false}) {
    final id = ++_noteId;
    if (Zone.current[#untraced] == true) return id;
    if (_relOf(path) == null && !(to != null && _relOf(to) != null)) return id;
    final tag = Zone.current[#life];
    final by = Zone.current[#who];
    final who = by != null
        ? '$by'
        : Zone.current[#exempt] == true
        ? 'daemon'
        : tag == null
        ? 'test'
        : tag != life
        ? 'ZOMBIE(life $tag, now $life)'
        : 'app(life $tag)';
    final line =
        '#$id ${_clock.elapsedMilliseconds}ms $phase $who $op ${_show(path)}${to == null ? '' : ' -> ${_show(to)}'}${refused ? ' (refused)' : ''}';
    _add(id, line);
    if (track && !refused) inflight[id] = line;
    if (!refused && (_writeOps.contains(op) || op == 'ffiPublish' || op == 'ffiRestore')) {
      final app = by == null && Zone.current[#exempt] != true && tag != null;
      final stack = app ? _appFrames() : null;
      for (final p in [path, ?to]) {
        final key = _pageKey(p);
        if (key == null) continue;
        lastWrite[key] = line;
        if (stack != null) lastAppWrite[key] = '$line\n$stack';
      }
    }
    return id;
  }

  /// The last write to each page file (by its id): any writer, and the app's
  /// own with the Dart stack of the call (only the app's and the packages'
  /// frames, kept for writes only so the trail stays cheap).
  final Map<String, String> lastWrite = {};
  final Map<String, String> lastAppWrite = {};

  /// The page id a world path is the page file of, else null (a temp, an aside
  /// or a verified copy beside it is no page write).
  String? _pageKey(String p) {
    if (_relOf(p) == null) return null;
    final name = _base(p);
    if (!name.endsWith('.canvas')) return null;
    final key = name.split('.').first;
    return key.length < 8 ? null : key;
  }

  static final RegExp _appFrame = RegExp(r'^#\d+\s+(\S+)\s+\((package:noted[^)]*)\)');

  static String _appFrames() {
    final out = <String>[];
    for (final line in StackTrace.current.toString().split('\n')) {
      final m = _appFrame.firstMatch(line);
      if (m == null || m.group(2)!.contains('io_trace.dart')) continue;
      final frame = '      ${m.group(1)} (${m.group(2)})';
      if (!out.contains(frame)) out.add(frame);
      if (out.length == 12) break;
    }
    return out.isEmpty ? '      (no application frames)' : out.join('\n');
  }

  void ended(int id, [Object? error]) {
    if (inflight.remove(id) == null) return;
    _add(id, 'end #$id ${_clock.elapsedMilliseconds}ms ${error == null ? 'ok' : 'failed'}');
  }

  /// The page file the last replace was about (for the copy-gap seam).
  String? replaceTarget;

  /// The trail must see the drive's files whatever form the temp folder's name
  /// takes (8.3 names, links): a known read of a page file has to appear.
  void _checkTrail() {
    final files = pageFiles();
    if (files.isEmpty) throw StateError('the trail self-check found no page file');
    readText(files.first);
    if (!trail.any((t) => t.line.contains(' readSync Drive/') && t.line.contains(_base(files.first.path)))) {
      throw StateError(
        'the IO trail does not see the drive (${w.drive.path} under ${w.root.path}): ${trail.map((t) => t.line).take(5).join(' | ')}',
      );
    }
  }

  /// The trail lines that name any of [files] (page file names), with the
  /// `end` lines of those operations.
  List<String> trailOf(Iterable<String> files, {int last = 60}) {
    final names = {
      for (final f in files) f.replaceAll(r'\', '/').split('/').last.split('.').first,
    }..removeWhere((n) => n.length < 8);
    if (names.isEmpty) return const [];
    final ids = <int>{
      for (final t in trail)
        if (!t.line.startsWith('end ') && names.any(t.line.contains)) t.id,
    };
    final hits = [
      for (final t in trail)
        if (ids.contains(t.id)) t.line,
    ];
    return hits.length <= last ? hits : hits.sublist(hits.length - last);
  }

  int coordCalls = 0;
  int _segChannel = 0;
  int _segCoord = 0;
  int _counter = 0;
  bool _launched = false;
  String phase = 'start';

  String get drivePath => w.drive.path;
  String get appPath => '${w.root.path}/app';

  // -- Kill points ------------------------------------------------------------

  void point(String kind) {
    if (Zone.current[#exempt] == true && !kind.startsWith('server:')) return;
    if (armed &&
        !killDone &&
        kind == killKind &&
        snapshot == null &&
        ++_killSeen >= killNth) {
      killDone = true;
      snapshot = _take();
      _killed.add(kind);
      log.add('kill planned at $kind');
      if (inflight.isNotEmpty) {
        log.add('in flight at the snapshot: ${inflight.values.join(' | ')}');
      }
    }
  }

  _Snapshot _take() {
    return runZoned(() {
      final dir = Directory('${snapRoot.path}/snap${_counter++}')
        ..createSync(recursive: true);
      try {
        _copyTree(w.root, dir, skip: {});
      } on _HarnessError catch (e) {
        harnessError ??= e.message;
      }
      return _Snapshot(dir, {
        for (final v in versions)
          for (final x in w.channel.versionsOf(v.path)) x.id: x.resolved,
      });
    }, zoneValues: {#exempt: true, #who: 'snapshot'});
  }

  /// A test seam: called between a folder's listing and its copies (a rename
  /// of the app's, in flight on an IO thread, lands in this gap).
  void Function(Directory from, List<FileSystemEntity> listed)? copyGap;

  /// Whether a snapshot looks again at a folder when a file it listed went
  /// away while it was copied. A rename is atomic: a crash keeps the file under
  /// one of its two names. False only for the test that shows what the gap does.
  bool faithfulSnapshot = true;

  /// A test seam: called before each file copy (throw a [FileSystemException]
  /// to make the copy fail).
  void Function(File e, String name)? copyFault;

  /// A snapshot that could not be taken: the seed fails with it at the end of
  /// the step (the throw inside the app's kill point could be swallowed).
  String? harnessError;

  void _checkHarness() {
    final e = harnessError;
    if (e != null) throw StateError('seed $seed: harness error, $e; steps: ${log.join(', ')}');
  }

  void _said(String what, String text) {
    log.add('$what: $text');
    debugPrint('[snapshot-race] seed $seed $killKind: $what: $text');
  }

  void _copyTree(Directory from, Directory to, {required Set<String> skip, String what = 'snapshot'}) {
    final copied = <String>{};
    final first = <String>{};
    var vanished = 0;
    void copyOne(File e, String name) {
      for (var attempt = 0; ; attempt++) {
        try {
          copyFault?.call(e, name);
          e.copySync('${to.path}/$name');
          return;
        } on FileSystemException {
          if (_isTemp(name)) return; // a temp that went away is no loss
          if (!e.existsSync()) {
            vanished++;
            _said(what, '$name vanished while copied');
            return;
          }
          // Still there: held by someone for a moment (a sharing violation).
          // A copy that never succeeds is not a crash state: the snapshot
          // would lack a file the app never lost. A harness error.
          if (attempt >= 40) {
            _said(what, '$name busy, not copied');
            throw _HarnessError('$what: $name could not be copied after ${attempt + 1} attempts (busy)');
          }
          sleep(const Duration(milliseconds: 10));
        }
      }
    }

    final listed = from.listSync(followLinks: false);
    copyGap?.call(from, listed);
    for (final e in listed) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      first.add(name);
      if (skip.contains(name)) continue;
      if (e is Directory) {
        final d = Directory('${to.path}/$name')..createSync();
        _copyTree(e, d, skip: {}, what: what);
      } else if (e is File) {
        copyOne(e, name);
        copied.add(name);
      }
    }
    // A rename is atomic: a crash keeps the file under one of its names. For
    // each file that vanished, the name it moved to is looked for: only names
    // that were not in the first listing, no more than the files that went,
    // and not a content already copied (a rename of a file that was copied).
    for (var pass = 0; pass < 5 && vanished > 0 && faithfulSnapshot; pass++) {
      final have = {
        for (final c in to.listSync(followLinks: false))
          if (c is File) base64Encode(c.readAsBytesSync()),
      };
      for (final e in from.listSync(followLinks: false)) {
        if (vanished <= 0) break;
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is! File || first.contains(name) || copied.contains(name) || skip.contains(name)) continue;
        copied.add(name);
        try {
          if (have.contains(base64Encode(e.readAsBytesSync()))) continue;
        } on FileSystemException {
          continue;
        }
        final before = vanished;
        copyOne(e, name);
        if (vanished == before) vanished--;
      }
    }
  }

  Future<void> _restore(_Snapshot s) async {
    await runZoned(() async {
      for (final name in ['Drive', 'app', 'state']) {
        final live = Directory('${w.root.path}/$name');
        if (live.existsSync()) {
          for (final e in live.listSync(followLinks: false)) {
            await busyRetry(() => e.delete(recursive: true));
          }
        }
        final saved = Directory('${s.dir.path}/$name');
        if (saved.existsSync()) {
          live.createSync(recursive: true);
          _copyTree(saved, live, skip: {}, what: 'restore');
        }
      }
    }, zoneValues: {#exempt: true, #who: 'restore'});
    for (final v in versions) {
      for (final x in w.channel.versionsOf(v.path)) {
        final was = s.resolved[x.id];
        if (was != null) x.resolved = was;
      }
    }
  }

  // -- The IO seam --------------------------------------------------------------

  static final RegExp _tempName = RegExp(r'\.tmp$');
  static const _writeOps = {
    'write',
    'writeSync',
    'rename',
    'renameSync',
    'copy',
    'copySync',
    'create',
    'createSync',
    'delete',
    'deleteSync',
    'openWrite',
    'openWriteSync',
    'renameDir',
    'renameDirSync',
    'deleteDir',
    'deleteDirSync',
  };
  static const _readOps = {'read', 'readSync', 'openRead', 'open', 'openSync'};

  String _norm(String p) => p.replaceAll(r'\', '/').toLowerCase();

  bool _inDrive(String p) => _norm(p).startsWith('${_norm(drivePath)}/');

  String _base(String p) => p.split(RegExp(r'[\\/]')).last;

  // Temp files, and the self-test's probe files (created, replaced and removed
  // by the probe itself before the root is used).
  bool _isTemp(String p) =>
      _tempName.hasMatch(_base(p)) || _base(p).startsWith('.noted-probe-');

  // A name with no file whose stub is there: not downloaded.
  bool _datalessNow(String p) {
    final marked = debugDatalessPaths;
    if (marked != null &&
        marked.contains(debugDatalessKey(p)) &&
        FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound) {
      return true;
    }
    final cut = p.lastIndexOf(RegExp(r'[\\/]'));
    final stub = '${p.substring(0, cut + 1)}.${p.substring(cut + 1)}.icloud';
    return FileSystemEntity.typeSync(stub, followLinks: false) !=
            FileSystemEntityType.notFound &&
        FileSystemEntity.typeSync(p, followLinks: false) ==
            FileSystemEntityType.notFound;
  }

  void io(String op, String path, String? to) {
    if (Zone.current[#exempt] == true) return;
    // What a process that was killed still had running does nothing.
    final tag = Zone.current[#life];
    if (tag != null && tag != life) {
      throw FileSystemException('this process is gone', path);
    }
    if (!_launched) return;
    final touches = [path, ?to].where(_inDrive).toList();
    if (touches.isEmpty) return;
    final write = _writeOps.contains(op);
    final read =
        _readOps.contains(op) ||
        ((op == 'copy' || op == 'copySync') && _inDrive(path));
    if (write && (Zone.current[#coordinated] as _Flag?)?.on != true) {
      final temps = touches.every(_isTemp);
      if (!temps) {
        violations.add(
          'write outside coordinated(): $op ${_base(path)}${to == null ? '' : ' -> ${_base(to)}'}',
        );
      }
    }
    if (read && _datalessNow(path) && !_justEvicted(path)) {
      violations.add('read of a dataless file: $op ${_base(path)}\n${_appFrames()}');
    }
    if (write) {
      final target = to ?? path;
      if (_inDrive(target) &&
          !_isTemp(target) &&
          _datalessNow(target) &&
          !_justEvicted(target) &&
          op.startsWith('rename')) {
        violations.add('published onto a dataless name: $op ${_base(target)}');
      }
    }
  }

  // -- Launch and quit -----------------------------------------------------------

  int life = 0;

  /// Runs [body] as part of the current life of the process; what it starts
  /// belongs to it, and is stopped when that life is killed.
  Future<T> inLife<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {#life: life});

  Future<void> boot() async {
    life++;
    await inLife(_boot);
  }

  Future<void> _boot() async {
    await w.init();
    // The folder access runs on a clock the sequence moves (the backstop).
    w.clock = FakeClock();
    snapRoot = await Directory.systemTemp.createTemp('noted_icloud_snaps');
    f = await w.picked();
    _wrap();
    nb = _notebook(f);
    channelHooks();
    _launched = true;
    await nb.load();
    await nb.discoveryIdle;
    pageIds.add(nb.currentId!);
    _checkTrail();
    await nb.flush();
    // t2a: a file in the assets folder of the first page.
    plantAsset(nb.currentId!);
  }

  // Since the coordinator was put in place, the channel got one `coordinate`
  // for each call the coordinator had: the hook is called once per outermost
  // call, and nothing else asks the channel.
  void checkSegment() {
    final channel = w.channel.callsOf('coordinate').length - _segChannel;
    final ours = coordCalls - _segCoord;
    if (channel != ours) {
      violations.add(
        'the coordinator had $ours calls, the channel got $channel',
      );
    }
    _segChannel += channel;
    _segCoord += ours;
  }

  void channelHooks() {
    w.channel.onVersions = (path, temps) => point('versionTemp');
    f.landingStep = (step, path) async => point('landing:$step');
    // What the daemon or another device does inside the resolve call (t3c).
    w.channel.onResolve = (path, id) {
      // A landing of a process that was killed does nothing to the world.
      final tag = Zone.current[#life];
      if (tag != null && tag != life) return;
      resolveActs.remove(id)?.call();
    };
  }

  /// One-shot replaces armed by the conflict ops, run when the landing resolves
  /// the version with that id.
  final Map<String, void Function()> resolveActs = {};

  void _wrap() {
    unregisterCoordinator(drivePath);
    registerCoordinator(drivePath, _Coord(f.coordinator, this));
    _segChannel = w.channel.callsOf('coordinate').length;
    _segCoord = coordCalls;
  }

  Notebook _notebook(IcloudFolders f) {
    final settings = AppSettings(File('${w.root.path}/app/settings.json'))
      ..defaultPageFolder = drivePath;
    final n = Notebook(
      _Store(w.drive, this),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${w.root.path}/app/binders.json'),
      recoveryDirectory: Directory('${w.root.path}/app/recovery'),
      folderCheckInterval: Duration.zero,
      watchFiles: false,
      backoffFirst: const Duration(milliseconds: 20),
      backoffMax: const Duration(milliseconds: 100),
      icloud: f,
      settings: settings,
      folderLocks: w.locks,
      storeFactory: (d) => _Store(d, this),
    );
    w.notebooks.add(n);
    // 0150: a stray folder the app declines to move says so (once); that is its answer.
    n.attachmentNotices.listen((m) {
      if (m.contains('stayed in') && m.contains('may still be the page')) strayDeclined = true;
    });
    return n;
  }

  Future<void> launch() async {
    life++;
    await inLife(_launch);
  }

  Future<void> _launch() async {
    phase = 'launch';
    w.locks = FolderLocks(); // a new process has its own locks
    f = await w.relaunched();
    _wrap();
    nb = _notebook(f);
    channelHooks();
    _launched = true;
    _resyncAssets();
    await nb.load();
    await nb.discoveryIdle;
  }

  Future<void> quit({bool flush = true}) async {
    phase = 'quit';
    if (!_launched) return;
    if (flush) {
      try {
        await nb.flush();
      } on Object {
        // Whatever it could not save is in recovery.
      }
    }
    life++; // what the old life still has running is stopped from here on
    nb.dispose();
    _launched =
        false; // what is still running after this is a process that is gone
    checkSegment();
    w.notebooks.remove(nb);
    f.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  /// The planned kill came: drop the live notebook, put the copy back, launch.
  Future<void> crash() async {
    _checkHarness();
    final s = snapshot!;
    snapshot = null;
    log.add('crash and relaunch');
    life++; // the old life writes nothing from here on, `_restore` included
    await quit(flush: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (inflight.isNotEmpty) {
      log.add('in flight at the restore: ${inflight.values.join(' | ')}');
    }
    await _restore(s);
    await launch();
  }

  // -- Markers, files ----------------------------------------------------------------

  String marker() => 'm$seed-${(++_counter).toString().padLeft(4, '0')}';

  BoxRecord box(String marker) => BoxRecord.create(
    id: (seed * 100000 + int.parse(marker.split('-').last))
        .toRadixString(16)
        .padLeft(16, '0'),
    typeId: 'x.unregistered',
    dataVersion: 1,
    bounds: Bounds(
      20.0 + (_counter % 10) * 30,
      20.0 + (_counter % 7) * 30,
      10,
      10,
    ),
    data: const RawJson.trusted('{"k":1}'),
    snapshotText: marker,
    rev: 'r$_counter',
  );

  String _stubOf(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    return '${path.substring(0, cut + 1)}.${path.substring(cut + 1)}.icloud';
  }

  static final RegExp _pageFile = RegExp(r'^[A-Za-z0-9_]+\.canvas$');

  /// The page files of the folder that are there (not evicted).
  List<File> pageFiles() => [
    for (final e in w.drive.listSync(followLinks: false))
      if (e is File && _pageFile.hasMatch(_base(e.path))) e,
  ]..sort((a, b) => a.path.compareTo(b.path));

  T exempt<T>(T Function() body) => runZoned(body, zoneValues: {#exempt: true});

  Future<T> exemptAsync<T>(Future<T> Function() body, {String? who}) =>
      runZoned(body, zoneValues: {#exempt: true, #who: ?who});

  bool get quiet => snapshot == null;

  void claim(String marker, String what) {
    if (quiet) durable[marker] = what;
  }

  File? pick(bool Function(File f) test) {
    final all = [
      for (final f in pageFiles())
        if (test(f)) f,
    ];
    if (all.isEmpty) return null;
    return all[rnd.nextInt(all.length)];
  }

  String? idOf(File f) => _base(f.path).replaceAll('.canvas', '');

  // The daemon's file operations are synchronous, so what it read is what it
  // replaces (a sync client sees one state of the file); a sharing violation
  // while the app has the file open is waited out.
  T retrySync<T>(T Function() op) {
    for (var i = 0; ; i++) {
      try {
        return exempt(op);
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        final busy =
            Platform.isWindows &&
            (code == 5 || code == 32 || code == 33 || code == 145);
        if (!busy || i > 400) rethrow;
        sleep(const Duration(milliseconds: 5));
      }
    }
  }

  String? readText(File f) {
    try {
      return retrySync(() => f.readAsStringSync());
    } on Object {
      return null;
    }
  }

  void daemonWrite(File f, String text) {
    unseam(f.path); // a daemon write brings the file back
    retrySync(() => f.writeAsStringSync(text));
  }

  // -- Operations ----------------------------------------------------------------------

  // The markers that are in no file of the folder or the app's data, not
  // counting a version that is still unresolved in iCloud or a file that is
  // only a stub (the daemon has its text).
  /// Every file of the world that holds [marker], excluded ones too.
  List<String> where(String marker) => [
    for (final e in w.root.listSync(recursive: true, followLinks: false))
      if (e is File && _holds(e, marker)) _base(e.path),
  ];

  bool _isAsset(String path) => _norm(path).contains('.assets/');

  bool _holds(File e, String marker) {
    if (_isAsset(e.path)) return false;
    try {
      return latin1.decode(e.readAsBytesSync()).contains(marker);
    } on FileSystemException {
      return false;
    }
  }

  // [withTemps]: a `.tmp` (the version temp landing keeps a version in between
  // a resolve and its re-publish) holds a marker too: the per-step check counts
  // it, the end check does not.
  List<String> missing({bool withTemps = false, Set<String> staleTemps = const {}}) {
    final texts = StringBuffer();
    for (final e in w.root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      // Attachments hold no marker (and one that is not downloaded is not read).
      if (_isAsset(e.path)) continue;
      // A leftover or a temp is not where a version is kept.
      final name = _base(e.path);
      if (name.endsWith(asideSuffix) ||
          name.endsWith(verifiedSuffix) ||
          (name.endsWith('.tmp') && (!withTemps || staleTemps.contains(e.path)))) {
        continue;
      }
      try {
        texts.write(latin1.decode(e.readAsBytesSync()));
      } on FileSystemException {
        // A temp that went away.
      }
    }
    for (final t in evicted.values) {
      texts.write(t);
    }
    final all = texts.toString();
    final out = <String>[];
    for (final e in durable.entries) {
      if (all.contains(e.key)) continue;
      final v = versionOfMarker[e.key];
      if (v != null &&
          w.channel
              .versionsOf(v.path)
              .any((x) => x.id == v.id && !x.resolved)) {
        continue;
      }
      out.add(e.key);
    }
    return out;
  }

  /// The pages the app has listed so far.
  final Set<String> seen = {};

  void noteSeen() {
    for (final r in nb.tree.roots) {
      seen
        ..add(r.id)
        ..addAll(nb.tree.descendantsOf(r.id));
    }
  }

  Future<void> step(String op) async {
    log.add(op);
    phase = op;
    noteSeen();
    try {
      await inLife(() => run(op));
    } on FileSystemException {
      // The daemon could not get at a file the app holds open: it did not happen.
      if (!op.startsWith('daemon') && op != 'plantLeftover') rethrow;
      log.add('$op skipped: busy');
    }
    _checkHarness();
    if (afterStep != null) await inLife(() => afterStep!(op));
    await audit(op);
  }

  Future<void> run(String op) async {
    switch (op) {
      case 'appEdit':
        await appEdit();
      case 'appCreate':
        final id = await nb.createPage();
        if (quiet) pageIds.add(id);
        if (quiet && arnd.nextBool()) plantAsset(id);
      case 'daemonEdit':
        await daemonEdit();
      case 'daemonConflict':
        await daemonConflict();
      case 'daemonEqualConflict':
        await daemonEqualConflict();
      case 'daemonEvict':
        await daemonEvict();
      case 'daemonEvictConsumed':
        await daemonEvictConsumed();
      case 'appConsumedCopy':
        await appConsumedCopy();
      case 'daemonRevert':
        await daemonRevert();
      case 'appRecheck':
        await appRecheck();
      case 'daemonMaterialize':
        await daemonMaterialize();
      case 'daemonNewPage':
        await daemonNewPage();
      case 'plantLeftover':
        await plantLeftover();
      case 'appCheck':
        await appCheck();
      case 'landAll':
        await f.landAllVersions();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      case 'restart':
        await quit();
        await launch();
      case 'serverWrite':
        await serverWrite();
      case 'daemonEvictAttachment':
        await daemonEvictAttachment();
      case 'appPaste':
        await appPaste();
      case 'appMove':
        await appMove();
      case 'appTemplate':
        await appTemplate();
    }
    await pause();
  }

  // What held each durable marker after the last step (file names), to say where
  // one was when it goes. Run outside the life zone: a read there is blocked
  // once the process has been relaunched.
  Map<String, List<String>> _held = {};

  Set<String> _prevTemps = {};

  /// Runs [body] without noting its file operations in the trail (the
  /// harness's own polling).
  T untraced<T>(T Function() body) =>
      runZoned(body, zoneValues: {#exempt: true, #untraced: true});

  Future<void> audit(String op) async {
    if (const bool.fromEnvironment('ICLOUD_TRACE')) {
      String short(String s) => s.replaceAllMapped(
        RegExp(r'([0-9a-f]{4})[0-9a-f]{12}'),
        (m) => m[1]!,
      );
      final files = [
        for (final x in listing())
          if (x.startsWith('Drive/')) short(x.substring(6)),
      ];
      final rows = [
        for (final u in nb.unreadable)
          '${short(_base(u.path))}:${u.reason.split(' ').take(3).join('_')}',
      ];
      log.add('=> files ${files.join(' ')} | rows ${rows.join(' ')}');
    }
    if (!quiet) return;
    untraced(auditTemplates);
    final now = untraced(() => {for (final m in durable.keys) m: where(m)});
    // A marker can be between files for a moment: the app's save has moved the
    // page aside and not published yet. Only one that stays out of every file
    // while it is looked at again is lost.
    final clock = Stopwatch()..start();
    // A `.tmp` that was already there at the previous step is not a holder
    // (one left by a killed life would hide a later loss).
    List<String> look() => untraced(() => missing(withTemps: true, staleTemps: _prevTemps));
    var lost = look();
    while (lost.isNotEmpty && clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      lost = look();
    }
    _prevTemps = untraced(
      () => {
        for (final e in w.root.listSync(recursive: true, followLinks: false))
          if (e is File && e.path.endsWith('.tmp')) e.path,
      },
    );
    final gone = <String>[];
    for (final m in lost) {
      if (reportedMissing.add(m)) {
        gone.add(m);
        log.add(
          'MISSING $m (${durable[m]}) after $op; it was in ${_held[m]}, the files are ${listing().join(' ')}',
        );
      }
    }
    if (gone.isNotEmpty) {
      // Fail at the step that lost it, not at the end: the last write to its
      // files is the one to look at.
      fail(
        'seed $seed (kill at $killKind #$killNth) failed: ${gone.join(', ')} disappeared after step $op '
        '(it was in ${_held[gone.first]}; a marker moved into a conflict copy or a version counts as present)'
        '\nsteps: ${log.join(', ')}${_lostTrail()}',
      );
    }
    _held = {
      for (final e in now.entries) e.key: e.value.isEmpty ? (_held[e.key] ?? e.value) : e.value,
    };
  }

  Future<void> pause() =>
      Future<void>.delayed(const Duration(milliseconds: 15));

  Future<void> appEdit() async {
    final ids = {
      for (final r in nb.tree.roots) r.id,
      for (final r in nb.tree.roots) ...nb.tree.descendantsOf(r.id),
    }.toList()..sort();
    if (ids.isEmpty) return;
    final id = ids[rnd.nextInt(ids.length)];
    try {
      await nb.open(id);
    } on Object {
      return; // not downloaded, or busy: the app says so in its list
    }
    final page = nb.current;
    if (page == null || nb.currentId != id) return;
    final m = marker();
    final b = box(m);
    page.insertBox(b);
    if (page.page.node(b.id) == null) {
      return; // a page that is only a preview takes no edit
    }
    try {
      await nb.flush();
    } on Object {
      // It is kept in recovery.
    }
    claim(m, 'an app edit of $id');
  }

  Future<void> daemonEdit() async {
    final file = pick((f) => true);
    if (file == null) return;
    final text = readText(file);
    if (text == null) return;
    final m = marker();
    final NotedPage next;
    try {
      next = readPage(text).insertNode(box(m));
    } on Object {
      return;
    }
    daemonWrite(file, writePage(next));
    claim(m, 'a daemon edit of ${_base(file.path)}');
    if (rnd.nextBool()) await w.channel.emit('changed', {'path': file.path});
  }

  /// Whether the planned kill is in a landing, which an event starts.
  bool get _feedsLanding => killKind.startsWith('landing:') || killKind == 'versionTemp';

  Future<void> daemonConflict() async {
    final file = pick((f) => true);
    if (file == null) return;
    final text = readText(file);
    if (text == null) return;
    final a = marker();
    final b = marker();
    final NotedPage current;
    try {
      current = readPage(text);
    } on Object {
      return;
    }
    daemonWrite(file, writePage(current.insertNode(box(a))));
    final versionText = writePage(current.insertNode(box(b)));
    final id = w.channel.addVersion(file.path, utf8.encode(versionText));
    versions.add((path: file.path, id: id));
    claim(a, 'a daemon replace of ${_base(file.path)}');
    claim(b, 'a conflict version of ${_base(file.path)}');
    versionOfMarker[b] = versions.last;
    final interfere = rnd.nextBool();
    if (interfere) {
      // Inside the landing's resolve the copy of the version is replaced by a
      // page without the version's marker (and with one of its own): the
      // version is let go only once a file holds its bytes.
      final c = marker();
      resolveActs[id] = () {
        final copy = _copyHolding(file, versionText);
        if (copy == null) return;
        daemonWrite(copy, writePage(current.insertNode(box(c))));
        unawaited(w.channel.emit('changed', {'path': copy.path})); // as a daemon's write is announced
        claim(c, 'a daemon replace of the copy of a version of ${_base(file.path)}');
      };
    }
    // A conflict that feeds a landing kill is always told: the event is what lands it.
    final told = rnd.nextBool() || _feedsLanding;
    if (told) await w.channel.emit('changed', {'path': file.path});
  }

  /// The copy (`<stem>-icloud-<h>.canvas`) of [file] that holds [text], if one does.
  File? _copyHolding(File file, String text) {
    final hash = contentHash(utf8.encode(text));
    final stem = _base(file.path).replaceAll('.canvas', '');
    for (final n in [8, 16]) {
      final copy = File('${file.parent.path}/$stem-icloud-${hash.substring(0, n)}.canvas');
      if (copy.existsSync() && readText(copy) == text) return copy;
    }
    return null;
  }

  /// A version equal to the file. Inside the landing's resolve the file may be
  /// replaced by an earlier page, without the newest marker it holds.
  Future<void> daemonEqualConflict() async {
    final file = pick((f) => true);
    if (file == null) return;
    final text = readText(file);
    if (text == null) return;
    final id = w.channel.addVersion(file.path, utf8.encode(text));
    versions.add((path: file.path, id: id));
    if (rnd.nextBool()) {
      final held = [
        for (final m in RegExp('m$seed-\\d{4}').allMatches(text))
          if (durable.containsKey(m.group(0))) m.group(0)!,
      ]..sort();
      if (held.isNotEmpty) {
        final newest = held.last;
        resolveActs[id] = () {
          // Only a file still as the version is: another state is not "the
          // earlier base" of anything.
          if (readText(file) != text) return;
          daemonWrite(file, writePage(readPage(text).removeNode(box(newest).id)));
        };
      }
    }
    // A conflict that feeds a landing kill is always told: the event is what lands it.
    final told = rnd.nextBool() || _feedsLanding;
    if (told) await w.channel.emit('changed', {'path': file.path});
  }

  Future<void> daemonEvict() async {
    final file = pick((f) => !evicted.containsKey(f.path));
    if (file == null) return;
    final text = readText(file);
    if (text == null) return;
    retrySync(() {
      file.deleteSync();
      File(_stubOf(file.path)).writeAsStringSync('');
    });
    evictedText[file.path] = text;
    evictExcuse.add(_norm(file.path));
    if (rnd.nextBool()) await w.channel.emit('changed', {'path': file.path});
  }

  // -- t2a: attachments that are not downloaded -------------------------------------

  // The files the daemon planted in `<id>.assets`, by `<page id>|<name>`.
  final Map<String, Uint8List> assets = {};
  // The copies evicted through the dataless seam (the file stays), by path, with their key.
  final Map<String, String> seamedAssets = {};
  // The copies evicted to a stub, by the path of the file.
  final Set<String> stubbedAssets = {};
  // The paths the app asked the platform to download, from the first request.
  final Set<String> askedAssets = {};
  // Template ids this sequence's saves made (their assets folders may be removed
  // by the save's own rollback).
  final Set<String> madeTemplates = {};
  // The app said it left a stray folder where it was, because a file there may still be the page.
  bool strayDeclined = false;
  // The attachments' own random numbers and counter, so the other ops draw what they always drew.
  late final Random arnd = Random(seed * 104729 + 7);
  int _assetN = 0;
  // Template assets folders seen at an earlier step, to find one that went while its
  // template file was absent.
  Set<String> _templateFolders = {};

  Directory get subDir => Directory('$drivePath/Sub');
  List<String> get _locs => [drivePath, subDir.path];

  /// Where page [id]'s file is (or its stub), or null.
  String? pageLoc(String id) {
    for (final loc in _locs) {
      final p = '$loc/$id.canvas';
      if (File(p).existsSync() || File(_stubOf(p)).existsSync()) return loc;
    }
    return null;
  }

  String _assetPathIn(String loc, String key) {
    final cut = key.indexOf('|');
    return '$loc/${key.substring(0, cut)}.assets/${key.substring(cut + 1)}';
  }

  /// Every copy of a planted file that is not downloaded now, by path: the file is
  /// gone and its stub stands, or the seam marks it. A page that moved while one
  /// was evicted has the evicted copy at its old place (a stray) and may have
  /// another at its new one (a paste).
  Map<String, String> get evictedPaths => {
    for (final k in assets.keys)
      for (final loc in _locs)
        if (_isEvictedAt(_assetPathIn(loc, k))) _assetPathIn(loc, k): k,
  };

  bool _isEvictedAt(String path) {
    final there = FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
    if (!there) return File(_stubOf(path)).existsSync();
    return seamedAssets.containsKey(path);
  }

  /// The daemon puts a file in the assets folder of page [id].
  void plantAsset(String id) {
    final n = ++_assetN;
    final bytes = Uint8List.fromList(List.generate(48, (i) => (seed * 31 + n * 17 + i * 5) % 251));
    final name = '${contentHash(bytes)}.bin';
    final path = _assetPathIn(pageLoc(id) ?? drivePath, '$id|$name');
    retrySync(() {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsBytesSync(bytes);
    });
    assets['$id|$name'] = bytes;
  }

  void _forgetSeamedAssets() {
    for (final p in seamedAssets.keys) {
      debugUnmarkDataless(p);
    }
    seamedAssets.clear();
    stubbedAssets.clear();
  }

  /// After a crash and a restore: what the files say is what there is.
  void _resyncAssets() {
    _forgetSeamedAssets();
    assets.removeWhere((k, _) => !_locs.any((loc) {
      final p = _assetPathIn(loc, k);
      return File(p).existsSync() || File(_stubOf(p)).existsSync();
    }));
    for (final p in evictedPaths.keys) {
      stubbedAssets.add(p);
    }
  }

  /// Notes what the platform was asked to download.
  void noteAsked() {
    for (final c in w.channel.callsOf('startDownloading')) {
      askedAssets.add(_norm('${c.args['path']}'));
    }
  }

  /// The fake daemon evicts a copy of a planted file: it goes and its stub stands,
  /// or the seam marks it. Then `isDataless` must say so (a path spelling that the
  /// seam does not match would hide a read from every check).
  Future<void> daemonEvictAttachment() async {
    final paths = [
      for (final k in assets.keys)
        for (final loc in _locs)
          if (File(_assetPathIn(loc, k)).existsSync() && !_isEvictedAt(_assetPathIn(loc, k))) _assetPathIn(loc, k),
    ]..sort();
    if (paths.isEmpty) return;
    final path = paths[arnd.nextInt(paths.length)];
    final key = assets.keys.firstWhere((k) => _locs.any((loc) => _assetPathIn(loc, k) == path));
    if (arnd.nextBool()) {
      retrySync(() {
        File(path).deleteSync();
        File(_stubOf(path)).writeAsStringSync('');
      });
      stubbedAssets.add(path);
    } else {
      debugMarkDataless(path);
      seamedAssets[path] = key;
    }
    if (!isDataless(path)) {
      violations.add('the evicted attachment is not dataless to the app: ${_base(path)}');
    }
    if (arnd.nextBool()) await w.channel.emit('changed', {'path': File(_stubOf(path)).existsSync() ? _stubOf(path) : path});
  }

  /// The fake daemon downloads the copy at [path]: only one the app asked for.
  Future<bool> daemonMaterializeAttachment(String path, String key) async {
    noteAsked();
    if (!askedAssets.contains(_norm(path))) return false;
    final bytes = assets[key]!;
    if (seamedAssets.remove(path) != null) {
      debugUnmarkDataless(path);
    } else {
      retrySync(() {
        File(path).writeAsBytesSync(bytes);
        final stub = File(_stubOf(path));
        if (stub.existsSync()) stub.deleteSync();
      });
      stubbedAssets.remove(path);
    }
    await w.channel.emit('changed', {'path': path});
    return true;
  }

  /// The app pastes the bytes of an evicted file onto its page: nothing is
  /// written in its place (no `.kept-` copy, no recovery copy).
  Future<void> appPaste() async {
    final evicted = evictedPaths.values.toSet().toList()..sort();
    if (evicted.isEmpty) return;
    final key = evicted[arnd.nextInt(evicted.length)];
    final id = key.substring(0, key.indexOf('|'));
    try {
      await nb.open(id);
    } on Object {
      return;
    }
    final store = nb.attachments;
    if (store == null || nb.currentId != id) return;
    try {
      await store.put(assets[key]!, extension: 'bin');
    } on StorageBusy {
      // Expected: the file is on its way.
    } on FileSystemException {
      // A locked or vanished folder; checked by the end checks.
    }
  }

  /// A page moves between the drive's two folders, with its images and files.
  Future<void> appMove() async {
    // The drive's second folder, and a page in it, are made at the first move.
    try {
      subDir.createSync();
      await nb.addStandaloneFolder(subDir.path);
      if (quiet && !pageIds.any((id) => pageLoc(id) == subDir.path)) {
        final sub = await nb.createPage(folderPath: subDir.path);
        await nb.flush();
        // A kill planned while it was made means the page may not survive the crash.
        if (quiet) {
          pageIds.add(sub);
          plantAsset(sub);
        }
      }
    } on Object catch (e) {
      log.add('no second folder: $e');
      return;
    }
    // The page that stays in the second folder is never moved: a page moving in has a parent there.
    final anchor = pageIds.where((id) => pageLoc(id) == subDir.path).toList()..sort();
    if (anchor.isEmpty) return;
    // A page that has an edit waiting in recovery stays where it is: the harness is about
    // attachments, and a kept edit moves with its page by rules of its own (R5).
    final waiting = {for (final e in (await nb.recoveryStoreForTest!.list()).entries) e.pageId};
    final movable = [
      for (final id in pageIds)
        if (id != anchor.first &&
            !waiting.contains(id) &&
            pageLoc(id) != null &&
            !_hasFilesBeside(id) &&
            nb.tree.descendantsOf(id).isEmpty)
          id,
    ]..sort();
    if (movable.isEmpty) return;
    // A page with an evicted file is the one to move, when there is one.
    final withEvicted = [
      for (final id in movable)
        if (evictedPaths.values.any((k) => k.startsWith('$id|'))) id,
    ];
    final pool = withEvicted.isNotEmpty ? withEvicted : movable;
    final id = pool[arnd.nextInt(pool.length)];
    final from = pageLoc(id);
    final parents = [
      anchor.first,
      for (final o in movable)
        if (o != id && pageLoc(o) != from && !nb.tree.descendantsOf(id).contains(o)) o,
    ].where((p) => pageLoc(p) != from).toList();
    if (parents.isEmpty) return;
    final parent = parents[arnd.nextInt(parents.length)];
    // Apple's rules: a folder with something not downloaded in it is never renamed.
    // They stay on for the rest of the sequence: the stray mover of the settle moves
    // what a move left behind under the same rules (cleared in [dispose]).
    debugAppleMode = true;
    try {
      await nb.move(id, parentId: parent);
    } on NotebookException {
      // A file stayed behind (still downloading), or the move was refused.
    } on FileSystemException {
      // A busy folder.
    }
    // A folder rename over an evicted file would have taken it along: an evicted copy
    // that was evicted before the move is where it was.
    for (final p in [...seamedAssets.keys, ...stubbedAssets]) {
      if (!File(p).existsSync() && !File(_stubOf(p)).existsSync()) {
        violations.add('an evicted attachment is gone from ${_base(File(p).parent.path)} after a move (renamed with its folder?)');
      }
    }
  }

  // Whether the folder of page [id] holds a copy, version, leftover or stub of its file:
  // those stay behind when a page moves (a rule of the moves, not of the attachments).
  bool _hasFilesBeside(String id) {
    final loc = pageLoc(id);
    if (loc == null) return false;
    for (final e in Directory(loc).listSync(followLinks: false)) {
      final n = _base(e.path);
      if (e is Directory || n.endsWith('.assets')) continue;
      if (n.toLowerCase().contains(id.toLowerCase()) && n != '$id.canvas') return true;
    }
    return false;
  }

  /// A page is saved as a template, with its images and files.
  Future<void> appTemplate() async {
    final ids = pageIds.where((id) => pageLoc(id) != null).toList()..sort();
    if (ids.isEmpty) return;
    final id = ids[arnd.nextInt(ids.length)];
    try {
      final t = await nb.savePageAsTemplate(id, name: 'T$id');
      madeTemplates.add(t.id);
    } on NotebookException {
      // Refused: a file is still downloading.
    } on FileSystemException {
      // A busy folder.
    }
  }

  Directory get _templatesDir => Directory('${w.root.path}/app/templates');

  /// The template assets folders that exist, with whether their template file does.
  Map<String, bool> _templateAssetFolders() {
    final d = _templatesDir;
    if (!d.existsSync()) return {};
    return {
      for (final e in d.listSync(followLinks: false))
        if (e is Directory && _base(e.path).endsWith('.assets'))
          _base(e.path).replaceAll('.assets', ''): File('${d.path}/${_base(e.path).replaceAll('.assets', '')}.notedtemplate').existsSync(),
    };
  }

  /// No template assets folder that this sequence did not make goes while its
  /// template file is absent (another device's assets may come before its file).
  void auditTemplates() {
    final now = _templateAssetFolders();
    for (final id in _templateFolders) {
      if (now.containsKey(id) || madeTemplates.contains(id)) continue;
      if (!File('${_templatesDir.path}/$id.notedtemplate').existsSync()) {
        violations.add('template assets $id.assets went while its template file was absent');
      }
    }
    _templateFolders = now.keys.toSet();
  }

  // Whether a file in [loc] counts as page [id] by 0150's rule: its name carries the id
  // (a conflict copy, a leftover, a stub).
  bool _mayStillBePage(String loc, String id) {
    final here = _norm(loc);
    // A file the app could not read in the folder: anything uncertain counts.
    if (nb.unreadable.any((u) => _norm(File(u.path).parent.path) == here)) return true;
    for (final e in Directory(loc).listSync(followLinks: false)) {
      final n = _base(e.path).toLowerCase();
      if (n.endsWith('.assets') || e is Directory) continue;
      if (n.contains(id.toLowerCase())) return true;
      // A page file that is not one of the sequence's (or only a stub): it may be
      // the page, restored by sync under another name.
      if (n.endsWith('.canvas') && !pageIds.contains(n.substring(0, n.length - '.canvas'.length))) return true;
      if (n.endsWith('.icloud')) return true;
    }
    return false;
  }

  /// The end checks of the attachments: whole at their page's location, nothing
  /// kept beside them, nothing in recovery, no template with partial assets, and
  /// no evicted file left unasked.
  Future<List<String>> attachmentProblems() async {
    final out = <String>[];
    for (final e in assets.entries) {
      final id = e.key.substring(0, e.key.indexOf('|'));
      final loc = pageLoc(id);
      if (loc == null) continue; // the page is not there (a page that was never saved)
      final p = _assetPathIn(loc, e.key);
      final f = File(p);
      // A stray that 0150 declines: a file in the old folder may still be the page.
      final declined = [
        for (final other in _locs)
          if (other != loc &&
              (File(_assetPathIn(other, e.key)).existsSync() || File(_stubOf(_assetPathIn(other, e.key))).existsSync()) &&
              _mayStillBePage(other, id))
            other,
      ].isNotEmpty;
      if (!f.existsSync() && (declined || strayDeclined)) continue;
      if (!f.existsSync()) {
        out.add(
          'the attachment ${_base(p)} of page $id is not at the page\'s place after the downloads (${loc == drivePath ? 'drive' : 'Sub'}); '
          'it is ${[for (final l in _locs) '${l == drivePath ? 'drive' : 'Sub'}: ${File(_assetPathIn(l, e.key)).existsSync() ? 'file' : File(_stubOf(_assetPathIn(l, e.key))).existsSync() ? 'stub' : 'absent'}']}; '
          'the page is at ${[for (final l in _locs) '${l == drivePath ? 'drive' : 'Sub'}: ${File('$l/$id.canvas').existsSync()}']}; '
          'drive holds ${[for (final x in Directory(drivePath).listSync(followLinks: false)) _base(x.path)]}, unreadable ${[for (final u in nb.unreadable) '${_base(u.path)} ${u.reason}']}',
        );
      } else if (!_sameBytes(exempt(() => f.readAsBytesSync()), e.value)) {
        out.add('the attachment ${_base(p)} of page $id changed');
      }
      for (final other in _locs) {
        if (other == loc) continue;
        final left = File(_assetPathIn(other, e.key));
        // A stray that 0150 declines (a file there may still be the page) is not a failure,
        // nor a copy whose name is taken at the page's place by the same file (a paste).
        if (left.existsSync() && pageLoc(id) != null && !_mayStillBePage(other, id) && !strayDeclined && !f.existsSync()) {
          out.add(
            'the attachment ${_base(p)} of page $id is left at the old place; ${other == drivePath ? 'drive' : 'Sub'} holds '
            '${[for (final x in Directory(other).listSync(followLinks: false)) _base(x.path)]}, unreadable ${[for (final u in nb.unreadable) '${_base(u.path)} ${u.reason}']}',
          );
        }
      }
    }
    for (final e in w.root.listSync(recursive: true, followLinks: false)) {
      if (e is File && _base(e.path).contains('.kept-')) out.add('a kept copy appeared: ${_base(e.path)}');
    }
    final rec = Directory('${w.root.path}/app/recovery');
    if (rec.existsSync()) {
      for (final e in rec.listSync(followLinks: false)) {
        if (e is Directory && _base(e.path).endsWith('.assets') && e.listSync().isNotEmpty) {
          out.add('a file went to the recovery folder: ${_base(e.path)}');
        }
      }
    }
    // A listed template has all the files its pages had when it was saved.
    final tdir = _templatesDir;
    if (tdir.existsSync()) {
      for (final e in await TemplateStore(tdir).scan()) {
        if (e is! ReadableTemplate) continue;
        final t = e.template;
        for (final k in assets.keys) {
          final pid = k.substring(0, k.indexOf('|'));
          if (t.kind != TemplateKind.page || t.page.id != pid) continue;
          final copy = Directory('${tdir.path}/${t.id}.assets/$pid');
          if (copy.existsSync() && !File('${copy.path}/${k.substring(k.indexOf('|') + 1)}').existsSync()) {
            // A save that began before this file was planted lacks it: only a file
            // that was there at the save is checked, which the copy's own files say.
            if (copy.listSync().isNotEmpty) continue;
            out.add('the template ${t.id} has partial assets for page $pid');
          }
        }
      }
    }
    return out;
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Opens each page with an evicted attachment headless, so its store asks; then
  /// the daemon downloads what was asked for and the stray check runs twice.
  Future<void> settleAttachments() async {
    phase = 'settle: attachments';
    for (var round = 0; round < 3; round++) {
      final evicted = evictedPaths;
      final ids = {for (final k in evicted.values) k.substring(0, k.indexOf('|'))}.toList()..sort();
      log.add('attachments round $round: evicted ${evicted.keys.map(_base).toList()} of pages $ids');
      if (ids.isEmpty) break;
      for (final id in ids) {
        try {
          await nb.open(id);
        } on Object {
          // Not downloaded itself: the page's own file is materialised before this.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // A file left at a page's old place is the stray mover's to ask for.
      await nb.checkFolders();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      noteAsked();
      for (final e in evicted.entries) {
        if (!askedAssets.contains(_norm(e.key))) {
          // The page that holds it may not have opened: the next round asks again.
          if (round == 2) violations.add('an evicted attachment was never asked for: ${e.key}');
          continue;
        }
        await daemonMaterializeAttachment(e.key, e.value);
      }
      await nb.discoveryIdle;
    }
  }

  /// Once everything else is settled (the pages are classified), the stray check
  /// runs twice with no quiet wait: what a move left behind comes to its page.
  Future<void> settleStrays() async {
    // Only when a file really is at a page's old place.
    final stray = assets.keys.any((k) {
      final loc = pageLoc(k.substring(0, k.indexOf('|')));
      if (loc == null) return false;
      return _locs.any(
        (o) => o != loc && (File(_assetPathIn(o, k)).existsSync() || File(_stubOf(_assetPathIn(o, k))).existsSync()),
      );
    });
    if (!stray) return;
    phase = 'settle: strays';
    final quiet = Notebook.strayQuiet;
    Notebook.strayQuiet = Duration.zero;
    try {
      for (final file in pageFiles()) {
        await nb.checkFile(file.path);
      }
      for (var i = 0; i < 2; i++) {
        await nb.checkFolders();
        await nb.discoveryIdle;
      }
    } finally {
      Notebook.strayQuiet = quiet;
    }
    await nb.flush();
  }

  // -- t3a (R-2): a consumed copy whose page is evicted --------------------------

  /// The recovery entries kept for page [id].
  Future<int> _entriesOf(String id) async =>
      (await nb.recoveryStoreForTest!.list()).entries.where((e) => e.pageId == id).length;

  /// Makes a consumed copy for the page that is open and closes it: a conflict
  /// copy beside it is merged by the app, which keeps the copy in recovery
  /// until a later read of the page shows it is held (0183). The page's text
  /// before the merge is kept for [daemonRevert].
  Future<void> appConsumedCopy() async {
    await nb.flush();
    final id = nb.currentId!;
    final path = '$drivePath/$id.canvas';
    final before = readText(File(path));
    if (before == null) throw StateError('seed $seed: the page $id has no file to copy');
    final q = await nb.createPage(); // [id] is closed now
    pageIds.add(q);
    await nb.checkFile(path);
    final m = marker();
    final copy = File('$drivePath/$id-DESKTOP-ABC.canvas');
    daemonWrite(copy, writePage(readPage(before).insertNode(box(m))));
    claim(m, 'a conflict copy of $id');
    for (var i = 0; i < 6 && copy.existsSync(); i++) {
      await nb.checkFile(copy.path);
    }
    if (copy.existsSync() || await _entriesOf(id) != 1) {
      throw StateError('seed $seed: the copy of $id was not merged and kept (entries ${await _entriesOf(id)})');
    }
    consumedId = id;
    consumedPath = path;
    consumedBefore = before;
  }

  /// A sync client puts back the page's file as it was before the merge: the
  /// entry is then the only place the copy's boxes are kept.
  Future<void> daemonRevert() async {
    final path = consumedPath, text = consumedBefore;
    if (path == null || text == null) return;
    daemonWrite(File(path), text);
    if (rnd.nextBool()) await w.channel.emit('changed', {'path': path});
  }

  /// The daemon evicts the consumed copy's page ([evictMode]: its file goes and
  /// a stub stands, or the file stays and is not downloaded). A stub-only page
  /// is first seen gone (an eviction looks like a delete first), so the app
  /// lists it nowhere.
  Future<void> daemonEvictConsumed() async {
    final path = consumedPath;
    if (path == null) return;
    final text = readText(File(path));
    if (text == null) return;
    evictedText[path] = text;
    if (evictMode == 'dataless') {
      debugMarkDataless(path);
      seamed.add(path);
    } else {
      retrySync(() => File(path).deleteSync());
      await nb.checkFile(path); // seen gone: the page is listed nowhere
      retrySync(() => File(_stubOf(path)).writeAsStringSync(''));
    }
    evictExcuse.add(_norm(path));
    // The stub is told, as the daemon tells it: the app lists the page or its
    // file as still downloading (checkNotAbsent).
    await w.channel.emit('changed', {'path': evictMode == 'stub' ? _stubOf(path) : path});
  }

  bool _recheckChecked = false;

  /// The re-check of the consumed copies, run now. Before the first one the
  /// state is the pinned one: the entry is there, not parked or deleting, and
  /// the page is not open and not busy. The page's eviction excuse is cleared,
  /// so a read of it here is a violation.
  Future<void> appRecheck() async {
    final id = consumedId;
    if (id == null) return;
    if (!_recheckChecked) {
      _recheckChecked = true;
      final problems = <String>[
        if (await _entriesOf(id) != 1) 'the entry of $id is not there',
        if (nb.consumedCopiesForTest.isEmpty || nb.consumedCopiesForTest.values.any((p) => p))
          'the mark is not there, or is parked',
        if (nb.consumedDeletingForTest.values.any((d) => d)) 'the mark is being deleted',
        if (nb.deleteHoldsForTest(id)) 'a delete holds $id',
        if (nb.currentId == id) '$id is open',
        if (nb.isBusy(id)) '$id is busy',
      ];
      if (problems.isNotEmpty) throw StateError('seed $seed: not the pinned state: ${problems.join(', ')}');
    }
    evictExcuse.clear();
    await nb.recheckConsumedCopiesForTest();
    await nb.discoveryIdle;
  }

  Future<void> daemonMaterialize({String? path, bool told = false}) async {
    final target =
        path ??
        (evicted.isEmpty
            ? null
            : (evicted.keys.toList()..sort())[rnd.nextInt(evicted.length)]);
    if (target == null) return;
    final text = evictedText[target];
    if (text == null) return;
    unseam(target);
    retrySync(() {
      File(target).writeAsStringSync(text);
      final stub = File(_stubOf(target));
      if (stub.existsSync()) stub.deleteSync();
    });
    if (rnd.nextBool() || told) await w.channel.emit('changed', {'path': target});
  }

  Future<void> daemonNewPage() async {
    final id = 'd${seed}n${++_counter}';
    final m = marker();
    final page = NotedPage.create(
      PageMeta.create(id: id, title: 'Daemon $id', order: 50 + _counter),
    ).insertNode(box(m));
    daemonWrite(File('$drivePath/$id.canvas'), writePage(page));
    claim(m, 'a page of the daemon');
    if (quiet) pageIds.add(id);
    if (rnd.nextBool()) {
      await w.channel.emit('changed', {'path': '$drivePath/$id.canvas'});
    }
  }

  /// What a crashed replace leaves: the page's earlier bytes under an aside
  /// name, sometimes with a version of its own (R-4).
  Future<void> plantLeftover() async {
    final file = pick((f) => !evicted.containsKey(f.path));
    if (file == null) return;
    final text = readText(file);
    if (text == null) return;
    final NotedPage page;
    try {
      page = readPage(text);
    } on Object {
      return;
    }
    final left = File(
      '${file.path}.${rnd.nextInt(0xffffff).toRadixString(16).padLeft(6, '0')}$asideSuffix',
    );
    daemonWrite(left, text);
    if (rnd.nextBool()) {
      final m = marker();
      final id = w.channel.addVersion(
        left.path,
        utf8.encode(writePage(page.insertNode(box(m)))),
      );
      versions.add((path: left.path, id: id));
      claim(m, 'a version of a leftover of ${_base(file.path)}');
      versionOfMarker[m] = versions.last;
    }
  }

  Future<void> appCheck() async {
    final files = pageFiles();
    if (files.isNotEmpty && rnd.nextBool()) {
      await w.channel.emit('changed', {
        'path': files[rnd.nextInt(files.length)].path,
      });
    }
    await nb.checkFolders();
    await nb.discoveryIdle;
    checkNotAbsent();
  }

  /// A page whose file is only a stub is still listed (or listed as not yet
  /// downloaded), never gone.
  void checkNotAbsent() {
    final listed = {
      for (final r in nb.tree.roots) r.id,
      for (final r in nb.tree.roots) ...nb.tree.descendantsOf(r.id),
    };
    final unreadable = {for (final u in nb.unreadable) _norm(_base(u.path))};
    for (final p in evicted.keys) {
      final id = _base(p).replaceAll('.canvas', '');
      if (!seen.contains(id)) continue; // the app never listed it
      // The pinned t3a scenario evicts as a delete first (an eviction looks like
      // one), so the app forgot the page before its stub showed. Neither the
      // stub's event nor a folder check (it does not rescan the pages) makes the
      // app list the page or a "Still downloading" row: that waits for the next
      // scan. Reported with the t3a review; the scenario is about the entry.
      if (evictMode == 'stub' && p == consumedPath) continue;
      if (listed.contains(id) || unreadable.contains(_norm(_base(p)))) continue;
      violations.add(
        '${_base(p)} is only a stub, and the app lists neither the page nor the file',
      );
    }
  }

  /// The app is closed, the server replaces a page, the app starts again.
  Future<void> serverWrite() async {
    final file = pick((f) => !evicted.containsKey(f.path));
    if (file == null) return;
    await quit();
    final text = readText(file);
    if (text != null) {
      final m = marker();
      final NotedPage next;
      try {
        next = readPage(text).insertNode(box(m));
      } on Object {
        await launch();
        return;
      }
      final writer = ClosedWriter(
        dataDir: Directory(appPath)..createSync(recursive: true),
        folders: [drivePath],
      );
      writer.beforePublish = () async => point('server:beforePublish');
      writer.beforeAsideDelete = (_) async => point('server:beforeAsideDelete');
      final result = await exemptAsync(
        who: 'server',
        () => writer.replacePage(
          file.path,
          expected: utf8.encode(text),
          text: utf8.encode(writePage(next)),
        ),
      );
      if (result == PageReplace.done) {
        claim(m, 'a server write of ${_base(file.path)}');
      }
    }
    if (snapshot != null) {
      // Killed in the server: the app starts from what it left.
      final s = snapshot!;
      snapshot = null;
      log.add('server crashed');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _restore(s);
    }
    await launch();
  }

  // -- The end ---------------------------------------------------------------------------

  /// The told and the missed conflict (t2b): two pages of their own, closed,
  /// materialised, with no row, no recovery entry, not a copy or a leftover,
  /// that nothing later touches. Each gets a version of the daemon's; the told
  /// one's change event is delivered, the missed one's is not.
  File? toldFile;
  File? missedFile;

  Future<void> finalConflicts() async {
    phase = 'final conflicts';
    await f.versionAskIdle;
    File page(String tag) {
      final id = 'd$seed$tag';
      final m = marker();
      final file = File('$drivePath/$id.canvas');
      daemonWrite(
        file,
        writePage(NotedPage.create(PageMeta.create(id: id, title: 'Page $id', order: 80 + _counter)).insertNode(box(m))),
      );
      claim(m, 'the page of a $tag conflict');
      pageIds.add(id);
      return file;
    }

    void conflict(File file, String what) {
      final b = marker();
      final id = w.channel.addVersion(
        file.path,
        utf8.encode(writePage(readPage(readText(file)!).insertNode(box(b)))),
      );
      versions.add((path: file.path, id: id));
      claim(b, 'a $what conflict version of ${_base(file.path)}');
      versionOfMarker[b] = versions.last;
    }

    final told = toldFile = page('told');
    final missed = missedFile = page('missed');
    conflict(told, 'told');
    conflict(missed, 'missed');
    // Only the told one is announced; the clock does not move.
    await w.channel.emit('changed', {'path': told.path, 'version': true});
    await f.versionAskIdle;
    final left = w.channel.unresolvedOf(told.path);
    final byEvent = f.debugVersionLandings.any(
      (l) => _norm(l.path) == _norm(told.path) && l.reason == VersionLandReason.event,
    );
    if (left.isNotEmpty || !byEvent) {
      fail(
        'seed $seed (kill at $killKind #$killNth) failed: the told conflict of ${_base(told.path)} was not landed by its event '
        '(${left.length} unresolved, landings ${[for (final l in f.debugVersionLandings) if (_norm(l.path) == _norm(told.path)) l.reason.name]})'
        '\nsteps: ${log.join(', ')}',
      );
    }
    if (w.channel.unresolvedOf(missed.path).isEmpty) {
      fail('seed $seed: the missed conflict was landed before any scan: ${log.join(', ')}');
    }
  }

  /// After the settle: the missed conflict was found by the backstop.
  void checkBackstop() {
    final missed = missedFile;
    if (missed == null) return;
    final left = w.channel.unresolvedOf(missed.path);
    final byScan = f.debugVersionLandings.any(
      (l) => _norm(l.path) == _norm(missed.path) && l.reason == VersionLandReason.backstop,
    );
    if (left.isNotEmpty || !byScan) {
      fail(
        'seed $seed (kill at $killKind #$killNth) failed: the missed conflict of ${_base(missed.path)} was not landed by the backstop '
        '(${left.length} unresolved, landings ${[for (final l in f.debugVersionLandings) if (_norm(l.path) == _norm(missed.path)) l.reason.name]})'
        '\nsteps: ${log.join(', ')}',
      );
    }
  }

  Future<void> settle() async {
    phase = 'settle';
    for (final p in evicted.keys.toList()) {
      await daemonMaterialize(path: p, told: true); // its own event
    }
    for (var round = 0; round < 6; round++) {
      // The backstop: the clock moves past the scan interval and the largest
      // backoff, and the folder tick scans for versions (no launch pass, no
      // event for a file the daemon did not materialise).
      phase = 'settle: backstop';
      w.clock!.advance(const Duration(minutes: 31));
      await nb.folderTickForTest();
      await f.versionAskIdle;
      phase = 'settle: checkFolders';
      await nb.checkFolders();
      phase = 'settle: scan';
      await nb.scanLocationForTest(
        '',
      ); // the periodic look at the folder: leftovers are swept
      await nb.discoveryIdle;
      phase = 'settle: checkFile';
      for (final file in pageFiles()) {
        await nb.checkFile(file.path);
      }
      phase = 'settle: flush';
      await nb.flush();
      await nb.discoveryIdle;
      log.add(
        "settle $round: missing=${missing()} files=${[for (final e in w.drive.listSync(followLinks: false)) _base(e.path)].join(" ")} unresolved=${[for (final v in versions)
          for (final x in w.channel.versionsOf(v.path))
            if (!x.resolved) x.id]}",
      );
      final left = [
        for (final v in versions)
          for (final x in w.channel.versionsOf(v.path))
            if (!x.resolved) x,
      ];
      final leftovers = [
        for (final e in w.drive.listSync())
          if (e is File && _base(e.path).endsWith(asideSuffix)) e,
      ];
      // A copy a landing published is merged by the app (0053) before it ends.
      final copies = [
        for (final e in w.drive.listSync())
          if (e is File && RegExp(r'-icloud-[0-9a-f]+\.canvas$').hasMatch(_base(e.path))) e,
      ];
      if (left.isEmpty &&
          leftovers.isEmpty &&
          copies.isEmpty &&
          !nb.trouble.isTrouble &&
          round >= 1) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // After the versions are settled: opening a page earlier would leave it open while a
    // version lands (the rest of the settle is what it always was).
    await settleAttachments();
    await settleStrays();
  }

  List<String> summary(Notebook n) {
    final out = <String>[];
    for (final r in n.tree.roots) {
      for (final id in [r.id, ...n.tree.descendantsOf(r.id)]) {
        out.add('page $id "${n.pageTitleOf(id)}"');
      }
    }
    for (final u in n.unreadable) {
      out.add('unreadable ${_base(u.path)} ${u.reason}');
    }
    return out..sort();
  }

  Set<String> boxesOf(Notebook n) => {
    for (final node in n.current!.page.nodes)
      '${node.id}@${node is BoxRecord ? node.rev : ''}',
  };

  /// Every file of the world, relative to its root.
  List<String> listing() => [
    for (final e in w.root.listSync(recursive: true, followLinks: false))
      if (e is File)
        e.path.substring(w.root.path.length + 1).replaceAll('\\', '/'),
  ]..sort();

  Future<void> verify() async {
    phase = 'verify';
    _checkHarness();
    final problems = <String>[];
    // The live notebook, as a watcher event would leave it: its folder looked
    // at again, everything saved.
    await nb.scanLocationForTest(
      '',
    ); // the standalone location: the default folder
    await nb.discoveryIdle;
    await nb.flush();
    final live = summary(nb);
    final liveIds = {
      for (final r in nb.tree.roots) r.id,
      for (final r in nb.tree.roots) ...nb.tree.descendantsOf(r.id),
    };
    final liveBoxes = <String, Set<String>>{};
    for (final id in liveIds) {
      try {
        await nb.open(id);
        liveBoxes[id] = boxesOf(nb);
      } on Object catch (e) {
        problems.add('page $id could not be opened live: $e');
      }
    }
    await nb.flush();
    // 2. every version is a page or a listed copy: before the reload, in a
    // file or in recovery (what a restart would replay).
    for (final m in missing()) {
      problems.add('$m (${durable[m]}) is in no file before the reload');
    }
    for (final v in versions) {
      for (final x in w.channel.versionsOf(v.path)) {
        if (!x.resolved) {
          final tr = [for (final t in trail) if (t.line.contains(_base(v.path))) t.line].join('\n  ');
          problems.add('a version of ${_base(v.path)} is still unresolved; trail:\n  $tr');
        }
      }
    }
    final before = listing();
    // 1. a fresh notebook, as a restart makes it, lists what the live one does.
    await quit();
    await launch();
    await nb.discoveryIdle;
    await nb.flush();
    final reloaded = summary(nb);
    // The pages are the same. The rows for files that can't be opened or are
    // copies: a restart never lists one the live notebook hides. The live one
    // may still list a row for a state that has passed (a leftover that was
    // consumed, a stub that arrived): its rows are only refreshed by a scan,
    // which is when a restart looks (the same as before this step).
    final livePages = [
      for (final l in live)
        if (l.startsWith('page ')) l,
    ];
    final reloadedPages = [
      for (final l in reloaded)
        if (l.startsWith('page ')) l,
    ];
    if (livePages.join('\n') != reloadedPages.join('\n')) {
      problems.add(
        'the live notebook lists\n  ${live.join('\n  ')}\nbut a reload lists\n  ${reloaded.join('\n  ')}\nfiles: ${before.join(' ')}',
      );
    }
    final hidden = [
      for (final r in reloaded)
        if (r.startsWith('unreadable ') && !live.contains(r)) r,
    ];
    if (hidden.isNotEmpty) {
      problems.add(
        'a reload lists, and the live notebook does not:\n  ${hidden.join('\n  ')}\nfiles: ${before.join(' ')}',
      );
    }
    final ids = {
      for (final r in nb.tree.roots) r.id,
      for (final r in nb.tree.roots) ...nb.tree.descendantsOf(r.id),
    };
    for (final id in ids) {
      try {
        await nb.open(id);
        final b = boxesOf(nb);
        final a = liveBoxes[id];
        // The live notebook may lag a restart for a copy whose merge was
        // refused (`Could not be merged … versionsPending`, tried again at the
        // next scan): a restart merges it, so the reload has every box the live
        // page has, and more. No other row excuses a difference.
        final lagging = live.any(
          (l) =>
              (l.startsWith('unreadable $id-') ||
                  l.startsWith('unreadable $id.')) &&
              l.contains('Could not be merged') &&
              l.contains('versionsPending'),
        );
        final same = a != null && a.length == b.length && a.containsAll(b);
        final superset = a != null && b.containsAll(a);
        if (a != null && !(lagging ? superset : same)) {
          final texts = {for (final n in nb.current!.page.nodes) if (n is BoxRecord) '${n.id}@${n.rev}': n.snapshotText};
          problems.add(
            'page $id: live ${a.length} boxes, reload ${b.length}; only in the reload: ${[for (final k in b.difference(a)) '$k ${texts[k]}']}; '
            'only live: ${[for (final k in a.difference(b)) k]}; recovery entries ${await _entriesOf(id)}; page is at ${pageLoc(id) == drivePath ? 'drive' : 'Sub'}; moved: ${log.where((l) => l == 'appMove').length}',
          );
        }
      } on Object catch (e) {
        problems.add('page $id could not be opened after a reload: $e');
      }
    }
    // 3. nothing known is gone.
    for (final id in pageIds) {
      if (!ids.contains(id)) {
        problems.add(
          'page $id is not listed after a reload (it is at ${pageLoc(id)}; folders ${[for (final f in nb.standaloneFolders) '${f.path} ${f.available}']}; '
          'Sub holds ${subDir.existsSync() ? [for (final e in subDir.listSync()) _base(e.path)] : 'nothing'})',
        );
      }
    }
    for (final m in missing()) {
      if (!problems.any((p) => p.startsWith('$m '))) {
        problems.add(
          '$m (${durable[m]}) is in no file after the reload; now: ${listing().join(' ')}',
        );
      }
    }
    checkSegment();
    problems.addAll(await attachmentProblems());
    auditTemplates();
    problems.addAll(violations);
    // t3c: no version was resolved while no temp held its bytes.
    for (final r in w.channel.resolveViolations) {
      problems.add('resolved without a temp holding the version: $r');
    }
    if (problems.isNotEmpty) {
      fail(
        'seed $seed (kill at $killKind #$killNth) failed:\n${problems.take(12).join('\n')}\nsteps: ${log.join(', ')}${_lostTrail()}',
      );
    }
  }

  // What touched the files that held each lost marker (and the file its claim
  // names), from the trail: who did what, in which life, in which step.
  String _lostTrail() {
    final out = StringBuffer();
    for (final m in {...reportedMissing, ...missing()}) {
      final files = <String>{
        ...?_held[m],
        ...RegExp(
          r'[0-9a-f]{16}(?:\.canvas)?',
        ).allMatches(durable[m] ?? '').map((x) => '${x.group(0)!.split('.').first}.canvas'),
      };
      for (final f in files) {
        final key = f.split('.').first;
        out.write('\nlast write to $f: ${lastWrite[key] ?? 'none seen'}');
        final app = lastAppWrite[key]?.split('\n');
        if (app != null) {
          if (app.first == lastWrite[key]) {
            out.write(' (the app\'s)');
          } else {
            out.write('\nlast app write to $f: ${app.first}');
          }
          out.write('\n${app.skip(1).join('\n')}');
        }
      }
      out.write(
        '\nIO trail for $m (${durable[m]}), files $files (oldest retained #${trail.isEmpty ? '-' : trail.first.id}):',
      );
      for (final l in trailOf(files)) {
        out.write('\n  $l');
      }
    }
    return out.toString();
  }

  /// A test seam: runs as the app after each step, before the markers are
  /// checked (a write that loses one).
  Future<void> Function(String op)? afterStep;

  /// A test seam: awaited first in [dispose] (a disposal that hangs).
  Future<void> Function()? disposeSeam;

  Future<void> dispose() async {
    await disposeSeam?.call();
    debugDatalessPaths = null;
    debugAppleMode = null;
    Notebook.strayQuiet = const Duration(seconds: 30);
    await w.dispose();
    if (snapRoot.existsSync()) await deleteTestFolder(snapRoot);
  }
}

List<String> _plan(_Sim s) {
  const ops = [
    'appEdit',
    'appEdit',
    'appEdit',
    'appCreate',
    'daemonEdit',
    'daemonEdit',
    'daemonConflict',
    'daemonConflict',
    'daemonEqualConflict',
    'daemonEvict',
    'daemonEvict',
    'daemonMaterialize',
    'daemonMaterialize',
    'daemonNewPage',
    'plantLeftover',
    'plantLeftover',
    'appCheck',
    'appCheck',
    'appCheck',
    'restart',
    'serverWrite',
  ];
  final plan = [
    for (var i = 0; i < _steps; i++) ops[s.rnd.nextInt(ops.length)],
  ];
  // The kill kind has to be reachable: the ops that lead to it come early.
  final feed = _feeders[s.killKind]!;
  for (var i = 0; i < feed.length; i++) {
    plan[2 + i * 3] = feed[i];
    plan[3 + i * 3] = 'appCheck';
  }
  // t2a: the attachments that are not downloaded follow the rest, with random numbers
  // of their own (the sequence above is what it always was).
  return [
    ...plan,
    'daemonEvictAttachment',
    'appPaste',
    'appMove',
    'appTemplate',
    'daemonEvictAttachment',
    'appMove',
    'appPaste',
    'appTemplate',
  ];
}

Future<void> _sequence(
  int seed, {
  void Function(_Sim)? setUp,
  List<String>? plan,
  Duration disposeLimit = const Duration(seconds: 90),
}) async {
  final s = _Sim(seed);
  setUp?.call(s);
  final recorder = _Recorder(s);
  await IOOverrides.runWithIOOverrides(() async {
    Object? failure;
    try {
      Future<void> whole() async {
        await s.boot();
        s.armed = true;
        Future<void> run() async {
          for (final op in plan ?? _plan(s)) {
            await s.step(op);
            if (s.snapshot != null) await s.crash();
          }
          if (s.snapshot != null) await s.crash();
          // The kills are over: the last two conflicts and the settle run clean.
          s.armed = false;
          await s.inLife(s.finalConflicts);
          await s.inLife(s.settle);
          s.checkBackstop();
          await s.verify();
        }

        await run();
      }

      await whole().timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw StateError(
          'seed $seed hung in ${s.phase}; steps: ${s.log.join(', ')}',
        ),
      );
    } catch (e) {
      failure = e;
      rethrow;
    } finally {
      // The settle helper reports stuck work after 20 s and a delete retries for
      // 20 s: the limit is above both, and a disposal that does not finish
      // fails the seed (0192) instead of letting it pass. The seed's own
      // failure, when there is one, is the one reported.
      try {
        await s.dispose().timeout(
          disposeLimit,
          onTimeout: () => throw TestFailure(
            'seed $seed: disposal did not finish within $disposeLimit (phase ${s.phase}); '
            'in flight: ${inFlightOf(s.w.notebooks) ?? 'nothing'}; steps: ${s.log.join(', ')}',
          ),
        );
      } catch (e) {
        if (failure == null) rethrow;
        debugPrint('seed $seed: disposal also failed: $e');
      }
    }
  }, TracingIoOverrides(recorder));
  if (setUp == null) _ranSeeds.add(seed);
}

BoxRecord _plainBox(int n, String marker) => BoxRecord.create(
  id: n.toRadixString(16).padLeft(16, '0'),
  typeId: 'x.unregistered',
  dataVersion: 1,
  bounds: Bounds(20.0 + n * 30, 40, 10, 10),
  data: const RawJson.trusted('{"k":1}'),
  snapshotText: marker,
  rev: 'r$n',
);

/// Windows' iCloud folder is a plain local folder (design, "Windows folder"):
/// no coordinator, no stubs, the sync client leaves `<stem> (1).canvas` and
/// `<stem> 2.canvas` beside a page it could not merge. They merge into the page
/// and go, as OneDrive's copies do (0053), and a restart agrees. It only guards
/// today's patterns; what iCloud for Windows really writes is probe I3.
void _windowsFolderTests() {
  group('a plain local folder with `<stem> (1).canvas` and `<stem> 2.canvas` (Windows folder)', () {
    for (final open in [false, true]) {
      test(
        'beside ${open ? 'the open' : 'a closed'} page: merged and removed, live and after a restart',
        () async {
          final root = await Directory.systemTemp.createTemp('noted_winfolder');
          final pages = Directory('${root.path}/pages');
          final made = <Notebook>[];
          Notebook make() {
            final n = Notebook(
              PageStore(pages),
              buildModules(),
              saveDelay: const Duration(hours: 1),
              bindersFile: File('${root.path}/binders.json'),
              recoveryDirectory: Directory('${root.path}/recovery'),
              folderCheckInterval: Duration.zero,
            );
            made.add(n);
            return n;
          }

          List<String> names() => [
            for (final e in pages.listSync())
              e.uri.pathSegments.where((s) => s.isNotEmpty).last,
          ]..sort();

          try {
            final nb = make();
            await nb.load();
            await nb.discoveryIdle;
            final id = nb.currentId!;
            final other = await nb.createPage();
            await nb.open(open ? id : other);
            await nb.flush();
            final file = File('${pages.path}/$id.canvas');
            final base = readPage(file.readAsStringSync());
            final one = File('${pages.path}/$id (1).canvas')
              ..writeAsStringSync(
                writePage(base.insertNode(_plainBox(1, 'copy-one'))),
              );
            final two = File('${pages.path}/$id 2.canvas')
              ..writeAsStringSync(
                writePage(base.insertNode(_plainBox(2, 'copy-two'))),
              );
            await nb.checkFile(one.path);
            await nb.checkFile(two.path);
            await nb.flush();
            expect(
              names(),
              unorderedEquals(['$id.canvas', '$other.canvas']),
              reason: 'both copies are merged and removed',
            );
            final text = file.readAsStringSync();
            expect(text, contains('copy-one'));
            expect(text, contains('copy-two'));
            expect(nb.unreadable, isEmpty);
            if (open) {
              expect(
                nb.current!.page.node('0000000000000001'),
                isNotNull,
                reason: 'the open page shows the first copy\'s box',
              );
              expect(
                nb.current!.page.node('0000000000000002'),
                isNotNull,
                reason: 'and the second\'s',
              );
            }
            // A restart lists the same pages and shows the same boxes.
            final live = {
              for (final r in nb.tree.roots) r.id,
              for (final r in nb.tree.roots) ...nb.tree.descendantsOf(r.id),
            };
            nb.dispose();
            made.remove(nb);
            final fresh = make();
            await fresh.load();
            await fresh.discoveryIdle;
            expect({
              for (final r in fresh.tree.roots) r.id,
              for (final r in fresh.tree.roots)
                ...fresh.tree.descendantsOf(r.id),
            }, live);
            expect(fresh.unreadable, isEmpty);
            expect(names(), unorderedEquals(['$id.canvas', '$other.canvas']));
            await fresh.open(id);
            expect(fresh.current!.page.node('0000000000000001'), isNotNull);
            expect(fresh.current!.page.node('0000000000000002'), isNotNull);
          } finally {
            for (final n in made) {
              n.dispose();
            }
            await deleteTestFolder(root);
          }
        },
      );
    }
  });
}

// A CI run picks its seeds by environment variable (the manual workflow
// `reload-seeds.yml`): `NOTED_RELOAD_SEEDS` is a list of numbers and ranges
// (`1-40`, `3,7,20-25`); `NOTED_RELOAD_REPEAT_SEED` and
// `NOTED_RELOAD_REPEAT_COUNT` run one seed that many times, each its own test.
// With either set, the first failing seed stops the rest, and its failure is
// printed whole.
List<int>? _envSeeds() {
  final spec = Platform.environment['NOTED_RELOAD_SEEDS']?.trim() ?? '';
  if (spec.isEmpty) return null;
  final out = <int>[];
  for (final part in spec.split(',')) {
    final m = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(part);
    if (m == null) throw ArgumentError('NOTED_RELOAD_SEEDS: cannot read "$part"');
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2) ?? m.group(1)!);
    for (var i = a; i <= b; i++) {
      out.add(i);
    }
  }
  return out;
}

bool _stopped = false;

Future<void> _runSeed(int seed, String what, {required bool stopAtFirst}) async {
  if (stopAtFirst && _stopped) {
    markTestSkipped('an earlier seed failed');
    return;
  }
  try {
    await _sequence(seed);
  } catch (e) {
    if (stopAtFirst) {
      _stopped = true;
      debugPrint('[reload-seeds] $what FAILED:\n$e');
    }
    rethrow;
  }
}

void main() {
  final envSeeds = _envSeeds();
  final rawSeed = Platform.environment['NOTED_RELOAD_REPEAT_SEED']?.trim() ?? '';
  final rawCount = Platform.environment['NOTED_RELOAD_REPEAT_COUNT']?.trim() ?? '';
  final repeatSeed = int.tryParse(rawSeed);
  final repeatCount = int.tryParse(rawCount) ?? 0;
  if ((rawSeed.isNotEmpty && repeatSeed == null) ||
      (rawCount.isNotEmpty && int.tryParse(rawCount) == null)) {
    throw ArgumentError(
      'NOTED_RELOAD_REPEAT_SEED "$rawSeed" and NOTED_RELOAD_REPEAT_COUNT "$rawCount" must be whole numbers',
    );
  }
  final repeating = repeatSeed != null && repeatCount > 0;
  final stopAtFirst = envSeeds != null || repeating;
  final seeds =
      envSeeds ??
      (repeating ? const <int>[] : [for (var i = 1; i <= _fixedSeeds + _extraSeeds; i++) i]);

  _windowsFolderTests();

  // t2a: pinned scenarios of the attachments that are not downloaded.
  group('attachments that are not downloaded (t2a)', () {
    for (final entry in <String, List<String>>{
      'a move between the two folders, with files that are present': ['appMove', 'appMove', 'restart'],
      'an eviction, a paste and a move': [
        'daemonEvictAttachment',
        'appPaste',
        'appMove',
        'daemonEvictAttachment',
        'appMove',
        'appCheck',
      ],
      'an eviction and a template save': ['daemonEvictAttachment', 'appTemplate', 'appTemplate', 'appCheck'],
      'every file evicted, then two moves': [
        'appMove',
        'daemonEvictAttachment',
        'daemonEvictAttachment',
        'daemonEvictAttachment',
        'appMove',
        'appMove',
        'appCheck',
      ],
      'two evictions, a move and a restart': [
        'appMove',
        'daemonEvictAttachment',
        'daemonEvictAttachment',
        'appMove',
        'restart',
        'appPaste',
        'appTemplate',
      ],
    }.entries) {
      for (final seed in const [2, 5, 9]) {
        test(
          '${entry.key} (seed $seed)',
          () => _sequence(seed, plan: entry.value),
          timeout: const Timeout(Duration(minutes: 4)),
        );
      }
    }
  });

  group('an iCloud folder: a live notebook and a reload agree (R5.13)', () {
    for (final seed in seeds) {
      test(
        'seed $seed',
        () => _runSeed(seed, 'seed $seed', stopAtFirst: stopAtFirst),
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }
    if (repeating) {
      for (var i = 1; i <= repeatCount; i++) {
        test(
          'seed $repeatSeed, run $i of $repeatCount',
          () => _runSeed(repeatSeed, 'seed $repeatSeed run $i of $repeatCount', stopAtFirst: true),
          timeout: const Timeout(Duration(minutes: 4)),
        );
      }
    }

    // The snapshot lists a folder and copies file by file, while the app's
    // renames run on IO threads: one that lands after the listing leaves the
    // file under neither name in the copy, a state no crash produces (a rename
    // is atomic). The seam lands the replace's own rename (the page moved
    // aside) between the listing and the copies of a `replace:beforeMoveAside`
    // kill.
    group('a rename landing between the snapshot\'s listing and its copies', () {
      // A minimal plan, not the random one: one page, edits whose first replace
      // is the killed one, so the listing holds the page and the seam fires
      // whatever background work a slow runner interleaves.
      for (final seed in const [7]) {
        for (final faithful in [true, false]) {
          test(
            'seed $seed, ${faithful ? 'the snapshot looks again' : 'the old snapshot (loses the page)'}',
            () async {
              _Sim? sim;
              var landed = false;
              Future<void> run() => _sequence(
                seed,
                setUp: (s) {
                  sim = s;
                  s.faithfulSnapshot = faithful;
                  s.killNth = 1;
                  s.copyGap = (from, listed) {
                    final t = s.replaceTarget;
                    if (landed || t == null) return;
                    // By name: the snapshot lists the root as the temp folder
                    // spells it (8.3 short names on Windows CI), the target is
                    // the resolved drive path.
                    String name(String p) => p.split(RegExp(r'[\\/]')).last;
                    if (!listed.any((e) => name(e.path) == name(t))) return;
                    landed = true;
                    File(t).renameSync('$t.ab12cd$asideSuffix');
                  };
                },
                plan: const ['appEdit', 'appEdit', 'appCheck', 'appEdit'],
              );
              if (faithful) {
                await run();
              } else {
                await expectLater(
                  run,
                  throwsA(
                    isA<TestFailure>().having(
                      (e) => e.message,
                      'message',
                      anyOf(contains('is not listed after a reload'), contains('is in no file')),
                    ),
                  ),
                  reason: 'without the second look the page is in no file of the snapshot',
                );
              }
              expect(landed, isTrue, reason: 'the seam fired');
              expect(sim!.log.any((l) => l.contains('vanished while copied')), isTrue);
            },
            timeout: const Timeout(Duration(minutes: 4)),
          );
        }
      }
    });

    // A disposal that hangs fails the seed, naming what is in flight (it used
    // to be cut off after 15 s and the seed passed).
    test('a disposal that does not finish fails the seed', () async {
      final gate = Completer<void>();
      await expectLater(
        () => _sequence(
          3,
          setUp: (s) => s.disposeSeam = () => gate.future,
          plan: const ['appEdit', 'appCheck'],
          disposeLimit: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('disposal did not finish'), contains('in flight:')),
          ),
        ),
      );
      // Let the stuck disposal finish, so the next test starts clean.
      gate.complete();
      await Future<void>.delayed(const Duration(seconds: 2));
    }, timeout: const Timeout(Duration(minutes: 4)));

    // A marker that goes is reported at the step that lost it, with the last
    // write to its file: who made it and, for the app, the Dart stack.
    test('a marker lost by a write fails at that step and names the write', () async {
      var done = false;
      await expectLater(
        () => _sequence(
          5,
          setUp: (s) {
            s.afterStep = (op) async {
              final mine = [
                for (final e in s.durable.entries)
                  if (e.value.startsWith('an app edit')) e.key,
              ];
              if (done || mine.isEmpty) return;
              done = true;
              final m = mine.first;
              final file = s.pageFiles().firstWhere((f) => s.readText(f)!.contains(m));
              final text = file.readAsStringSync();
              final gone = readPage(text).removeNode(s.box(m).id);
              await _Store(s.w.drive, s).saveIfUnchanged(gone, text);
            };
          },
          plan: const ['appEdit', 'appEdit', 'appCheck'],
        ),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('disappeared after step'),
              contains('last write to'),
              contains('app(life'),
              contains('_replaceIfUnchanged'),
            ),
          ),
        ),
      );
      expect(done, isTrue);
    }, timeout: const Timeout(Duration(minutes: 4)));

    // A marker held only by a version temp (`.tmp`) between a resolve and its
    // re-publish is not lost at that step.
    test('a marker held only by a .tmp counts as present at a step', () async {
      File? tmp;
      File? page;
      String? original;
      final checked = <String>[];
      await _sequence(
        5,
        setUp: (s) {
          s.afterStep = (op) async {
            checked.add(op);
            if (tmp == null) {
              final m = [
                for (final e in s.durable.entries)
                  if (e.value.startsWith('an app edit')) e.key,
              ].firstOrNull;
              if (m == null) return;
              page = s.pageFiles().firstWhere((f) => s.readText(f)!.contains(m));
              original = s.readText(page!)!;
              tmp = File('${page!.path}.99999-1.tmp');
              s.retrySync(() => tmp!.writeAsStringSync(original!));
              s.daemonWrite(page!, writePage(readPage(original!).removeNode(s.box(m).id)));
            } else if (tmp!.existsSync()) {
              // The next step: the re-publish.
              s.daemonWrite(page!, original!);
              s.retrySync(() => tmp!.deleteSync());
            }
          };
        },
        plan: const ['appEdit', 'appCheck', 'appCheck'],
      );
      expect(tmp, isNotNull, reason: 'the hook held the marker in a temp');
      expect(tmp!.existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 4)));

    // A `.tmp` that was already there at the previous step (one left by a
    // killed life) does not hide a later loss.
    test('a stale .tmp does not hold a marker at a later step', () async {
      File? tmp;
      await expectLater(
        () => _sequence(
          5,
          setUp: (s) {
            s.afterStep = (op) async {
              final m = [
                for (final e in s.durable.entries)
                  if (e.value.startsWith('an app edit')) e.key,
              ].firstOrNull;
              if (m == null) return;
              final page = s.pageFiles().firstWhere((f) => s.readText(f)!.contains(m));
              final text = s.readText(page)!;
              if (tmp == null) {
                tmp = File('${page.path}.99999-1.tmp');
                s.retrySync(() => tmp!.writeAsStringSync(text));
              } else if (text.contains(m)) {
                s.daemonWrite(page, writePage(readPage(text).removeNode(s.box(m).id)));
              }
            };
          },
          plan: const ['appEdit', 'appCheck', 'appCheck'],
        ),
        throwsA(
          isA<TestFailure>().having((e) => e.message, 'message', contains('disappeared after step')),
        ),
      );
      expect(tmp, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 4)));

    // A copy that keeps failing while the file is there is a harness error, not
    // a snapshot without the file (the restore would report a loss that did
    // not happen).
    test('a snapshot copy that keeps failing fails the seed as a harness error', () async {
      await expectLater(
        () => _sequence(
          7,
          setUp: (s) {
            s.killNth = 1;
            s.copyFault = (e, name) {
              if (name.endsWith('.canvas')) throw FileSystemException('busy', e.path);
            };
          },
          plan: const ['appEdit', 'appEdit', 'appCheck', 'appEdit'],
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('harness error')),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    // t3a (R-2, 0190, 0183): a consumed copy's page is evicted after the sync
    // client put the pre-merge file back, so the entry is the only place the
    // copy's boxes are kept. The re-check must not read the page, and must not
    // take a stub for a deleted page and retire the entry. Pinned: make the
    // consumed copy for the page and close it, revert, evict, check, re-check;
    // then the page comes back and the re-check retires the entry. Once per
    // seed in each mode: a stub only, and present but dataless (the seam).
    // Without the guarded read the stub-only mode loses the copy's boxes (a
    // marker in no file), and the dataless mode reads the evicted file.
    for (final seed in seeds.isEmpty ? const <int>[] : seeds.take(_fixedSeeds)) {
      for (final mode in ['stub', 'dataless']) {
        test(
          'seed $seed, a consumed copy\'s page evicted ($mode): the re-check keeps the entry',
          () => _sequence(
            seed,
            setUp: (s) {
              s.killKind = 'none'; // no kill in this scenario
              s.evictMode = mode;
            },
            plan: const [
              'appEdit',
              'appConsumedCopy',
              'daemonRevert',
              'daemonEvictConsumed',
              'appCheck',
              'appRecheck',
              'appCheck',
              'appRecheck',
              'daemonMaterialize',
              'appCheck',
              'appRecheck',
              'appRecheck',
              'appRecheck',
            ],
          ),
          timeout: const Timeout(Duration(minutes: 4)),
        );
      }
    }

    test('every kill point was reached by some seed', () {
      if (_ranSeeds.length < _fixedSeeds) return; // a single seed was asked for
      expect(
        _killed.toSet(),
        containsAll(_killKinds),
        reason:
            'the kinds never killed: ${_killKinds.toSet().difference(_killed)}',
      );
    });
  });
}
