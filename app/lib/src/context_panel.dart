// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'app_commands.dart';
import 'notebook.dart';
import 'settings_panel.dart';

/// The contextual right panel: what applies to the page, or to the one box
/// selected (or being edited). Every control is a command of the canvas's live
/// [registry] (0067), read live; a pointer press on a control takes no focus
/// (as the toolbar's, 0068), so an open note keeps its caret.
///
/// The canvas has single selection only, so there is no several-boxes state.
class ContextPanel extends StatefulWidget {
  const ContextPanel({
    super.key,
    required this.notebook,
    required this.controller,
    required this.registry,
    this.onClose,
  });

  final Notebook notebook;
  final CanvasController controller;
  final CommandRegistry registry;

  /// Shown as a Close button when the panel is an overlay.
  final VoidCallback? onClose;

  @override
  State<ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends State<ContextPanel> {
  // Page settings and Binder settings: the same dialogs as the title row's
  // button and the menus.
  late final CommandRegistry _own = CommandRegistry()
    ..registerAll([
      Command(
        id: AppCommands.pageSettings,
        label: 'Page settings…',
        icon: Icons.tune_rounded,
        invoke: () => showPageSettings(context, widget.notebook, widget.controller.page.id),
      ),
      Command(
        id: AppCommands.binderSettings,
        label: 'Binder settings…',
        icon: Icons.tune_rounded,
        enabled: () => _binderPath != null,
        invoke: () {
          final path = _binderPath;
          if (path != null) return showBinderSettings(context, widget.notebook, path);
        },
      ),
    ]);

  String? get _binderPath => widget.notebook.binderOfPage(widget.controller.page.id);

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    // The canvas shows its controller for a frame after the notebook let it go.
    if (widget.controller.isDisposed) return SizedBox(width: m.detailsWidth);
    return SizedBox(
      width: m.detailsWidth,
      child: DecoratedBox(
        key: const ValueKey('context-panel'),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(left: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: Semantics(
          container: true,
          label: 'Page and box options',
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.controller, widget.registry, widget.notebook]),
            // Every control is built (a short list, not a lazy one): Tab reaches
            // all of them and tests find them.
            builder: (context, _) => SingleChildScrollView(
              padding: EdgeInsets.all(m.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.onClose != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const ValueKey('context-panel-close'),
                        onPressed: widget.onClose,
                        child: const Text('Close'),
                      ),
                    ),
                  ..._content(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final c = widget.controller;
    final id = c.editingId ?? c.selectedId;
    final node = id == null ? null : c.page.node(id);
    return node == null ? _page(context) : _box(context, node);
  }

  Widget _heading(BuildContext context, String text) {
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    return Padding(
      padding: EdgeInsets.only(top: m.space4, bottom: m.space2),
      child: Text(
        text.toUpperCase(),
        style: type.label.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _button(
    BuildContext context,
    Command? command, {
    String? label,
    bool destructive = false,
    bool wide = true,
  }) {
    if (command == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final checked = command.checked ?? false;
    final m = NotedMetrics.of(context);
    final text = label ?? command.label;
    final button = OutlinedButton(
      key: ValueKey('panel-${command.id}'),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        foregroundColor: destructive ? scheme.error : scheme.onSurface,
        backgroundColor: checked ? scheme.primaryContainer : null,
      ),
      onPressed: command.enabled ? () => command.run() : null,
      child: Text(text, overflow: TextOverflow.ellipsis),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: m.space1),
      // A press on a Material button takes no focus; Tab still reaches it.
      child: wide ? SizedBox(width: double.infinity, child: button) : button,
    );
  }

  List<Widget> _page(BuildContext context) {
    final r = widget.registry;
    final c = widget.controller;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final nb = widget.notebook;
    final hasIssues = c.issues(disallowedTypes: nb.disallowedBoxTypesFor(c.page.id)).isNotEmpty;
    final zoom = r[CanvasCommands.zoomReset];
    return [
      _heading(context, 'Page'),
      Text(
        c.page.meta.title.isEmpty ? 'Untitled' : c.page.meta.title,
        key: const ValueKey('panel-page-title'),
        style: type.bodyStrong,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      _heading(context, 'Background'),
      for (final b in PageBackground.values)
        _button(context, r[CanvasCommands.pageBackgroundOf(b)], label: pageBackgroundLabel(b)),
      _heading(context, 'View'),
      Padding(
        padding: EdgeInsets.only(bottom: m.space2),
        child: Text(
          zoom?.text?.call() ?? '',
          key: const ValueKey('panel-zoom-readout'),
          style: type.numeric,
        ),
      ),
      _button(context, r[CanvasCommands.zoomOut]),
      _button(context, r[CanvasCommands.zoomReset]),
      _button(context, r[CanvasCommands.zoomIn]),
      _button(context, r[CanvasCommands.fitAll]),
      _heading(context, 'Find'),
      _button(context, r[CanvasCommands.find]),
      if (hasIssues) _button(context, r['canvas.showIssues']),
      _heading(context, 'Settings'),
      _button(context, _own[AppCommands.pageSettings]),
      if (_binderPath != null) _button(context, _own[AppCommands.binderSettings]),
    ];
  }

  List<Widget> _box(BuildContext context, CanvasNode node) {
    final r = widget.registry;
    final type = NotedTypography.of(context);
    final c = widget.controller;
    final typeId = node is BoxRecord ? node.typeId : null;
    final notAllowed = typeId != null && c.disallowedTypes.contains(typeId);
    final name = typeId == null ? 'Box' : (boxTypeSingularName(typeId) ?? 'Box');
    return [
      _heading(context, 'Box'),
      Text(name, key: const ValueKey('panel-box-type'), style: type.bodyStrong),
      if (notAllowed)
        Padding(
          padding: EdgeInsets.only(top: NotedMetrics.of(context).space2),
          child: Text(
            'Not allowed on this page',
            key: const ValueKey('panel-not-allowed'),
            style: type.small.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      _heading(context, 'Arrange'),
      _button(context, r[CanvasCommands.bringToFront]),
      _button(context, r[CanvasCommands.bringForward]),
      _button(context, r[CanvasCommands.sendBackward]),
      _button(context, r[CanvasCommands.sendToBack]),
      _heading(context, 'Delete'),
      _button(context, r[CanvasCommands.delete], destructive: true),
    ];
  }
}

/// The contextual panel as an overlay, for a window too narrow to show it
/// beside the canvas: from the right edge of the page area, over the canvas,
/// with a scrim. Escape, a click on the scrim, the panel's Close button or the
/// menu item close it. Focus goes back to the node that had it when the
/// overlay opened, or to the canvas if that node is gone.
class ContextPanelOverlay extends StatefulWidget {
  const ContextPanelOverlay({
    super.key,
    required this.notebook,
    required this.controller,
    required this.registry,
    required this.onClose,
    required this.focusCanvas,
  });

  final Notebook notebook;
  final CanvasController controller;
  final CommandRegistry registry;
  final VoidCallback onClose;
  final VoidCallback focusCanvas;

  @override
  State<ContextPanelOverlay> createState() => _ContextPanelOverlayState();
}

class _ContextPanelOverlayState extends State<ContextPanelOverlay> {
  final FocusNode _focus = FocusNode(debugLabel: 'context panel overlay');

  // Recorded before the overlay takes the focus.
  late final FocusNode? _origin = FocusManager.instance.primaryFocus;

  // The controller this overlay holds the editor focus of.
  late CanvasController _held;

  // How many overlays are on screen: a page change makes the new one before the
  // old one's restore runs, and that restore must not take the focus from it.
  static int _live = 0;

  @override
  void didUpdateWidget(ContextPanelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another page's controller: the hold moves to it.
    if (!identical(_held, widget.controller)) {
      _held.editorFocusHold.release();
      _held = widget.controller;
      _held.editorFocusHold.hold();
    }
  }

  @override
  void initState() {
    super.initState();
    _origin;
    // The overlay takes the focus: a note being edited keeps its editor (and its
    // selection) until the focus is given back.
    _held = widget.controller;
    _held.editorFocusHold.hold();
    _live++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    final origin = _origin;
    final canvas = widget.focusCanvas;
    final controller = _held;
    _focus.dispose();
    _live--;

    // After this frame: the focus tree is being taken apart now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      var restored = false;
      // Another overlay took over (a page change): the focus is its.
      if (_live > 0) {
        controller.editorFocusHold.release();
        return;
      }
      try {
        if (origin != null
 && origin.context?.mounted == true && origin.canRequestFocus) {
          origin.requestFocus();
          restored = true;
        }
      } on Object {
        restored = false;
      }
      if (!restored) canvas();
      // Released after that focus has been applied, so the editor regains it
      // while still held.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.editorFocusHold.release());
      WidgetsBinding.instance.scheduleFrame();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('context-panel-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: ColoredBox(color: NotedColors.of(context).overlayScrim),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: ContextPanel(
              key: const ValueKey('context-panel-overlay'),
              notebook: widget.notebook,
              controller: widget.controller,
              registry: widget.registry,
              onClose: widget.onClose,
            ),

          ),
        ],
      ),
    );
  }
}
