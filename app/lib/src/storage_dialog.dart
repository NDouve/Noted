// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'notebook.dart';

/// Asks where a new top-level standalone page should be stored (0027).
///
/// Lists the default folder (preselected), the other standalone folders in
/// use, and "Choose another folder…". Enter accepts the selection. Returns
/// the chosen folder, or null if cancelled.
Future<String?> askStorageFolder(BuildContext context, Notebook notebook) {
  return showDialog<String>(
    context: context,
    builder: (context) => _StorageDialog(notebook: notebook),
  );
}

class _StorageDialog extends StatefulWidget {
  const _StorageDialog({required this.notebook});

  final Notebook notebook;

  @override
  State<_StorageDialog> createState() => _StorageDialogState();
}

class _StorageDialogState extends State<_StorageDialog> {
  final FocusNode _create = FocusNode();
  late final String _default;
  late final List<String> _others;
  late String _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    final nb = widget.notebook;
    _default = nb.defaultFolderPath;
    _others = [
      for (final f in nb.standaloneFolders)
        if (f.available) f.path,
    ];
    _selected = _default;
  }

  @override
  void dispose() {
    _create.dispose();
    super.dispose();
  }

  Future<void> _chooseOther() async {
    final pick = widget.notebook.pickFolder;
    if (pick == null) return;
    final picked = await pick();
    if (picked == null || !mounted) return;
    try {
      final path = await widget.notebook.checkStandaloneFolder(picked);
      if (!mounted) return;
      setState(() {
        _error = null;
        if (path != _default && !_others.contains(path)) _others.add(path);
        _selected = path;
      });
    } on NotebookException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    _create.requestFocus();
  }

  Widget _option(String path, String label) {
    final on = _selected == path;
    return ListTile(
      key: ValueKey('storage-option-$path'),
      dense: true,
      leading: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
      title: Text(label, overflow: TextOverflow.ellipsis),
      selected: on,
      onTap: () {
        setState(() {
          _selected = path;
          _error = null;
        });
        _create.requestFocus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPick = widget.notebook.pickFolder != null;
    return AlertDialog(
      title: const Text('Where should this page be stored?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _option(_default, 'Default ($_default)'),
            for (final p in _others) _option(p, p),
            if (canPick)
              ListTile(
                key: const ValueKey('storage-choose-other'),
                dense: true,
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Choose another folder…'),
                onTap: _chooseOther,
              ),
            if (_error != null)
              Padding(
                padding: EdgeInsets.only(top: NotedMetrics.of(context).space2),
                child: Text(
                  _error!,
                  key: const ValueKey('storage-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          focusNode: _create,
          autofocus: true,
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
