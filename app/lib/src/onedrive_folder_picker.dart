// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_sync/noted_sync.dart' show FolderHint, RemoteItem;

import 'onedrive_sync.dart';

/// The refusal shown for a folder that is itself a binder.
const String binderFolderRefusal = 'This folder is a binder. Choose the folder that holds it.';

/// Opens the full-screen folder browser; returns the folder the user chose,
/// or null if they went back.
Future<ChosenRoot?> pickOneDriveFolder(BuildContext context, FolderSource source) =>
    Navigator.of(context).push<ChosenRoot>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => OneDriveFolderPicker(source: source)),
    );

/// "12 pages, 3 binders", "No Noted files".
String folderHintText(FolderHint h) {
  if (h.isEmpty) return 'No Noted files';
  final parts = [
    if (h.canvasCount > 0) '${h.canvasCount} ${h.canvasCount == 1 ? 'page' : 'pages'}',
    if (h.binderCount > 0) '${h.binderCount} ${h.binderCount == 1 ? 'binder' : 'binders'}',
  ];
  return parts.join(', ');
}

/// A browser of OneDrive's folders, one level at a time, with *Use this
/// folder* for the open one (OneDrive sync stage 3, §5). It only offers a
/// folder that holds Noted pages and binders, never one that is a binder.
class OneDriveFolderPicker extends StatefulWidget {
  const OneDriveFolderPicker({super.key, required this.source});

  final FolderSource source;

  @override
  State<OneDriveFolderPicker> createState() => _OneDriveFolderPickerState();
}

class _OneDriveFolderPickerState extends State<OneDriveFolderPicker> {
  // The open folders from the top; empty is the drive's root.
  final List<RemoteItem> _stack = [];
  List<RemoteItem> _items = const [];
  FolderHint? _hint;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  RemoteItem? get _open => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _hint = null;
      _items = const [];
    });
    final open = _open;
    try {
      final items = await widget.source.listFolders(parentItemId: open?.id);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
      });
      if (open != null) {
        final hint = await widget.source.folderHint(open.id, driveId: open.driveId);
        if (!mounted || gen != _generation) return;
        setState(() => _hint = hint);
      }
    } on Object {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loading = false;
        _error = "OneDrive's folders couldn't be listed.";
      });
    }
  }

  void _into(RemoteItem folder) {
    _stack.add(folder);
    unawaited(_load());
  }

  void _up() {
    if (_stack.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _stack.removeLast();
    unawaited(_load());
  }

  String get _path => _stack.map((f) => f.name ?? '').join('/');

  Future<void> _use() async {
    final open = _open;
    final hint = _hint;
    if (open == null || hint == null || hint.holdsBinderFile) return;
    final driveId = open.driveId;
    if (driveId == null) {
      setState(() => _error = "OneDrive didn't say which drive this folder is in.");
      return;
    }
    if (hint.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No Noted files here'),
          content: const Text('This folder has no pages or binders yet. Use it anyway?'),
          actions: [
            TextButton(
              key: const ValueKey('picker-empty-cancel'),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('picker-empty-use'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use this folder'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    Navigator.of(context).pop(ChosenRoot(driveId: driveId, itemId: open.id, path: _path));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final open = _open;
    final hint = _hint;
    final refused = hint != null && hint.holdsBinderFile;
    final note = open == null
        ? "Open a folder to use it. The top level of OneDrive can't be chosen."
        : refused
        ? binderFolderRefusal
        : hint == null
        ? (_error == null ? 'Looking…' : null)
        : folderHintText(hint);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('picker-up'),
          tooltip: open == null ? 'Close' : 'Up',
          icon: Icon(open == null ? Icons.close : Icons.arrow_back),
          onPressed: _up,
        ),
        title: Text(open?.name ?? 'OneDrive', key: const ValueKey('picker-title')),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty && _error == null
                ? Center(
                    child: Text(
                      'No folders here',
                      key: const ValueKey('picker-no-folders'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView(
                    children: [
                      for (final f in _items)
                        SizedBox(
                          height: m.rowSize,
                          child: ListTile(
                            key: ValueKey('picker-folder-${f.id}'),
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(f.name ?? ''),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _into(f),
                          ),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: EdgeInsets.all(m.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: m.space2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _error!,
                            key: const ValueKey('picker-error'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('picker-retry'),
                          onPressed: () => unawaited(_load()),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                if (note != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: m.space2),
                    child: Text(
                      note,
                      key: const ValueKey('picker-hint'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: refused ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('picker-use'),
                    onPressed: open == null || hint == null || refused ? null : () => unawaited(_use()),
                    child: const Text('Use this folder'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
