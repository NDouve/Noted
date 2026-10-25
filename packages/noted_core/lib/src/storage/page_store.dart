// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import '../format/page_format.dart';
import '../model/page.dart';

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

  /// Reads every page file in the folder.
  Future<List<PageEntry>> scan() async {
    await directory.create(recursive: true);
    _paths.clear();
    final entries = <PageEntry>[];
    await for (final f in directory.list()) {
      if (f is! File || !f.path.endsWith(extension)) continue;
      try {
        final page = readPage(await f.readAsString());
        if (_paths.containsKey(page.id)) {
          entries.add(UnreadablePage(f.path, 'duplicate page id ${page.id}'));
          continue;
        }
        _paths[page.id] = f.path;
        entries.add(ReadablePage(f.path, page.meta, conflicted: hasConflicts(page)));
      } on PageFormatException catch (e) {
        entries.add(UnreadablePage(f.path, e.message));
      } on FileSystemException catch (e) {
        entries.add(UnreadablePage(f.path, e.message));
      }
    }
    return entries;
  }

  Future<NotedPage> load(String pageId) async =>
      readPage(await File(_pathFor(pageId)).readAsString());

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

  Future<void> delete(String pageId) async {
    final f = File(_pathFor(pageId));
    if (await f.exists()) await f.delete();
    _paths.remove(pageId);
  }

  /// The path of the file holding (or that will hold) page [pageId].
  String pathFor(String pageId) => _pathFor(pageId);

  String _pathFor(String pageId) =>
      _paths[pageId] ??
      '${directory.path}${Platform.pathSeparator}$pageId$extension';
}
