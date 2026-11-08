// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

import 'clock.dart';
import 'graph_client.dart';
import 'journal.dart';
import 'remote_item.dart';
import 'remote_tree.dart';
import 'types.dart';

/// A round can't go on for a reason that isn't an error (a missing folder).
class _PauseRound implements Exception {
  _PauseRound(this.reason);
  final String reason;
}

class _Fetched {
  _Fetched(this.map, this.deltaLink, this.endpoint, this.seq, this.resync);
  final Map<String, RemoteEntry> map;
  final String deltaLink;
  final String endpoint;
  final int seq;
  final GraphGone? resync;
}

class _Download {
  _Download(this.file, this.identity);
  final File file;
  final ContentIdentity identity;
}

enum _Local { absent, aside, same, differs, notFile }

/// The read-only pull of one OneDrive folder into a working copy (stage 3).
///
/// A round lists the remote changes up to a delta link, folds them into the
/// journal's map, derives paths from the tree and applies the difference to
/// the working copy: a state-based reconcile, run on every poll, so a failed
/// step is simply retried. It never reads page content: it moves bytes and
/// compares lengths and hashes. Nothing local is overwritten or deleted unless
/// it still equals what the engine last put there. No network I/O happens
/// under a [FolderLocks] lock.
class PullEngine {
  PullEngine({
    required this.workingCopy,
    required this.stateDir,
    required this.locks,
    required this.graph,
    required this.driveId,
    required this.rootItemId,
    Clock? clock,
    this.onStep,
  }) : _clock = clock ?? const SystemClock(),
       _store = JournalStore(stateDir),
       _blobs = BlobStore(
         Directory('${stateDir.path}${Platform.pathSeparator}base'),
       ),
       _tmpDir = Directory('${stateDir.path}${Platform.pathSeparator}tmp');

  final Directory workingCopy;
  final Directory stateDir;
  final FolderLocks locks;
  final GraphClient graph;
  final String driveId;
  final String rootItemId;

  /// A seam for tests: called at each named step of a round, and free to
  /// throw to stand for a kill there (or to edit a file, as the Files app
  /// would). The core's own hooks are passed through as `replaceBeforePublish`,
  /// `replaceBeforeRestore`, `deleteBeforeDelete` and `deleteBeforeRestore`; `restoreCopy` is before a kept
  /// copy is put back.
  /// Steps: `deltaFetched`, `mapSaved`,
  /// `downloaded`, `blobWritten`, `published`, `journalSaved`, `deleted`,
  /// `repathCopied`, `movingWritten`, `oldDeleted`.
  final void Function(String step)? onStep;

  /// How long a planned delete must keep being planned before it applies.
  static const Duration deleteDelay = Duration(seconds: 30);

  final Clock _clock;
  final JournalStore _store;
  final BlobStore _blobs;
  final Directory _tmpDir;
  late final BlobStore _keep = BlobStore(
    Directory('${stateDir.path}${Platform.pathSeparator}keep'),
  );
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Journal? _journal;
  bool _started = false;
  Future<RoundResult>? _running;
  Future<void>? _answering;
  SyncStatus _status = const SyncStatus(SyncState.idle);
  List<SyncIssue> _issues = const [];
  List<SyncIssue> _roundIssues = [];
  GuardQuestion? _question;
  Map<String, String> _guardKeys = {};
  RoundResult _cur = RoundResult();
  Set<String> _binderKeys = {};
  int _tmpCounter = 0;

  static const String _sep = '/';

  // --- Public API ----------------------------------------------------------

  SyncStatus get status => _status;
  GuardQuestion? get guardQuestion => _question;
  List<SyncIssue> get issues => List.unmodifiable(_issues);
  Stream<void> get changes => _changes.stream;

  /// Runs one round. Never overlaps: a call during a round returns the
  /// running one. Never throws; [RoundResult.error] says what stopped it.
  Future<RoundResult> runRound() {
    final running = _running;
    if (running != null) return running;
    final answering = _answering;
    if (answering != null) return answering.then((_) => runRound());
    final f = _runGuarded().whenComplete(() => _running = null);
    return _running = f;
  }

  /// Answers the question: [remove] removes the listed paths here too, else
  /// they are kept here. Only paths still in the plan count. Returns the round
  /// that follows (null if no listed path was still in the plan).
  Future<RoundResult?> answerGuard(GuardQuestion q, {required bool remove}) async {
    // One answer at a time, and never while a round is running.
    while (true) {
      final running = _running;
      if (running != null) {
        await running;
        continue;
      }
      final other = _answering;
      if (other == null) break;
      await other;
    }
    final done = Completer<void>();
    _answering = done.future;
    final j = _journal;
    var any = false;
    try {
      if (j == null) return null;
      // What this answer adds, to take it back if it can't be saved: an answer
      // that is not on disk must not act later.
      final added = <String>[];
      final target = remove ? j.approved : j.kept;
      for (final p in q.paths) {
        final key = _guardKeys[p];
        if (key == null) continue;
        any = true;
        if (target.add(key)) added.add(key);
      }
      if (any) {
        try {
          await _save();
        } catch (_) {
          added.forEach(target.remove);
          rethrow;
        }
        _question = null;
        _notify();
      }
    } finally {
      _answering = null;
      done.complete();
    }
    return any ? await runRound() : null;
  }

  void dispose() {
    _changes.close();
  }

  // --- A round -------------------------------------------------------------

  Future<RoundResult> _runGuarded() async {
    final r = RoundResult();
    _cur = r;
    _setStatus(const SyncStatus(SyncState.running));
    try {
      await _round();
    } catch (e) {
      // What the start of the round listed (a copy put back, say) stays.
      final extra = _roundIssues.where((i) => !_issues.contains(i)).toList();
      if (extra.isNotEmpty) _issues = [..._issues, ...extra];
      if (e is! _PauseRound) r.error = e;
      _setStatus(_statusFor(e));
      return r;
    }
    return r;
  }

  SyncStatus _statusFor(Object e) {
    if (e is SignedOutException || e is GraphUnauthorized) {
      return const SyncStatus(SyncState.signedOut);
    }
    if (e is JournalUnreadable) {
      return SyncStatus(SyncState.journalUnreadable, e.message);
    }
    if (e is _PauseRound) return SyncStatus(SyncState.paused, e.reason);
    // Never `'$e'` of an unknown type: it can carry an address with a token.
    if (e is GraphException) return SyncStatus(SyncState.paused, e.message);
    if (e is FileSystemException) {
      return SyncStatus(SyncState.paused, e.message);
    }
    return SyncStatus(
      SyncState.paused,
      'Unexpected problem (${e.runtimeType})',
    );
  }

  void _setStatus(SyncStatus s) {
    _status = s;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _step(String name) => onStep?.call(name);

  void _issue(String path, String reason) =>
      _roundIssues.add(SyncIssue(path, reason));

  Future<void> _round() async {
    _roundIssues = [];
    if (!await workingCopy.exists()) {
      throw _PauseRound('The OneDrive folder is missing on this device');
    }
    await _start();
    final j = _journal!;
    _Fetched? fetched;
    try {
      fetched = await _fetchRemote();
    } on GraphNotFound {
      // The delta call itself may be what is missing: is the root gone?
      var gone = false;
      try {
        final root = await graph.getItem(driveId, rootItemId);
        gone = root.deleted || !root.isFolder;
      } on GraphNotFound {
        gone = true;
      }
      if (!gone) rethrow;
      _setStatus(
        const SyncStatus(SyncState.rootGone, 'The OneDrive folder is gone'),
      );
      return;
    }
    if (fetched == null) return;
    j.map = fetched.map;
    j.deltaLink = fetched.deltaLink;
    j.endpoint = fetched.endpoint;
    j.seq = fetched.seq;
    final view = buildView(j.map, rootItemId);
    if (fetched.resync?.uploadDifferences ?? false) {
      // A path missing remotely is kept and listed, never turned into a delete.
      for (final e in j.files.entries) {
        if (!view.desired.containsKey(e.key) &&
            !view.treePaths.contains(e.key) &&
            !view.skippedIds.contains(e.value.itemId) &&
            !view.desired.values.any((d) => d.item.id == e.value.itemId)) {
          j.kept.add(e.key);
        }
      }
    }
    await _save();
    _step('mapSaved');
    try {
      await _completeMoving();
      await _apply(view);
    } finally {
      _issues = _roundIssues;
      _notify();
    }
    final mismatching = j.mismatches.values.any((n) => n >= 3);
    if (_question != null) {
      _setStatus(const SyncStatus(SyncState.guardWaiting));
    } else if (mismatching) {
      _setStatus(
        const SyncStatus(
          SyncState.paused,
          'Downloads keep failing the checksum from OneDrive',
        ),
      );
    } else {
      _setStatus(const SyncStatus(SyncState.idle));
    }
  }

  Future<void> _save() => _store.save(_journal!);

  // --- Start ---------------------------------------------------------------

  Future<void> _start() async {
    if (_started) return;
    final loaded = await _store.load();
    _journal = loaded ?? Journal();
    await stateDir.create(recursive: true);
    if (await _tmpDir.exists()) {
      await for (final e in _tmpDir.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } on FileSystemException {
          // Left for the next start.
        }
      }
    } else {
      await _tmpDir.create(recursive: true);
    }
    await _sweepAll();
    await _completeMoving();
    _started = true;
  }

  bool _isAssetsOrTemplates(String name) {
    final n = foldKey(name);
    return n == 'templates' || n.endsWith('.assets');
  }

  /// G15: puts back what a killed replace or delete left set aside, in every
  /// mirrored folder, under the folder's lock.
  Future<void> _sweepAll() async {
    final dirs = <Directory>[workingCopy];
    Future<void> below(Directory d) async {
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory) {
          dirs.add(e);
          await below(e);
        }
      }
    }

    await for (final e in workingCopy.list(followLinks: false)) {
      if (e is! Directory) continue;
      dirs.add(e);
      final name = _basename(e.path);
      if (_isAssetsOrTemplates(name)) {
        await below(e);
        continue;
      }
      await for (final s in e.list(followLinks: false)) {
        if (s is Directory && _isAssetsOrTemplates(_basename(s.path))) {
          dirs.add(s);
          await below(s);
        }
      }
    }
    for (final d in dirs) {
      await _sweepFolder(d);
    }
  }

  Future<void> _sweepFolder(Directory d) async {
    try {
      await locks.run(
        Directory(_lockDirForAbsDir(d.path)),
        () => sweepAsideFiles(d, extension: ''),
      );
    } on FileSystemException {
      // Left for the next sweep.
    }
  }

  // --- Paths ---------------------------------------------------------------

  String get _root => workingCopy.absolute.path;

  String _abs(String rel) => rel.isEmpty
      ? _root
      : '$_root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

  String _basename(String p) => p.split(RegExp(r'[\\/]')).last;

  String _relOf(String abs) {
    var r = abs.substring(_root.length);
    while (r.startsWith('/') || r.startsWith(r'\')) {
      r = r.substring(1);
    }
    return r.replaceAll(r'\', '/');
  }

  /// The notebook's own rule for a root-level folder that is not a binder
  /// (exact, case-sensitive): a dot folder, `*.assets` or `templates`.
  bool _notABinderFolder(String name) =>
      name.startsWith('.') || name.endsWith('.assets') || name == 'templates';

  /// The folder whose lock covers [rel]: the binder folder for anything in or
  /// under a root-level folder that is not `templates` or `*.assets` (for the
  /// folder itself too, when [folder]), else the root. Decided by the path
  /// alone, so it stays the same when the binder file has moved or gone.
  String _lockDirFor(String rel, {bool folder = false}) {
    final segs = rel.split('/');
    if (segs.isNotEmpty &&
        (segs.length >= 2 || folder) &&
        !_notABinderFolder(segs[0])) {
      return _abs(segs[0]);
    }
    return _root;
  }

  String _lockDirForRel(String rel) => _lockDirFor(rel);

  String _lockDirForAbsDir(String dirPath) =>
      _lockDirFor(_relOf(dirPath), folder: true);

  /// The local path (relative) for the remote path [segs]: folders already
  /// tracked keep their disk spelling.
  String _localPathFor(List<String> segs) {
    final j = _journal!;
    var local = '';
    for (var i = 0; i < segs.length - 1; i++) {
      final key = segs.take(i + 1).map(foldKey).join('/');
      local =
          j.folders[key] ?? (local.isEmpty ? segs[i] : '$local$_sep${segs[i]}');
    }
    return local.isEmpty ? segs.last : '$local$_sep${segs.last}';
  }

  bool _exists(String abs) =>
      FileSystemEntity.typeSync(abs, followLinks: false) !=
      FileSystemEntityType.notFound;

  bool _asidePresent(String abs) {
    final f = File(abs);
    final dir = f.parent;
    if (!dir.existsSync()) return false;
    final name = _basename(abs);
    try {
      for (final e in dir.listSync(followLinks: false)) {
        final n = _basename(e.path);
        if ((n.endsWith(asideSuffix) || n.endsWith(verifiedSuffix)) &&
            n.startsWith('$name.')) {
          return true;
        }
      }
    } on FileSystemException {
      return true;
    }
    return false;
  }

  void _changed(String abs) {
    _cur.changedPaths.add(abs);
    if (_basename(abs) == binderFileName) _cur.anyBinderChange = true;
  }

  File _newTmp(String ext) =>
      File('${_tmpDir.path}${Platform.pathSeparator}${++_tmpCounter}.$ext');

  // --- Fetching the remote -------------------------------------------------

  Future<_Fetched?> _fetchRemote() async {
    final j = _journal!;
    var fresh = j.deltaLink == null;
    var working = fresh ? <String, RemoteEntry>{} : Map.of(j.map);
    var seq = j.seq;
    var endpoint = j.endpoint;
    Uri? link = fresh ? null : Uri.parse(j.deltaLink!);
    GraphGone? resync;
    var resyncs = 0;
    var rootDeleted = false;

    Future<bool> seed() async {
      try {
        final root = await graph.getItem(driveId, rootItemId);
        if (root.deleted || !root.isFolder) return false;
      } on GraphNotFound {
        return false;
      }
      working[rootItemId] = RemoteEntry(
        id: rootItemId,
        parent: null,
        name: '',
        folder: true,
      );
      return true;
    }

    if (fresh && !await seed()) {
      _setStatus(
        const SyncStatus(SyncState.rootGone, 'The OneDrive folder is gone'),
      );
      return null;
    }

    late String deltaLink;
    while (true) {
      try {
        DeltaPage page;
        if (link != null) {
          page = await graph.deltaAt(link);
        } else if (endpoint == 'drive') {
          page = await graph.deltaStart(driveId, null);
        } else {
          try {
            page = await graph.deltaStart(driveId, rootItemId);
            endpoint = 'folder';
          } on GraphNotSupported {
            page = await graph.deltaStart(driveId, null);
            endpoint = 'drive';
          } on GraphNotFound {
            // Either the folder form of delta isn't there, or the root went
            // since it was read: look again before choosing.
            RemoteItem? again;
            try {
              again = await graph.getItem(driveId, rootItemId);
            } on GraphNotFound {
              again = null;
            }
            if (again == null || again.deleted || !again.isFolder) {
              _setStatus(
                const SyncStatus(
                  SyncState.rootGone,
                  'The OneDrive folder is gone',
                ),
              );
              return null;
            }
            page = await graph.deltaStart(driveId, null);
            endpoint = 'drive';
          }
        }
        while (true) {
          for (final it in page.items) {
            seq++;
            if (it.id == rootItemId) {
              if (it.deleted) rootDeleted = true;
              continue;
            }
            if (it.deleted) {
              working.remove(it.id);
              continue;
            }
            // The drive's own root is never ours.
            if (it.isRoot) continue;
            var parent = it.parentId;
            if (parent == null) {
              // A live item without a parent: a known one keeps its parent,
              // an unknown one can't be placed, so the round fails.
              final known = working[it.id];
              if (known == null) {
                throw GraphException('A listed item had no parent');
              }
              parent = known.parent;
            }
            working[it.id] = RemoteEntry(
              id: it.id,
              parent: parent,
              name: it.name ?? '',
              folder: it.isFolder && !it.isSpecial,
              special: it.isSpecial,
              cTag: it.cTag,
              hash: it.quickXorHash,
              size: it.size,
              seq: seq,
            );
          }
          final next = page.nextLink;
          if (next != null) {
            page = await graph.deltaAt(next);
            continue;
          }
          final done = page.deltaLink;
          if (done == null) {
            throw GraphException('A delta page had no link to follow');
          }
          deltaLink = done.toString();
          break;
        }
        break;
      } on GraphGone catch (g) {
        if (++resyncs > 3) rethrow;
        resync = g;
        fresh = true;
        working = <String, RemoteEntry>{};
        rootDeleted = false;
        link = g.location;
        if (!await seed()) {
          _setStatus(
            const SyncStatus(SyncState.rootGone, 'The OneDrive folder is gone'),
          );
          return null;
        }
      }
    }
    _step('deltaFetched');
    if (rootDeleted) {
      _setStatus(
        const SyncStatus(SyncState.rootGone, 'The OneDrive folder is gone'),
      );
      return null;
    }
    final pruned = pruneToSubtree(working, rootItemId);

    // Folders new to an existing map may not come with their children.
    if (!fresh) {
      final queue = [
        for (final e in pruned.values)
          if (e.folder && e.id != rootItemId && !j.map.containsKey(e.id)) e.id,
      ];
      final listed = <String>{...queue};
      for (var i = 0; i < queue.length; i++) {
        final List<RemoteItem> kids;
        try {
          kids = await graph.children(driveId, queue[i]);
        } on GraphNotFound {
          continue;
        }
        for (final k in kids) {
          if (k.deleted || k.id == rootItemId) continue;
          if (!pruned.containsKey(k.id)) {
            seq++;
            pruned[k.id] = RemoteEntry(
              id: k.id,
              parent: k.parentId ?? queue[i],
              name: k.name ?? '',
              folder: k.isFolder && !k.isSpecial,
              special: k.isSpecial,
              cTag: k.cTag,
              hash: k.quickXorHash,
              size: k.size,
              seq: seq,
            );
          }
          if (k.isFolder && listed.add(k.id)) queue.add(k.id);
        }
      }
    }
    return _Fetched(pruned, deltaLink, endpoint ?? 'folder', seq, resync);
  }

  // --- The re-path journal step --------------------------------------------

  Future<bool> _hasIdentity(String abs, ContentIdentity id) async {
    try {
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      return await ContentIdentity.ofFile(abs) == id;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _completeMoving() async {
    final j = _journal!;
    final m = j.moving;
    if (m == null) return;
    final rec = j.files[m.oldKey];
    final oldAbs = _abs(m.oldPath);
    final newAbs = _abs(m.newPath);
    final oldGone = !_exists(oldAbs) && !_asidePresent(oldAbs);
    if (rec != null &&
        !j.files.containsKey(m.newKey) &&
        oldGone &&
        await _hasIdentity(newAbs, m.identity)) {
      j.files.remove(m.oldKey);
      rec.path = m.newPath;
      j.files[m.newKey] = rec;
      await _save();
      _notify();
    }
    // Whatever else is left is redone from a fresh snapshot by the plan, but
    // first a file with the snapshot's bytes must be on disk.
    await _settleMoving();
  }

  /// Confirms a file with the entry's bytes is on disk (putting the kept copy
  /// back when neither the new nor the old path has them), then clears the
  /// entry and drops the kept copy. Until confirmed the entry stays.
  Future<void> _settleMoving() async {
    final j = _journal!;
    final m = j.moving;
    if (m == null) return;
    if (!await _confirmMoving(m)) return;
    j.moving = null;
    await _save();
    await _keep.remove(m.keep);
  }

  Future<bool> _confirmMoving(Moving m) async {
    final oldAbs = _abs(m.oldPath);
    final newAbs = _abs(m.newPath);
    if (await _hasIdentity(newAbs, m.identity) ||
        await _hasIdentity(oldAbs, m.identity)) {
      return true;
    }
    final j = _journal!;
    // A snapshot that is what OneDrive had needs no restoring: only one with
    // local edits does.
    final rec = j.files[m.oldKey] ?? j.files[m.newKey];
    if (rec?.base == m.identity) return true;
    final keep = _keep.fileFor(m.keep);
    if (!keep.existsSync() ||
        await ContentIdentity.ofFile(keep.path) != m.identity) {
      _issue(m.oldPath, 'The earlier copy of this page could not be found');
      return true;
    }
    // Back at the old path if its folder is there and the name is free; else
    // beside it, or beside the new path when the old folder is gone.
    final oldFolderThere = File(oldAbs).parent.existsSync();
    final String name = _basename(oldAbs);
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final String lockRel = oldFolderThere ? m.oldPath : m.newPath;
    final String folderAbs = oldFolderThere
        ? oldAbs.substring(0, oldAbs.length - name.length)
        : newAbs.substring(0, newAbs.length - _basename(newAbs).length);
    String sibling() =>
        '$folderAbs${conflictCopyName(name, label: 'recovered', extension: ext)}';
    var target = oldAbs;
    if (!oldFolderThere || _exists(oldAbs) || _asidePresent(oldAbs)) {
      target = sibling();
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      final tmp = _newTmp('rs');
      try {
        _step('restoreCopy');
        await keep.copy(tmp.path);
        final dest = target;
        final ok = await locks.run(
          Directory(_lockDirForRel(lockRel)),
          () => publishExclusive(tmp, dest),
        );
        if (ok && await _hasIdentity(dest, m.identity)) {
          _changed(dest);
          _issue(
            _relOf(dest),
            'Put back: the new copy of this page changed before the old one was removed',
          );
          return true;
        }
      } on FileSystemException {
        return false;
      } finally {
        _dropTemp(tmp);
      }
      target = sibling();
    }
    return false;
  }

  /// Under the locks of both paths (the new folder's first, when they differ),
  /// deletes the old file only if the new one still holds [identity]. Null
  /// when the new one changed: nothing is deleted.
  Future<DeleteResult?> _deleteChecked(
    String oldRel,
    String newRel,
    ContentIdentity identity,
  ) {
    final oldAbs = _abs(oldRel);
    final newAbs = _abs(newRel);
    Future<DeleteResult?> job() async {
      if (!await _hasIdentity(newAbs, identity)) return null;
      return deleteFileIfMatches(oldAbs, identity: identity);
    }

    final oldDir = Directory(_lockDirForRel(oldRel));
    final newDir = Directory(_lockDirForRel(newRel));
    if (FolderLocks.keyOf(oldDir) == FolderLocks.keyOf(newDir)) {
      return locks.run(oldDir, job);
    }
    return locks.run(newDir, () => locks.run(oldDir, job));
  }

  // --- Applying ------------------------------------------------------------

  Future<void> _apply(RemoteView view) async {
    final j = _journal!;
    final now = _clock.now().millisecondsSinceEpoch;
    _roundIssues.addAll(view.issues);
    _binderKeys = {
      ...view.binderKeys,
      for (final e in j.files.entries)
        if (!e.value.retained &&
            e.key.split('/').length == 2 &&
            e.key.endsWith('/$binderFileName'))
          e.key.split('/').first,
    };
    j.kept.removeWhere(
      (k) => view.desired.containsKey(k) || !j.files.containsKey(k),
    );
    j.mismatches.removeWhere((k, _) => !view.desired.containsKey(k));

    final desiredIds = <String, String>{
      for (final d in view.desired.values) d.item.id: d.key,
    };

    // --- Plan the re-paths.
    final repaths = <(String, DesiredFile)>[];
    final held = <String>{};
    final heldKeys = <String>{};
    final byId = <String, String>{
      for (final e in j.files.entries)
        if (e.value.itemId != null && !e.value.retained) e.value.itemId!: e.key,
    };
    final keys = view.desired.keys.toList()..sort();
    // Whether the item [id] has a record here and is wanted at another path.
    bool moving(String? id) {
      if (id == null) return false;
      final to = desiredIds[id];
      final from = byId[id];
      return to != null && from != null && from != to;
    }

    for (final k in keys) {
      final d = view.desired[k]!;
      final rec = j.files[k];
      if (rec != null && rec.itemId == d.item.id && !rec.retained) continue;
      final src = byId[d.item.id];
      if (src == null || src == k) continue;
      final occupied = rec != null && !rec.retained;
      // Held only when the item in the way is itself moving (a swap, or a
      // chain that clears once its tail has moved; the tail has a free
      // target, so it moves in this round). A stale record at the
      // target (its item was deleted or replaced) is no obstacle: the row for
      // that path applies, and the old record is dropped when it lasts.
      if (occupied && moving(rec.itemId)) {
        _issue(
          d.path,
          'Moved on OneDrive, but something is in the way here; waiting',
        );
        held.add(src);
        heldKeys
          ..add(k)
          ..add(src);
        continue;
      }
      if (occupied) continue;
      repaths.add((src, d));
    }

    // A binder folder renamed: moved as a whole, or not at all.
    final heldPrefixes = <String>{};
    final groups = <String, List<(String, DesiredFile)>>{};
    for (final rp in repaths) {
      final sf = rp.$1.split('/');
      final df = rp.$2.key.split('/');
      if (sf.length >= 2 &&
          df.length >= 2 &&
          sf[0] != df[0] &&
          j.files.containsKey('${sf[0]}/$binderFileName') &&
          !j.files['${sf[0]}/$binderFileName']!.retained) {
        (groups['${sf[0]}>${df[0]}'] ??= []).add(rp);
      }
    }
    final inHeldGroup = <String>{};
    for (final g in groups.entries) {
      var blocked = false;
      for (final (src, d) in g.value) {
        final rec = j.files[src]!;
        if (d.isAttachment) continue;
        // An absent old file is no re-path at all (it is handled one by one).
        if (!_exists(_abs(rec.path))) continue;
        final target = _abs(_localPathFor(d.segs));
        if (!_exists(target)) continue;
        // A target that already holds the same bytes (the engine's own copy
        // from a step that was killed) is free.
        if (!await _sameFile(_abs(rec.path), target)) blocked = true;
      }
      if (blocked) {
        final names = g.key.split('>');
        heldPrefixes.addAll(names);
        for (final (src, _) in g.value) {
          inHeldGroup.add(src);
        }
        _issue(
          g.value.first.$2.segs.first,
          'A renamed binder can\'t be moved here: a different file is in the way',
        );
      }
    }

    // --- Plan the deletes.
    final planned = <String>{};
    final mustDropNow = <String>[];
    for (final e in j.files.entries.toList()) {
      final key = e.key;
      final rec = e.value;
      if (view.desired.containsKey(key)) continue;
      final abs = _abs(rec.path);
      if (rec.retained) {
        if (!_exists(abs) && !_asidePresent(abs)) mustDropNow.add(key);
        continue;
      }
      final id = rec.itemId;
      if (id != null && view.skippedIds.contains(id)) continue;
      if (id != null && desiredIds.containsKey(id)) {
        // Its item lives at another path. Until that path carries the item's
        // record the move is pending; after, this is a leftover and goes
        // through the usual delete rules.
        if (j.files[desiredIds[id]!]?.itemId != id) continue;
      }
      if (view.treePaths.contains(key)) {
        _issue(rec.path, 'No longer mirrored; left here');
        continue;
      }
      if (isAttachmentPath(key)) {
        rec.retained = true;
        continue;
      }
      if (j.kept.contains(key)) {
        _issue(rec.path, 'Removed on OneDrive; kept here');
        continue;
      }
      if (!_exists(abs) && !_asidePresent(abs)) {
        mustDropNow.add(key);
        continue;
      }
      planned.add(key);
    }
    for (final k in mustDropNow) {
      j.files.remove(k);
      j.firstSeen.remove(k);
      j.approved.remove(k);
      j.kept.remove(k);
    }
    j.firstSeen.removeWhere((k, _) => !planned.contains(k));
    j.approved.removeWhere((k) => !planned.contains(k));
    final lasting = <String>[];
    for (final k in planned.toList()..sort()) {
      final first = j.firstSeen.putIfAbsent(k, () => now);
      if (now - first >= deleteDelay.inMilliseconds) {
        lasting.add(k);
      } else {
        _issue(j.files[k]!.path, 'Removed on OneDrive; waiting to be sure');
      }
    }

    // Nothing under a held binder folder is deleted meanwhile.
    lasting.removeWhere((k) {
      final segs = k.split('/');
      return segs.length >= 2 && heldPrefixes.contains(segs.first);
    });

    // --- The guard.
    _question = null;
    _guardKeys = {};
    final counted = j.files.entries
        .where((e) => !e.value.retained && !isAttachmentPath(e.key))
        .length;
    var exceeds = lasting.length > 10 || lasting.length > 0.2 * counted;
    if (!exceeds) {
      for (final b in _binderKeys) {
        final members = j.files.entries
            .where(
              (e) =>
                  e.key.startsWith('$b/') &&
                  !e.value.retained &&
                  !isAttachmentPath(e.key),
            )
            .map((e) => e.key)
            .toList();
        if (members.isNotEmpty && members.every(lasting.contains)) {
          exceeds = true;
        }
      }
    }
    if (exceeds) {
      final unasked = [
        for (final k in lasting)
          if (!j.approved.contains(k)) k,
      ];
      if (unasked.isNotEmpty) {
        _guardKeys = {for (final k in unasked) j.files[k]!.path: k};
        _question = GuardQuestion(_guardKeys.keys.toList()..sort());
        await _save();
        return;
      }
    }
    await _save();

    // --- Re-paths.
    final ordered = [...repaths]
      ..sort((a, b) {
        int rank((String, DesiredFile) x) =>
            x.$2.segs.length >= 2 && foldKey(x.$2.segs.last) == binderFileName
            ? 1
            : 0;
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : a.$2.key.compareTo(b.$2.key);
      });
    for (final (src, d) in ordered) {
      if (inHeldGroup.contains(src) || held.contains(src)) continue;
      await _repath(src, d);
    }
    // A move that is pending (held, or not finished) leaves its old record:
    // say so, every round.
    for (final e in j.files.entries) {
      final rec = e.value;
      final id = rec.itemId;
      if (id == null || rec.retained) continue;
      final to = desiredIds[id];
      if (to == null || to == e.key || j.files[to]?.itemId == id) continue;
      if (_roundIssues.any((i) => i.path == rec.path)) continue;
      _issue(rec.path, 'Moved on OneDrive; not moved here yet, will retry');
    }

    // --- Files that are new or changed.
    for (final k in keys) {
      final d = view.desired[k]!;
      final first = d.segs.first.toLowerCase();
      if (heldPrefixes.contains(first) && d.segs.length >= 2) continue;
      if (heldKeys.contains(k)) continue;
      final rec = j.files[k];
      if (rec == null || rec.retained) {
        await _rowNew(d, rec);
      } else {
        await _rowKnown(d, rec);
      }
    }

    // --- Lasting deletes.
    for (final k in lasting) {
      final rec = j.files[k];
      if (rec == null) continue;
      await _deleteOne(k, rec);
    }

    await _pruneFolders(view);
    await _listStrays(view);
    await _keep.sweep({if (j.moving != null) j.moving!.keep});
    await _blobs.sweep({
      for (final r in j.files.values)
        if (r.blob && r.base != null) r.base!.sha256,
    });
    await _save();
  }

  // --- Rows ----------------------------------------------------------------

  /// Whether [a] and [b] are one file, or two files with the same bytes.
  Future<bool> _sameFile(String a, String b) async {
    try {
      if (FileSystemEntity.typeSync(a, followLinks: false) !=
              FileSystemEntityType.file ||
          FileSystemEntity.typeSync(b, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      if (await FileSystemEntity.identical(a, b)) return true;
      return await ContentIdentity.ofFile(a) == await ContentIdentity.ofFile(b);
    } on FileSystemException {
      return false;
    }
  }

  bool _sameRemote(FileRecord r, RemoteEntry e) {
    if (r.hash != null && e.hash != null) {
      return r.hash == e.hash && r.size == e.size;
    }
    if (r.hash == null && e.hash == null) {
      return r.size == e.size && r.cTag == e.cTag;
    }
    return false;
  }

  bool _hasHash(RemoteEntry e) => e.hash != null || e.size == 0;

  bool _pageLike(DesiredFile d) {
    if (d.isAttachment) return false;
    final n = foldKey(d.segs.last);
    return n.endsWith('.canvas') || n == binderFileName;
  }

  Future<String> _quick(String abs) =>
      QuickXorHash.ofStream(File(abs).openRead());

  Future<(_Local, ContentIdentity?)> _localState(
    String rel,
    FileRecord rec,
  ) async {
    final abs = _abs(rel);
    final type = FileSystemEntity.typeSync(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (_asidePresent(abs) ? _Local.aside : _Local.absent, null);
    }
    if (type != FileSystemEntityType.file) return (_Local.notFile, null);
    final base = rec.base;
    final st = await File(abs).stat();
    final mt = st.modified.millisecondsSinceEpoch;
    if (base != null && rec.mtime == mt && st.size == base.length) {
      return (_Local.same, base);
    }
    final ident = await ContentIdentity.ofFile(abs);
    if (base != null && ident == base) {
      rec.mtime = mt;
      return (_Local.same, ident);
    }
    return (_Local.differs, ident);
  }

  Future<bool> _equalsRemote(
    String abs,
    ContentIdentity ident,
    RemoteEntry e,
  ) async {
    if (ident.length != e.size) return false;
    if (e.hash == null) return e.size == 0;
    return await _quick(abs) == e.hash;
  }

  Future<void> _adopt(
    DesiredFile d,
    String rel,
    ContentIdentity ident, {
    FileRecord? existing,
  }) async {
    final j = _journal!;
    final abs = _abs(rel);
    final pageLike = _pageLike(d);
    if (pageLike) await _blobs.put(File(abs), ident.sha256);
    final st = await File(abs).stat();
    final rec = existing ?? FileRecord(path: rel);
    rec
      ..path = rel
      ..itemId = d.item.id
      ..cTag = d.item.cTag
      ..hash = d.item.hash
      ..size = d.item.size
      ..base = ident
      ..blob = pageLike
      ..retained = false
      ..mtime = st.modified.millisecondsSinceEpoch;
    j.files[d.key] = rec;
    j.firstSeen.remove(d.key);
    j.mismatches.remove(d.key);
    await _save();
  }

  Future<void> _rowNew(DesiredFile d, FileRecord? retained) async {
    final j = _journal!;
    final rel = retained?.path ?? _localPathFor(d.segs);
    final abs = _abs(rel);
    final type = FileSystemEntity.typeSync(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (_asidePresent(abs)) {
        _issue(rel, 'Being replaced on this device; waiting');
        return;
      }
      await _publishNew(d, rel, retained);
      return;
    }
    if (type != FileSystemEntityType.file) {
      _issue(rel, 'Something else is already here; left alone');
      return;
    }
    if (!_hasHash(d.item)) {
      _issue(rel, 'OneDrive sent no checksum; left alone');
      return;
    }
    try {
      final ident = await ContentIdentity.ofFile(abs);
      if (await _equalsRemote(abs, ident, d.item)) {
        await _adopt(d, rel, ident, existing: retained);
      } else {
        _issue(rel, 'A different file is already here; left alone');
        j.mismatches.remove(d.key);
      }
    } on FileSystemException catch (e) {
      _issue(rel, 'Can\'t read the file here: ${e.message}');
    }
  }

  /// An error about this one item (a 4xx other than 401 and 429), not about
  /// the connection or the sign-in: the round goes on without the item.
  bool _itemLevel(GraphException e) {
    final c = e.statusCode;
    return c != null && c >= 400 && c < 500 && c != 401 && c != 429;
  }

  /// Downloads and checks one item. Null (with an issue listed) when it can't
  /// be applied.
  Future<_Download?> _download(DesiredFile d, String rel) async {
    final j = _journal!;
    if (!_hasHash(d.item)) {
      _issue(rel, 'OneDrive sent no checksum; not applied');
      return null;
    }
    final tmp = _newTmp('dl');
    try {
      await graph.download(driveId, d.item.id, tmp);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // Swept at the next start.
      }
      if (e is GraphException && _itemLevel(e)) {
        _issue(rel, 'OneDrive refused this file (${e.statusCode}); left alone');
        return null;
      }
      rethrow;
    }
    _step('downloaded');
    var ok = await tmp.length() == d.item.size;
    if (ok && d.item.hash != null) {
      ok = await _quick(tmp.path) == d.item.hash;
    }
    if (!ok) {
      try {
        await tmp.delete();
      } on FileSystemException {
        // Swept at the next start.
      }
      final n = (j.mismatches[d.key] ?? 0) + 1;
      j.mismatches[d.key] = n;
      _issue(
        rel,
        n >= 3
            ? 'The download keeps failing OneDrive\'s checksum; not applied'
            : 'The download failed OneDrive\'s checksum; trying again next time',
      );
      return null;
    }
    final ident = await ContentIdentity.ofFile(tmp.path);
    if (_pageLike(d)) {
      await _blobs.put(tmp, ident.sha256);
      _step('blobWritten');
    }
    return _Download(tmp, ident);
  }

  /// G11: makes the folders above [segs], tracking each. False (with an issue)
  /// when a tracked folder is gone or one can't be made.
  Future<bool> _ensureFolders(List<String> segs, String issuePath) async {
    final j = _journal!;
    var local = '';
    var changed = false;
    for (var i = 0; i < segs.length - 1; i++) {
      final key = segs.take(i + 1).map(foldKey).join('/');
      final tracked = j.folders[key];
      if (tracked != null) {
        local = tracked;
        if (!Directory(_abs(local)).existsSync()) {
          _issue(
            issuePath,
            'The folder was removed on this device; not recreated',
          );
          if (changed) await _save();
          return false;
        }
        continue;
      }
      local = local.isEmpty ? segs[i] : '$local$_sep${segs[i]}';
      final dir = Directory(_abs(local));
      if (!dir.existsSync()) {
        try {
          dir.createSync();
        } on FileSystemException catch (e) {
          _issue(issuePath, 'Can\'t make the folder: ${e.message}');
          if (changed) await _save();
          return false;
        }
      }
      j.folders[key] = local;
      changed = true;
    }
    if (changed) await _save();
    return true;
  }

  Future<void> _publishNew(
    DesiredFile d,
    String rel,
    FileRecord? retained,
  ) async {
    // The folder first: nothing is fetched for a folder that was removed.
    if (!await _ensureFolders(d.segs, rel)) return;
    final dl = await _download(d, rel);
    if (dl == null) return;
    try {
      final abs = _abs(rel);
      final lockDir = _lockDirForRel(rel);
      bool published;
      try {
        published = await locks.run(
          Directory(lockDir),
          () => publishExclusive(dl.file, abs),
        );
      } on FileSystemException catch (e) {
        _issue(rel, 'Can\'t write the file here: ${e.message}');
        return;
      }
      _step('published');
      if (published) {
        _changed(abs);
        await _adopt(d, rel, dl.identity, existing: retained);
        _step('journalSaved');
        return;
      }
      // Someone made the file meanwhile.
      try {
        final now = await ContentIdentity.ofFile(abs);
        if (now == dl.identity) {
          await _adopt(d, rel, now, existing: retained);
        } else {
          _issue(rel, 'A different file is already here; left alone');
        }
      } on FileSystemException catch (e) {
        _issue(rel, 'Can\'t read the file here: ${e.message}');
      }
    } finally {
      _dropTemp(dl.file);
    }
  }

  void _dropTemp(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // Swept at the next start.
    }
  }

  Future<void> _rowKnown(DesiredFile d, FileRecord rec) async {
    final rel = rec.path;
    final remoteSame = _sameRemote(rec, d.item);
    final (state, ident) = await _localState(rel, rec);
    if (remoteSame) {
      // The record takes the new item only while the local file is the one it
      // describes: otherwise the old record stays, pending and listed.
      var touched = false;
      if (state == _Local.same) {
        if (rec.itemId != d.item.id) {
          rec.itemId = d.item.id;
          touched = true;
        }
        if (rec.cTag != d.item.cTag) {
          rec.cTag = d.item.cTag;
          touched = true;
        }
      }
      if (touched) await _save();
      switch (state) {
        case _Local.same:
          break;
        case _Local.aside:
          _issue(rel, 'Being replaced on this device; waiting');
        case _Local.absent:
          _issue(rel, 'Missing on this device; not restored');
        case _Local.differs:
        case _Local.notFile:
          _issue(rel, 'Changed on this device; not uploaded');
      }
      return;
    }
    // The remote changed.
    switch (state) {
      case _Local.aside:
        _issue(rel, 'Being replaced on this device; waiting');
        return;
      case _Local.absent:
        _issue(rel, 'Missing on this device; OneDrive\'s version not applied');
        return;
      case _Local.notFile:
        _issue(rel, 'Changed on this device; OneDrive\'s version not applied');
        return;
      case _Local.differs:
        final abs = _abs(rel);
        if (ident != null &&
            _hasHash(d.item) &&
            await _equalsRemote(abs, ident, d.item)) {
          await _adopt(d, rel, ident, existing: rec);
        } else {
          _issue(
            rel,
            'Changed on this device; OneDrive\'s version not applied',
          );
        }
        return;
      case _Local.same:
        break;
    }
    if (d.isAttachment) {
      // The local file equals its base, which differs from the remote's: a
      // changed attachment is never replaced.
      _issue(rel, 'Differs from OneDrive\'s file; left alone');
      return;
    }
    final dl = await _download(d, rel);
    if (dl == null) return;
    try {
      final abs = _abs(rel);
      final lockDir = _lockDirForRel(rel);
      final ReplaceResult res;
      try {
        res = await locks.run(
          Directory(lockDir),
          () => replaceIfUnchanged(
            dl.file,
            abs,
            null,
            identity: rec.base,
            beforePublish: () => _step('replaceBeforePublish'),
            beforeRestore: () => _step('replaceBeforeRestore'),
          ),
        );
      } on FileSystemException catch (e) {
        _issue(rel, 'Can\'t replace the file here: ${e.message}');
        await _sweepFolder(File(abs).parent);
        return;
      }
      _step('published');
      if (res.replaced) {
        _changed(abs);
        await _adopt(d, rel, dl.identity, existing: rec);
        _step('journalSaved');
      } else {
        _issue(rel, 'Changed on this device; OneDrive\'s version not applied');
        if (res.keptPath != null) {
          _issue(
            _relOf(res.keptPath!),
            'Kept as a copy of a version replaced meanwhile',
          );
        }
      }
    } finally {
      _dropTemp(dl.file);
    }
  }

  // --- Deletes -------------------------------------------------------------

  Future<void> _deleteOne(String key, FileRecord rec) async {
    final j = _journal!;
    final rel = rec.path;
    final abs = _abs(rel);
    final base = rec.base;
    if (base == null) {
      _issue(
        rel,
        'Removed on OneDrive; not removed here (no earlier version known)',
      );
      return;
    }
    if (!_exists(abs) && _asidePresent(abs)) {
      _issue(rel, 'Being replaced on this device; waiting');
      return;
    }
    final DeleteResult res;
    try {
      res = await locks.run(
        Directory(_lockDirForRel(rel)),
        () => deleteFileIfMatches(
          abs,
          identity: base,
          beforeDelete: () async => _step('deleteBeforeDelete'),
          beforeRestore: () => _step('deleteBeforeRestore'),
        ),
      );
    } on FileSystemException catch (e) {
      _issue(rel, 'Can\'t remove the file here: ${e.message}');
      await _sweepFolder(File(abs).parent);
      return;
    }
    _step('deleted');
    switch (res.outcome) {
      case DeleteOutcome.deleted:
        _changed(abs);
        j.files.remove(key);
      case DeleteOutcome.absent:
        j.files.remove(key);
      case DeleteOutcome.changed:
      case DeleteOutcome.changedKept:
        _issue(
          rel,
          'Removed on OneDrive; changed on this device, so not removed',
        );
        return;
    }
    j.firstSeen.remove(key);
    j.approved.remove(key);
    await _save();
  }

  // --- Re-path -------------------------------------------------------------

  Future<void> _repath(String srcKey, DesiredFile d) async {
    final j = _journal!;
    if (j.moving != null) {
      _issue(
        j.files[srcKey]!.path,
        'An earlier move is not settled yet; waiting',
      );
      return;
    }
    final rec = j.files[srcKey]!;
    final oldRel = rec.path;
    final oldAbs = _abs(oldRel);
    final newRel = _localPathFor(d.segs);
    final newAbs = _abs(newRel);

    if (!_exists(oldAbs)) {
      if (_asidePresent(oldAbs)) {
        _issue(oldRel, 'Being replaced on this device; waiting');
        return;
      }
      // Nothing to move: the new path follows the usual rows.
      if (j.moving?.oldKey == srcKey) j.moving = null;
      j.files.remove(srcKey);
      j.firstSeen.remove(srcKey);
      await _save();
      return;
    }
    if (_exists(newAbs) &&
        FileSystemEntity.typeSync(newAbs, followLinks: false) ==
            FileSystemEntityType.file &&
        await FileSystemEntity.identical(oldAbs, newAbs)) {
      // The same file under a spelling the volume folds.
      j.files.remove(srcKey);
      rec.itemId = d.item.id;
      j.files[d.key] = rec;
      await _save();
      return;
    }
    if (!await _ensureFolders(d.segs, newRel)) return;

    final copy = _newTmp('rp');
    try {
      try {
        await File(oldAbs).copy(copy.path);
      } on FileSystemException catch (e) {
        _issue(oldRel, 'Can\'t copy the file to its new place: ${e.message}');
        return;
      }
      final identity = await ContentIdentity.ofFile(copy.path);
      final isAttachment = d.isAttachment || isAttachmentPath(srcKey);
      if (!isAttachment) {
        // A durable copy of the snapshot, before anything can be deleted (an
        // attachment's source is never deleted, so it needs none).
        try {
          await _keep.put(copy, identity.sha256);
        } on FileSystemException catch (e) {
          _issue(oldRel, 'Can\'t keep a copy before moving it: ${e.message}');
          return;
        }
      }
      final newDir = Directory(_lockDirForRel(newRel));
      String? problem;
      try {
        problem = await locks.run(newDir, () async {
          if (!_exists(newAbs)) {
            if (_asidePresent(newAbs)) {
              return 'Being replaced on this device';
            }
            final ok = await publishExclusive(copy, newAbs);
            if (!ok && !_exists(newAbs)) return 'Can\'t write the file here';
          }
          if (FileSystemEntity.typeSync(newAbs, followLinks: false) !=
              FileSystemEntityType.file) {
            return 'Something else is already here';
          }
          if (await ContentIdentity.ofFile(newAbs) != identity) {
            return 'A different file is already here';
          }
          return null;
        });
      } on FileSystemException catch (e) {
        problem = 'Can\'t write the file here: ${e.message}';
      }
      if (problem != null) {
        _issue(newRel, '$problem; the old copy stays at $oldRel');
        return;
      }
      _step('repathCopied');
      if (isAttachment) {
        // Attachments are copied, never moved: a kept page may still need them.
        _changed(newAbs);
        final moved = rec.copy()
          ..path = newRel
          ..itemId = d.item.id
          ..retained = false;
        rec.retained = true;
        j.files[d.key] = moved;
        await _save();
        return;
      }
      _changed(newAbs);
      j.moving = Moving(
        oldKey: srcKey,
        oldPath: oldRel,
        newKey: d.key,
        newPath: newRel,
        identity: identity,
        keep: identity.sha256,
      );
      await _save();
      _step('movingWritten');
      final DeleteResult? res;
      try {
        res = await _deleteChecked(oldRel, newRel, identity);
      } on FileSystemException catch (e) {
        _issue(oldRel, 'Can\'t remove the old copy: ${e.message}');
        await _sweepFolder(File(oldAbs).parent);
        await _settleMoving();
        return;
      }
      _step('oldDeleted');
      if (res == null) {
        _issue(newRel, 'Changed while it was being moved; both copies stay');
      } else if (res.outcome == DeleteOutcome.deleted ||
          res.outcome == DeleteOutcome.absent) {
        if (res.deleted) _changed(oldAbs);
        j.files.remove(srcKey);
        rec.path = newRel;
        rec.itemId = d.item.id;
        j.files[d.key] = rec;
        await _save();
      } else {
        _issue(oldRel, 'Changed after it was copied; both copies stay');
      }
      await _settleMoving();
    } finally {
      _dropTemp(copy);
    }
  }

  // --- Folders and strays --------------------------------------------------

  Future<void> _pruneFolders(RemoteView view) async {
    final j = _journal!;
    final needed = view.neededFolders;
    final candidates = j.folders.keys.where((k) => !needed.contains(k)).toList()
      ..sort((a, b) => b.split('/').length.compareTo(a.split('/').length));
    for (final k in candidates) {
      final rel = j.folders[k]!;
      final dir = Directory(_abs(rel));
      if (!dir.existsSync()) {
        j.folders.remove(k);
        await _save();
        continue;
      }
      final lock = _lockDirFor(rel, folder: true);
      bool removed;
      try {
        removed = await locks.run(Directory(lock), () async {
          try {
            dir.deleteSync();
            return true;
          } on FileSystemException {
            return false; // Not empty, or in use.
          }
        });
      } on FileSystemException {
        removed = false;
      }
      if (removed) {
        j.folders.remove(k);
        await _save();
      }
    }
  }

  /// G4's last row: files here that nothing mirrors are left alone, and the
  /// ones that look like pages or binder copies are listed.
  Future<void> _listStrays(RemoteView view) async {
    final j = _journal!;
    final known = {for (final r in j.files.values) foldKey(r.path)};
    final stray = RegExp(r'^noted-binder-.*-[0-9a-f]+\.json$');
    Future<void> scan(Directory d, String prefix) async {
      if (!d.existsSync()) return;
      try {
        await for (final e in d.list(followLinks: false)) {
          if (e is! File) continue;
          final name = _basename(e.path);
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          final n = foldKey(name);
          if (!(n.endsWith('.canvas') || stray.hasMatch(n))) continue;
          if (known.contains(foldKey(rel))) continue;
          if (view.desired.containsKey(foldKey(rel))) continue;
          _issue(rel, 'Not on OneDrive; left alone');
        }
      } on FileSystemException {
        // Next round.
      }
    }

    await scan(workingCopy, '');
    for (final b in _binderKeys) {
      final rel = j.folders[b] ?? b;
      await scan(Directory(_abs(rel)), rel);
    }
  }
}
