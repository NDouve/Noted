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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

// The server's closed writer, as the other reload-equivalence tests use it
// (they run the whole server in a child process; this is its page writer).
// ignore: avoid_relative_lib_imports
import '../../packages/noted_mcp/lib/src/closed_writer.dart';

import 'support/busy_retry.dart';
import 'support/icloud_world.dart';
import 'support/notebook_folder.dart';
import 'support/io_trace.dart' show IoTrace, TracingIoOverrides;

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
];

/// What each kill kind needs to happen at least once in a sequence.
const Map<String, List<String>> _feeders = {
  'coordinate': ['appEdit'],
  'versionTemp': ['daemonConflict', 'landAll'],
  'landing:copied': ['daemonConflict', 'landAll'],
  'landing:published': ['daemonConflict', 'landAll'],
  'landing:verified': ['daemonConflict', 'landAll'],
  'landing:resolved': ['daemonConflict', 'landAll'],
  'replace:beforeMoveAside': ['appEdit', 'appEdit'],
  'replace:beforePublish': ['appEdit', 'appEdit'],
  'replace:beforeAsideDelete': ['appEdit', 'appEdit'],
  'replace:beforeFinalCheck': ['appEdit', 'appEdit'],
  'saveNew:beforePublish': ['appCreate'],
  'server:beforePublish': ['serverWrite'],
  'server:beforeAsideDelete': ['serverWrite'],
};

final Set<String> _killed = {};
int _ran = 0;

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
        sim.point('replace:beforeMoveAside');
        beforeMoveAside?.call();
      },
      afterRead: afterRead,
      beforePublish: () {
        sim.point('replace:beforePublish');
        beforePublish?.call();
      },
      beforeRestore: beforeRestore,
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
    sim.io(op, path, to);
    return 0;
  }

  @override
  void end(int id, [Object? error]) {}

  @override
  void failed(int id, String op, String path, Object error, {String? to}) {}
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

  // The app checks `isDataless` and then reads, and the file can go in between
  // (a job waiting for the folder's lock): the first read of a file after its
  // eviction is excused, the next is not.
  bool _justEvicted(String p) => evictExcuse.remove(_norm(p));

  Map<String, String> get evicted => {
    for (final e in evictedText.entries)
      if (File(_stubOf(e.key)).existsSync()) e.key: e.value,
  };
  final List<({String path, String id})> versions = [];
  final Map<String, ({String path, String id})> versionOfMarker = {};
  final Set<String> reportedMissing = {};
  final List<String> violations = [];
  final List<String> log = [];
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
    }
  }

  _Snapshot _take() {
    return runZoned(() {
      final dir = Directory('${snapRoot.path}/snap${_counter++}')
        ..createSync(recursive: true);
      _copyTree(w.root, dir, skip: {});
      return _Snapshot(dir, {
        for (final v in versions)
          for (final x in w.channel.versionsOf(v.path)) x.id: x.resolved,
      });
    }, zoneValues: {#exempt: true});
  }

  void _copyTree(Directory from, Directory to, {required Set<String> skip}) {
    for (final e in from.listSync(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (skip.contains(name)) continue;
      if (e is Directory) {
        final d = Directory('${to.path}/$name')..createSync();
        _copyTree(e, d, skip: {});
      } else if (e is File) {
        try {
          e.copySync('${to.path}/$name');
        } on FileSystemException {
          // A temp that went away while it was copied.
        }
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
          _copyTree(saved, live, skip: {});
        }
      }
    }, zoneValues: {#exempt: true});
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
      violations.add('read of a dataless file: $op ${_base(path)}');
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
    snapRoot = await Directory.systemTemp.createTemp('noted_icloud_snaps');
    f = await w.picked();
    _wrap();
    nb = _notebook(f);
    channelHooks();
    _launched = true;
    await nb.load();
    await nb.discoveryIdle;
    pageIds.add(nb.currentId!);
    await nb.flush();
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
  }

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
    final s = snapshot!;
    snapshot = null;
    log.add('crash and relaunch');
    life++; // the old life writes nothing from here on, `_restore` included
    await quit(flush: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
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

  Future<T> exemptAsync<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {#exempt: true});

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

  void daemonWrite(File f, String text) =>
      retrySync(() => f.writeAsStringSync(text));

  // -- Operations ----------------------------------------------------------------------

  // The markers that are in no file of the folder or the app's data, not
  // counting a version that is still unresolved in iCloud or a file that is
  // only a stub (the daemon has its text).
  /// Every file of the world that holds [marker], excluded ones too.
  List<String> where(String marker) => [
    for (final e in w.root.listSync(recursive: true, followLinks: false))
      if (e is File && _holds(e, marker)) _base(e.path),
  ];

  bool _holds(File e, String marker) {
    try {
      return latin1.decode(e.readAsBytesSync()).contains(marker);
    } on FileSystemException {
      return false;
    }
  }

  List<String> missing() {
    final texts = StringBuffer();
    for (final e in w.root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      // A leftover or a temp is not where a version is kept.
      final name = _base(e.path);
      if (name.endsWith(asideSuffix) ||
          name.endsWith(verifiedSuffix) ||
          name.endsWith('.tmp')) {
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
    audit(op);
  }

  Future<void> run(String op) async {
    switch (op) {
      case 'appEdit':
        await appEdit();
      case 'appCreate':
        final id = await nb.createPage();
        if (quiet) pageIds.add(id);
      case 'daemonEdit':
        await daemonEdit();
      case 'daemonConflict':
        await daemonConflict();
      case 'daemonEvict':
        await daemonEvict();
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
    }
    await pause();
  }

  // What held each durable marker after the last step (file names), to say where
  // one was when it goes. Run outside the life zone: a read there is blocked
  // once the process has been relaunched.
  Map<String, List<String>> _held = {};

  void audit(String op) {
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
    final now = {for (final m in durable.keys) m: where(m)};
    for (final m in missing()) {
      if (reportedMissing.add(m)) {
        log.add(
          'MISSING $m (${durable[m]}) after $op; it was in ${_held[m]}, the files are ${listing().join(' ')}',
        );
      }
    }
    _held = now;
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
    final id = w.channel.addVersion(
      file.path,
      utf8.encode(writePage(current.insertNode(box(b)))),
    );
    versions.add((path: file.path, id: id));
    claim(a, 'a daemon replace of ${_base(file.path)}');
    claim(b, 'a conflict version of ${_base(file.path)}');
    versionOfMarker[b] = versions.last;
    if (rnd.nextBool()) await w.channel.emit('changed', {'path': file.path});
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

  Future<void> daemonMaterialize({String? path}) async {
    final target =
        path ??
        (evicted.isEmpty
            ? null
            : (evicted.keys.toList()..sort())[rnd.nextInt(evicted.length)]);
    if (target == null) return;
    final text = evictedText[target];
    if (text == null) return;
    retrySync(() {
      File(target).writeAsStringSync(text);
      final stub = File(_stubOf(target));
      if (stub.existsSync()) stub.deleteSync();
    });
    if (rnd.nextBool()) await w.channel.emit('changed', {'path': target});
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

  Future<void> settle() async {
    phase = 'settle';
    for (final p in evicted.keys.toList()) {
      await daemonMaterialize(path: p);
    }
    for (var round = 0; round < 6; round++) {
      phase = 'settle: landAll';
      await f.landAllVersions();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // The presenter tells the app about every file.
      phase = 'settle: changed events';
      for (final e in w.drive.listSync(followLinks: false)) {
        if (e is File) await w.channel.emit('changed', {'path': e.path});
      }
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
      if (left.isEmpty &&
          leftovers.isEmpty &&
          !nb.trouble.isTrouble &&
          round >= 1) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
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
          problems.add('a version of ${_base(v.path)} is still unresolved');
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
          problems.add('page $id: live ${a.length} boxes, reload ${b.length}');
        }
      } on Object catch (e) {
        problems.add('page $id could not be opened after a reload: $e');
      }
    }
    // 3. nothing known is gone.
    for (final id in pageIds) {
      if (!ids.contains(id)) {
        problems.add('page $id is not listed after a reload');
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
    problems.addAll(violations);
    if (problems.isNotEmpty) {
      fail(
        'seed $seed (kill at $killKind #$killNth) failed:\n${problems.take(12).join('\n')}\nsteps: ${log.join(', ')}',
      );
    }
  }

  Future<void> dispose() async {
    await w.dispose();
    if (snapRoot.existsSync()) {
      try {
        await deleteTestFolder(snapRoot);
      } on FileSystemException {
        // Left behind.
      }
    }
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
    'landAll',
    'landAll',
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
  return plan;
}

Future<void> _sequence(int seed) async {
  final s = _Sim(seed);
  final recorder = _Recorder(s);
  await IOOverrides.runWithIOOverrides(() async {
    try {
      Future<void> whole() async {
        await s.boot();
        s.armed = true;
        Future<void> run() async {
          for (final op in _plan(s)) {
            await s.step(op);
            if (s.snapshot != null) await s.crash();
          }
          if (s.snapshot != null) await s.crash();
          await s.inLife(s.settle);
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
    } finally {
      await s.dispose().timeout(const Duration(seconds: 15), onTimeout: () {});
    }
  }, TracingIoOverrides(recorder));
  _ran++;
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
            try {
              await deleteTestFolder(root);
            } on FileSystemException {
              // A handle that is still closing.
            }
          }
        },
      );
    }
  });
}

void main() {
  final seeds = [for (var i = 1; i <= _fixedSeeds + _extraSeeds; i++) i];

  _windowsFolderTests();

  group('an iCloud folder: a live notebook and a reload agree (R5.13)', () {
    for (final seed in seeds) {
      test(
        'seed $seed',
        () => _sequence(seed),
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    test('every kill point was reached by some seed', () {
      if (_ran < _fixedSeeds) return; // a single seed was asked for
      expect(
        _killed.toSet(),
        containsAll(_killKinds),
        reason:
            'the kinds never killed: ${_killKinds.toSet().difference(_killed)}',
      );
    });
  });
}
