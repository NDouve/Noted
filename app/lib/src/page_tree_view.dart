// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show CommandRegistry, NotedColors;
import 'package:noted_core/noted_core.dart';

import 'app_commands.dart';
import 'binder_colors.dart';
import 'notebook.dart';
import 'storage_dialog.dart';
import 'template_dialogs.dart';

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

class _PageTreeViewState extends State<PageTreeView> implements PageTreeActions {
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

  /// A menu entry for command [id] of [registry]: its label, enabled as the
  /// command is. The menu's value is the command's id.
  PopupMenuItem<String> _item(CommandRegistry registry, String id) {
    final c = registry[id]!;
    return PopupMenuItem<String>(value: id, enabled: c.enabled, child: Text(c.label));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = pagesHeaderCommands(_nb, this);
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
    if (!_nb.defaultFolderAvailable) {
      rows.add(
        _unavailableFolder(
          context,
          const ValueKey('folder-header-default'),
          'Default pages folder',
          'Folder not found. It may be on another device.',
        ),
      );
    }
    for (final f in _nb.standaloneFolders) {
      if (!f.available) rows.add(_folderHeader(context, f));
    }
    final cantOpen = <UnreadablePage>[..._nb.unreadable, ..._nb.recoveryDamaged];
    for (final b in _nb.binders) {
      rows.add(_binderHeader(context, b));
      // A binder whose folder is away keeps its pages listed, greyed.
      if (!b.available && !b.readOnly && !b.missing) continue;
      cantOpen.addAll(b.unreadable);
      if (!_collapsed.contains(_binderKey(b))) {
        addTree(b.tree, b.available ? binderSidebarColor(context, b.color) : null);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DragTarget<String>(
          key: const ValueKey('pages-header'),
          // Dropping a page on the "Pages" header makes it a standalone page.
          onWillAcceptWithDetails: (d) =>
          _nb.treeOfPage(d.data)[d.data] != null && !_nb.isReadOnlyPage(d.data),
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
                    tooltip: header[AppCommands.newBinder]!.label,
                    icon: Icon(header[AppCommands.newBinder]!.icon),
                    onPressed: () => header.invoke(AppCommands.newBinder),
                  ),
                IconButton(
                  tooltip: header[AppCommands.newPage]!.label,
                  icon: Icon(header[AppCommands.newPage]!.icon),
                  onPressed: () => header.invoke(AppCommands.newPage),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('pages-menu'),
                  tooltip: 'Pages options',
                  iconSize: 18,
                  onSelected: (id) => header.invoke(id),
                  itemBuilder: (_) => [
                    _item(header, AppCommands.newPage),
                    _item(header, AppCommands.newPageFromTemplate),
                    if (_nb.pickFolder != null) ...[
                      const PopupMenuDivider(),
                      _item(header, AppCommands.newBinder),
                      _item(header, AppCommands.newBinderFromTemplate),
                    ],
                  ],
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
  Future<void> _guard(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } on NotebookException catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Asks where a new top-level standalone page goes (0027), unless there is
  /// nothing to choose from, and returns the folder (null: the default one).
  /// [cancelled] is true if the user cancelled.
  Future<(String?, bool)> _askFolder() async {
    if (_nb.pickFolder == null && _nb.standaloneFolders.isEmpty) return (null, false);
    final folder = await askStorageFolder(context, _nb);
    return (folder, folder == null);
  }

  Future<void> _newStandalonePage() async {
    final (folder, cancelled) = await _askFolder();
    if (cancelled) return;
    await _nb.createPage(folderPath: folder);
  }

  // The page tree's actions, which the app's commands (app_commands.dart)
  // call. Menus and buttons invoke the commands, not these directly.

  @override
  Future<void> newStandalonePage() => _guard(_newStandalonePage);

  @override
  Future<void> newPageFromTemplate() => _guard(() async {
    final t = await _pickTemplate(TemplateKind.page, 'New page from template');
    if (t == null || !mounted) return;
    final (folder, cancelled) = await _askFolder();
    if (cancelled) return;
    await _nb.createPageFromTemplate(t.template, folderPath: folder);
  });

  @override
  Future<void> newBinder() => _guard(_nb.newBinder);

  @override
  Future<void> newBinderFromTemplate() => _guard(_newBinderFromTemplate);

  Future<TemplateItem?> _pickTemplate(TemplateKind kind, String title, {String? binderPath}) async {
    final listing = await _nb.listTemplates(kind, binderPath: binderPath);
    if (!mounted) return null;
    return pickTemplate(context, _nb, listing, title: title);
  }

  Future<void> _newBinderFromTemplate() async {
    final pick = _nb.pickFolder;
    if (pick == null) return;
    final t = await _pickTemplate(TemplateKind.binder, 'New binder from template');
    if (t == null) return;
    final path = await pick();
    if (path == null) return;
    await _nb.createBinderFromTemplate(t.template, path);
  }

  Future<void> _saveAsTemplate(PageMeta p) async {
    final inBinder = _nb.binderOfPage(p.id) != null;
    final choice = await askSaveTemplate(
      context,
      title: 'Save as template',
      defaultName: p.title,
      offerBinder: inBinder,
    );
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final t = await _nb.savePageAsTemplate(p.id, name: choice.name, inBinder: choice.inBinder);
    if (!mounted) return;
    messenger?.showSnackBar(SnackBar(content: Text('Saved template "${t.name}"')));
  }

  Future<void> _saveBinderAsTemplate(BinderSection b) async {
    final choice = await askSaveTemplate(
      context,
      title: 'Save binder as template',
      defaultName: b.title,
      offerBinder: false,
    );
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final t = await _nb.saveBinderAsTemplate(b.path, name: choice.name);
    if (!mounted) return;
    messenger?.showSnackBar(SnackBar(content: Text('Saved template "${t.name}"')));
  }

  // A remembered standalone folder that can't be used now (0027).
  Widget _folderHeader(BuildContext context, StandaloneFolder f) => _unavailableFolder(
    context,
    ValueKey('folder-header-${f.path}'),
    f.name,
    f.reason ?? '',
    remove: () => _guard(() => _nb.removeStandaloneFolder(f.path)),
    menuKey: ValueKey('folder-menu-${f.path}'),
  );

  // A standalone folder that isn't there; [remove] is null for the default one.
  Widget _unavailableFolder(
    BuildContext context,
    Key key,
    String name,
    String reason, {
    VoidCallback? remove,
    Key? menuKey,
  }) {
    final theme = Theme.of(context);
    return Tooltip(
      message: reason,
      child: Opacity(
        opacity: 0.6,
        child: SizedBox(
          key: key,
          height: _rowHeight + 20,
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Icon(Icons.cloud_off_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, overflow: TextOverflow.ellipsis),
                    Text('On another device', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              if (remove != null)
                PopupMenuButton<String>(
                  key: menuKey,
                  tooltip: 'Folder options',
                  iconSize: 18,
                  onSelected: (_) => remove(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'remove', child: Text('Remove from list')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _binderHeader(BuildContext context, BinderSection b) {
    final theme = Theme.of(context);
    final color = binderSidebarColor(context, b.color);
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
                        unreadable ? "Binder file can't be read" : 'On another device',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('binder-menu-${b.path}'),
                  tooltip: 'Binder options',
                  iconSize: 18,
                  onSelected: (v) => binderCommands(_nb, b, this).invoke(v),
                  itemBuilder: (_) => _binderItems(b),
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
      onWillAcceptWithDetails: (d) =>
          _nb.treeOfPage(d.data)[d.data] != null && !_nb.isReadOnlyPage(d.data),
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
                  onSelected: (v) => binderCommands(_nb, b, this).invoke(v),
                  itemBuilder: (_) => _binderItems(b),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _binderItems(BinderSection b) {
    final r = binderCommands(_nb, b, this);
    return [
      if (r[AppCommands.binderNewPage] != null) ...[
        _item(r, AppCommands.binderNewPage),
        _item(r, AppCommands.binderNewPageFromTemplate),
        _item(r, AppCommands.binderCover),
        const PopupMenuDivider(),
        _item(r, AppCommands.binderSaveAsTemplate),
        const PopupMenuDivider(),
      ],
      _item(r, AppCommands.binderRemove),
    ];
  }

  @override
  Future<void> binderNewPage(BinderSection b) async {
    setState(() => _collapsed.remove(_binderKey(b)));
    await _guard(() => _nb.createPage(binderPath: b.path));
  }

  @override
  Future<void> binderNewPageFromTemplate(BinderSection b) => _guard(() async {
    final t = await _pickTemplate(TemplateKind.page, 'New page from template', binderPath: b.path);
    if (t == null) return;
    setState(() => _collapsed.remove(_binderKey(b)));
    await _nb.createPageFromTemplate(t.template, binderPath: b.path);
  });

  @override
  Future<void> binderSaveAsTemplate(BinderSection b) => _guard(() => _saveBinderAsTemplate(b));

  @override
  Future<void> binderRemove(BinderSection b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove binder from sidebar?'),
        content: Text(
          '"${b.title}" will no longer be listed. Its folder and files are not deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok ?? false) await _nb.removeBinder(b.path);
  }

  Widget _endTarget(ThemeData theme) {
    return DragTarget<String>(
      key: const ValueKey('page-tree-end'),
      onWillAcceptWithDetails: (d) =>
          _nb.treeOfPage(d.data)[d.data] != null && !_nb.isReadOnlyPage(d.data),
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
    // Pages of a binder whose file can't be read: greyed, to view only.
    final locked = _nb.isReadOnlyPage(p.id);
    final greyed = theme.colorScheme.onSurface.withValues(alpha: 0.38);

    final content = Material(
      color: hover == DropZone.into
          ? theme.colorScheme.primary.withValues(alpha: 0.18)
          : selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: () => _guard(() => _nb.open(p.id)),
        onDoubleTap: locked ? null : () => _rename(context, p),
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
                  color: locked ? greyed : stripe,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: divider ? FontWeight.w600 : null,
                      color: locked ? greyed : null,
                    ),
                  ),
                ),
                if (_nb.hasConflict(p.id))
                  Tooltip(
                    message: 'Has conflicting changes',
                    child: Icon(
                      Icons.circle,
                      key: ValueKey('page-conflict-${p.id}'),
                      size: 10,
                      color: NotedColors.of(context).conflict,
                    ),
                  ),
                if (locked)
                  const SizedBox(width: 8)
                else
                  PopupMenuButton<String>(
                    tooltip: 'Page options',
                    iconSize: 18,
                    onSelected: (v) => pageCommands(_nb, p, this).invoke(v),
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
      locked,
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
          !locked &&
          !_nb.isReadOnlyPage(d.data) &&
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
        onSecondaryTapDown: locked ? null : (d) => _contextMenu(context, p, d.globalPosition),
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
  Widget _draggable(PageMeta p, String title, bool locked, Widget child) {
    if (locked) return child; // read-only pages can't be dragged
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
    final r = pageCommands(_nb, p, this);
    return [
      _item(r, AppCommands.newSubpage),
      _item(r, AppCommands.newSubpageFromTemplate),
      _item(r, AppCommands.saveAsTemplate),
      _item(r, AppCommands.rename),
      const PopupMenuDivider(),
      _item(r, AppCommands.moveUp),
      _item(r, AppCommands.moveDown),
      _item(r, AppCommands.indent),
      _item(r, AppCommands.outdent),
      const PopupMenuDivider(),
      _item(r, AppCommands.delete),
    ];
  }

  // The page's actions, which its commands call.

  @override
  Future<void> newSubpage(PageMeta p) async {
    setState(() => _collapsed.remove(p.id));
    await _guard(() => _nb.createPage(parentId: p.id));
  }

  @override
  Future<void> newSubpageFromTemplate(PageMeta p) => _guard(() async {
    final t = await _pickTemplate(
      TemplateKind.page,
      'New subpage from template',
      binderPath: _nb.binderOfPage(p.id),
    );
    if (t == null) return;
    setState(() => _collapsed.remove(p.id));
    await _nb.createPageFromTemplate(t.template, parentId: p.id);
  });

  @override
  Future<void> saveAsTemplate(PageMeta p) => _guard(() => _saveAsTemplate(p));

  @override
  Future<void> rename(PageMeta p) => _rename(context, p);

  @override
  Future<void> indent(PageMeta p) async {
    final above = _aboveSibling(p.id);
    if (await _nb.indent(p.id) && above != null) {
      setState(() => _collapsed.remove(above));
    }
  }

  @override
  Future<void> delete(PageMeta p) => _delete(context, p);

  Future<void> _contextMenu(BuildContext context, PageMeta p, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      items: _menuItems(p),
    );
    if (v != null && context.mounted) await pageCommands(_nb, p, this).invoke(v);
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
