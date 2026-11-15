// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'graph_client.dart';
import 'journal.dart';
import 'remote_driver.dart';
import 'remote_item.dart';
import 'remote_tree.dart';
import 'types.dart';

/// OneDrive through Microsoft Graph: a delta listing of the chosen folder,
/// with quickXor hashes.
class GraphDriver implements RemoteDriver {
  GraphDriver({
    required this.graph,
    required this.driveId,
    required String rootItemId,
  }) : rootId = rootItemId;

  final GraphClient graph;
  final String driveId;

  @override
  final String rootId;

  @override
  String get provider => 'onedrive';

  @override
  String get displayName => 'OneDrive';

  @override
  RemoteCaps get caps =>
      const RemoteCaps(serverHash: true, fullListing: false);

  @override
  Future<RemoteItem> root() => graph.getItem(driveId, rootId);

  @override
  Future<List<RemoteItem>> children(String itemId) =>
      graph.children(driveId, itemId);

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) =>
      graph.listFolders(parentItemId: parentItemId, driveId: driveId);

  @override
  Future<FolderHint> folderHint(String itemId) =>
      graph.folderHint(itemId, driveId: driveId);

  @override
  Future<void> download(RemoteEntry entry, File dest) =>
      graph.download(driveId, entry.id, dest);

  @override
  Future<RemoteFetch?> fetch(
    Map<String, RemoteEntry> map,
    String? cursor,
    String? endpoint,
    int seq,
  ) async {
    final rootItemId = rootId;
    var fresh = cursor == null;
    var working = fresh ? <String, RemoteEntry>{} : Map.of(map);
    Uri? link = fresh ? null : Uri.parse(cursor);
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

    if (fresh && !await seed()) return null;

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
        if (!await seed()) return null;
      }
    }
    if (rootDeleted) return null;
    final pruned = pruneToSubtree(working, rootItemId);

    // Folders new to an existing map may not come with their children.
    if (!fresh) {
      final queue = [
        for (final e in pruned.values)
          if (e.folder && e.id != rootItemId && !map.containsKey(e.id)) e.id,
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
    return RemoteFetch(
      map: pruned,
      cursor: deltaLink,
      endpoint: endpoint ?? 'folder',
      seq: seq,
      resync: resync == null
          ? null
          : RemoteResync(uploadDifferences: resync.uploadDifferences),
    );
  }
}
