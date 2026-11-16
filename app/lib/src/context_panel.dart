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

/// The Details panel (spec §5): what applies to the page, or to the one box
/// selected (or being edited). Every control is a command of the canvas's live
/// [registry] (0067), read live; a pointer press on a control takes no focus
/// (as the toolbar's, 0068), so an open note keeps its caret.
///
/// States, by precedence: a read-only page (nothing that changes it), a
/// disallowed box (Delete only), one box, the page. The canvas has single
/// selection only, so there is no several-boxes state yet.
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

  /// Shown as the header's Close button when given.
  final VoidCallback? onClose;

  @override
  State<ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends State<ContextPanel> {
  // Page settings: the same dialog as the menus.
  late final CommandRegistry _own = CommandRegistry()
    ..registerAll([
      Command(
        id: AppCommands.pageSettings,
        label: 'Page settings…',
        icon: Icons.tune_rounded,
        invoke: () => showPageSettings(context, widget.notebook, widget.controller.page.id),
      ),
    ]);

  final GlobalKey _backgroundKey = GlobalKey();

  String? get _binderPath => widget.notebook.binderOfPage(widget.controller.page.id);

  String? get _binderName {
    final path = _binderPath;
    if (path == null) return null;
    for (final b in widget.notebook.binders) {
      if (b.path == path) return b.title;
    }
    return null;
  }

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
          label: 'Details',
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.controller, widget.registry, widget.notebook]),
            builder: (context, _) {
              final (title, content) = _state(context);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, title),
                  // Every control is built (a short list, not a lazy one): Tab
                  // reaches all of them and tests find them.
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(m.space4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: content,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String title) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final onClose = widget.onClose;
    return SizedBox(
      height: m.detailsHeaderHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outline)),
        ),
        child: Padding(
          padding: EdgeInsets.only(left: m.space4, right: m.space2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  key: const ValueKey('panel-header-title'),
                  style: NotedTypography.of(context).boxTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onClose != null)
                // A 36 px target at the trailing edge.
                IconButton(
                  key: const ValueKey('context-panel-close'),
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                  iconSize: m.icon,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(36),
                    fixedSize: const Size.square(36),
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The header title and the body of the state the panel is in.
  (String, List<Widget>) _state(BuildContext context) {
    final c = widget.controller;
    // A read-only page shows the page, whatever is selected.
    if (c.readOnly || widget.notebook.readOnlyReason != null) {
      return ('Page', _readOnlyPage(context));
    }
    final id = c.editingId ?? c.selectedId;
    final node = id == null ? null : c.page.node(id);
    if (node == null) return ('Page', _page(context));
    final typeId = node is BoxRecord ? node.typeId : null;
    if (typeId != null && c.disallowedTypes.contains(typeId)) {
      return ('Box', _disallowedBox(context));
    }
    final name = typeId == null ? null : boxTypeSingularName(typeId);
    return (name == null ? 'Box' : '$name box', _box(context));
  }

  // A section label (12/16, 600, uppercase).
  Widget _heading(BuildContext context, String text, {bool first = false}) {
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : m.space4, bottom: m.space2),
      child: Text(
        text.toUpperCase(),
        style: type.label.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  // An action: 32 px visible in a 36 px row (2 px vertical hit insets),
  // outlined with `outline-control`; a focused one paints the 2 px accent ring.
  Widget _button(
    BuildContext context,
    Command? command, {
    String? label,
    bool enabled = true,
    bool wide = false,
  }) {
    if (command == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    final m = NotedMetrics.of(context);
    final on = enabled && command.enabled;
    final button = SizedBox(
      height: 32,
      child: OutlinedButton(
        key: ValueKey('panel-${command.id}'),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          minimumSize: const Size(0, 32),
          padding: EdgeInsets.symmetric(horizontal: wide ? m.space2 : m.space3),
        ).copyWith(side: _side(scheme, colors, on)),
        onPressed: on ? () => command.run() : null,
        child: Text(label ?? command.label, overflow: TextOverflow.ellipsis),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // A press on a Material button takes no focus; Tab still reaches it.
      child: wide ? SizedBox(width: double.infinity, child: button) : Align(alignment: Alignment.centerLeft, child: button),
    );
  }

  WidgetStateProperty<BorderSide> _side(ColorScheme scheme, NotedColors colors, bool on) =>
      WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.focused)) return BorderSide(color: scheme.primary, width: 2);
        return BorderSide(color: on ? colors.outlineControl : scheme.outline);
      });

  Widget _title(BuildContext context) {
    final c = widget.controller;
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final binder = _binderName;
    return Padding(
      padding: EdgeInsets.only(bottom: m.space2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.page.meta.title.isEmpty ? 'Untitled' : c.page.meta.title,
            key: const ValueKey('panel-page-title'),
            style: NotedTypography.of(context).boxTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (binder != null)
            Text(
              binder,
              key: const ValueKey('panel-binder-name'),
              style: NotedTypography.of(context).small.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  List<Widget> _page(BuildContext context) {
    final r = widget.registry;
    return [
      _title(context),
      _heading(context, 'Page background'),
      _backgroundDropdown(context),
      SizedBox(height: NotedMetrics.of(context).space2),
      _button(context, _own[AppCommands.pageSettings]),
      _button(context, r[CanvasCommands.fitAll]),
    ];
  }

  // One button showing the checked choice; it opens a Menu-component list of
  // the four, each running its `canvas.pageBackground.<b>` command.
  Widget _backgroundDropdown(BuildContext context) {
    final r = widget.registry;
    final c = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    final m = NotedMetrics.of(context);
    final current = c.page.meta.background;
    final enabled = PageBackground.values.every((b) => r[CanvasCommands.pageBackgroundOf(b)]?.enabled ?? false);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
        key: const ValueKey('panel-background-dropdown'),
        height: 32,
        child: OutlinedButton(
          key: _backgroundKey,
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            minimumSize: const Size(0, 32),
            padding: EdgeInsets.symmetric(horizontal: m.space3),
            foregroundColor: scheme.primary,
            backgroundColor: scheme.primaryContainer,
          ).copyWith(side: _side(scheme, colors, enabled)),
          onPressed: enabled ? () => _openBackground(context) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pageBackgroundLabel(current),
                key: const ValueKey('panel-background-current'),
              ),
              SizedBox(width: m.space2),
              Icon(Icons.expand_more_rounded, size: m.icon),
            ],
        ),
      ),
        ),
      ),
    );
  }

  Future<void> _openBackground(BuildContext context) async {
    final box = _backgroundKey.currentContext;
    final target = box?.findRenderObject() as RenderBox?;
    if (box == null || target == null) return;
    final r = widget.registry;
    final overlay = Overlay.of(box).context.findRenderObject()! as RenderBox;
    final rect = target.localToGlobal(Offset.zero, ancestor: overlay) & target.size;
    final entries = <PopupMenuEntry<String>>[
      for (final b in PageBackground.values)
        if (r[CanvasCommands.pageBackgroundOf(b)] case final cmd?)
          NotedMenuItem<String>(
            key: ValueKey('menu-${cmd.id}'),
            value: cmd.id,
            label: pageBackgroundLabel(b),
            leading: MenuCheckMark(checked: cmd.checked ?? false),
            enabled: cmd.enabled,
          ),
    ];
    // What the choice must still find when it runs: a page opened or a registry
    // rebuilt while the menu was up means it would change another page.
    final guard = CanvasTargetGuard(
      controller: widget.controller,
      pageId: widget.controller.page.id,
      registry: r,
    );
    final id = await showMenu<String>(
      context: box,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, rect.bottom + 2, rect.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints(minWidth: rect.width < 160 ? 160 : rect.width),
      items: entries,
    );
    if (id == null || !mounted) return;
    if (!guard.holds(widget.controller, widget.controller.page.id, registry: widget.registry)) return;
    r[id]?.run();
  }

  List<Widget> _readOnlyPage(BuildContext context) {
    final r = widget.registry;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    return [
      _title(context),
      Padding(
        padding: EdgeInsets.symmetric(vertical: m.space2),
        child: DecoratedBox(
          key: const ValueKey('panel-read-only-card'),
          decoration: BoxDecoration(color: colors.conflictSoft, borderRadius: m.borderMd),
          child: Padding(
            padding: EdgeInsets.all(m.space3),
            child: Semantics(
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Read-only', style: type.bodyStrong.copyWith(color: scheme.onSurface)),
                  SizedBox(height: m.space1),
                  Text(
                    // The banner's reason, as the notebook words it.
                    widget.notebook.readOnlyReason ?? ReadOnlyBanner.paused,
                    key: const ValueKey('panel-read-only-reason'),
                    style: type.small.copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      SizedBox(height: m.space2),
      _button(context, r[CanvasCommands.find], label: 'Find on page', wide: false),
      _button(context, r[CanvasCommands.fitAll], wide: false),
    ];
  }

  List<Widget> _disallowedBox(BuildContext context) {
    // No type data, and nothing but the verified delete path (0166).
    return [_delete(context)];
  }

  Widget _delete(BuildContext context) {
    final r = widget.registry;
    final scheme = Theme.of(context).colorScheme;
    final command = r[CanvasCommands.delete];
    if (command == null) return const SizedBox.shrink();
    final editing = widget.controller.editingId != null;
    final on = command.enabled && !editing;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: ValueKey('panel-${command.id}'),
          style: TextButton.styleFrom(
            foregroundColor: scheme.error,
            minimumSize: const Size(0, 32),
          ),
          onPressed: on ? () => command.run() : null,
          child: const Text('Delete box'),
        ),
      ),
    );
  }

  List<Widget> _box(BuildContext context) {
    final r = widget.registry;
    final m = NotedMetrics.of(context);
    // While the editor owns focus, Arrange and Delete show disabled.
    final free = widget.controller.editingId == null;
    Widget cell(String id) => Expanded(child: _button(context, r[id], enabled: free, wide: true));
    Widget row(String a, String b) => Row(
      children: [
        cell(a),
        SizedBox(width: m.space2),
        cell(b),
      ],
    );
    return [
      _heading(context, 'Arrange', first: true),
      row(CanvasCommands.bringToFront, CanvasCommands.bringForward),
      row(CanvasCommands.sendToBack, CanvasCommands.sendBackward),
      Padding(
        padding: EdgeInsets.symmetric(vertical: m.space2),
        child: const Divider(key: ValueKey('panel-separator')),
      ),
      _delete(context),
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
