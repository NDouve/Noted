// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'notebook.dart';

/// The page tree in the sidebar (0025). A page with subpages is shown as a
/// divider and can be collapsed; it still opens like any other page.
class PageTreeView extends StatefulWidget {
  const PageTreeView({super.key, required this.notebook});

  final Notebook notebook;

  @override
  State<PageTreeView> createState() => _PageTreeViewState();
}

class _PageTreeViewState extends State<PageTreeView> {
  final Set<String> _collapsed = {};

  Notebook get _nb => widget.notebook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    void add(PageMeta p, int depth) {
      rows.add(_row(context, p, depth));
      if (_collapsed.contains(p.id)) return;
      for (final c in _nb.tree.childrenOf(p.id)) {
        add(c, depth + 1);
      }
    }

    for (final r in _nb.tree.roots) {
      add(r, 0);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text('Pages', style: theme.textTheme.titleSmall)),
              IconButton(
                tooltip: 'New page',
                icon: const Icon(Icons.add),
                onPressed: () => _nb.createPage(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              ...rows,
              if (_nb.unreadable.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text("Can't open", style: theme.textTheme.labelSmall),
                ),
                for (final u in _nb.unreadable)
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
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, PageMeta p, int depth) {
    final divider = _nb.tree.isDivider(p.id);
    final collapsed = _collapsed.contains(p.id);
    final selected = _nb.currentId == p.id;
    final title = p.title.isEmpty ? 'Untitled page' : p.title;
    return Material(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: () => _nb.open(p.id),
        onDoubleTap: () => _rename(context, p),
        child: Padding(
          padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 4),
          child: SizedBox(
            height: 36,
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
                Icon(divider ? Icons.topic_outlined : Icons.article_outlined, size: 18),
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
                  onSelected: (v) {
                    switch (v) {
                      case 'sub':
                        _collapsed.remove(p.id);
                        _nb.createPage(parentId: p.id);
                      case 'rename':
                        _rename(context, p);
                      case 'delete':
                        _delete(context, p);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'sub', child: Text('Add subpage')),
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final subpages = _nb.tree.descendantsOf(p.id).length;
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
    if (ok ?? false) await _nb.delete(p.id);
  }
}
