// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../model/page.dart';

/// The page tree, rebuilt from the parent id each page file records (0027).
///
/// A page with subpages is labelled a divider; it is still an ordinary page
/// (0025). A page whose parent is missing, or whose parent chain loops, is
/// shown at the top level.
final class PageTree {
  PageTree._(this._byId, this._children, this.roots, this._parents);

  factory PageTree.build(Iterable<PageMeta> pages) {
    final byId = <String, PageMeta>{for (final p in pages) p.id: p};

    String? effectiveParent(PageMeta p) {
      final seen = <String>{p.id};
      var cur = p.parentId;
      while (cur != null) {
        final parent = byId[cur];
        if (parent == null || !seen.add(cur)) return null;
        cur = parent.parentId;
      }
      return p.parentId;
    }

    final children = <String, List<PageMeta>>{};
    final roots = <PageMeta>[];
    final parents = <String, String?>{};
    for (final p in byId.values) {
      final parent = effectiveParent(p);
      parents[p.id] = parent;
      if (parent == null) {
        roots.add(p);
      } else {
        (children[parent] ??= []).add(p);
      }
    }
    int compare(PageMeta a, PageMeta b) {
      final c = a.order.compareTo(b.order);
      return c != 0 ? c : a.title.compareTo(b.title);
    }

    roots.sort(compare);
    for (final list in children.values) {
      list.sort(compare);
    }
    return PageTree._(
      byId,
      {for (final e in children.entries) e.key: List.unmodifiable(e.value)},
      List.unmodifiable(roots),
      parents,
    );
  }

  final Map<String, PageMeta> _byId;
  final Map<String, List<PageMeta>> _children;
  final List<PageMeta> roots;
  final Map<String, String?> _parents;

  /// The page's parent as shown in the tree: null for a top-level page, and
  /// for one whose recorded parent is missing or loops.
  String? parentIdOf(String id) => _parents[id];

  /// The pages next to [id] (including it), in order.
  List<PageMeta> siblingsOf(String id) {
    final parent = _parents[id];
    return parent == null ? roots : childrenOf(parent);
  }

  /// Whether moving [id] under [newParentId] (null: top level) would put a
  /// page under itself or one of its own descendants.
  bool wouldCycle(String id, String? newParentId) {
    if (newParentId == null) return false;
    return newParentId == id || descendantsOf(id).contains(newParentId);
  }

  PageMeta? operator [](String id) => _byId[id];

  List<PageMeta> childrenOf(String id) => _children[id] ?? const [];

  /// Whether the page has subpages, which makes it a divider (0025).
  bool isDivider(String id) => childrenOf(id).isNotEmpty;

  /// All pages below [id], depth-first.
  List<String> descendantsOf(String id) {
    final out = <String>[];
    void walk(String p) {
      for (final c in childrenOf(p)) {
        out.add(c.id);
        walk(c.id);
      }
    }

    walk(id);
    return out;
  }

  /// The order value for a new last child of [parentId] (null: top level).
  int nextOrder(String? parentId) {
    final siblings = parentId == null ? roots : childrenOf(parentId);
    var max = -1;
    for (final s in siblings) {
      if (s.order > max) max = s.order;
    }
    return max + 1;
  }
}
