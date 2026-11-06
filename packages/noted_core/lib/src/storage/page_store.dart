// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import '../format/page_format.dart';
import '../merge/conflict_copy.dart';
import '../model/page.dart';
import 'exclusive_publish.dart';
import 'replace_if_unchanged.dart';

/// The result of scanning one page file.
sealed class PageEntry {
  const PageEntry(this.path);

  final String path;
}

final class ReadablePage extends PageEntry {
  const ReadablePage(super.path, this.meta, {this.conflicted = false});

  final PageMeta meta;

  /// Some box on the page has an unresolved conflict (0020).
  final bool conflicted;
}

/// A sync client's conflict copy of another page file (same page id, a name
/// like `<id>-DESKTOP-4QK2N8L.canvas`). It is not a page of its own: the
/// caller merges it into [originalPath] and then removes it.
final class ConflictCopyPage extends PageEntry {
  const ConflictCopyPage(super.path, this.meta, this.originalPath);

  final PageMeta meta;

  /// The page file this one is a copy of.
  final String originalPath;
}

/// A file that couldn't be read. The store never overwrites it.
final class UnreadablePage extends PageEntry {
  const UnreadablePage(super.path, this.reason);

  final String reason;
}

/// Page files in one local folder, one `<pageId>.canvas` file per page.
///
/// Prototype 1 has a single local location; sync drivers come later (0007).
class PageStore {
  PageStore(this.directory);

  static const String extension = '.canvas';

  final Directory directory;
  final Map<String, String> _paths = {};
  // Files chosen with [adopt], kept for the life of the store: a scan lists
  // such a file first while it exists and holds that id.
  final Map<String, String> _adopted = {};
  // Adopted files the last scan read as a valid page with another id.
  Map<String, String> _released = const {};
  static int _tmpCounter = 0;

  /// The adopted files (page id to path) that the last [scan] read as a valid
  /// page holding another id. They are not ranked for the id they were adopted
  /// for; the choice stays in the store until [unadopt], so the caller decides.
  /// Each scan replaces it.
  Map<String, String> get releasedAdoptions => _released;

  /// Reads every page file in the folder.
  ///
  /// A file that is a sync client's conflict copy of another page file in the
  /// folder (see [conflictCopyOriginalNames]; same page id) is reported as a
  /// [ConflictCopyPage], not as a duplicate.
  ///
  /// It first runs [sweepAsideFiles], which takes the set-aside files of any
  /// [saveIfUnchanged] in flight on this folder: callers must not run `scan`
  /// and `saveIfUnchanged` on the same folder at the same time.
  ///
  /// [createFolder] false never creates the folder: a missing one fails the
  /// listing with a [FileSystemException] (binder discovery reads shared
  /// storage and must not make a folder there). [sweep] false skips the sweep
  /// and leaves set-aside files for the writer that made them (they may belong
  /// to a write still under way on another device); they are listed as files
  /// that can't be opened.
  Future<List<PageEntry>> scan({bool createFolder = true, bool sweep = true}) async {
    if (createFolder) await directory.create(recursive: true);
    // Put back what a crashed or failed replace left under a set-aside name
    // (see [sweepAsideFiles]); one that can't be moved yet is listed below.
    if (sweep) await sweepAsideFiles(directory, extension: extension);
    _paths.clear();
    _released = const {};
    final entries = <PageEntry>[];
    final read = <String, (String, NotedPage)>{}; // by file name
    await for (final f in directory.list()) {
      if (f is File && (f.path.endsWith(asideSuffix) || f.path.endsWith(verifiedSuffix))) {
        entries.add(UnreadablePage(f.path, 'left over from a replace; not put back yet'));
        continue;
      }
      if (f is! File || !f.path.endsWith(extension)) continue;
      try {
        read[_name(f.path)] = (f.path, readPage(await f.readAsString()));
      } on PageFormatException catch (e) {
        entries.add(UnreadablePage(f.path, e.message));
      } on FileSystemException catch (e) {
        entries.add(UnreadablePage(f.path, e.message));
      }
    }
    // Names that are conflict copies, with the file each one is a copy of.
    final copyOf = <String, String>{};
    for (final e in read.entries) {
      for (final cand in conflictCopyOriginalNames(e.key, extension: extension)) {
        if (read[cand]?.$2.id == e.value.$2.id) {
          copyOf[e.key] = cand;
          break;
        }
      }
    }
    // A copy of a copy belongs to the file at the end of the chain.
    String rootOf(String name) {
      var n = name;
      while (copyOf.containsKey(n)) {
        n = copyOf[n]!;
      }
      return n;
    }

    // A chosen file that was listed as unreadable (locked, half written,
    // damaged) still holds its id: every readable file with that id is a
    // duplicate. One that holds another valid page is reported, not ranked.
    final released = <String, String>{};
    for (final a in _adopted.entries) {
      final name = _name(a.value);
      bool same(String x) => Platform.isWindows ? x.toLowerCase() == name.toLowerCase() : x == name;
      if (entries.any((e) => e is UnreadablePage && same(_name(e.path)))) {
        _paths[a.key] = a.value;
      } else if (read.entries.any((e) => same(e.key) && e.value.$2.id != a.key)) {
        released[a.key] = a.value;
      }
    }
    _released = released;

    // Files chosen with [adopt] are listed first, so they are the ones kept.
    bool chosen(MapEntry<String, (String, NotedPage)> e) {
      final a = _adopted[e.value.$2.id];
      if (a == null) return false;
      final x = _name(a), y = e.key;
      return Platform.isWindows ? x.toLowerCase() == y.toLowerCase() : x == y;
    }

    for (final e in [
      ...read.entries.where(chosen),
      ...read.entries.where((e) => !chosen(e)),
    ]) {
      final (path, page) = e.value;
      if (copyOf.containsKey(e.key)) {
        entries.add(ConflictCopyPage(path, page.meta, read[rootOf(e.key)]!.$1));
        continue;
      }
      if (_paths.containsKey(page.id)) {
        entries.add(UnreadablePage(path, 'duplicate page id ${page.id}'));
        continue;
      }
      _paths[page.id] = path;
      entries.add(ReadablePage(path, page.meta, conflicted: hasConflicts(page)));
    }
    return entries;
  }

  /// The file that [copyPath] (holding [copy]) is a conflict copy of: a file
  /// in the same folder whose name [copyPath]'s name extends by a hyphen and
  /// a suffix, and that holds the same page id. Null if there is none, so the
  /// file is not a conflict copy.
  static Future<String?> findConflictOriginal(String copyPath, NotedPage copy) async {
    final file = File(copyPath);
    final dir = file.parent.path;
    for (final cand in conflictCopyOriginalNames(_name(copyPath))) {
      final other = File('$dir${Platform.pathSeparator}$cand');
      try {
        if (!await other.exists()) continue;
        if (readPage(await other.readAsString()).id != copy.id) continue;
      } on PageFormatException {
        continue;
      } on FileSystemException {
        continue;
      }
      // Prefer the end of a chain of copies.
      return await findConflictOriginal(other.path, copy) ?? other.path;
    }
    return null;
  }

  static String _name(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Reads the page's file. Throws [PageFormatException] if the file holds a
  /// different page, so one page's content is never served under another id.
  Future<NotedPage> load(String pageId) async {
    final page = readPage(await File(_pathFor(pageId)).readAsString());
    if (page.id != pageId) throw const PageFormatException('the page file holds a different page');
    return page;
  }

  /// The text of the page's file, as stored.
  Future<String> readText(String pageId) => File(_pathFor(pageId)).readAsString();

  /// Writes [page] atomically: to a temporary file first, then renamed over
  /// the old file, so a crash mid-write never leaves a half-written page.
  Future<void> save(NotedPage page) async {
    final path = _pathFor(page.id);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(writePage(page), flush: true);
    await tmp.rename(path);
    _paths[page.id] = path;
  }

  /// Writes [page] as a new file, and only if no file is at its path at the
  /// moment of publishing (see [publishExclusive]). Returns false, leaving the
  /// existing file untouched and removing the temporary file, when one is.
  ///
  /// The temporary name is unique per call, so a leftover hard link (see
  /// [publishExclusive]) is never reopened by a later [save].
  ///
  /// [beforePublish] runs after the temporary file is written and before it is
  /// published; it is a seam for tests.
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) =>
      saveNewText(page, writePage(page), beforePublish: beforePublish);

  /// As [saveNew], but writes [text] (the page's file text, for putting back a
  /// file byte for byte); [page] is the page [text] holds.
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
  }) async {
    final path = _pathFor(page.id);
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
    final bool published;
    try {
      await tmp.writeAsString(text, flush: true);
      if (beforePublish != null) await beforePublish();
      published = await publishExclusive(tmp, path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    if (!published) {
      if (await tmp.exists()) await tmp.delete();
      return false;
    }
    _paths[page.id] = path;
    return true;
  }

  /// Writes [page] over the page's file only if the file still holds exactly
  /// [expectedText] (null: no file expected) at the moment of replacing; see
  /// [replaceIfUnchanged]. On [ReplaceOutcome.changed] and the `Kept` outcomes
  /// the file on disk is not what the caller merged against: reread, merge
  /// again and retry. The temporary file is always removed. On
  /// [ReplaceOutcome.supersededKept] the replaced version stays as a conflict
  /// copy at [ReplaceResult.keptPath]; it is never deleted here, even when it
  /// equals [expectedText], because it may be the only durable copy.
  ///
  /// Callers must serialise this with [scan] on the same folder (see [scan]).
  ///
  /// The hooks are seams for tests (see [replaceIfUnchanged]).
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) async {
    final path = _pathFor(page.id);
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
    try {
      final written = writePage(page);
      await tmp.writeAsString(written, flush: true);
      final expected = expectedText == null ? null : utf8.encode(expectedText);
      final result = await replaceIfUnchanged(
        tmp,
        path,
        expected,
        beforeMoveAside: beforeMoveAside,
        afterRead: afterRead,
        beforePublish: beforePublish,
        beforeRestore: beforeRestore,
      );
      if (result.replaced) _paths[page.id] = path;
      return result;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> delete(String pageId) async {
    final f = File(_pathFor(pageId));
    if (await f.exists()) await f.delete();
    _paths.remove(pageId);
  }

  /// Deletes the page's file only if it still holds exactly [expectedText]; see
  /// [deleteFileIfUnchanged]. Like [saveIfUnchanged], serialise it with [scan].
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) async {
    final r = await deleteFileIfUnchanged(
      _pathFor(pageId),
      utf8.encode(expectedText),
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
    if (r.deleted || r.outcome == DeleteOutcome.absent) _paths.remove(pageId);
    return r;
  }

  /// Makes [path] (a page file of this folder holding [pageId]) the file this
  /// store reads and writes for that page, when another file with the same id
  /// was listed first. Later scans keep the choice while the file exists and
  /// holds that id. Nothing is saved across restarts. Writes nothing.
  void adopt(String pageId, String path) {
    _paths[pageId] = path;
    _adopted[pageId] = path;
  }

  /// Forgets the choice made with [adopt] for [pageId].
  void unadopt(String pageId) => _adopted.remove(pageId);

  /// The path of the file holding (or that will hold) page [pageId].
  String pathFor(String pageId) => _pathFor(pageId);

  String _pathFor(String pageId) =>
      _paths[pageId] ??
      '${directory.path}${Platform.pathSeparator}$pageId$extension';
}
