// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

import 'journal.dart';
import 'types.dart';

/// The key two spellings of one path share (case-folded).
String foldKey(String s) => s.toLowerCase();

/// Whether a name from the server may be used as one path part (G8): not
/// empty, not `.` or `..`, no separators, NUL, colon or control characters,
/// and no trailing dot or space.
bool isSafeName(String name) {
  if (name.isEmpty || name == '.' || name == '..') return false;
  if (name.endsWith('.') || name.endsWith(' ')) return false;
  for (final c in name.codeUnits) {
    if (c < 0x20 || c == 0x2f || c == 0x5c || c == 0x3a) return false;
  }
  return true;
}

/// Whether [path] (a case-folded or plain relative path with `/`) has a
/// folder part that ends with `.assets`.
bool isAttachmentPath(String path) {
  final segs = path.split('/');
  for (var i = 0; i < segs.length - 1; i++) {
    if (foldKey(segs[i]).endsWith('.assets')) return true;
  }
  return false;
}

final RegExp _remoteCopy = RegExp(r'-remote-[0-9a-f]{8}\.canvas$');

bool _neverTransferred(String name) {
  final n = foldKey(name);
  return n.endsWith('.tmp') ||
      n.endsWith(asideSuffix) ||
      n.endsWith(verifiedSuffix) ||
      _remoteCopy.hasMatch(n);
}

/// A remote file the pull mirrors.
class DesiredFile {
  const DesiredFile({
    required this.key,
    required this.segs,
    required this.item,
    required this.isAttachment,
  });

  /// The case-folded path.
  final String key;

  /// The path parts as the server spells them.
  final List<String> segs;
  final RemoteEntry item;

  /// The path has a `*.assets` folder part: never deleted by a pull.
  final bool isAttachment;

  String get path => segs.join('/');
}

/// The remote map as paths: what is mirrored, what exists at all, and what
/// had to be skipped.
class RemoteView {
  RemoteView({
    required this.desired,
    required this.treePaths,
    required this.skippedIds,
    required this.binderKeys,
    required this.issues,
  });

  /// Mirrored files by case-folded path.
  final Map<String, DesiredFile> desired;

  /// Every valid path in the tree, files and folders, mirrored or not.
  final Set<String> treePaths;

  /// Items with an unusable name, and everything below them.
  final Set<String> skippedIds;

  /// Case-folded names of the root's immediate folders that hold
  /// `noted-binder.json`.
  final Set<String> binderKeys;
  final List<SyncIssue> issues;

  /// Folders (case-folded) that mirrored files need.
  Set<String> get neededFolders {
    final out = <String>{};
    for (final d in desired.values) {
      for (var i = 1; i < d.segs.length; i++) {
        out.add(d.segs.take(i).map(foldKey).join('/'));
      }
    }
    return out;
  }
}

/// Derives the paths of [map] below [rootId] (G6): two live ids on one path
/// are settled by the higher arrival sequence, names are checked (G8) and the
/// mirror filter is applied by name only.
RemoteView buildView(Map<String, RemoteEntry> map, String rootId) {
  final kids = <String?, List<RemoteEntry>>{};
  for (final e in map.values) {
    if (e.id == rootId) continue;
    (kids[e.parent] ??= []).add(e);
  }
  final issues = <SyncIssue>[];
  final skipped = <String>{};

  void skipSubtree(RemoteEntry e) {
    final todo = [e];
    while (todo.isNotEmpty) {
      final x = todo.removeLast();
      if (!skipped.add(x.id)) continue;
      todo.addAll(kids[x.id] ?? const []);
    }
  }

  /// The children of [parentId] that win their name, valid ones only.
  List<RemoteEntry> live(String parentId, String parentPath) {
    final byName = <String, RemoteEntry>{};
    for (final c in kids[parentId] ?? const <RemoteEntry>[]) {
      if (!isSafeName(c.name)) {
        issues.add(
          SyncIssue(
            parentPath.isEmpty ? c.name : '$parentPath/${c.name}',
            'OneDrive sent a name that can\'t be used here',
          ),
        );
        skipSubtree(c);
        continue;
      }
      final k = foldKey(c.name);
      final cur = byName[k];
      if (cur == null || c.seq > cur.seq) byName[k] = c;
    }
    return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  // The root's immediate folders that hold a binder file.
  final binderKeys = <String>{};
  final rootKids = live(rootId, '');
  for (final c in rootKids) {
    if (!c.folder) continue;
    final inner = <String, RemoteEntry>{};
    for (final g in kids[c.id] ?? const <RemoteEntry>[]) {
      if (g.folder || g.special || !isSafeName(g.name)) continue;
      if (foldKey(g.name) == binderFileName) inner[foldKey(g.name)] = g;
    }
    if (inner.isNotEmpty) binderKeys.add(foldKey(c.name));
  }

  final desired = <String, DesiredFile>{};
  final tree = <String>{};

  final visited = <String>{rootId};
  final stack = <(RemoteEntry, List<String>)>[
    for (final c in rootKids) (c, [c.name]),
  ];
  while (stack.isNotEmpty) {
    final (e, segs) = stack.removeLast();
    if (!visited.add(e.id)) continue;
    final key = segs.map(foldKey).join('/');
    tree.add(key);
    if (e.special) {
      issues.add(
        SyncIssue(
          segs.join('/'),
          'A shortcut or package is not mirrored; left alone',
        ),
      );
      continue;
    }
    if (e.folder) {
      final path = segs.join('/');
      for (final c in live(e.id, path)) {
        stack.add((c, [...segs, c.name]));
      }
      continue;
    }
    final kind = _mirrorKind(segs, binderKeys);
    switch (kind) {
      case _Kind.skip:
        break;
      case _Kind.rootBinder:
        issues.add(
          SyncIssue(
            segs.join('/'),
            'A binder file at the top of the folder is not mirrored',
          ),
        );
      case _Kind.mirrored:
        desired[key] = DesiredFile(
          key: key,
          segs: segs,
          item: e,
          isAttachment: isAttachmentPath(segs.join('/')),
        );
    }
  }
  return RemoteView(
    desired: desired,
    treePaths: tree,
    skippedIds: skipped,
    binderKeys: binderKeys,
    issues: issues,
  );
}

enum _Kind { skip, mirrored, rootBinder }

/// The mirror filter, by name only: `*.canvas` and `noted-binder.json` in the
/// root and in each binder, and everything below a `templates` or `*.assets`
/// folder there. Never `*.tmp`, asides or `-remote-` copies.
_Kind _mirrorKind(List<String> segs, Set<String> binderKeys) {
  final name = segs.last;
  if (_neverTransferred(name)) return _Kind.skip;
  final inBinder = segs.length >= 2 && binderKeys.contains(foldKey(segs[0]));
  final rest = inBinder ? segs.sublist(1) : segs;
  if (rest.length == 1) {
    final n = foldKey(name);
    if (n == binderFileName) {
      return inBinder ? _Kind.mirrored : _Kind.rootBinder;
    }
    if (n.endsWith('.canvas')) return _Kind.mirrored;
    return _Kind.skip;
  }
  final first = foldKey(rest[0]);
  if (first == 'templates' || first.endsWith('.assets')) return _Kind.mirrored;
  return _Kind.skip;
}

/// The part of [map] that hangs below [rootId]: items whose parent chain
/// reaches it (G13: filtered once, at the delta link, not per page).
Map<String, RemoteEntry> pruneToSubtree(
  Map<String, RemoteEntry> map,
  String rootId,
) {
  final kids = <String?, List<RemoteEntry>>{};
  for (final e in map.values) {
    (kids[e.parent] ??= []).add(e);
  }
  final out = <String, RemoteEntry>{};
  final root = map[rootId];
  if (root != null) out[rootId] = root;
  final todo = [rootId];
  while (todo.isNotEmpty) {
    final id = todo.removeLast();
    for (final c in kids[id] ?? const <RemoteEntry>[]) {
      if (c.id == rootId || out.containsKey(c.id)) continue;
      out[c.id] = c;
      if (c.folder) todo.add(c.id);
    }
  }
  return out;
}
