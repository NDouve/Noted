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
const String _landing =
    'the fixed-name <target>.landing.tmp of a non-hash kept file (known; a unique name is for the area audit)';
const String _tempMixed =
    'own temporary files: unique names, and the fixed-name <target>.landing.tmp of a non-hash kept file (known)';

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
    'if (await d.list().isEmpty) await d.delete();',
    1,
    _emptyDir,
  ),
  (
    'app/lib/src/attachment_copy.dart',
    'await Directory(p).delete();',
    1,
    _emptyDir,
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await tmp.exists()) await tmp.delete();',
    4,
    _tempMixed,
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await tmp.exists()) await tmp.delete(); // left by an earlier try',
    1,
    _landing,
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await d.exists()) await d.delete(recursive: true);',
    1,
    'the deleted-attachments folder under the app folder (_removeDir), not shared storage',
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await dir.parent.exists() && await dir.parent.list().isEmpty) await dir.parent.delete();',
    1,
    _emptyDir,
  ),
  (
    'app/lib/src/notebook.dart',
    'if (await dir.exists() && await dir.list().isEmpty) await dir.delete();',
    1,
    _emptyDir,
  ),
  (
    'app/lib/src/notebook.dart',
    "final r = await _templateLocked(binder, snap, 'delete', () => TemplateStore(dir).delete(item.path, item.identity));",
    1,
    'checked: TemplateStore.delete is deleteFileIfMatches with the listed identity',
  ),
  ('app/lib/src/notebook.dart', 'await d.delete();', 2, _emptyDir),
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
    'await f.source.delete();',
    1,
    'a kept file in the recovery folder (app-private), after its copy was verified in place',
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
const String _unchecked =
    'KNOWN unchecked replace of a shared file, left for the area audit (see the design note)';

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
  ('app/lib/src/notebook.dart', 'await from.rename(to.path);', 1, _move),
  ('app/lib/src/notebook.dart', 'await tmp.rename(f.path);', 1, _ownTemp),
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
    'packages/noted_core/lib/src/storage/page_store.dart',
    'await tmp.rename(path);',
    1,
    '$_unchecked: PageStore.save',
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
    'packages/noted_core/lib/src/template/template.dart',
    'await tmp.rename(file.path);',
    1,
    '$_unchecked: TemplateStore.save',
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
}
