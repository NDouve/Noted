// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'binder_cover.dart';
import 'notebook.dart';

/// Where on a row a dragged page is dropped.
enum DropZone {
  /// The upper edge: place before the row, as its sibling.
  before,

  /// The middle: become the row's last subpage.
  into,

  /// The lower edge: place after the row, as its sibling.
  after,
}

/// The page tree in the sidebar (0025). A page with subpages is shown as a
/// divider and can be collapsed; it still opens like any other page.
///
/// Rows can be dragged to reorder or nest them, and every row has a menu
/// (the "⋯" button, or a right click) with the same actions.
class PageTreeView extends StatefulWidget {
  const PageTreeView({super.key, required this.notebook});

  final Notebook notebook;

  @override
  State<PageTreeView> createState() => _PageTreeViewState();
}

class _PageTreeViewState extends State<PageTreeView> {
  static const double _rowHeight = 36;

  // Collapsed state lasts for the session only.
  final Set<String> _collapsed = {};
  final Map<String, GlobalKey> _rowKeys = {};

  // The drop being previewed: a row and zone, or the empty area at the end.
  String? _hoverRow;
  DropZone? _hoverZone;
  bool _hoverEnd = false;

  // A header being dropped on: a binder's path, or '' for "Pages".
  String? _hoverHeader;

  Notebook get _nb => widget.notebook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    void addTree(PageTree tree, Color? stripe) {
      void add(PageMeta p, int depth) {
        rows.add(_row(context, p, depth, stripe));
        if (_collapsed.contains(p.id)) return;
        for (final c in tree.childrenOf(p.id)) {
          add(c, depth + 1);
        }
      }

      for (final r in tree.roots) {
        add(r, 0);
      }
    }

    addTree(_nb.tree, null);
    final cantOpen = <UnreadablePage>[..._nb.unreadable];
    for (final b in _nb.binders) {
      rows.add(_binderHeader(context, b));
      if (!b.available) continue;
      cantOpen.addAll(b.unreadable);
      if (!_collapsed.contains(_binderKey(b))) {
        addTree(b.tree, parseBinderColor(b.color));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DragTarget<String>(
          key: const ValueKey('pages-header'),
          // Dropping a page on the "Pages" header makes it a standalone page.
          onWillAcceptWithDetails: (d) => _nb.treeOfPage(d.data)[d.data] != null,
          onMove: (_) {
            if (_hoverHeader != '') setState(() => _hoverHeader = '');
          },
          onLeave: (_) {
            if (_hoverHeader == '') setState(() => _hoverHeader = null);
          },
          onAcceptWithDetails: (d) {
            setState(() => _hoverHeader = null);
            _guard(() => _nb.moveToLocation(d.data));
          },
          builder: (context, _, _) => Container(
            color: _hoverHeader == '' ? theme.colorScheme.primary.withValues(alpha: 0.18) : null,
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(child: Text('Pages', style: theme.textTheme.titleSmall)),
                if (_nb.pickFolder != null)
                  IconButton(
                    tooltip: 'New binder',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () => _guard(_nb.newBinder),
                  ),
                IconButton(
                  tooltip: 'New page',
                  icon: const Icon(Icons.add),
                  onPressed: () => _nb.createPage(),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverList(delegate: SliverChildListDelegate(rows)),
              if (cantOpen.isNotEmpty)
                SliverList(
                  delegate: SliverChildListDelegate([
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text("Can't open", style: theme.textTheme.labelSmall),
                    ),
                    for (final u in cantOpen)
                      Tooltip(
                        message: u.reason,
                        child: ListTile(
                          dense: true,
                          enabled: false,
                          leading: const Icon(Icons.block, size: 18),
                          title: Text(
                            u.path.split(RegExp(r'[\\/]')).last,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ]),
                ),
              // The empty area below the list: dropping here moves a page to
              // the end of the top level of its own location.
              SliverFillRemaining(hasScrollBody: false, child: _endTarget(theme)),
            ],
          ),
        ),
      ],
    );
  }

  String _binderKey(BinderSection b) => 'binder:${b.path}';

  /// Runs [action], showing a [NotebookException] in a SnackBar.
  Future<void> _guard(Future<Object?> Function() action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } on NotebookException catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _binderHeader(BuildContext context, BinderSection b) {
    final theme = Theme.of(context);
    final color = parseBinderColor(b.color);
    if (!b.available) {
      final unreadable = b.status == BinderStatus.unreadable;
      return Tooltip(
        message: b.reason ?? '',
        child: Opacity(
          opacity: 0.6,
          child: SizedBox(
            key: ValueKey('binder-header-${b.path}'),
            height: _rowHeight + 20,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(unreadable ? Icons.block : Icons.cloud_off_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.title, overflow: TextOverflow.ellipsis),
                      Text(
                        unreadable ? "Can't open" : 'On another device',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('binder-menu-${b.path}'),
                  tooltip: 'Binder options',
                  iconSize: 18,
                  onSelected: (v) => _binderAction(context, b, v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'remove', child: Text('Remove from sidebar')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final collapsed = _collapsed.contains(_binderKey(b));
    final hover = _hoverHeader == b.path;
    final shown = _nb.coverPath == b.path;
    return DragTarget<String>(
      key: ValueKey('binder-header-${b.path}'),
      // Dropping a page on a binder header moves it (and its subpages) in.
      onWillAcceptWithDetails: (d) => _nb.treeOfPage(d.data)[d.data] != null,
      onMove: (_) {
        if (_hoverHeader != b.path) setState(() => _hoverHeader = b.path);
      },
      onLeave: (_) {
        if (_hoverHeader == b.path) setState(() => _hoverHeader = null);
      },
      onAcceptWithDetails: (d) {
        setState(() {
          _hoverHeader = null;
          _collapsed.remove(_binderKey(b));
        });
        _guard(() => _nb.moveToLocation(d.data, binderPath: b.path));
      },
      builder: (context, _, _) => Material(
        color: hover
            ? color.withValues(alpha: 0.25)
            : shown
            ? theme.colorScheme.secondaryContainer
            : color.withValues(alpha: 0.08),
        child: InkWell(
          onTap: () => _nb.showCover(b.path),
          child: SizedBox(
            height: _rowHeight + 4,
            child: Row(
              children: [
                Container(key: ValueKey('binder-stripe-${b.path}'), width: 5, color: color),
                SizedBox(
                  width: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    tooltip: collapsed ? 'Expand' : 'Collapse',
                    icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
                    onPressed: () => setState(
                      () => collapsed
                          ? _collapsed.remove(_binderKey(b))
                          : _collapsed.add(_binderKey(b)),
                    ),
                  ),
                ),
                Icon(Icons.book_outlined, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    b.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('binder-menu-${b.path}'),
                  tooltip: 'Binder options',
                  iconSize: 18,
                  onSelected: (v) => _binderAction(context, b, v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'new', child: Text('New page')),
                    PopupMenuItem(value: 'cover', child: Text('Open cover')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'remove', child: Text('Remove from sidebar')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _binderAction(BuildContext context, BinderSection b, String action) async {
    switch (action) {
      case 'new':
        setState(() => _collapsed.remove(_binderKey(b)));
        await _guard(() => _nb.createPage(binderPath: b.path));
      case 'cover':
        _nb.showCover(b.path);
      case 'remove':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove binder from sidebar?'),
            content: Text(
              '"${b.title}" will no longer be listed. Its folder and files are not deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (ok ?? false) await _nb.removeBinder(b.path);
    }
  }

  Widget _endTarget(ThemeData theme) {
    return DragTarget<String>(
      key: const ValueKey('page-tree-end'),
      onWillAcceptWithDetails: (d) => _nb.treeOfPage(d.data)[d.data] != null,
      onMove: (_) {
        if (!_hoverEnd) {
          setState(() {
            _hoverEnd = true;
            _hoverRow = null;
            _hoverZone = null;
          });
        }
      },
      onLeave: (_) {
        if (_hoverEnd) setState(() => _hoverEnd = false);
      },
      onAcceptWithDetails: (d) {
        setState(() => _hoverEnd = false);
        _guard(() => _nb.move(d.data, parentId: null));
      },
      builder: (context, _, _) => Container(
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.topCenter,
        child: _hoverEnd
            ? Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: theme.colorScheme.primary,
              )
            : null,
      ),
    );
  }

  DropZone _zoneFor(String rowId, Offset global) {
    final box = _rowKeys[rowId]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return DropZone.into;
    final y = box.globalToLocal(global).dy / box.size.height;
    if (y < 0.25) return DropZone.before;
    if (y > 0.75) return DropZone.after;
    return DropZone.into;
  }

  Future<void> _drop(String dragged, PageMeta target, DropZone zone) async {
    switch (zone) {
      case DropZone.into:
        if (await _nb.move(dragged, parentId: target.id)) {
          setState(() => _collapsed.remove(target.id));
        }
      case DropZone.before:
        await _nb.moveRelative(dragged, target.id, after: false);
      case DropZone.after:
        await _nb.moveRelative(dragged, target.id, after: true);
    }
  }

  Widget _row(BuildContext context, PageMeta p, int depth, Color? stripe) {
    final theme = Theme.of(context);
    final divider = _nb.treeOfPage(p.id).isDivider(p.id);
    final collapsed = _collapsed.contains(p.id);
    final selected = _nb.currentId == p.id && _nb.coverPath == null;
    final title = p.title.isEmpty ? 'Untitled page' : p.title;
    final key = _rowKeys.putIfAbsent(p.id, () => GlobalKey());
    final hover = _hoverRow == p.id ? _hoverZone : null;
    final indent = 8.0 + depth * 16;

    final content = Material(
      color: hover == DropZone.into
          ? theme.colorScheme.primary.withValues(alpha: 0.18)
          : selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: () => _nb.open(p.id),
        onDoubleTap: () => _rename(context, p),
        child: Padding(
          padding: EdgeInsets.only(left: indent, right: 4),
          child: SizedBox(
            height: _rowHeight,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: divider
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: collapsed ? 'Expand' : 'Collapse',
                          icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
                          onPressed: () => setState(
                            () => collapsed ? _collapsed.remove(p.id) : _collapsed.add(p.id),
                          ),
                        )
                      : null,
                ),
                Icon(
                  divider ? Icons.topic_outlined : Icons.article_outlined,
                  size: 18,
                  color: stripe,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: divider ? const TextStyle(fontWeight: FontWeight.w600) : null,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Page options',
                  iconSize: 18,
                  onSelected: (v) => _act(context, p, v),
                  itemBuilder: (_) => _menuItems(p),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final line = Container(
      height: 2,
      margin: EdgeInsets.only(left: indent, right: 4),
      color: theme.colorScheme.primary,
    );

    final draggable = _draggable(
      p,
      title,
      stripe == null
          ? content
          : DecoratedBox(
              key: ValueKey('page-stripe-${p.id}'),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: stripe, width: 3)),
              ),
              child: content,
            ),
    );

    return DragTarget<String>(
      key: ValueKey('page-row-${p.id}'),
      // A page can't go onto itself or into its own subtree.
      // Pages in other locations are moved across (their subpages with them).
      onWillAcceptWithDetails: (d) =>
          d.data != p.id &&
          _nb.treeOfPage(d.data)[d.data] != null &&
          !(_nb.binderOfPage(d.data) == _nb.binderOfPage(p.id) &&
              _nb.treeOfPage(p.id).wouldCycle(d.data, p.id)),
      onMove: (d) {
        final zone = _zoneFor(p.id, d.offset);
        if (_hoverRow != p.id || _hoverZone != zone || _hoverEnd) {
          setState(() {
            _hoverRow = p.id;
            _hoverZone = zone;
            _hoverEnd = false;
          });
        }
      },
      onLeave: (_) {
        if (_hoverRow == p.id) {
          setState(() {
            _hoverRow = null;
            _hoverZone = null;
          });
        }
      },
      onAcceptWithDetails: (d) {
        final zone = _zoneFor(p.id, d.offset);
        setState(() {
          _hoverRow = null;
          _hoverZone = null;
        });
        _guard(() => _drop(d.data, p, zone));
      },
      builder: (context, _, _) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (d) => _contextMenu(context, p, d.globalPosition),
        child: Stack(
          key: key,
          children: [
            draggable,
            if (hover == DropZone.before) Positioned(top: 0, left: 0, right: 0, child: line),
            if (hover == DropZone.after) Positioned(bottom: 0, left: 0, right: 0, child: line),
          ],
        ),
      ),
    );
  }

  /// Wraps a row so it can be dragged. Touch needs a long press so scrolling
  /// the list still works; a mouse drags at once.
  Widget _draggable(PageMeta p, String title, Widget child) {
    final feedback = Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(title, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    final ghost = Opacity(opacity: 0.4, child: child);
    // Drags as soon as the mouse moves (desktop); a sidebar list doesn't
    // scroll on mouse drag, so nothing competes with it.
    return Draggable<String>(
      data: p.id,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: ghost,
      child: child,
    );
  }

  List<PopupMenuEntry<String>> _menuItems(PageMeta p) {
    final siblings = _nb.treeOfPage(p.id).siblingsOf(p.id);
    final i = siblings.indexWhere((s) => s.id == p.id);
    return [
      const PopupMenuItem(value: 'sub', child: Text('New subpage')),
      const PopupMenuItem(value: 'rename', child: Text('Rename')),
      const PopupMenuDivider(),
      PopupMenuItem(value: 'up', enabled: i > 0, child: const Text('Move up')),
      PopupMenuItem(
        value: 'down',
        enabled: i >= 0 && i < siblings.length - 1,
        child: const Text('Move down'),
      ),
      PopupMenuItem(value: 'indent', enabled: i > 0, child: const Text('Indent')),
      PopupMenuItem(
        value: 'outdent',
        enabled: _nb.treeOfPage(p.id).parentIdOf(p.id) != null,
        child: const Text('Outdent'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'delete', child: Text('Delete')),
    ];
  }

  Future<void> _contextMenu(BuildContext context, PageMeta p, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      items: _menuItems(p),
    );
    if (v != null && context.mounted) await _act(context, p, v);
  }

  Future<void> _act(BuildContext context, PageMeta p, String action) async {
    switch (action) {
      case 'sub':
        setState(() => _collapsed.remove(p.id));
        await _nb.createPage(parentId: p.id);
      case 'rename':
        await _rename(context, p);
      case 'up':
        await _nb.moveUp(p.id);
      case 'down':
        await _nb.moveDown(p.id);
      case 'indent':
        final above = _aboveSibling(p.id);
        if (await _nb.indent(p.id) && above != null) {
          setState(() => _collapsed.remove(above));
        }
      case 'outdent':
        await _nb.outdent(p.id);
      case 'delete':
        await _delete(context, p);
    }
  }

  String? _aboveSibling(String id) {
    final siblings = _nb.treeOfPage(id).siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    return i > 0 ? siblings[i - 1].id : null;
  }

  Future<void> _rename(BuildContext context, PageMeta p) async {
    final text = TextEditingController(text: p.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename page'),
        content: TextField(
          controller: text,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    text.dispose();
    if (title != null && title.trim().isNotEmpty) await _nb.rename(p.id, title.trim());
  }

  Future<void> _delete(BuildContext context, PageMeta p) async {
    final subpages = _nb.treeOfPage(p.id).descendantsOf(p.id).length;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete page?'),
        content: Text(
          subpages == 0
              ? '"${p.title}" will be deleted.'
              : '"${p.title}" and its $subpages subpage${subpages == 1 ? '' : 's'} will be deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    final deleted = await _nb.delete(p.id);
    if (messenger == null) return;
    // The deleted pages stay in memory only as long as the snackbar (or until
    // the next delete); once it goes away without Undo they are dropped.
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text('Deleted "${p.title.isEmpty ? 'Untitled page' : p.title}"'),
            action: SnackBarAction(label: 'Undo', onPressed: () => _nb.undoDelete(deleted)),
          ),
        )
        .closed
        .then((reason) {
          if (reason != SnackBarClosedReason.action) _nb.discardDeleted(deleted);
        });
  }
}
