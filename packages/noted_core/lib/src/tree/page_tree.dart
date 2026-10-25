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
  PageTree._(this._byId, this._children, this.roots);

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
    for (final p in byId.values) {
      final parent = effectiveParent(p);
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
    );
  }

  final Map<String, PageMeta> _byId;
  final Map<String, List<PageMeta>> _children;
  final List<PageMeta> roots;

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
