// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Every place that removes a file by path (`.delete(`, `deleteSync(`) or
// renames over a name (`.rename(`, `renameSync(`) in the app and the packages
// is listed here with its reason (0131, 0132). A new site, a changed line or a
// vanished one fails the test: a new site has to be checked (see
// deleteFileIfMatches and publishExclusive) or named here on purpose.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One allowed line: the file (from the repository root), the trimmed line, how
/// many times it occurs in the file, and why it is not a checked delete.
typedef Site = (String file, String text, int count, String reason);

const String _unique = 'its own temporary file (a name only this writer makes)';
const String _call =
    'not a file delete: a call on a store, a transaction or the notebook';
const String _private = 'an app-private file or folder, not shared storage';
const String _emptyDir =
    'a non-recursive folder delete: it fails when anything is in it';
const String _primitive = 'the checked primitive itself';

const List<Site> deleteSites = [
  ('app/lib/src/ai/ai_link_server.dart', 'file.deleteSync();', 1, _private),
  ('app/lib/src/app_commands.dart', 'invoke: () => a.delete(p),', 1, _call),
  (
    'app/lib/src/menu_bar.dart',
    'Future<void> delete(PageMeta page) => _go((a) => a.delete(page));',
    1,
    _call,
  ),
  (
    'app/lib/src/page_tree_view.dart',
    'deleted = await _nb.delete(p.id);',
    1,
    _call,
  ),
  (
    'app/lib/src/secure_token_store.dart',
    'Future<void> delete(String key) => _storage.delete(key: key);',
    1,
    _call,
  ),
  (
    'app/lib/src/attachment_copy.dart',
    'if (await tmp.exists()) await tmp.delete();',
    2,
    _unique,
  ),
  (
    'app/lib/src/attachment_copy.dart',
    'await dir.delete(recursive: recursive);',
    1,
    'coordinated: removeFolderCoordinated, one write on the parent (N4); callers remove an empty folder or, for the failed-delete rollback, the emptied trash folder',
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await tmp.exists()) await tmp.delete();',
    2,
    _unique,
  ),
  (
    'app/lib/src/notebook.dart',
    '() => tmp.delete(),',
    1,
    'coordinated: delete the file, write its folder (N4); the fixed-name <target>.landing.tmp of a non-hash kept file',
  ),
  (
    'app/lib/src/notebook.dart',
    "final r = await _templateLocked(binder, snap, 'delete', () => TemplateStore(dir).delete(item.path, item.identity));",
    1,
    'checked: TemplateStore.delete is deleteFileIfMatches with the listed identity',
  ),
  (
    'app/lib/src/notebook.dart',
    'await tx.delete(e);',
    5,
    'a recovery-store transaction (app-private)',
  ),
  (
    'app/lib/src/notebook.dart',
    'await rec.transaction((tx) => tx.delete(e));',
    1,
    'a recovery-store transaction (app-private)',
  ),
  (
    'app/lib/src/notebook.dart',
    '() => f.source.delete(),',
    1,
    'coordinated: delete the file, write its folder (N4); a kept file in the recovery folder, after its copy was verified in place',
  ),
  (
    'app/lib/src/recovery_store.dart',
    'if (await f.exists()) await f.delete();',
    1,
    _private,
  ),
  (
    'app/lib/src/recovery_store.dart',
    'if (await first.exists()) await first.delete();',
    1,
    _private,
  ),
  (
    'app/lib/src/recovery_store.dart',
    'if (await second.exists()) await second.delete();',
    1,
    _private,
  ),
  ('app/lib/src/recovery_store.dart', 'await pageFile.delete();', 1, _private),
  ('app/lib/src/recovery_store.dart', 'await metaFile.delete();', 1, _private),
  ('app/lib/src/recovery_store.dart', 'await f.delete();', 4, _private),
  (
    'app/lib/src/storage_check.dart',
    'await f.delete();',
    1,
    'the probe file the check made itself',
  ),
  (
    'app/lib/src/storage_check.dart',
    'if (f.existsSync()) f.deleteSync();',
    1,
    'the probe file the check made itself',
  ),
  (
    'packages/noted_auth/lib/src/auth_session.dart',
    'await _store.delete(refreshKey(previous));',
    1,
    _call,
  ),
  (
    'packages/noted_auth/lib/src/auth_session.dart',
    'await _store.delete(k);',
    1,
    _call,
  ),
  (
    'packages/noted_auth/lib/src/auth_session.dart',
    'await _store.delete(refreshKey(key));',
    2,
    _call,
  ),
  (
    'packages/noted_canvas/lib/src/canvas_commands.dart',
    'if (id != null) c.delete(id);',
    1,
    _call,
  ),
  (
    'packages/noted_core/lib/src/ai/locked_file.dart',
    'if (tmp.existsSync()) tmp.deleteSync();',
    1,
    _unique,
  ),
  (
    'packages/noted_core/lib/src/storage/page_store.dart',
    'if (await tmp.exists()) await tmp.delete();',
    3,
    _unique,
  ),
  (
    'packages/noted_core/lib/src/template/template.dart',
    'if (await tmp.exists()) await tmp.delete();',
    1,
    _unique,
  ),
  (
    'packages/noted_core/lib/src/storage/drop_verified.dart',
    'drop.deleteSync();',
    1,
    'deleteFileIfMatches: the verified file renamed to a fresh name, checked again just before',
  ),
  (
    'packages/noted_mcp/lib/src/closed_writer.dart',
    'if (await tmp.exists()) await tmp.delete();',
    1,
    _unique,
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'await part.delete();',
    1,
    _private,
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'if (part.existsSync()) await part.delete();',
    1,
    'its own blob copy: .part-<random> file in the app-private base folder, after a failed copy',
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'await fileFor(sha).delete();',
    1,
    _private,
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'await f.delete();',
    1,
    _private,
  ),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'await e.delete(recursive: true);',
    1,
    _private,
  ),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'if (tmp.existsSync()) tmp.deleteSync();',
    2,
    'its own download or compare temp (a unique name in the app-private state folder)',
  ),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'await tmp.delete();',
    2,
    'its own download temp (a unique name in the app-private state folder)',
  ),
  (
    'packages/noted_sync/lib/src/webdav/webdav_client.dart',
    'if (dest.existsSync()) dest.deleteSync();',
    1,
    'the fresh temp the engine gave the download (a unique name in the app-private state folder), dropped when the body was not the listed size',
  ),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'if (f.existsSync()) f.deleteSync();',
    1,
    _private,
  ),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'dir.deleteSync();',
    1,
    _emptyDir,
  ),
  (
    'app/lib/src/webdav_sync.dart',
    'await store.delete(conn.passwordKey);',
    1,
    'not a file: a keychain item of a connection that could not be saved',
  ),
  (
    'app/lib/src/webdav_sync.dart',
    'await store.delete(c.passwordKey);',
    1,
    'not a file: the keychain item of the connection being disconnected',
  ),
  (
    'app/lib/src/webdav_sync.dart',
    'if (await file.exists()) await file.delete();',
    1,
    'the connection file in the app-private state folder; Disconnect forgets it',
  ),
];

const String _ownTemp =
    'a unique or fixed own temporary file renamed over an app-private file';
const String _rename = 'not a file operation: a rename of a page or a command';
const String _move =
    'a folder or file move onto a free name; the primitives that rename aside are checked';

final List<Site> renameSites = [
  for (final call in [
    'Directory(from).renameSync(to);',
    'Link(from).renameSync(to);',
    'File(from).renameSync(to);',
  ])
    (
      'packages/noted_core/lib/src/storage/exclusive_move.dart',
      call,
      1,
      'the Android fallback below API 30, after an lstat that found no target, under the folder locks',
    ),
  (
    'app/lib/src/ai/ai_link_server.dart',
    'tmp.renameSync(file.path);',
    1,
    _ownTemp,
  ),
  ('app/lib/src/app_commands.dart', 'invoke: () => a.rename(p),', 1, _rename),
  ('app/lib/src/app_settings.dart', 'tmp.renameSync(f.path);', 1, _ownTemp),
  (
    'app/lib/src/menu_bar.dart',
    'Future<void> rename(PageMeta page) => _go((a) => a.rename(page));',
    1,
    _rename,
  ),
  (
    'app/lib/src/notebook.dart',
    '() => tmp.rename(f.path),',
    1,
    'coordinated: move the temp, write the folder (N4; outside every root, so direct); $_ownTemp',
  ),
  (
    'app/lib/src/onedrive_sync.dart',
    'await tmp.rename(file.path);',
    1,
    _ownTemp,
  ),
  (
    'app/lib/src/webdav_sync.dart',
    'await tmp.rename(file.path);',
    1,
    _ownTemp,
  ),
  (
    'app/lib/src/page_title_field.dart',
    'Future.microtask(() => nb.rename(id, typed).catchError((Object _) {}));',
    1,
    _rename,
  ),
  (
    'app/lib/src/page_title_field.dart',
    'await _nb.rename(widget.pageId, t);',
    1,
    _rename,
  ),
  (
    'app/lib/src/page_tree_view.dart',
    'if (title != null && title.trim().isNotEmpty) await _nb.rename(p.id, title.trim());',
    1,
    _rename,
  ),
  ('app/lib/src/recovery_store.dart', 'await tmp.rename(f.path);', 1, _ownTemp),
  ('app/lib/src/recovery_store.dart', 'await from.rename(to.path);', 1, _move),
  (
    'app/lib/src/recovery_store.dart',
    'await f.rename(target.path);',
    1,
    'the recovery store (app-private)',
  ),
  (
    'packages/noted_core/lib/src/ai/locked_file.dart',
    'tmp.renameSync(file.path);',
    1,
    _ownTemp,
  ),
  (
    'packages/noted_core/lib/src/storage/drop_verified.dart',
    'await aside.rename(dropPath);',
    1,
    _primitive,
  ),
  (
    'packages/noted_core/lib/src/storage/replace_if_unchanged.dart',
    'await File(target).rename(aside.path);',
    2,
    _primitive,
  ),
  (
    'packages/noted_core/lib/src/storage/replace_if_unchanged.dart',
    "aside = await aside.rename('\$base\$verifiedSuffix');",
    1,
    _primitive,
  ),
  (
    'packages/noted_mcp/lib/src/closed_writer.dart',
    'await file.rename(aside.path);',
    1,
    'the MCP writer sets the page aside (exclusive, checked afterwards)',
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'await tmp.rename(file.path);',
    1,
    _ownTemp,
  ),
  (
    'packages/noted_sync/lib/src/journal.dart',
    'await part.rename(fileFor(sha).path);',
    1,
    'the journal (app-private)',
  ),
];

// Every create and write of a file or folder (`.create(`, `createSync(`,
// `writeAsBytes`/`writeAsString`, `openWrite(`, `.copy(`, `FileMode.`) in the
// app and the packages, each marked (R5.4, N4):
//  - `coordinated`: one `coordinated()` call, with the intents R5.4 names;
//  - `temp`: a fresh, unique name that no presenter, version or other writer
//    knows (its publish or removal is inside a primitive's call);
//  - `outside roots`: app-private state, or a file nothing registers a root for
//    (the server's, a system temp folder, the recovery folder);
//  - `gap`: not coordinated yet, and not in R5.4's table. Each is a site a
//    later step or the maintainer decides; a gap has to be named here.
// A new or changed site fails the test until it is listed with a mark.
const String _coordinatedMark = 'coordinated';
const String _tempMark = 'temp';
const String _outsideMark = 'outside roots';
const String _gapMark = 'gap';
const List<String> _marks = [_coordinatedMark, _tempMark, _outsideMark, _gapMark];

const String _appState = '$_outsideMark: app-private state';
const String _appTemp = '$_outsideMark: its temp in app-private state, renamed over an app-private file';
const String _freshTemp =
    '$_tempMark: a unique name made for this call, published or removed by it';

const List<Site> writeSites = [
  ('app/lib/src/ai/ai_access_service.dart', 'raf = mcpLog.openSync(mode: FileMode.append);', 2, '$_outsideMark: the MCP access log in app data'),
  ('app/lib/src/ai/ai_link_server.dart', 'file.parent.createSync(recursive: true);', 1, _appState),
  ('app/lib/src/ai/ai_link_server.dart', 'tmp.writeAsStringSync(', 1, _appTemp),
  ('app/lib/src/ai/ai_running_lock.dart', 'if (!dataFolder.existsSync()) dataFolder.createSync(recursive: true);', 1, _appState),
  (
    'app/lib/src/ai/ai_running_lock.dart',
    "file = File('\${dataFolder.path}\${Platform.pathSeparator}\$aiRunningLockFileName').openSync(mode: FileMode.append);",
    1,
    _appState,
  ),
  ('app/lib/src/app_settings.dart', 'f.parent.createSync(recursive: true);', 1, _appState),
  ('app/lib/src/app_settings.dart', 'tmp.writeAsStringSync(jsonEncode(_raw), flush: true);', 1, _appTemp),
  (
    'app/lib/src/attachment_copy.dart',
    'await dir.create(recursive: recursive);',
    1,
    '$_coordinatedMark: createFolderCoordinated, one write on the parent (the folder creates of R5.4)',
  ),
  ('app/lib/src/attachment_copy.dart', 'await tmp.writeAsBytes(bytes, flush: true);', 1, _freshTemp),
  ('app/lib/src/attachment_copy.dart', 'final out = await dst.open(mode: FileMode.write);', 1, _freshTemp),
  (
    'app/lib/src/attachment_copy.dart',
    'await f.create(exclusive: true);',
    1,
    '$_coordinatedMark: _createExclusive, write: the folder (C2)',
  ),
  (
    'app/lib/src/attachment_copy.dart',
    'final o = out = await f.open(mode: FileMode.writeOnlyAppend);',
    1,
    '$_coordinatedMark: _createExclusive\'s fill, write: the folder (C2)',
  ),
  (
    'app/lib/src/cloud_sync.dart',
    'await dir.create(recursive: true);',
    1,
    '$_gapMark: the folder the user chose for sync, made before any coordinator is registered for it (R5.9 step 5)',
  ),
  ('app/lib/src/link_log.dart', 'target.parent.createSync(recursive: true);', 1, _appState),
  ('app/lib/src/link_log.dart', "if (target.existsSync() && target.lengthSync() > linkLogLimit) target.writeAsStringSync('');", 1, _appState),
  (
    'app/lib/src/link_log.dart',
    "target.writeAsStringSync('\${DateTime.now().toIso8601String()} \$line\\n', mode: FileMode.append, flush: true);",
    1,
    _appState,
  ),
  ('app/lib/src/notebook.dart', 'await tmp.writeAsString(text, flush: true);', 2, _freshTemp),
  (
    'app/lib/src/notebook.dart',
    "await tmp.writeAsString('\${_settings.toRaw().text}\\n', flush: true);",
    1,
    '$_tempMark: the settings temp, renamed under coordinated() (outside every root)',
  ),
  (
    'app/lib/src/notebook.dart',
    '() => e.copy(tmp.path),',
    1,
    '$_coordinatedMark: the landing temp, write: the folder (the fixed-name <target>.landing.tmp)',
  ),
  ('app/lib/src/onedrive_sync.dart', 'await file.parent.create(recursive: true);', 1, _appState),
  ('app/lib/src/onedrive_sync.dart', 'await tmp.writeAsString(jsonEncode(root.toJson()), flush: true);', 1, _appTemp),
  ('app/lib/src/page_attachments.dart', 'await dir.create(recursive: true);', 1, '$_outsideMark: a folder in the system temp, for opening an embedded file'),
  ('app/lib/src/page_attachments.dart', 'await file.writeAsBytes(bytes, flush: true);', 1, '$_outsideMark: a copy in the system temp, for opening an embedded file'),
  ('app/lib/src/recovery_lock.dart', 'file.parent.createSync(recursive: true);', 1, _appState),
  ('app/lib/src/recovery_lock.dart', 'raf = file.openSync(mode: FileMode.append);', 1, _appState),
  ('app/lib/src/recovery_store.dart', 'await tmp.writeAsString(text, flush: true);', 2, _appState),
  ('app/lib/src/recovery_store.dart', 'await directory.create(recursive: true);', 1, _appState),
  ('app/lib/src/recovery_store.dart', 'await tmp.writeAsString(jsonEncode(meta), flush: true);', 1, _appState),
  (
    'app/lib/src/storage_check.dart',
    'await dir.create(recursive: true);',
    1,
    '$_gapMark: the folder the write check probes, made if missing; not in R5.4\'s table',
  ),
  (
    'app/lib/src/storage_check.dart',
    "await f.writeAsString('x', flush: true);",
    1,
    '$_tempMark: the probe, a unique name the check removes itself',
  ),
  ('app/lib/src/webdav_sync.dart', 'await file.parent.create(recursive: true);', 1, _appState),
  ('app/lib/src/webdav_sync.dart', 'await tmp.writeAsString(jsonEncode(conn.toJson()), flush: true);', 1, _appTemp),
  ('packages/noted_core/lib/src/ai/locked_file.dart', 'if (!dir.existsSync()) dir.createSync(recursive: true);', 2, _appState),
  ('packages/noted_core/lib/src/ai/locked_file.dart', "final lock = File('\${file.path}.lock').openSync(mode: FileMode.append);", 1, _appState),
  ('packages/noted_core/lib/src/ai/locked_file.dart', 'tmp.writeAsStringSync(text, flush: true);', 1, _appTemp),
  (
    'packages/noted_core/lib/src/binder/binder_store.dart',
    'Future<void> writeTemp(File temp, List<int> bytes) => temp.writeAsBytes(bytes, flush: true);',
    1,
    '$_tempMark: BinderStore.newTempFile, a fresh name published by publishExclusive',
  ),
  (
    'packages/noted_core/lib/src/binder/binder_store.dart',
    'await directory.create(recursive: true);',
    1,
    '$_gapMark: BinderStore.create makes the binder folder; only its StorageBusy handler is in step 2\'s files',
  ),
  (
    'packages/noted_core/lib/src/storage/page_store.dart',
    'await directory.create(recursive: true);',
    1,
    '$_coordinatedMark: PageStore.scan\'s folder create, write: the folder that holds it',
  ),
  ('packages/noted_core/lib/src/storage/page_store.dart', 'await tmp.writeAsString(text, flush: true);', 1, _freshTemp),
  ('packages/noted_core/lib/src/storage/page_store.dart', 'await tmp.writeAsString(written, flush: true);', 1, _freshTemp),
  (
    'packages/noted_core/lib/src/template/template.dart',
    'await directory.create(recursive: true);',
    1,
    '$_coordinatedMark: TemplateStore.save\'s folder create, write: the folder (C2)',
  ),
  ('packages/noted_core/lib/src/template/template.dart', 'await tmp.writeAsString(template.write(), flush: true);', 1, _freshTemp),
  ('packages/noted_mcp/lib/src/closed_writer.dart', 'final raf = await _log.open(mode: FileMode.append);', 1, '$_outsideMark: the server\'s own access log'),
  (
    'packages/noted_mcp/lib/src/closed_writer.dart',
    'await made.create(exclusive: true);',
    1,
    '$_outsideMark: the server registers no coordinator (invariant 4), so its writes are direct',
  ),
  ('packages/noted_mcp/lib/src/closed_writer.dart', 'await tmp.writeAsBytes(text, flush: true);', 1, _freshTemp),
  ('packages/noted_mcp/lib/src/running_probe.dart', 'raf = await File(path).open(mode: FileMode.read);', 1, '$_outsideMark: a read, in app data'),
  ('packages/noted_sync/lib/src/graph_client.dart', 'final sink = dest.openWrite();', 1, '$_outsideMark: the fresh download temp in the app-private state folder'),
  ('packages/noted_sync/lib/src/webdav/webdav_client.dart', 'final sink = dest.openWrite();', 1, '$_outsideMark: the fresh download temp in the app-private state folder'),
  ('packages/noted_sync/lib/src/journal.dart', 'await dir.create(recursive: true);', 2, _appState),
  ('packages/noted_sync/lib/src/journal.dart', 'await tmp.writeAsString(jsonEncode(journal.toJson()), flush: true);', 1, _appTemp),
  ('packages/noted_sync/lib/src/journal.dart', 'await src.copy(part.path);', 1, _appState),
  ('packages/noted_sync/lib/src/pull_engine.dart', 'await stateDir.create(recursive: true);', 1, _appState),
  ('packages/noted_sync/lib/src/pull_engine.dart', 'await _tmpDir.create(recursive: true);', 1, _appState),
  ('packages/noted_sync/lib/src/pull_engine.dart', 'await keep.copy(tmp.path);', 1, '$_tempMark: _newTmp, a fresh name in the state folder'),
  (
    'packages/noted_sync/lib/src/pull_engine.dart',
    'dir.createSync();',
    1,
    '$_gapMark: the pull engine makes a folder inside a notebook folder; `pull_engine.dart` is not in step 2\'s files',
  ),
  ('packages/noted_sync/lib/src/pull_engine.dart', 'await File(oldAbs).copy(copy.path);', 1, '$_tempMark: _newTmp, a fresh name in the state folder'),
];

/// This sees only direct calls: a handler around a function that itself calls a
/// primitive (for instance `writeNewAttachmentFile`) is not found, so those
/// handlers are checked by hand and by the refusal tests in
/// `storage_busy_sites_test.dart`.
///
/// The calls a handler has to treat a refusal of: the checked primitives, a
/// `coordinated()` call, the helpers that wrap one (`createFolderCoordinated`,
/// `removeFolderCoordinated`) and `TemplateStore.save`. `moveExclusive` is not
/// here: it answers `MoveOutcome.busy` itself and never throws a StorageBusy.
final RegExp _coordinatedCall = RegExp(
  r'\b(publishExclusive|replaceIfUnchanged|deleteFileIfUnchanged|deleteFileIfMatches|sweepAsideFiles|coordinated|\w+Coordinated|TemplateStore\([^)]*\)\.save)\(',
);

/// The 1-based line of each `try` in [source] whose body calls a storage
/// primitive and which has an `on FileSystemException` clause with no
/// `on StorageBusy` clause before it.
List<int> handlersWithoutStorageBusy(String source) {
  final text = source
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      })
      .join('\n');
  int closing(int open) {
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      if (text[i] == '{') depth++;
      if (text[i] == '}' && --depth == 0) return i;
    }
    return -1;
  }

  final clause = RegExp(
    r'^\s*(on\s+[A-Za-z_<>?]+(\s+catch\s*\([^)]*\))?|catch\s*\([^)]*\))\s*\{',
  );
  final out = <int>[];
  for (final m in RegExp(r'\btry\s*\{').allMatches(text)) {
    final open = m.end - 1;
    final close = closing(open);
    if (close < 0 || !_coordinatedCall.hasMatch(text.substring(open, close))) continue;
    final clauses = <String>[];
    var pos = close + 1;
    while (true) {
      final c = clause.firstMatch(text.substring(pos));
      if (c == null) break;
      clauses.add(c.group(1)!.trim());
      pos = closing(pos + c.end - 1) + 1;
    }
    final fs = clauses.indexWhere((c) => c.startsWith('on FileSystemException'));
    if (fs < 0) continue;
    final busy = clauses.indexWhere((c) => c.startsWith('on StorageBusy'));
    if (busy < 0 || busy > fs) out.add('\n'.allMatches(text.substring(0, m.start)).length + 1);
  }
  return out;
}

void main() {
  // The repository root: the app's tests run in `app/`.
  final root = Directory.current.parent;

  // Every source line (not a comment) of `app/lib` and `packages/*/lib` that
  // matches [pattern], counted by file and trimmed text.
  Map<(String, String), int> found(RegExp pattern) {
    final dirs = [
      Directory('${root.path}/app/lib'),
      for (final p in Directory(
        '${root.path}/packages',
      ).listSync().whereType<Directory>())
        Directory('${p.path}/lib'),
    ];
    final out = <(String, String), int>{};
    for (final d in dirs.where((d) => d.existsSync())) {
      for (final f
          in d
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final rel = f.path
            .substring(root.path.length + 1)
            .replaceAll(r'\', '/');
        for (final line in f.readAsLinesSync()) {
          final text = line.trim();
          if (text.startsWith('//') || !pattern.hasMatch(text)) continue;
          out.update((rel, text), (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    return out;
  }

  void expectOnly(
    Map<(String, String), int> actual,
    List<Site> allowed,
    String what,
  ) {
    final want = {for (final s in allowed) (s.$1, s.$2): s.$3};
    expect(want.length, allowed.length, reason: 'an entry is listed twice');
    for (final s in allowed) {
      expect(s.$4, isNotEmpty);
    }
    final extra = [
      for (final e in actual.entries)
        if (want[e.key] != e.value)
          '${e.key.$1}: ${e.key.$2} (x${e.value}, listed ${want[e.key] ?? 0})',
    ];
    final gone = [
      for (final e in want.entries)
        if (!actual.containsKey(e.key)) '${e.key.$1}: ${e.key.$2}',
    ];
    expect(
      extra,
      isEmpty,
      reason:
          'a new or changed $what site: check it (deleteFileIfMatches / publishExclusive) or list it with a reason',
    );
    expect(
      gone,
      isEmpty,
      reason: 'a listed $what site is gone or changed: update the list',
    );
  }

  test('every delete of a file by path is listed with its reason', () {
    expectOnly(
      found(RegExp(r'\.delete\(|deleteSync\(')),
      deleteSites,
      'delete',
    );
  });

  test('every rename over a name is listed with its reason', () {
    expectOnly(
      found(RegExp(r'\.rename\(|renameSync\(')),
      renameSites,
      'rename',
    );
  });

  test('PageStore has no unchecked delete', () {
    final text = File(
      '${root.path}/packages/noted_core/lib/src/storage/page_store.dart',
    ).readAsStringSync();
    expect(RegExp(r'Future<void>\s+delete\(').hasMatch(text), isFalse);
  });

  test('PageStore has no blind save (a rename over the page file)', () {
    final text = File(
      '${root.path}/packages/noted_core/lib/src/storage/page_store.dart',
    ).readAsStringSync();
    expect(RegExp(r'Future<void>\s+save\(').hasMatch(text), isFalse);
  });

  // Nothing registers a coordinator in the app yet (R5.14 step 5). The gap rows
  // above are not coordinated, so the step that registers one has to coordinate
  // them first (or list why not): this fails until no gap row is left.
  test('no coordinator is registered in the app while a gap row remains', () {
    final gaps = [for (final s in writeSites) if (s.$4.startsWith('$_gapMark: ')) '${s.$1}: ${s.$2}'];
    final registered = [
      for (final f in Directory('${root.path}/app/lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && f.readAsStringSync().contains('registerCoordinator('))
          f.path.substring(root.path.length + 1),
    ];
    if (registered.isNotEmpty) {
      expect(gaps, isEmpty, reason: 'registerCoordinator( in $registered, with gap rows left');
    }
  });

  test('every create and write into a folder is listed with a mark (N4)', () {
    for (final s in writeSites) {
      expect(
        _marks.any((m) => s.$4.startsWith('$m: ')),
        isTrue,
        reason: '${s.$1}: ${s.$2} has no mark (${_marks.join(', ')})',
      );
    }
    expectOnly(
      found(
        RegExp(
          r'\.create\((recursive:|exclusive:)|\)\.create\(\)|createSync\(|\bwriteAs(Bytes|String)(Sync)?\(|openWrite\(|\.copy\([^)]|copySync\(|FileMode\.',
        ),
      ),
      writeSites,
      'create or write',
    );
  });

  // C2: a StorageBusy is a FileSystemException, so a handler that catches the
  // second around a storage call has to catch the first before it.
  group('every FileSystemException handler around a storage call catches StorageBusy first (C2)', () {
    for (final file in [
      'app/lib/src/attachment_copy.dart',
      'packages/noted_core/lib/src/template/template.dart',
      'app/lib/src/notebook.dart',
    ]) {
      test(file, () {
        final text = File('${root.path}/$file').readAsStringSync();
        expect(handlersWithoutStorageBusy(text), isEmpty);
      });
    }

    test('the check finds a handler that has none, and accepts one that has', () {
      const bad = '''
Future<void> f() async {
  try {
    await publishExclusive(a, b);
  } on FileSystemException {
    await fallbackWrite();
  }
}''';
      const good = '''
Future<void> f() async {
  try {
    await publishExclusive(a, b);
  } on StorageBusy {
    rethrow;
  } on FileSystemException {
    await fallbackWrite();
  }
}''';
      const late = '''
Future<void> f() async {
  try {
    await deleteFileIfMatches(a, identity: i);
  } on FileSystemException {
    await fallbackWrite();
  } on StorageBusy {
    rethrow;
  }
}''';
      const unrelated = '''
Future<void> f() async {
  try {
    await File(a).readAsString();
  } on FileSystemException {
    await other();
  }
}''';
      expect(handlersWithoutStorageBusy(bad), hasLength(1));
      expect(handlersWithoutStorageBusy(good), isEmpty);
      expect(handlersWithoutStorageBusy(late), hasLength(1), reason: 'StorageBusy must come first');
      expect(handlersWithoutStorageBusy(unrelated), isEmpty);
    });
  });
}
