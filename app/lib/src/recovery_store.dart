// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// The folder for recovery entries: `recovery` next to `binders.json`, the
/// app settings folder.
Directory defaultRecoveryDirectory(File bindersFile) =>
    Directory('${bindersFile.absolute.parent.path}${Platform.pathSeparator}recovery');

/// An edit that couldn't be saved because its folder was unavailable.
///
/// On disk an entry is two files in the recovery folder, named
/// `<page id>-<hash of folder and id>`:
///
/// - `<name>.canvas`: exactly the text a normal save of the page writes
///   (`writePage`). Nothing else is derived from the page's content, so an
///   entry never holds anything a page file wouldn't (invariant 3).
/// - `<name>.json`, for example (all strings, `base` may be null):
///
///       {"format":1,"folder":"D:\Notes","pageId":"p1",
///        "time":"2026-10-25T10:00:00.000Z","base":"...page file text..."}
///
///   `base` is the page file
///   as last read or written by the app: the base of the three-way merge. It
///   is itself a former page file.
///
/// Both files are written atomically (temporary file, then rename); the page
/// first. A newer edit of the same page replaces its entry.
class RecoveryEntry {
  RecoveryEntry._(
    this.folder,
    this.pageId,
    this.time,
    this.baseText,
    this.pageText,
    this.page,
    this._stem,
    this._dir,
  );

  /// The folder the page belongs in.
  final String folder;
  final String pageId;
  final DateTime time;

  /// The page file as last read or written before the edit; null if unknown.
  final String? baseText;

  /// What a normal save of the page would have written.
  final String pageText;
  final NotedPage page;
  final String _stem;
  final Directory _dir;

  File get pageFile => File('${_dir.path}${Platform.pathSeparator}$_stem.canvas');
  File get metaFile => File('${_dir.path}${Platform.pathSeparator}$_stem.json');
}

/// What a scan of the recovery folder found: [entries] that can be used and
/// [problems] (descriptions of files that can't be read; they are kept).
class RecoveryListing {
  const RecoveryListing(this.entries, this.problems);
  final List<RecoveryEntry> entries;
  final List<String> problems;
}

/// The recovery folder: one entry per page, never deleted except by [delete].
class RecoveryStore {
  RecoveryStore(this.directory);

  final Directory directory;

  static String _name(String folder, String pageId) {
    var h = 0xcbf29ce484222325;
    for (final u in utf8.encode('${folder.replaceAll(r'\', '/').toLowerCase()}|$pageId')) {
      h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    final safe = pageId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${safe.length > 40 ? safe.substring(0, 40) : safe}-${h.toRadixString(16)}';
  }

  Future<void> _atomic(File f, String text) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  /// Writes (or replaces) the entry of [page], belonging in [folder].
  Future<void> write({
    required String folder,
    required NotedPage page,
    required String? baseText,
    required DateTime time,
  }) async {
    await directory.create(recursive: true);
    final stem = _name(folder, page.id);
    final base = '${directory.path}${Platform.pathSeparator}$stem';
    await _atomic(File('$base.canvas'), writePage(page));
    await _atomic(
      File('$base.json'),
      jsonEncode({
        'format': 1,
        'folder': folder,
        'pageId': page.id,
        'time': time.toUtc().toIso8601String(),
        'base': baseText,
      }),
    );
  }

  /// Reads every entry. Files that can't be read are reported, not removed.
  Future<RecoveryListing> list() async {
    final entries = <RecoveryEntry>[];
    final problems = <String>[];
    if (!await directory.exists()) return const RecoveryListing([], []);
    final names = <String>{};
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final p = f.path;
      if (p.endsWith('.canvas') || p.endsWith('.json')) {
        names.add(p.substring(0, p.lastIndexOf('.')));
      }
    }
    for (final base in names.toList()..sort()) {
      final stem = base.split(RegExp(r'[\\/]')).last;
      try {
        final meta = jsonDecode(await File('$base.json').readAsString());
        if (meta is! Map || meta['format'] != 1) throw const FormatException('unknown format');
        final folder = meta['folder'];
        final id = meta['pageId'];
        final b = meta['base'];
        if (folder is! String || id is! String || (b != null && b is! String)) {
          throw const FormatException('missing fields');
        }
        final time = DateTime.tryParse('${meta['time']}') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final text = await File('$base.canvas').readAsString();
        final page = readPage(text);
        if (b is String) readPage(b);
        entries.add(RecoveryEntry._(folder, id, time, b as String?, text, page, stem, directory));
      } on Object catch (e) {
        final why = e is FormatException
            ? e.message
            : e is PageFormatException
            ? e.message
            : '$e';
        problems.add('$base: $why');
      }
    }
    return RecoveryListing(entries, problems);
  }

  /// Removes [entry]'s files.
  Future<void> delete(RecoveryEntry entry) async {
    for (final f in [entry.metaFile, entry.pageFile]) {
      if (await f.exists()) await f.delete();
    }
  }
}

/// Checks a recovered page [result] (read back from disk) against the three
/// pages it came from. Returns null if it is sound, else why not:
///
/// - every box of [theirs] is still there;
/// - every box of [mine] is still there, unless [theirs] removed it while
///   [mine] hadn't changed it since [base];
/// - a box that [mine] changed keeps [mine]'s content verbatim, or is
///   conflicted (the other version recorded), or was merged by its codec;
///   what must not happen is that [theirs]'s version silently replaces it.
String? verifyRecoveredPage({
  required NotedPage base,
  required NotedPage mine,
  required NotedPage? theirs,
  required NotedPage result,
}) {
  if (result.id != mine.id) return 'the page id changed';
  final out = {for (final n in result.nodes) n.id: n};
  final baseById = {for (final n in base.nodes) n.id: n};
  final theirsById = {for (final n in theirs?.nodes ?? const <CanvasNode>[]) n.id: n};
  for (final id in theirsById.keys) {
    if (!out.containsKey(id)) return 'box $id of the saved file is missing';
  }
  for (final m in mine.nodes) {
    final b = baseById[m.id];
    final x = out[m.id];
    final changed = b == null || b.toRaw() != m.toRaw();
    if (x == null) {
      if (!changed && theirs != null && !theirsById.containsKey(m.id)) continue; // removed there
      return 'box ${m.id} is missing';
    }
    if (!changed || x.toRaw() == m.toRaw()) continue;
    if (x is BoxRecord && x.isConflicted) continue;
    final t = theirsById[m.id];
    if (t != null && x.toRaw() == t.toRaw()) return 'the edit of box ${m.id} was lost';
  }
  return null;
}
