// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import '../journal.dart';
import '../remote_driver.dart';
import '../remote_item.dart';
import '../remote_tree.dart' show isSafeName;
import '../types.dart';
import 'webdav_client.dart';

/// A WebDAV folder (RFC 4918), read only. Every round is a full walk of the
/// folder; the version of a file is its ETag (kept in the entry's `cTag`, with
/// a leading `W/` dropped), and there is no server hash.
///
/// An item's id is of the [idKind] fixed at connect: `DAV:resource-id`, else
/// `oc:fileid`, else the path below the root. A later round in which an item
/// lacks that id is incomplete. The root's id is [rootId] (`/` for path ids).
class WebDavDriver implements RemoteDriver {
  /// A driver for a connection made before: [idKind] and [rootId] are the
  /// ones [connect] found.
  WebDavDriver({
    required this.client,
    required this.idKind,
    required this.rootId,
  });

  /// The cursor saved in the journal: a full walk has none, but the journal
  /// wants a link.
  static const String cursor = 'webdav:full';

  /// Connects: `OPTIONS` must list class 1, the address must be a folder, a
  /// first full walk must give every file a version (else
  /// [RemoteNotSupported]), and the id kind is chosen from what that walk
  /// shows.
  static Future<WebDavDriver> connect(WebDavClient client) async {
    await client.checkDav();
    final top = await client.stat(client.root);
    if (!top.folder) {
      throw RemoteNotSupported('This address is not a folder');
    }
    final listing = await client.list(connecting: true);
    final kind = _chooseKind(listing.nodes);
    return WebDavDriver(
      client: client,
      idKind: kind,
      rootId: listing.nodes.first.idFor(kind)!,
    );
  }

  /// The first kind every item has, with no two items sharing an id.
  static DavIdKind _chooseKind(List<DavNode> nodes) {
    for (final k in const [DavIdKind.resourceId, DavIdKind.fileId]) {
      final ids = <String>{};
      var all = true;
      for (final n in nodes) {
        final id = n.idFor(k);
        if (id == null || !ids.add(id)) {
          all = false;
          break;
        }
      }
      if (all) return k;
    }
    return DavIdKind.path;
  }

  final WebDavClient client;
  final DavIdKind idKind;

  @override
  final String rootId;

  /// Where each item of the latest listing is, by id.
  final Map<String, Uri> _urls = {};

  @override
  String get provider => 'webdav';

  @override
  String get displayName => 'WebDAV';

  @override
  RemoteCaps get caps => const RemoteCaps(serverHash: false, fullListing: true);

  Set<DavIdKind> get _idProps => idKind == DavIdKind.path ? const {} : {idKind};

  /// The address of the item [id] from the latest listing; null when unknown.
  /// For the folder picker, to start a driver rooted at a chosen folder.
  Uri? urlOf(String id) {
    if (id == rootId) return client.root;
    final known = _urls[id];
    if (known != null) return known;
    if (idKind != DavIdKind.path) return null;
    try {
      final base = [
        for (final s in client.root.pathSegments)
          if (s.isNotEmpty) s,
      ];
      return client.root.replace(
        pathSegments: [...base, ...id.split('/').map(Uri.decodeComponent)],
      );
    } on FormatException {
      return null;
    }
  }

  String _idOf(DavNode n) => n.idFor(idKind) ?? n.pathId;

  RemoteItem _item(DavNode n, String? parent) => RemoteItem(
    id: _idOf(n),
    name: n.name,
    parentId: parent,
    isFolder: n.folder,
    eTag: n.etag,
    size: n.size,
  );

  @override
  Future<RemoteItem> root() async {
    final n = await client.stat(client.root, idProps: _idProps);
    final id = n.idFor(idKind);
    if (id == null) throw WebDavIncomplete('The server gave an item no id');
    return RemoteItem(
      id: rootId,
      name: '',
      isFolder: n.folder,
      // Another folder at the address now: this one is gone.
      deleted: id != rootId,
    );
  }

  @override
  Future<RemoteFetch?> fetch(
    Map<String, RemoteEntry> map,
    String? cursor,
    String? endpoint,
    int seq,
  ) async {
    final listing = await client.list(idProps: _idProps);
    final root = listing.nodes.first;
    final rid = root.idFor(idKind);
    if (rid == null) throw WebDavIncomplete('The server gave an item no id');
    if (rid != rootId) return null;
    final byPath = <String, String>{'': rootId};
    final ids = <String>{rootId};
    final entries = <String, RemoteEntry>{
      rootId: RemoteEntry(id: rootId, parent: null, name: '', folder: true),
    };
    final urls = <String, Uri>{rootId: client.root};
    var next = seq;
    for (final n in listing.nodes.skip(1)) {
      final id = n.idFor(idKind);
      if (id == null) throw WebDavIncomplete('The server gave an item no id');
      if (!ids.add(id)) throw WebDavIncomplete('Two items share one id');
      final parentPath = n.segments.length <= 1
          ? ''
          : n.segments
                .take(n.segments.length - 1)
                .map(Uri.encodeComponent)
                .join('/');
      final parent = byPath[parentPath];
      if (parent == null) {
        throw WebDavIncomplete('The server listed an item without its folder');
      }
      byPath[n.pathId] = id;
      final tag = n.etag == null ? null : stripWeak(n.etag!);
      // An item that hasn't changed keeps its sequence: when two names differ
      // only by case, the one that arrived last wins, round after round.
      final old = map[id];
      final same =
          old != null &&
          old.parent == parent &&
          old.name == n.name &&
          old.folder == n.folder &&
          old.cTag == tag &&
          old.size == n.size;
      entries[id] = RemoteEntry(
        id: id,
        parent: parent,
        name: n.name,
        folder: n.folder,
        cTag: tag,
        size: n.size,
        seq: same ? old.seq : ++next,
      );
      urls[id] = n.url;
    }
    // A folder with an unusable name isn't walked. What was known below it is
    // carried forward unchanged, so the engine skips and lists it (as it does
    // for OneDrive, whose map keeps the descendants) and never reads the
    // folder's going unusable as the removal of what it held.
    final carried = <String>{};
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in map.values) {
        if (entries.containsKey(e.id) || e.parent == null) continue;
        final p = entries[e.parent];
        if (p != null &&
            p.folder &&
            p.id != rootId &&
            (carried.contains(p.id) || !isSafeName(p.name))) {
          carried.add(e.id);
          entries[e.id] = e;
          grew = true;
        }
      }
    }
    _urls
      ..clear()
      ..addAll(urls);
    return RemoteFetch(
      map: entries,
      cursor: WebDavDriver.cursor,
      endpoint: 'full',
      seq: next,
      issues: listing.issues,
    );
  }

  Future<DavFolder> _list(String itemId) {
    final url = urlOf(itemId);
    if (url == null) throw RemoteNotFound('Not found');
    return client.listFolder(url, idProps: _idProps);
  }

  @override
  Future<List<RemoteItem>> children(String itemId) async {
    final f = await _list(itemId);
    return [for (final c in f.children) _item(c, itemId)];
  }

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) async {
    final f = await _list(parentItemId ?? rootId);
    final out = <RemoteItem>[];
    for (final c in f.children) {
      if (!c.folder || !isSafeName(c.name)) continue;
      final item = _item(c, parentItemId ?? rootId);
      _urls[item.id] = c.url;
      out.add(item);
    }
    return out..sort(
      (a, b) =>
          (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()),
    );
  }

  @override
  Future<FolderHint> folderHint(String itemId) async {
    final f = await _list(itemId);
    var canvases = 0;
    var holds = false;
    final subfolders = <DavNode>[];
    for (final c in f.children) {
      if (!isSafeName(c.name)) continue;
      final n = c.name.toLowerCase();
      if (c.folder) {
        subfolders.add(c);
      } else if (n.endsWith('.canvas')) {
        canvases++;
      } else if (n == 'noted-binder.json') {
        holds = true;
      }
    }
    var binders = 0;
    for (final s in subfolders) {
      final inner = await client.listFolder(s.url, idProps: const {});
      if (inner.children.any(
        (k) => !k.folder && k.name.toLowerCase() == 'noted-binder.json',
      )) {
        binders++;
      }
    }
    return FolderHint(
      canvasCount: canvases,
      binderCount: binders,
      holdsBinderFile: holds,
    );
  }

  @override
  Future<void> download(RemoteEntry entry, File dest) async {
    final url = urlOf(entry.id);
    final tag = entry.cTag;
    if (url == null) throw RemoteNotFound('Not found');
    if (tag == null) throw RemoteException('The file has no version');
    await client.download(url, etag: tag, size: entry.size, dest: dest);
  }
}
