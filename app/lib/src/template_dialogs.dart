// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'notebook.dart';

/// What the user chose when saving a template.
class SaveTemplateChoice {
  const SaveTemplateChoice(this.name, this.inBinder);

  final String name;

  /// Save with the page's binder instead of app-wide.
  final bool inBinder;
}

/// Asks for a template name and, for a page in a binder, where to save it.
/// Returns null if cancelled.
Future<SaveTemplateChoice?> askSaveTemplate(
  BuildContext context, {
  required String title,
  required String defaultName,
  required bool offerBinder,
}) {
  return showDialog<SaveTemplateChoice>(
    context: context,
    builder: (context) =>
        _SaveTemplateDialog(title: title, defaultName: defaultName, offerBinder: offerBinder),
  );
}

class _SaveTemplateDialog extends StatefulWidget {
  const _SaveTemplateDialog({
    required this.title,
    required this.defaultName,
    required this.offerBinder,
  });

  final String title;
  final String defaultName;
  final bool offerBinder;

  @override
  State<_SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<_SaveTemplateDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.defaultName);
  late bool _inBinder = widget.offerBinder;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, SaveTemplateChoice(_name.text, _inBinder));

  Widget _where(String key, String label, bool inBinder) {
    final on = _inBinder == inBinder;
    return ListTile(
      key: ValueKey(key),
      dense: true,
      leading: Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(label),
      selected: on,
      onTap: () => setState(() => _inBinder = inBinder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('template-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Template name'),
              onSubmitted: (_) => _save(),
            ),
            SizedBox(height: NotedMetrics.of(context).space2),
            if (widget.offerBinder) ...[
              _where('template-where-binder', 'This binder', true),
              _where('template-where-app', 'All binders and pages', false),
            ] else
              Padding(
                padding: EdgeInsets.only(top: NotedMetrics.of(context).space1),
                child: Text(
                  'Saved with the templates for all binders and pages.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Lists [listing] and returns the template picked, or null. Templates can be
/// deleted from the list; a file that can't be read is shown and not
/// selectable.
Future<TemplateItem?> pickTemplate(
  BuildContext context,
  Notebook notebook,
  TemplateListing listing, {
  required String title,
}) {
  return showDialog<TemplateItem>(
    context: context,
    builder: (context) => _PickTemplateDialog(notebook: notebook, listing: listing, title: title),
  );
}

class _PickTemplateDialog extends StatefulWidget {
  const _PickTemplateDialog({
    required this.notebook,
    required this.listing,
    required this.title,
  });

  final Notebook notebook;
  final TemplateListing listing;
  final String title;

  @override
  State<_PickTemplateDialog> createState() => _PickTemplateDialogState();
}

class _PickTemplateDialogState extends State<_PickTemplateDialog> {
  late final List<TemplateItem> _items = [...widget.listing.items];
  String? _error;

  String _name(TemplateItem t) {
    final n = t.template.name.trim();
    return n.isEmpty ? 'Untitled template' : n;
  }

  Future<void> _delete(TemplateItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete template?'),
        content: Text('"${_name(item)}" will be deleted. Pages made from it are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) return;
    try {
      await widget.notebook.deleteTemplate(item);
      if (mounted) setState(() => _items.remove(item));
    } on NotebookException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bad = widget.listing.unreadable;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: _items.isEmpty && bad.isEmpty
            ? const Text('There are no templates yet.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final t in _items)
                    ListTile(
                      key: ValueKey('template-${t.template.id}'),
                      dense: true,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(_name(t), overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        t.binderPath == null ? 'All binders and pages' : 'This binder',
                      ),
                      onTap: () => Navigator.pop(context, t),
                      trailing: IconButton(
                        key: ValueKey('template-delete-${t.template.id}'),
                        tooltip: 'Delete template',
                        icon: Icon(Icons.delete_outline, size: NotedMetrics.of(context).icon),
                        onPressed: () => _delete(t),
                      ),
                    ),
                  for (final u in bad)
                    ListTile(
                      key: ValueKey('template-unreadable-${u.path}'),
                      dense: true,
                      enabled: false,
                      leading: Icon(Icons.block, size: NotedMetrics.of(context).icon),
                      title: Text(u.path.split(RegExp(r'[\\/]')).last, overflow: TextOverflow.ellipsis),
                      subtitle: Text("Can't open: ${u.reason}"),
                    ),
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.only(top: NotedMetrics.of(context).space2),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
