// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'box_host.dart';
import 'box_pick_list.dart';
import 'box_scroll.dart';
import 'canvas_commands.dart';
import 'canvas_context_menu.dart';
import 'canvas_target_guard.dart';
import 'canvas_controller.dart';
import 'canvas_tool.dart';
import 'canvas_view.dart';
import 'attachment_store.dart';
import 'command_toolbar.dart';
import 'find_bar.dart';
import 'commands.dart';
import 'geometry.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';
import 'page_background.dart';
import 'issue_tap_target.dart';
import 'page_ai_merge.dart';
import 'page_find.dart';
import 'page_issues_dialog.dart';
import 'toolbar_layout.dart';
import 'toolbar_placeholders.dart';

/// Auto-pan during a tool session: the edge zone, in screen pixels.
const double autoPanEdge = 40;

/// Auto-pan speed (screen pixels per second) at the very edge, and the cap
/// once the pointer is far past it.
const double autoPanSpeedAtEdge = 600;
const double autoPanMaxSpeed = 3000;

/// A page's freeform canvas (0002, 0003).
///
/// Built on [InteractiveViewer] for the transform, with its own pan and zoom
/// gestures switched off. All view changes go through [CanvasGeometry], so
/// pan bounds and zoom limits are enforced in one place. Input, with the
/// select/type tool (0033):
/// - click empty canvas: new note box (0015)
/// - wheel: scroll; Shift+wheel: scroll sideways; Ctrl+wheel: zoom
/// - middle-drag or two-finger touchpad: pan; pinch: zoom
/// - two fingers on a touch screen: pan and pinch-zoom around the fingers
///   (one finger does what the tool does, 0033)
/// - drag a box's grip to move it, its edges to resize it
///
/// With a module's canvas tool active (0033: the tool decides what input
/// does, not the device), every pointer except the middle button goes to
/// the tool and boxes receive none; wheel, Ctrl+wheel, middle-drag and the
/// touchpad still pan and zoom.
class PageCanvas extends StatefulWidget {
  const PageCanvas({
    super.key,
    required this.controller,
    this.tools,
    this.readOnly = false,
    this.toolbar = contextualToolbarLayout,
    this.findRequests,
    this.extraCommands,
    this.attachments,
    this.disallowedTypes = const {},
    this.aiMerge,
    this.issueSilence,
    this.boxTypeName,
    this.onCommandsChanged,
    this.sidePanel,
    this.overlayPanel,
    this.contextMenuStyle = ContextMenuStyle.list,
  });

  final CanvasController controller;

  /// Host only. How the canvas's context menus are drawn; the radial ring
  /// opens only for a mouse press, the list for everything else.
  final ContextMenuStyle contextMenuStyle;

  /// Host only. Called after the frame in which this canvas made a new
  /// command registry (the page, the tool selection or the allowed box types
  /// changed), and with null in the frame after the canvas is disposed. The
  /// replaced registry is disposed one frame after the call, so a holder
  /// never reads a disposed one.
  final ValueChanged<CommandRegistry?>? onCommandsChanged;

  /// Host only. A panel built with this canvas's live registry, shown right of
  /// the canvas and below the toolbar; null shows none.
  final Widget Function(BuildContext context, CommandRegistry registry)? sidePanel;

  /// Host only. A panel drawn over the canvas area (below the toolbar, so the
  /// toolbar stays uncovered), built with the canvas's live registry; null shows
  /// none. It fills the area: it brings its own scrim and position.
  final Widget Function(BuildContext context, CommandRegistry registry)? overlayPanel;

  /// The name of a box type for the list of boxes under a point ("Note"),
  /// or null for a type the app has no name for (it then reads "Unsupported
  /// box", or "Box" for a registered type).
  final String? Function(String typeId)? boxTypeName;

  /// The page AI's help with conflicts; null never shows the option.
  final PageAiMerge? aiMerge;

  /// Which pages' issue sequences the user silenced during this app run. The
  /// app passes one shared object; without it a page opened again shows its
  /// sequence again.
  final IssueSilence? issueSilence;

  /// Box types this page doesn't allow (module availability per page and
  /// binder). Such a type behaves as a switched-off module here (0035): its
  /// boxes show their saved snapshot read-only, its tools and commands are
  /// disabled, and files for it are refused. Nothing is changed in the page.
  /// A type that isn't a registered, switchable module is ignored: the
  /// always-on type can't be disallowed.
  final Set<String> disallowedTypes;

  /// The page's images and files (Box API 0.7), handed to the modules;
  /// null where the page has none (nothing can be pasted or dropped then).
  final AttachmentStore? attachments;

  /// Asks this canvas to open Find on page (for example from the results of
  /// a search of all pages). A request for another page is left alone; one
  /// for this page is taken (the notifier is set back to null).
  final ValueNotifier<FindRequest?>? findRequests;

  /// Commands the app adds to this canvas's registry, so they have shortcuts
  /// and can be placed on the toolbar (for example "Search all pages"). Called
  /// each time the registry is made; the registry owns and disposes them.
  final List<Command> Function()? extraCommands;

  /// The toolbar along the top: which commands it shows, where and when
  /// (one of the built-in [ToolbarStyle] layouts; the app passes the one
  /// chosen in the settings). It is built only from this canvas's
  /// [PageCanvasState.commands].
  final ToolbarArrangement toolbar;

  /// Show the page without any way to change it: boxes use their module's
  /// read-only view, with no grip, handles or editing; there is no toolbar
  /// and no tool, no box creation on click and no delete or undo keys. Panning
  /// and zooming still work. A controller that is itself read-only
  /// ([CanvasController.readOnly]) gets the same canvas.
  final bool readOnly;

  /// The clipped overlay that shows a tool session's live feedback.
  static const Key overlayKey = ValueKey('PageCanvas.toolOverlay');

  /// The clipped overlay above every box that outlines the box the pick list
  /// points at (dimming the rest) and a selected box that another covers.
  static const Key pickOverlayKey = ValueKey('PageCanvas.pickOverlay');

  /// The active tool, shared across pages. If null the canvas keeps its own.
  final CanvasToolSelection? tools;

  @override
  State<PageCanvas> createState() => PageCanvasState();
}

class PageCanvasState extends State<PageCanvas>
    with SingleTickerProviderStateMixin
    implements ToolContext, CanvasCommandTarget {
  final TransformationController _transform = TransformationController();
  CommandRegistry _commands = CommandRegistry();

  /// The zoom the toolbar was last built with.
  double? _toolbarScale;
  final FocusNode _focus = FocusNode(debugLabel: 'PageCanvas');
  final CanvasToolSelection _ownTools = CanvasToolSelection();
  final _OverlayRepaint _overlay = _OverlayRepaint();

  /// The box the open pick list points at, outlined on the top overlay.
  final ValueNotifier<String?> _pickHighlight = ValueNotifier(null);
  bool _pickOpen = false;

  /// Set when the canvas goes away, turns read-only or gets another controller:
  /// closes an open pick list (it holds this canvas's controller).
  final ValueNotifier<bool> _pickClose = ValueNotifier(false);
  bool _disposedWhileOpen = false;

  /// Counts the stylus pointers that went down and the tool sessions that
  /// started: a touch hold during which it changed was not a plain hold.
  int _inkSerial = 0;

  /// The id of the box the open pick list points at, or null.
  String? get pickHighlightId => _pickHighlight.value;

  // The context menus (section "Context menus" of the canvas design) -------

  /// Set when the canvas goes away, gets another controller or registry, or
  /// the target box goes or changes under an open context menu: the menu
  /// closes and runs nothing. Not the pick list's signal (a read-only flip
  /// doesn't set this one).
  final ValueNotifier<bool> _contextClose = ValueNotifier(false);
  final ValueNotifier<bool> _contextOpen = ValueNotifier(false);
  _ContextSession? _contextSession;
  bool _contextDisposed = false;

  /// Host only. True while a context menu (list or ring) is open: the app
  /// leaves its own keys alone then.
  ValueListenable<bool> get contextMenuOpen => _contextOpen;

  /// Test hook: awaited when a chosen entry's deferred frame arrives, before
  /// its target is checked, so a test can change the world in that window.
  @visibleForTesting
  Future<void> Function()? debugBeforeContextRun;

  /// Pointer events per tool session, for the debug readout.
  final ValueNotifier<_InputStats?> _stats = ValueNotifier(null);

  CanvasView? _view;
  CanvasGeometry? _geometry;
  Rect? _content;
  int? _middlePointer;
  // A touchpad pinch: the zoom the view had when it started, and the
  // two-finger pan applied so far (to move only by what is new).
  double _pinchStartScale = 1;
  Offset _pinchPan = Offset.zero;

  // Touch screens: the fingers down now (canvas-local, in the order they
  // landed), and whether the current touch gesture ever had two. Set until
  // the next pointer goes down; no tool session starts while it is set.
  final Map<int, Offset> _touches = {};
  bool _multiTouch = false;
  // Fingers that landed during a pen stroke or were down when it began: a
  // resting hand. Its lift selects and makes nothing. _upWasPalm is whether
  // the pointer that just lifted was one (the page tap that follows reads it).
  final Set<int> _palmPointers = {};
  bool _upWasPalm = false;
  Offset? _touchFocal;
  double? _touchSpan;

  /// True from the second finger until all fingers lift; boxes stop moving
  /// or resizing under a finger while it is.
  final ValueNotifier<bool> _multiTouchActive = ValueNotifier(false);

  /// Where the mouse last was over the canvas, null when it is elsewhere.
  Offset? _hover;
  ToolSession? _session;
  int? _sessionPointer;
  PointerEvent? _lastToolEvent;
  Duration _sampleTime = Duration.zero;

  /// Everything the view has shown during the current tool session; pan
  /// bounds include it, so auto-pan can reach new space.
  Rect? _sessionArea;
  Ticker? _autoPan;
  Duration _lastTick = Duration.zero;

  CanvasController get _c => widget.controller;
  bool get _readOnly => widget.readOnly || _c.readOnly;
  CanvasToolSelection get _tools => widget.tools ?? _ownTools;

  @override
  CanvasToolSelection get tools => _tools;

  @override
  bool get isReadOnly => _readOnly;

  @override
  void focusCanvas() => _focus.requestFocus();

  @override
  AttachmentStore? get attachments => widget.attachments;

  /// Gap between boxes made for several files at once, in page units.
  static const double _fileGap = 16;

  /// The page point in the middle of the view.
  @override
  Offset? get viewCentre {
    final v = _view;
    final g = _geometry;
    if (v == null || g == null) return null;
    return v.toWorld(g.viewport.center(Offset.zero));
  }

  @override
  Future<void> insertFiles(List<IncomingFile> files, {Offset? at}) async {
    final target = _pasteTarget(at);
    if (target == null || files.isEmpty) return;
    await _insertFilesInto(target, files);
  }

  /// What a paste or drop keeps from the moment it starts to the last box it
  /// makes: the controller object, its page, the store, and the point. A page
  /// opened meanwhile must not get the boxes (they would show files of the
  /// other page's folder).
  _PasteTarget? _pasteTarget(Offset? at) {
    final store = widget.attachments;
    if (store == null || _readOnly) return null;
    return _PasteTarget(_c, _c.page.id, store, at ?? viewCentre ?? Offset.zero, _off);
  }

  bool _pasteHolds(_PasteTarget t) =>
      mounted &&
      identical(_c, t.controller) &&
      _c.page.id == t.pageId &&
      identical(widget.attachments, t.store) &&
      !_readOnly;

  /// Stores each file in [target]'s own store and adds its box to [target]'s
  /// page. Before each file is stored and again before each box is added, the
  /// target is checked: if it no longer holds, nothing more is stored or
  /// added (what is stored stays unreferenced in the original page's folder)
  /// and the user is told once.
  Future<void> _insertFilesInto(_PasteTarget target, List<IncomingFile> files) async {
    final store = target.store;
    var point = target.point;
    String? last;
    var stopped = false;
    for (final f in files) {
      if (!_pasteHolds(target)) {
        stopped = true;
        break;
      }
      // The module is chosen under the types allowed when the paste started; if
      // it was disallowed since, the paste stops (no other module takes the file).
      final module = target.controller.modules.moduleForFile(f, exclude: target.off);
      if (module == null) continue;
      if (_off.contains(module.codec.typeId)) {
        stopped = true;
        break;
      }
      (Object?, Size)? made;
      try {
        made = await module.hostCreateFromFile(f, store);
      } on FileSystemException {
        // No copy could be stored: no box, so none points at a missing file.
        // The other files still go in. A page closed meanwhile refuses the
        // file: that is the stop, not a folder problem.
        if (!_pasteHolds(target)) {
          stopped = true;
          break;
        }
        store.notify('"${f.name}" could not be added: the page\'s folder could not be written.');
        continue;
      }
      if (made == null) continue;
      if (!_pasteHolds(target) || _off.contains(module.codec.typeId)) {
        stopped = true;
        break;
      }
      final (data, size) = made;
      final codec = module.codec;
      final box = commitBox(
        createBox(
          codec,
          Bounds(point.dx, point.dy, size.width, size.height),
          device: _c.deviceName,
        ),
        codec,
        data,
        device: _c.deviceName,
      ).withFixedHeight(true);
      _c.insertBox(box);
      last = box.id;
      point = point.translate(0, size.height + _fileGap);
    }
    if (stopped) {
      store.notify(
        'The paste stopped; nothing was added to another page.',
      );
    }
    if (last != null && _pasteHolds(target)) _c.select(last);
  }

  /// Boxes for [files] to the right of box [boxId], top-aligned with it.
  void _insertFilesBeside(String boxId, List<IncomingFile> files) {
    final b = _c.page.node(boxId)?.bounds;
    unawaited(
      insertFiles(
        files,
        at: b == null ? null : Offset(b.x + b.width + _fileGap * 1.5, b.y),
      ),
    );
  }

  @override
  Future<bool> pasteFiles() {
    final h = _hover;
    return pasteFilesAt(h == null ? null : _view?.toWorld(h));
  }

  /// Host only. Pastes the clipboard's files at the page point [at] (the
  /// middle of the view if null). The target (controller, page, store, point)
  /// is taken before the clipboard is read, and checked again before every
  /// box: a page opened meanwhile gets nothing (the paste target of the
  /// context menu's design, R-1). False if there was nothing to paste.
  Future<bool> pasteFilesAt(Offset? at) async {
    final target = _pasteTarget(at);
    if (target == null) return false;
    final files = await FileClipboard.read();
    if (files.isEmpty) return false;
    if (!_pasteHolds(target)) {
      target.store.notify('The paste stopped; nothing was added to another page.');
      return false;
    }
    await _insertFilesInto(target, files);
    return true;
  }

  /// Find on page for the open page (the find bar's model), for tests and
  /// the app shell.
  PageFind get find => _find;

  late PageFind _find;
  final FocusNode _findFocus = FocusNode(debugLabel: 'FindBar');

  @override
  bool get isFindOpen => _find.isOpen;

  @override
  void openFind() => _find.open();

  @override
  void closeFind() {
    final hadFocus = _findFocus.hasFocus;
    _find.close();
    if (hadFocus) _focus.requestFocus();
  }

  @override
  void stepFind(int delta) => _find.step(delta);

  PageFind _makeFind() =>
      PageFind(page: () => _c.page, onReveal: _revealBox);

  void _takeFindRequest() {
    final r = widget.findRequests?.value;
    if (r == null || r.pageId != _c.page.id) return;
    widget.findRequests!.value = null;
    // After the first layout, so the view can be moved.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _find.open(text: r.text, boxId: r.boxId, occurrence: r.occurrence);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Brings the box [id] into view: scrolls to it, and zooms out only if it
  /// doesn't fit at the current zoom (never in, so never past where the
  /// user already is). Does nothing if it is already fully in view.
  void _revealBox(String id) {
    final g = _geometry;
    final v = _view;
    final rect = _c.page.node(id)?.bounds?.rect;
    if (rect == null) return;
    if (g == null || v == null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealBox(id);
      });
      return;
    }
    final target = rect.inflate(canvasChromePadding);
    final fit = math.min(
      g.viewport.width / target.width,
      g.viewport.height / target.height,
    );
    final scale = math.min(v.scale, fit).clamp(g.minScale, g.maxScale).toDouble();
    if (scale == v.scale && v.visible(g.viewport).contains(target.topLeft) &&
        v.visible(g.viewport).contains(target.bottomRight)) {
      return;
    }
    final center = g.viewport.center(Offset.zero) - target.center * scale;
    // A box taller than the view (at the zoom floor) shows its top.
    final dy = target.height * scale > g.viewport.height
        ? -target.top * scale
        : center.dy;
    final dx = target.width * scale > g.viewport.width
        ? -target.left * scale
        : center.dx;
    setState(() => _view = g.clamp(CanvasView(scale, Offset(dx, dy))));
  }

  /// This canvas's commands: its own, its modules' tools and the modules'
  /// commands (Box API 0.4). Key presses and the toolbar go through it.
  /// Made again when the page or the tool selection changes.
  CommandRegistry get commands => _commands;

  // The ids of the "coming later" placeholders and of the commands made
  // unavailable for a disallowed type, in the registry made last.
  Set<String> _placeholderIds = const {};
  final Set<String> _notAllowedIds = {};

  void _buildCommands() {
    _notAllowedIds.clear();
    // A registry made again: an open context menu holds the old one.
    if (_contextSession != null) _contextClose.value = true;
    final old = _commands;
    _commands = CommandRegistry()
      ..registerAll(_forAvailability(buildCanvasCommands(this)))
      ..registerAll([
        Command(
          id: 'canvas.showIssues',
          label: 'Show page issues',
          icon: Icons.warning_amber_rounded,
          shortcut: const SingleActivator(LogicalKeyboardKey.f8),
          whileEditing: true,
          enabled: () => !_readOnly && _issues.isNotEmpty,
          invoke: () => unawaited(openIssues()),
        ),
      ])
      ..registerAll(_moduleCommands())
      ..registerAll(widget.extraCommands?.call() ?? const []);
    // Last, so a real command with a placeholder's id wins.
    final placeholders = placeholderCommands(_commands);
    _placeholderIds = {for (final p in placeholders) p.id};
    _commands.registerAll(placeholders);
    if (old.commands.isEmpty) {
      old.dispose();
      _announceCommands();
      return;
    }
    // A holder may still read the old registry until it has the new one: tell
    // it after this frame, and dispose the old one a frame later.
    _announceCommands();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
      SchedulerBinding.instance.scheduleFrame();
    });
  }

  // Tells the host about the registry that is current after this frame.
  void _announceCommands() {
    final callback = widget.onCommandsChanged;
    if (callback == null) return;
    final made = _commands;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_commands, made)) callback(made);
    });
  }

  // The switchable modules whose type this page disallows.
  Set<String> get _off => {
    for (final id in widget.disallowedTypes)
      if (_c.modules.isSwitchable(id)) id,
  };

  // The commands of the modules that are on, those of a disallowed module
  // disabled (and saying why in their tooltip).
  List<Command> _moduleCommands() {
    final off = _off;
    return [
      for (final m in _c.modules.enabled)
        ...off.contains(m.codec.typeId) ? m.commands(this).map(_notAllowed) : m.commands(this),
    ];
  }

  // The canvas's own commands, with the tool command of a disallowed module
  // disabled.
  List<Command> _forAvailability(List<Command> commands) {
    final off = _off;
    if (off.isEmpty) return commands;
    final toolIds = {
      for (final m in _c.modules.enabled)
        if (off.contains(m.codec.typeId))
          for (final t in m.tools) t.id,
    };
    return [for (final c in commands) toolIds.contains(c.id) ? _notAllowed(c) : c];
  }

  Command _notAllowed(Command c) {
    _notAllowedIds.add(c.id);
    final disabled = Command(
      id: c.id,
      label: '${c.label} (not allowed on this page)',
      icon: c.icon,
      iconBuilder: c.iconBuilder,
      showLabel: c.showLabel,
      // The button keeps its text (only the tooltip says why it's off).
      text: c.text,
      shortcut: c.shortcut,
      enabled: () => false,
      invoke: () {},
      menu: c.menu,
    );
    c.dispose();
    return disabled;
  }

  // A tool that is active but not allowed here (the selection is shared by
  // pages) goes back to Select and type.
  void _dropDisallowedTool() {
    final active = _tools.active;
    final off = _off;
    if (active == null || off.isEmpty) return;
    for (final m in _c.modules.enabled) {
      if (off.contains(m.codec.typeId) && m.tools.any((t) => identical(t, active))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_tools.active, active)) _tools.select(null);
        });
        return;
      }
    }
  }

  /// The current view, for tests and the app shell.
  CanvasView? get view => _view;

  /// The running tool session, for tests.
  ToolSession? get toolSession => _session;

  @override
  CanvasController get controller => _c;

  @override
  double get scale => _view?.scale ?? 1;

  @override
  Brightness get brightness => _brightness;

  @override
  NotedColors get colors => _colors;

  NotedColors _colors = NotedColors.light;

  Brightness _brightness = Brightness.light;

  @override
  void repaintOverlay() => _overlay.repaint();

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _checkContextRect());
    _c.addListener(_changed);
    _tools.addListener(_toolChanged);
    _find = _makeFind();
    _buildCommands();
    _dropDisallowedTool();
    widget.findRequests?.addListener(_takeFindRequest);
    _takeFindRequest();
    _showIssuesOnOpen();
  }

  final IssueSilence _ownSilence = IssueSilence();
  IssueSilence get _silence => widget.issueSilence ?? _ownSilence;
  bool _issuesOpen = false;

  /// Set when the canvas goes away or turns read-only: closes an open dialog.
  final ValueNotifier<bool> _issuesClose = ValueNotifier(false);

  List<PageIssue> get _issues => _c.issues(disallowedTypes: _off);

  /// A page with issues shows them one after another when it opens, unless
  /// the user silenced them during this run.
  void _showIssuesOnOpen() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _readOnly || _silence.isSilenced(_c.page.id)) return;
      if (_issues.isNotEmpty) unawaited(openIssues());
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Opens the issue sequence at the first unresolved issue, or, with
  /// [onlyBox], just that box's issues.
  Future<void> openIssues({String? onlyBox}) async {
    if (_issuesOpen || !mounted || _readOnly) return;
    setState(() => _issuesOpen = true);
    _issuesClose.value = false;
    final end = await showPageIssues(
      context,
      _c,
      closeSignal: _issuesClose,
      disallowedTypes: _off,
      aiMerge: widget.aiMerge,
      onlyBox: onlyBox,
      onPlace: (id) {
        _c.select(id);
        _revealBox(id);
        _focus.requestFocus();
      },
    );
    if (end == IssueDialogEnd.silenced && onlyBox == null) {
      _silence.silence(_c.page.id);
    }
    if (mounted) setState(() => _issuesOpen = false);
  }

  @override
  void didUpdateWidget(PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || (widget.readOnly && !oldWidget.readOnly)) {
      _issuesClose.value = true;
      _pickClose.value = true;
    }
    if (oldWidget.controller != widget.controller) {
      _contextClose.value = true;
    }
    if (oldWidget.controller != widget.controller) {
      _showIssuesOnOpen();
      _cancelSession();
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _view = null;
      _find.dispose();
      _find = _makeFind();
    }
    // A page that turns read-only (or editable) under an open menu: the edit
    // commands read it, so they are re-read now.
    if (oldWidget.readOnly != widget.readOnly) {
      _commands.refresh();
      _checkContextTarget();
    }
    if (oldWidget.onCommandsChanged != widget.onCommandsChanged) _announceCommands();
    if (oldWidget.findRequests != widget.findRequests) {
      oldWidget.findRequests?.removeListener(_takeFindRequest);
      widget.findRequests?.addListener(_takeFindRequest);
      _takeFindRequest();
    }
    if (oldWidget.attachments != widget.attachments) {
      _hostsRevision++;
      _hostPerBox.clear();
    }
    if (oldWidget.tools != widget.tools) {
      (oldWidget.tools ?? _ownTools).removeListener(_toolChanged);
      _tools.addListener(_toolChanged);
    }
    final disallowedChanged = !setEquals(oldWidget.disallowedTypes, widget.disallowedTypes);
    if (disallowedChanged) {
      _hostsRevision++;
      _hostPerBox.clear();
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.tools != widget.tools ||
        disallowedChanged) {
      _buildCommands();
      _dropDisallowedTool();
    }
  }

  @override
  void dispose() {
    _issuesClose.value = true;
    // An open context menu closes (first, so it is gone before the registry
    // it holds is disposed) and gives its focus hold back at once.
    _contextClose.value = true;
    _contextDisposed = true;
    _contextSession?.releaseHold();
    widget.findRequests?.removeListener(_takeFindRequest);
    _find.dispose();
    _findFocus.dispose();
    // The host may read the registry until the next frame; it is told then
    // that there is none, and the registry is disposed with that.
    final registry = _commands;
    final callback = widget.onCommandsChanged;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      callback?.call(null);
      registry.dispose();
    });
    // Listeners first: ending a session notifies the controller, and a
    // canvas being disposed must not rebuild.
    _c.removeListener(_changed);
    _tools.removeListener(_toolChanged);
    _cancelSession();
    _autoPan?.dispose();
    _multiTouchActive.dispose();
    _transform.dispose();
    _focus.dispose();
    _ownTools.dispose();
    _overlay.dispose();
    // The open list (if any) closes on its own and may still read the
    // notifier until then; it is disposed when the list is gone.
    _pickClose.value = true;
    if (_pickOpen) {
      _disposedWhileOpen = true;
    } else {
      _pickHighlight.dispose();
    }
    _pickClose.dispose();
    _contextClose.dispose();
    _contextOpen.dispose();
    _stats.dispose();
    super.dispose();
  }

  void _toolChanged() {
    _cancelSession();
    // Picking a tool ends text editing.
    if (_tools.active != null) _focus.requestFocus();
    setState(() {});
  }

  ToolPointer _toolPointer(PointerEvent e) => ToolPointer(
    position: _view!.toWorld(e.localPosition),
    kind: e.kind,
    time: e.timeStamp,
    pressure:
        e.kind == PointerDeviceKind.mouse || e.pressureMax <= e.pressureMin
        ? null
        : ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
              .clamp(0.0, 1.0),
  );

  /// The tool a pen's pointer uses (0033): with Select and type picked, the
  /// stylus inks and its eraser end erases, whatever box is under it. A
  /// picked tool is kept, except that the eraser end erases while the pen is
  /// picked. Null when the module that supplies the tool is off or missing.
  CanvasTool? _stylusTool(PointerDeviceKind kind) {
    final active = _tools.active;
    final StylusRole role;
    if (kind == PointerDeviceKind.stylus) {
      if (active != null) return active;
      role = StylusRole.pen;
    } else if (kind == PointerDeviceKind.invertedStylus) {
      if (active != null && active.stylusRole != StylusRole.pen) return active;
      role = StylusRole.eraser;
    } else {
      return active;
    }
    final off = _off;
    for (final m in _c.modules.enabled) {
      if (off.contains(m.codec.typeId)) continue;
      for (final t in m.tools) {
        if (t.stylusRole == role) return t;
      }
    }
    return active;
  }

  /// True if a click by [e] is no click on a box: a pen going to a tool, or
  /// a resting hand.
  bool _boxIgnores(PointerEvent e) =>
      _palmPointers.contains(e.pointer) ||
      _inkedBy(e.kind) ||
      (e is PointerDownEvent && (_mousePicks(e) || _ctrlPrimary(e)));

  /// True if the pointer [kind] goes to a tool (and so to no box) here.
  bool _inkedBy(PointerDeviceKind kind) =>
      !_readOnly && _stylusTool(kind) != null;

  void _toolDown(PointerDownEvent e) {
    final tool = _stylusTool(e.kind);
    if (_readOnly || tool == null || _session != null || _view == null) return;
    final usable = e.kind == PointerDeviceKind.mouse
        ? e.buttons & kPrimaryButton != 0
        : e.buttons & kMiddleMouseButton == 0;
    if (!usable) return;
    final session = tool.start(this, _toolPointer(e));
    if (session == null) return;
    _c.beginToolSession();
    _inkSerial++;
    _session = session;
    _sessionPointer = e.pointer;
    _lastToolEvent = e;
    _sampleTime = e.timeStamp;
    _sessionArea = _view!.visible(_geometry!.viewport);
    _stats.value = _InputStats.start(e.timeStamp);
    _updateAutoPan();
    _overlay.repaint();
  }

  void _toolMove(PointerMoveEvent e) {
    if (e.pointer != _sessionPointer) return;
    _lastToolEvent = e;
    if (e.timeStamp > _sampleTime) _sampleTime = e.timeStamp;
    _session!.update(_toolPointer(e));
    _stats.value = _stats.value?.add(e.timeStamp);
    _updateAutoPan();
  }

  void _toolUp(PointerUpEvent e) {
    if (e.pointer != _sessionPointer) return;
    final session = _session!;
    _endSession();
    // The session commits and the overlay clears in the same frame, so the
    // finished stroke never disappears for a frame.
    session.end();
    _c.endToolSession();
    _overlay.repaint();
  }

  void _cancelSession() {
    final session = _session;
    if (session == null) return;
    _endSession();
    session.cancel();
    _c.endToolSession();
    _overlay.repaint();
  }

  void _endSession() {
    _session = null;
    _sessionPointer = null;
    _lastToolEvent = null;
    _sessionArea = null;
    _autoPan?.stop();
  }

  /// Auto-scroll while a tool is in use, like a text selection in a document:
  /// with the pointer within [autoPanEdge] of the canvas edge, or past it,
  /// the canvas pans toward that edge, faster the further out the pointer
  /// is. Each tick also gives the session a sample at the pointer's screen
  /// position, so a stroke keeps following the pointer while it scrolls.
  void _updateAutoPan() {
    final e = _lastToolEvent;
    final g = _geometry;
    final moving =
        e != null &&
        g != null &&
        _autoPanVelocity(e.localPosition, g.viewport) != Offset.zero;
    final ticker = _autoPan ??= createTicker(_autoPanTick);
    if (moving && !ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    } else if (!moving && ticker.isActive) {
      ticker.stop();
    }
  }

  /// Screen pixels per second to pan, per axis, toward the edges [local]
  /// is near or past.
  static Offset _autoPanVelocity(Offset local, Size viewport) {
    double axis(double p, double extent) {
      if (p < autoPanEdge) return -_autoPanSpeed(autoPanEdge - p);
      if (p > extent - autoPanEdge) {
        return _autoPanSpeed(p - (extent - autoPanEdge));
      }
      return 0;
    }

    return Offset(
      axis(local.dx, viewport.width),
      axis(local.dy, viewport.height),
    );
  }

  /// Speed for a pointer [depth] pixels into the edge zone (more than
  /// [autoPanEdge] once it is past the edge).
  static double _autoPanSpeed(double depth) =>
      (depth / autoPanEdge * autoPanSpeedAtEdge)
          .clamp(0, autoPanMaxSpeed)
          .toDouble();

  void _autoPanTick(Duration elapsed) {
    final e = _lastToolEvent;
    final session = _session;
    final view = _view;
    final g = _geometry;
    if (e == null || session == null || view == null || g == null) {
      _autoPan?.stop();
      return;
    }
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    final v = _autoPanVelocity(e.localPosition, g.viewport);
    if (v == Offset.zero) {
      _autoPan?.stop();
      return;
    }
    final seconds = dt.inMicroseconds / 1e6;
    // Moving the view toward an edge shows what lies beyond it. Pan bounds
    // grow with everything shown during the session, so the stroke can go
    // into new space; the build won't clamp the view back.
    final next = CanvasView(view.scale, view.offset - v * seconds);
    _sessionArea = _sessionArea!.expandToInclude(next.visible(g.viewport));
    _sampleTime += dt;
    setState(() => _view = next);
    session.update(
      ToolPointer(
        position: next.toWorld(e.localPosition),
        kind: e.kind,
        time: _sampleTime,
        pressure: _toolPointer(e).pressure,
      ),
    );
    _overlay.repaint();
  }

  void _changed() {
    // The page turned read-only under a running tool: end it.
    if (_readOnly) {
      _cancelSession();
      _pickClose.value = true;
    }
    _checkContextTarget();
    // Once the page has no issues left, a later one is shown again.
    if (_silence.isSilenced(_c.page.id) && _issues.isEmpty) _silence.clear(_c.page.id);
    _find.refresh();
    _hostsRevision++;
    setState(() {});
  }

  /// Page bounds follow the content, except during a drag or resize: they
  /// update when the gesture ends, never under the pointer (0016).
  Rect? _contentRect() {
    if (!_c.isInteracting) _content = _c.page.contentBounds?.rect;
    return _content;
  }

  void _setView(CanvasView Function(CanvasGeometry g, CanvasView v) f) {
    final g = _geometry;
    final v = _view;
    if (g == null || v == null) return;
    setState(() => _view = f(g, v));
  }

  @override
  void fitAll() => _setView((g, _) => g.fitAll(_content));

  /// Zooms around the mouse if it is over the canvas, else around the
  /// centre of the view.
  @override
  void zoomBy(double factor) => _setView(
    (g, v) => g.zoomAt(
      v,
      _hover ?? g.viewport.center(Offset.zero),
      factor,
    ),
  );

  /// Zooms to [scale] around the centre of the view.
  @override
  void zoomTo(double scale) => _setView(
    (g, v) =>
        g.zoomAt(v, g.viewport.center(Offset.zero), scale / v.scale),
  );

  void _onSignal(PointerSignalEvent event) {
    if (event.kind == PointerDeviceKind.mouse) _hover = event.localPosition;
    // Registering lets a scrollable box claim the wheel first.
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScrollEvent) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _setView(
            (g, v) =>
                g.zoomAt(v, e.localPosition, math.exp(-e.scrollDelta.dy / 300)),
          );
        } else {
          var d = e.scrollDelta;
          if (HardwareKeyboard.instance.isShiftPressed && d.dx == 0) {
            d = Offset(d.dy, 0);
          }
          _setView((g, v) => g.pan(v, -d));
        }
      } else if (e is PointerScaleEvent) {
        _setView((g, v) => g.zoomAt(v, e.localPosition, e.scale));
      }
    });
  }

  /// The two first fingers' centre and distance, or null with fewer.
  (Offset, double)? _touchPair() {
    if (_touches.length < 2) return null;
    final it = _touches.values.iterator;
    it.moveNext();
    final a = it.current;
    it.moveNext();
    final b = it.current;
    return ((a + b) / 2, (a - b).distance);
  }

  void _touchDown(PointerDownEvent e) {
    if (_touches.isEmpty) _multiTouch = false;
    if (e.kind != PointerDeviceKind.touch) return;
    // A finger that lands during a pen stroke is a resting hand.
    if (_session != null && _lastToolEvent?.kind != PointerDeviceKind.touch) {
      _palmPointers.add(e.pointer);
    }
    _touches[e.pointer] = e.localPosition;
    _startPinch();
  }

  /// Starts the two-finger gesture once two fingers are down and no pen or
  /// mouse session holds the input (a resting palm must not interrupt a
  /// stroke; the next finger to land starts the pinch).
  void _startPinch() {
    if (_touches.length < 2 || _multiTouch) {
      if (_multiTouch) _resetPair();
      return;
    }
    if (_session != null && _lastToolEvent?.kind != PointerDeviceKind.touch) {
      return;
    }
    // The first finger was only the start of a pinch: a tool session it
    // began (an ink stroke) is dropped.
    _multiTouch = true;
    _multiTouchActive.value = true;
    _cancelSession();
    _resetPair();
  }

  /// Ends the two-finger gesture without waiting for the fingers to lift.
  void _endPinch() {
    _multiTouch = false;
    _multiTouchActive.value = false;
    _touchFocal = null;
    _touchSpan = null;
  }

  /// Takes the fingers' current centre and distance as the basis for the
  /// next move, so a change of which two fingers count never jumps the view.
  void _resetPair() {
    final pair = _touchPair();
    _touchFocal = pair?.$1;
    _touchSpan = pair?.$2;
  }

  /// Handles a touch move; true if it belongs to a two-finger gesture.
  bool _touchMove(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.touch || !_touches.containsKey(e.pointer)) {
      return false;
    }
    _touches[e.pointer] = e.localPosition;
    if (!_multiTouch) return false;
    final pair = _touchPair();
    final focal = _touchFocal;
    final span = _touchSpan;
    if (pair == null || focal == null || span == null) return true;
    _touchFocal = pair.$1;
    _touchSpan = pair.$2;
    // The content under the fingers stays under them: pan by the focal
    // point's move, zoom by the change of their distance around it.
    final factor = span > 0 && pair.$2 > 0 ? pair.$2 / span : 1.0;
    _setView((g, v) => g.zoomAt(v, pair.$1, factor, pan: pair.$1 - focal));
    return true;
  }

  void _touchEnd(PointerEvent e) {
    if (_touches.remove(e.pointer) == null) return;
    // With one finger left the gesture is over; that finger does nothing
    // more until it lifts.
    _resetPair();
    if (_touches.isEmpty) _multiTouchActive.value = false;
  }

  // The pick list (0024, 0129) ---------------------------------------------

  /// Whether the mouse press [e] picks among the boxes under it: a primary
  /// click with Alt (Option) held, Select and type, a page that can be
  /// changed, boxes under the point, and no link under it in the topmost one.
  bool _mousePicks(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryButton) return false;
    if (_readOnly || _tools.active != null || !pickModifierHeld(HardwareKeyboard.instance)) {
      return false;
    }
    final world = pageAtGlobal(e.position);
    if (world == null) return false;
    final rows = nodesAtPoint(_c.page, world);
    return rows.isNotEmpty && !_linkAt(rows.first, e.position);
  }

  /// Whether box [id], when it is live (module on and allowed here), has a
  /// link at the screen point [global] (Box API 0.15).
  bool _linkAt(String id, Offset global) {
    final node = _c.page.node(id);
    if (node is! BoxRecord || _off.contains(node.typeId)) return false;
    if (_c.modules.codecs.resolve(node) is! LiveBox) return false;
    return _c.modules.moduleFor(node.typeId)?.linkAt(id, global) ?? false;
  }

  /// Whether the touch [e] may start a hold: no tool, a page that can be
  /// changed and boxes under the finger. On a desktop platform a finger in
  /// the box being edited is the editor's (it moves the caret at once).
  bool _touchJoins(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch || _readOnly || _tools.active != null) return false;
    final world = pageAtGlobal(e.position);
    if (world == null || nodesAtPoint(_c.page, world).isEmpty) return false;
    final editing = _c.editingId;
    if (editing != null && _desktop) {
      final b = _c.page.node(editing)?.bounds;
      if (b != null && b.rect.contains(world)) return false;
    }
    return true;
  }

  static bool get _desktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };

  /// What the list says for [node]: its type, then its first words.
  String _pickLabel(CanvasNode node) => pickRowLabel(
    node,
    typeName: (id) => widget.boxTypeName?.call(id),
    known: node is BoxRecord && _c.modules.codecs.codecFor(node.typeId) != null,
  );

  void _openPickList(Offset global) {
    if (!mounted || _readOnly || _pickOpen || _contextOpen.value) return;
    final world = pageAtGlobal(global);
    final area = _areaKey.currentContext?.findRenderObject();
    if (world == null || area is! RenderBox || !area.hasSize) return;
    if (nodesAtPoint(_c.page, world).isEmpty) return;
    _pickOpen = true;
    _pickClose.value = false;
    _pickHighlight.value = null;
    unawaited(
      showBoxPickList(
        context,
        controller: _c,
        world: world,
        anchor: global,
        within: area.localToGlobal(Offset.zero) & area.size,
        highlight: _pickHighlight,
        closeSignal: _pickClose,
        label: _pickLabel,
      ).then((choice) {
        _pickOpen = false;
        if (!mounted) {
          if (_disposedWhileOpen) _pickHighlight.dispose();
          return;
        }
        _pickHighlight.value = null;
        final id = choice?.id;
        if (id != null && _c.page.node(id) != null) _c.select(id);
        // The route's own focus scope goes with the next frame. A row's More
        // opens that box's menu in the same callback, after the canvas has
        // the focus (so the canvas is the menu's origin and the menu keeps
        // the focus it takes).
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _focus.requestFocus();
          if (choice != null && choice.more && _c.page.node(choice.id) != null) {
            _openContextAt(global, boxId: choice.id);
          }
        });
        SchedulerBinding.instance.scheduleFrame();
      }),
    );
  }

  void _onBackgroundTap(TapUpDetails d) {
    final v = _view;
    // A tap with two fingers never gets here: the gesture arena (the
    // InteractiveViewer's scale recognizer) suppresses it; the "pinch then
    // lift" test guards that.
    if (v == null || _readOnly || _tools.active != null) return;
    if (d.kind == PointerDeviceKind.touch && _upWasPalm) return;
    // An Alt click that picks among boxes (or finds none) makes no box.
    if (d.kind == PointerDeviceKind.mouse && pickModifierHeld(HardwareKeyboard.instance)) return;
    final world = v.toWorld(d.localPosition);
    // A click that lands on a box's chrome or snapshot isn't a canvas click.
    if (nodesAtPoint(_c.page, world).isNotEmpty) return;
    // Place the box so the caret lands near the click.
    _c.createBoxAt(Bounds(world.dx - 10, world.dy - 14, 0, 0));
  }

  // Context menus ----------------------------------------------------------

  /// Whether a secondary press of a mouse opens a menu: a secondary button
  /// alone, or on macOS a primary press with Ctrl (the system's secondary
  /// click), on the page area.
  bool _mouseOpens(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || _view == null) return false;
    if (e.buttons != kSecondaryMouseButton && !_ctrlPrimary(e)) return false;
    return pageAtGlobal(e.position) != null;
  }

  /// macOS's Ctrl+click: a primary press with Ctrl, which means nothing else
  /// there (links use Cmd).
  bool _ctrlPrimary(PointerDownEvent e) =>
      defaultTargetPlatform == TargetPlatform.macOS &&
      e.kind == PointerDeviceKind.mouse &&
      e.buttons == kPrimaryButton &&
      HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isAltPressed &&
      !HardwareKeyboard.instance.isMetaPressed;

  bool _targetChanged(_ContextTarget t) {
    final id = t.boxId;
    if (id == null) return false;
    final n = _c.page.node(id);
    if (n == null || (n is BoxRecord) != t.isRecord) return true;
    if (n is BoxRecord && (n.typeId != t.typeId || _off.contains(n.typeId) != t.off)) return true;
    return false;
  }

  // The box half of the revalidation while a menu is open: the target box
  // goes, or changes kind, type or disallowed state.
  void _checkContextTarget() {
    final s = _contextSession;
    if (s == null) return;
    // A change of writability closes the menu: what it offered (and what is
    // selected) was for the other state.
    if (_targetChanged(s.target) || _readOnly != s.target.readOnly) _contextClose.value = true;
  }

  /// Opens the context menu at the screen point [global]: for the box at the
  /// point (or [boxId] when given), else for the empty canvas ([forceCanvas]
  /// skips the lookup). With a note being edited, a menu for that note or the
  /// canvas takes the editor focus hold and gives focus back to the editor.
  void _openContextAt(
    Offset global, {
    String? boxId,
    bool forceCanvas = false,
    bool mouse = false,
  }) {
    if (!mounted || _pickOpen || _contextSession != null) return;
    final world = pageAtGlobal(global);
    final area = _areaKey.currentContext?.findRenderObject();
    if (world == null || area is! RenderBox || !area.hasSize) return;
    String? id = boxId;
    if (id == null && !forceCanvas) {
      final rows = nodesAtPoint(_c.page, world);
      if (rows.isNotEmpty) id = rows.first;
    }
    final node = id == null ? null : _c.page.node(id);
    if (id != null && node == null) return;

    final c = _c;
    final editing = c.editingId;
    // A note being edited keeps its editor and selection through a hold, for
    // any target. Another box is selected only when an entry is chosen (the
    // note leaves its editor then), never on open.
    final hold = editing != null;
    final origin = hold ? FocusManager.instance.primaryFocus : _focus;

    final target = _ContextTarget(
      controller: c,
      registry: _commands,
      pageId: c.page.id,
      world: world,
      boxId: id,
      isRecord: node is BoxRecord,
      typeId: node is BoxRecord ? node.typeId : null,
      off: node is BoxRecord && _off.contains(node.typeId),
      readOnly: _readOnly,
    );

    final boxesHere = Command(
      id: contextPickId,
      label: 'Pick overlapping box…',
      icon: Icons.layers_rounded,
      listenable: Listenable.merge([c, _tools]),
      // Select tool, a writable page, no link under the point and at least two
      // boxes there (§6).
      enabled: () {
        if (_readOnly || _tools.active != null) return false;
        final rows = nodesAtPoint(c.page, world);
        return rows.length >= 2 && !_linkAt(rows.first, global);
      },
      invoke: () => _openPickList(global),
    );
    final paste = Command(
      id: CanvasCommands.paste,
      label: 'Paste',
      icon: Icons.content_paste_rounded,
      listenable: c,
      enabled: () => !_readOnly && widget.attachments != null,
      invoke: () => pasteFilesAt(world),
    );
    final spec = node == null || _readOnly
        ? canvasContextSpec(
            registry: _commands,
            paste: paste,
            readOnly: _readOnly,
            hidden: _placeholderIds,
            notAllowed: _notAllowedIds,
          )
        : boxContextSpec(
            registry: _commands,
            boxesHere: boxesHere,
            disallowed: target.off,
            listenable: c,
            enabledFor: (commandId) => _boxEntryOn(id!, commandId),
          );
    // The point commands the spec didn't take are not needed.
    for (final p in [boxesHere, paste]) {
      if (!spec.points.contains(p)) p.dispose();
    }
    // Nothing to offer (an empty target with nothing enabled, a disallowed box
    // that can't be deleted): no popup.
    if ((node == null || _readOnly || target.off) && !spec.entries.any((e) => e.enabled)) {
      for (final p in spec.points) {
        p.dispose();
      }
      return;
    }

    final session = _ContextSession(
      target,
      spec,
      origin,
      hold ? c : null,
      area: ValueNotifier(area.localToGlobal(Offset.zero) & area.size),
      selectedAtOpen: c.selectedId,
      editingAtOpen: editing,
    );
    session.holdNow();
    _contextSession = session;
    _contextClose.value = false;
    if (!_contextDisposed) _contextOpen.value = true;
    unawaited(
      showContextMenu(
        context,
        spec: spec,
        anchor: global,
        within: session.area,
        // A disallowed box and a read-only page always get the list.
        radial: mouse && !target.off && !_readOnly && widget.contextMenuStyle == ContextMenuStyle.radial,
        closeSignal: _contextClose,
      ).then((entry) => _contextDone(session, entry)),
    );
  }

  /// Run after every frame: a menu is laid out against the canvas rect as it is
  /// now (it moves with the toolbar wrapping, a bar appearing, a panel), so the
  /// open menu is told the new rect. It closes only when the canvas is gone.
  void _checkContextRect() {
    final s = _contextSession;
    if (!mounted || s == null || _contextClose.value) return;
    final area = _areaKey.currentContext?.findRenderObject();
    if (area is! RenderBox || !area.hasSize) {
      _contextClose.value = true;
      return;
    }
    final rect = area.localToGlobal(Offset.zero) & area.size;
    if (rect != s.area.value) s.area.value = rect;
  }

  void _contextDone(_ContextSession s, ContextEntry? entry) {
    if (identical(_contextSession, s)) _contextSession = null;
    if (!_contextDisposed) _contextOpen.value = false;
    final binding = SchedulerBinding.instance;
    // The route's own focus scope goes with the next frame: focus goes back
    // to the origin after it, then the chosen entry runs, and the hold ends
    // after the frame that applied the focus.
    binding.addPostFrameCallback((_) {
      if (mounted) _focusOrigin(s.origin);
      // The chosen entry runs in the frame after the focus restore (task 6 order),
      // and the hold ends with it.
      binding.addPostFrameCallback((_) {
        s.releaseHold();
        final run = entry == null ? Future<void>.value() : _runContextEntry(s, entry);
        unawaited(
          run.whenComplete(() {
            for (final p in s.spec.points) {
              p.dispose();
            }
          }),
        );
      });
      binding.scheduleFrame();
    });
    binding.scheduleFrame();
  }

  void _focusOrigin(FocusNode? origin) {
    var usable = false;
    try {
      usable = origin != null && origin.context?.mounted == true && origin.canRequestFocus;
    } on Object {
      usable = false;
    }
    if (usable) {
      origin!.requestFocus();
    } else {
      _focus.requestFocus();
    }
  }

  Future<void> _runContextEntry(_ContextSession s, ContextEntry entry) async {
    final gate = debugBeforeContextRun;
    if (gate != null) await gate();
    if (!mounted) return;
    final t = s.target;
    final guard = CanvasTargetGuard(
      controller: t.controller,
      pageId: t.pageId,
      registry: t.registry,
    );
    if (!guard.holds(_c, _c.page.id, registry: _commands)) return;
    if (t.boxId != null && _targetChanged(t)) return;
    if (!entry.onTarget) {
      await entry.command.run();
      return;
    }
    // A box entry: select the target, look up the live command (it acts on the
    // selection) and check it is on for the target now. If not, nothing runs
    // and the selection goes back to what it was when the menu opened.
    final id = t.boxId!;
    final live = t.registry[entry.command.id];
    _c.select(id);
    if (live == null || !live.enabled) {
      final prior = s.selectedAtOpen;
      _c.select(prior != null && _c.page.node(prior) != null ? prior : null);
      // The note that was being edited gets its editor back.
      final editing = s.editingAtOpen;
      if (editing != null && _c.page.node(editing) != null && _c.editingId != editing) {
        _focusOrigin(s.origin);
      }
      return;
    }
    // Choosing an entry for another box ends the edit of the note (0092).
    final editing = _c.editingId;
    if (editing != null && editing != id) _focus.requestFocus();
    await live.run();
  }

  // Whether the box entry [commandId] is on for the box [id] (its arrange
  // moves, Delete): read for the menu's target, not for the selection.
  bool _boxEntryOn(String id, String commandId) {
    if (_readOnly) return false;
    final move = switch (commandId) {
      CanvasCommands.bringToFront => StackMove.front,
      CanvasCommands.bringForward => StackMove.forward,
      CanvasCommands.sendBackward => StackMove.backward,
      CanvasCommands.sendToBack => StackMove.back,
      _ => null,
    };
    if (move != null) return _c.canRestack(id, move);
    return commandId == CanvasCommands.delete && _c.canDelete(id);
  }

  /// Whether the focused thing is a text field of its own (a sticky label, an
  /// image caption, the title, the find bar): it keeps Shift+F10 and the Menu
  /// key.
  bool _fieldOwnsKey() {
    if (_findFocus.hasFocus) return true;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static bool _isContextKey(KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.contextMenu) return true;
    final k = HardwareKeyboard.instance;
    return e.logicalKey == LogicalKeyboardKey.f10 &&
        k.isShiftPressed &&
        !k.isControlPressed &&
        !k.isAltPressed &&
        !k.isMetaPressed;
  }

  /// Opens the menu for the box being edited, else the selected box, else the
  /// canvas, anchored in the box or at the hover point or the middle of the
  /// view. A box outside the view is brought in first and the anchor is taken
  /// from the view after that frame.
  void _openContextFromKeyboard() {
    final id = _c.editingId ?? _c.selectedId;
    final node = id == null ? null : _c.page.node(id);
    final boxId = node?.bounds != null ? id : null;
    if (boxId != null) _revealBox(boxId);
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted) return;
      final at = _keyboardAnchor(boxId);
      if (at == null) return;
      _openContextAt(at, boxId: boxId, forceCanvas: boxId == null);
    });
    binding.scheduleFrame();
  }

  /// The screen point a keyboard-opened menu is anchored at.
  Offset? _keyboardAnchor(String? boxId) {
    final area = _areaKey.currentContext?.findRenderObject();
    final v = _view;
    final g = _geometry;
    if (area is! RenderBox || !area.hasSize || v == null || g == null) return null;
    final viewport = Offset.zero & g.viewport;
    Offset local;
    final rect = boxId == null ? null : _c.page.node(boxId)?.bounds?.rect;
    if (rect != null) {
      final screen = Rect.fromPoints(v.toScreen(rect.topLeft), v.toScreen(rect.bottomRight));
      final vis = screen.intersect(viewport);
      if (vis.isEmpty) {
        local = viewport.center;
      } else {
        final corner = vis.topLeft + const Offset(12, 12);
        final ok =
            vis.contains(corner) && nodesAtPoint(_c.page, v.toWorld(corner)).firstOrNull == boxId;
        local = ok ? corner : vis.center;
      }
    } else {
      final h = _hover;
      local = h != null && nodesAtPoint(_c.page, v.toWorld(h)).isEmpty ? h : viewport.center;
    }
    return area.localToGlobal(local);
  }

  /// Keys are looked up in the command registry. Keys bubble up from a
  /// focused editor: only the commands that work while editing (zoom,
  /// Escape) answer them, the rest is left to the editor. A read-only page
  /// answers only to the commands that work there (zoom).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // While a context menu is open no key acts on the canvas (Delete, Ctrl+Z,
    // V, P and E would change the page or the tool under the menu).
    if (_contextSession != null) return KeyEventResult.ignored;
    // Shift+F10 and the Menu key open the context menu, also from a note being
    // edited; a text field of its own (a label, a caption, the find bar) keeps
    // them.
    if (event is KeyDownEvent && _isContextKey(event)) {
      if (_fieldOwnsKey()) return KeyEventResult.ignored;
      if (_pickOpen) return KeyEventResult.handled;
      _openContextFromKeyboard();
      return KeyEventResult.handled;
    }
    final command = _commands.resolve(
      event,
      // The find bar's text field owns the keys like a box's editor does.
      editing: _c.editingId != null || _findFocus.hasFocus,
      readOnly: _readOnly,
    );
    if (command == null) return KeyEventResult.ignored;
    command.run();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    assert(
      setEquals(_off, _c.disallowedTypes),
      'The owner of the controller sets controller.disallowedTypes to the '
      'same set it gives PageCanvas.disallowedTypes.',
    );
    final scheme = Theme.of(context).colorScheme;
    _brightness = Theme.of(context).brightness;
    _colors = NotedColors.of(context);
    _toolbarScale = _view?.scale;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommandToolbar(
            registry: _commands,
            layout: widget.toolbar,
            readOnly: _readOnly,
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.sidePanel == null)
                  _canvasArea(scheme)
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _canvasArea(scheme)),
                      widget.sidePanel!(context, _commands),
                    ],
                  ),
                if (widget.overlayPanel != null) widget.overlayPanel!(context, _commands),
              ],
            ),
          ),


        ],
      ),
    );
  }

  // The boxes' widgets, kept while nothing they show has changed. Panning and
  // zooming rebuild this widget on every frame, but a BoxHost reads the zoom
  // when it needs it (BoxHost.scaleOf), so the same widget instances can be
  // handed to the Stack again and Flutter then skips every box (editors
  // included). The list is made again whenever the controller notifies (the
  // page, the selection, editing, read-only), and when the canvas child's
  // origin, the read-only state, the find model or the controller change.
  //
  // Each box's widget is also kept on its own while what that box shows is
  // unchanged: its node (the page replaces the node object of a box that
  // changes and keeps the others; compared by identity), whether it is
  // selected or being edited, and the read-only state. So when one note grows
  // with its text, only that box rebuilds, not every box on the page.
  List<Widget>? _hostWidgets;
  int _hostsRevision = 0;
  (int, CanvasController, Offset, bool, PageFind)? _hostsKey;
  final Map<String, ((CanvasNode, bool, bool, bool), BoxHost)> _hostPerBox = {};

  List<Widget> _boxHosts(Offset childOrigin, bool readOnly) {
    final key = (_hostsRevision, _c, childOrigin, readOnly, _find);
    final cached = _hostWidgets;
    if (cached != null && _hostsKey == key) return cached;
    final previous = _hostsKey;
    // Something every box uses changed: make every widget again.
    if (previous == null || (previous.$2, previous.$3, previous.$4, previous.$5) != (key.$2, key.$3, key.$4, key.$5)) {
      _hostPerBox.clear();
    }
    _hostsKey = key;
    final kept = <String, ((CanvasNode, bool, bool, bool), BoxHost)>{};
    final hosts = <Widget>[];
    for (final node in _c.page.nodes) {
      final boxKey = (node, _c.selectedId == node.id, _c.editingId == node.id, _c.readOnly);
      final old = _hostPerBox[node.id];
      final host = old != null && old.$1 == boxKey
          ? old.$2
          : BoxHost(
              key: ValueKey(node.id),
              node: node,
              controller: _c,
              childOrigin: childOrigin,
              scaleOf: () => scale,
              multiTouch: _multiTouchActive,
              inkedBy: _boxIgnores,
              onGripTap: _focus.requestFocus,
              readOnly: readOnly,
              find: _find,
              attachments: widget.attachments,
              insertFilesBeside: _readOnly ? null : _insertFilesBeside,
              disallowedTypes: _off,
              onIssueTap: (id) => unawaited(openIssues(onlyBox: id)),
            );
      kept[node.id] = (boxKey, host);
      hosts.add(host);
    }
    _hostPerBox
      ..clear()
      ..addAll(kept);
    return _hostWidgets = hosts;
  }

  Widget _canvasArea(ColorScheme scheme) {
    return KeyedSubtree(key: _areaKey, child: _canvasLayout(scheme));
  }

  final GlobalKey _areaKey = GlobalKey();

  /// The page point under the screen point [global], or null if the canvas
  /// isn't laid out.
  Offset? pageAtGlobal(Offset global) {
    final box = _areaKey.currentContext?.findRenderObject();
    final v = _view;
    if (box is! RenderBox || !box.hasSize || v == null) return null;
    return v.toWorld(box.globalToLocal(global));
  }

  /// Creates boxes for files dropped at the screen point [global].
  Future<void> dropFiles(List<IncomingFile> files, Offset global) =>
      insertFiles(files, at: pageAtGlobal(global));

  Widget _canvasLayout(ColorScheme scheme) {
    return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;          final content = _contentRect();
          final area = _sessionArea;
          final g = CanvasGeometry.compute(
            content: area == null
                ? content
                : (content?.expandToInclude(area) ?? area),
            viewport: size,
          );
          _geometry = g;
          final view = g.clamp(_view ?? g.initial(content));
          _view = view;
          // The toolbar is built before this runs: if the view settled on a
          // zoom it doesn't show, rebuild once so its percentage is right.
          if (view.scale != _toolbarScale) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
          final matrix = g.matrixFor(view);
          if (_transform.value != matrix) _transform.value = matrix;

          final readOnly = _readOnly;
          final issueCount = readOnly ? 0 : _issues.length;
          final showIssueIcon = issueCount > 0 && !_issuesOpen;
          // A tool picked on another page does nothing on a read-only one.
          final tool = readOnly ? null : _tools.active;
          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerSignal: _onSignal,
                  onPointerDown: (e) {
                    if (e.buttons & kMiddleMouseButton != 0) {
                      _middlePointer = e.pointer;
                    } else {
                      if (e.kind == PointerDeviceKind.stylus ||
                          e.kind == PointerDeviceKind.invertedStylus) {
                        _inkSerial++;
                      }
                      _touchDown(e);
                      if (e.kind == PointerDeviceKind.touch) {
                        // A second finger never starts a tool session.
                        if (!_multiTouch) _toolDown(e);
                      } else {
                        // A pen or mouse takes the input over: resting
                        // fingers stop panning and zooming.
                        _endPinch();
                        _toolDown(e);
                        // A finger already down is a resting hand.
                        if (_session != null) _palmPointers.addAll(_touches.keys);
                      }
                    }
                  },
                  onPointerMove: (e) {
                    if (e.pointer == _middlePointer) {
                      _setView((g, v) => g.pan(v, e.delta));
                    } else if (!_touchMove(e)) {
                      _toolMove(e);
                    }
                  },
                  onPointerUp: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                    _upWasPalm = _palmPointers.remove(e.pointer);
                    _touchEnd(e);
                    _toolUp(e);
                  },
                  onPointerCancel: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                    _palmPointers.remove(e.pointer);
                    _touchEnd(e);
                    if (e.pointer == _sessionPointer) _cancelSession();
                  },
                  onPointerHover: (e) {
                    if (e.kind == PointerDeviceKind.mouse) {
                      _hover = e.localPosition;
                    }
                  },
                  onPointerPanZoomStart: (_) {
                    _pinchStartScale = _view?.scale ?? 1;
                    _pinchPan = Offset.zero;
                  },
                  onPointerPanZoomUpdate: (e) {
                    // A box that scrolls has claimed this gesture's panning
                    // (BoxScrollScope); a pinch still zooms the canvas.
                    final claimed = TrackpadClaims.isClaimed(e.pointer);
                    // The focal point is where the fingers are now: the
                    // gesture's start plus its pan so far. The scale is
                    // the start scale times the gesture's cumulative scale,
                    // so it never drifts; the content under the fingers
                    // stays under them at every step.
                    // (e.pan, not e.localPan: Flutter transforms that as a
                    // position, so it would include the canvas's offset.)
                    final pan = claimed ? Offset.zero : e.pan;
                    final step = pan - _pinchPan;
                    _pinchPan = pan;
                    _setView(
                      (g, v) => g.zoomAt(
                        v,
                        e.localPosition + pan,
                        _pinchStartScale * e.scale / v.scale,
                        pan: step,
                      ),
                    );
                  },
                  onPointerPanZoomEnd: (e) => TrackpadClaims.release(e.pointer),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onBackgroundTap,
                    // A pen's pointer wins the arena at once, so no box under
                    // it moves, resizes or places a caret: it inks (0033).
                    child: RawGestureDetector(
                      behavior: HitTestBehavior.translucent,
                      gestures: {
                        _PenClaim:
                            GestureRecognizerFactoryWithHandlers<_PenClaim>(
                              _PenClaim.new,
                              (r) => r.inks = _inkedBy,
                            ),
                        _PickClaim:
                            GestureRecognizerFactoryWithHandlers<_PickClaim>(
                              _PickClaim.new,
                              (r) => r
                                ..picks = _mousePicks
                                ..joins = _touchJoins
                                ..serial = (() => _inkSerial)
                                ..blocked = (() => _upWasPalm || _multiTouch)
                                ..onPick = _openPickList,
                            ),
                        _ContextClaim:
                            GestureRecognizerFactoryWithHandlers<_ContextClaim>(
                              _ContextClaim.new,
                              (r) => r
                                ..opensMouse = _mouseOpens
                                ..ctrlPrimary = _ctrlPrimary
                                ..onOpen = ((global, {required mouse}) =>
                                    _openContextAt(global, mouse: mouse)),
                            ),
                      },
                      child: MouseRegion(
                      onExit: (_) => _hover = null,
                      cursor: tool?.cursor ?? MouseCursor.defer,
                      child: ColoredBox(
                        color: scheme.surfaceContainerLowest,
                        child: CustomPaint(
                          painter: PageBackgroundPainter(
                            background: _c.page.meta.background,
                            view: view,
                            pitch: NotedMetrics.of(context).paperPitch,
                            lineColor: _colors.paperLine,
                            dotColor: _colors.paperDot,
                            marginColor: _colors.paperMargin,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                          ),
                          child: InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          panEnabled: false,
                          scaleEnabled: false,
                          boundaryMargin: g.boundaryMargin,
                          minScale: g.minScale,
                          maxScale: g.maxScale,
                          child: SizedBox(
                            width: g.child.width,
                            height: g.child.height,
                            // With a tool active, input goes to the tool only.
                            child: IgnorePointer(
                              ignoring: tool != null,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: _boxHosts(g.child.topLeft, readOnly),
                              ),
                            ),
                          ),
                        ),
                        ),
                      ),
                    ),
                    ),
                  ),
                ),
              ),
              // The box the pick list points at, outlined with the rest dimmed,
              // and a selected box that another covers (BoxFrame).
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRect(
                    key: PageCanvas.pickOverlayKey,
                    child: CustomPaint(
                      painter: _PickOverlayPainter(
                        this,
                        Listenable.merge([_pickHighlight, _overlay]),
                      ),
                    ),
                  ),
                ),
              ),
              // The tool session's live feedback, in page coordinates, above
              // every box (0016: the stroke in progress is on a top overlay).
              Positioned.fill(
                child: IgnorePointer(
                  // Clipped to the canvas: ink in progress never paints
                  // over the sidebar or other UI.
                  child: ClipRect(
                    key: PageCanvas.overlayKey,
                    child: CustomPaint(
                      painter: _ToolOverlayPainter(this, _overlay),
                    ),
                  ),
                ),
              ),
              // The find bar, top right under the toolbar.
              Positioned(
                top: NotedMetrics.of(context).space2,
                right: NotedMetrics.of(context).space4 + (showIssueIcon ? _issueIconSize + 8 : 0),
                child: ListenableBuilder(
                  listenable: _find,
                  builder: (context, _) => _find.isOpen
                      ? FindBar(
                          find: _find,
                          focusNode: _findFocus,
                          onClose: closeFind,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              // The page's issues, folded into a red circle in the corner.
              if (showIssueIcon)
                Positioned(
                  top: NotedMetrics.of(context).space2,
                  right: NotedMetrics.of(context).space4,
                  child: _IssuesIcon(
                    count: issueCount,
                    onTap: () => unawaited(openIssues()),
                  ),
                ),
              if (kDebugMode)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _InputReadout(stats: _stats),
                ),
            ],
          );
        },
    );
  }
}

/// Wins the gesture arena at once for a pen's pointer (when [inks] says it
/// inks), so boxes under it see no tap or drag.
class _PenClaim extends OneSequenceGestureRecognizer {
  _PenClaim()
    : super(
        supportedDevices: {
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );

  bool Function(PointerDeviceKind kind) inks = (_) => false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!inks(event.kind)) return;
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pen claim';
}

/// What a [_PickClaim] knows of one pointer.
class _PickHold {
  _PickHold(this.down, this.serial, {required this.mouse});

  final Offset down;
  final int serial;
  final bool mouse;
  double far = 0;
  bool fired = false;
  Timer? timer;
}

/// Picks among overlapping boxes (0024).
///
/// A mouse press that [picks] wins the arena at once, so the grip, the light
/// view, an editor and the background tap all lose; on release without a
/// drag it opens the list. A touch that [joins] never wins at down: it waits
/// for the release and accepts then only if it was a hold ([kLongPressTimeout]
/// by its own timer, no movement past [kTouchSlop], no palm, second finger or
/// stylus meanwhile). A recognizer that won earlier (a drag, a scroll, a
/// long-press of a box's own) has already rejected it, so a hold followed by a
/// drag still moves, resizes or scrolls. When it accepts, every tap under the
/// finger loses. Otherwise it rejects itself and the tap goes as before.
class _PickClaim extends OneSequenceGestureRecognizer {
  _PickClaim()
    : super(
        supportedDevices: {PointerDeviceKind.mouse, PointerDeviceKind.touch},
      );

  bool Function(PointerDownEvent e) picks = (_) => false;
  bool Function(PointerDownEvent e) joins = (_) => false;
  int Function() serial = () => 0;
  bool Function() blocked = () => false;
  void Function(Offset global) onPick = (_) {};

  final Map<int, _PickHold> _holds = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final mouse = event.kind == PointerDeviceKind.mouse;
    if (mouse ? !picks(event) : !joins(event)) return;
    final hold = _PickHold(event.position, serial(), mouse: mouse);
    if (!mouse) hold.timer = Timer(kLongPressTimeout, () => hold.fired = true);
    _holds[event.pointer] = hold;
    startTrackingPointer(event.pointer, event.transform);
    if (mouse) resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    final hold = _holds[event.pointer];
    if (hold == null) return;
    hold.far = math.max(hold.far, (event.position - hold.down).distance);
    if (event is PointerUpEvent) {
      final pointer = event.pointer;
      if (hold.mouse) {
        _forget(pointer);
        if (hold.far <= kTouchSlop) onPick(event.position);
      } else {
        final ok =
            hold.fired && hold.far < kTouchSlop && serial() == hold.serial && !blocked();
        _forget(pointer);
        resolvePointer(pointer, ok ? GestureDisposition.accepted : GestureDisposition.rejected);
        if (ok) onPick(event.position);
      }
    } else if (event is PointerCancelEvent) {
      final pointer = event.pointer;
      final mouse = hold.mouse;
      _forget(pointer);
      if (!mouse) resolvePointer(pointer, GestureDisposition.rejected);
    }
  }

  void _forget(int pointer) {
    _holds.remove(pointer)?.timer?.cancel();
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _forget(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void dispose() {
    for (final h in _holds.values) {
      h.timer?.cancel();
    }
    _holds.clear();
    super.dispose();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pick claim';
}

/// What a paste or drop keeps from its start: the controller object, its
/// page, the store and the point (the context menus' paste target).
class _PasteTarget {
  _PasteTarget(this.controller, this.pageId, this.store, this.point, this.off);

  final CanvasController controller;
  final String pageId;
  final AttachmentStore store;
  final Offset point;

  /// The box types the page disallowed when the paste started.
  final Set<String> off;
}

/// What the open context menu was made for: the canvas objects, the page, the
/// point, and for a box its id, kind, type and whether the page disallows it.
class _ContextTarget {
  _ContextTarget({
    required this.controller,
    required this.registry,
    required this.pageId,
    required this.world,
    required this.boxId,
    required this.isRecord,
    required this.typeId,
    required this.off,
    required this.readOnly,
  });

  final CanvasController controller;
  final CommandRegistry registry;
  final String pageId;
  final Offset world;
  final String? boxId;
  final bool isRecord;
  final String? typeId;
  final bool off;


  /// Whether the page could not be changed when the menu opened.
  final bool readOnly;
}

/// One open context menu: its target, entries, the focus to give back, and
/// the editor focus hold it took (released once).
class _ContextSession {
  _ContextSession(this.target, this.spec, this.origin, this._holder, {required this.area, this.selectedAtOpen, this.editingAtOpen});

  /// The canvas rect (global), kept current while the menu is open.
  final ValueNotifier<Rect> area;

  final _ContextTarget target;
  final ContextMenuSpec spec;
  final FocusNode? origin;
  /// The selection when the menu opened: put back when a chosen entry is
  /// refused.
  final String? selectedAtOpen;

  /// The note being edited when the menu opened (its editor is the origin).
  final String? editingAtOpen;
  CanvasController? _holder;

  void holdNow() => _holder?.editorFocusHold.hold();

  void releaseHold() {
    final h = _holder;
    _holder = null;
    h?.editorFocusHold.release();
  }
}

/// What a [_ContextClaim] knows of one pointer.
class _ContextHold {
  _ContextHold(this.down);

  final Offset down;
  double far = 0;
  bool up = false;
  bool accepted = false;
}

/// Opens a context menu with the mouse (a touch hold on empty canvas opens
/// none: it behaves as before 0168).
///
/// A mouse press with the secondary button never resolves itself as accepted:
/// it joins the arena, rejects itself on movement past [kTouchSlop], and
/// opens only when the arena hands it the gesture and the pointer has come up
/// within slop. A recognizer deeper in the tree (a text field's, the note
/// editor's own secondary tap) is earlier in the arena and wins first, so
/// those keep their behaviour. On macOS a primary press with Ctrl is the
/// system's secondary click: it accepts at once (so no box sees a click) and
/// opens on the release.
class _ContextClaim extends OneSequenceGestureRecognizer {
  _ContextClaim()
    : super(
        supportedDevices: {PointerDeviceKind.mouse},
        allowedButtonsFilter: (_) => true,
      );

  bool Function(PointerDownEvent e) opensMouse = (_) => false;
  bool Function(PointerDownEvent e) ctrlPrimary = (_) => false;
  void Function(Offset global, {required bool mouse}) onOpen = (_, {required mouse}) {};

  final Map<int, _ContextHold> _holds = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!opensMouse(event)) return;
    _holds[event.pointer] = _ContextHold(event.position);
    startTrackingPointer(event.pointer, event.transform);
    if (ctrlPrimary(event)) resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    final hold = _holds[event.pointer];
    if (hold == null) return;
    hold.far = math.max(hold.far, (event.position - hold.down).distance);
    final pointer = event.pointer;
    if (event is PointerUpEvent) {
      stopTrackingPointer(pointer);
      hold.up = true;
      if (hold.far > kTouchSlop) {
        _holds.remove(pointer);
        resolvePointer(pointer, GestureDisposition.rejected);
      } else if (hold.accepted) {
        _holds.remove(pointer);
        onOpen(event.position, mouse: true);
      } else {
        _upAt[pointer] = event.position;
      }
    } else if (event is PointerCancelEvent) {
      stopTrackingPointer(pointer);
      _holds.remove(pointer);
      _upAt.remove(pointer);
      resolvePointer(pointer, GestureDisposition.rejected);
    } else if (hold.far > kTouchSlop && !hold.accepted) {
      // Dragging is no click.
      stopTrackingPointer(pointer);
      _holds.remove(pointer);
      resolvePointer(pointer, GestureDisposition.rejected);
    }
  }

  // Where a mouse pointer came up while the arena still held it.
  final Map<int, Offset> _upAt = {};

  @override
  void acceptGesture(int pointer) {
    final hold = _holds[pointer];
    if (hold != null) {
      hold.accepted = true;
      if (hold.up) {
        _holds.remove(pointer);
        final at = _upAt.remove(pointer);
        if (at != null && hold.far <= kTouchSlop) onOpen(at, mouse: true);
      }
    }
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _holds.remove(pointer);
    _upAt.remove(pointer);
    stopTrackingPointer(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void dispose() {
    _holds.clear();
    _upAt.clear();
    super.dispose();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'context claim';
}

const double _issueIconSize = 34;

/// The red circular warning icon that reopens the issue sequence; a count
/// badge shows when there is more than one issue.
class _IssuesIcon extends StatelessWidget {
  const _IssuesIcon({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    return IssueTapTarget(
      key: const ValueKey('issues-icon'),
      circle: true,
      label: count == 1
          ? '1 issue on this page. Open it.'
          : '$count issues on this page. Open them.',
      onTap: onTap,
      child: SizedBox(
            width: _issueIconSize,
            height: _issueIconSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
                  // A bold "!" in the app's own font: it can't go missing the
                  // way an icon-font glyph did in a release build.
                  child: SizedBox.expand(
                    child: Center(
                      child: Text(
                        '!',
                        key: const ValueKey('issues-icon-glyph'),
                        style: type.body.copyWith(
                          fontSize: 20,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          color: scheme.onError,
                        ),
                      ),
                    ),
                  ),
                ),
                if (count > 1)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: DecoratedBox(
                      key: const ValueKey('issues-icon-count'),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.error),
                      ),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: Center(
                          child: Text(
                            '$count',
                            style: type.small.copyWith(
                              fontSize: 12,
                              height: 1,
                              fontWeight: FontWeight.w700,
                              color: scheme.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    );
  }
}

class _OverlayRepaint extends ChangeNotifier {
  void repaint() => notifyListeners();
}

/// Paints the running tool session in page coordinates.
class _ToolOverlayPainter extends CustomPainter {
  _ToolOverlayPainter(this._canvas, Listenable repaint)
    : super(repaint: repaint);

  final PageCanvasState _canvas;

  @override
  void paint(Canvas canvas, Size size) {
    final session = _canvas._session;
    final view = _canvas._view;
    if (session == null || view == null) return;
    canvas.save();
    canvas.translate(view.offset.dx, view.offset.dy);
    canvas.scale(view.scale);
    session.paint(canvas, view.scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToolOverlayPainter oldDelegate) => true;
}

/// Paints the box the pick list points at (the rest of the canvas dimmed, a
/// 2px `accent` outline on top) and the 1px `accent` outline of a selected
/// box that another box covers, in screen coordinates.
class _PickOverlayPainter extends CustomPainter {
  _PickOverlayPainter(this._canvas, Listenable repaint) : super(repaint: repaint);

  final PageCanvasState _canvas;

  @override
  void paint(Canvas canvas, Size size) {
    final view = _canvas._view;
    if (view == null) return;
    final page = _canvas._c.page;
    final scheme = Theme.of(_canvas.context).colorScheme;
    final radius = Radius.circular(NotedMetrics.of(_canvas.context).radiusLg * view.scale);
    RRect screen(Bounds b) => RRect.fromRectAndRadius(
      Rect.fromLTWH(
        view.offset.dx + b.x * view.scale,
        view.offset.dy + b.y * view.scale,
        b.width * view.scale,
        b.height * view.scale,
      ),
      radius,
    );

    final lit = _canvas._pickHighlight.value;
    final litBounds = lit == null ? null : page.node(lit)?.bounds;
    if (litBounds != null) {
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(screen(litBounds));
      canvas.drawPath(
        path,
        Paint()..color = scheme.surfaceContainerLowest.withValues(alpha: 0.6),
      );
      canvas.drawRRect(
        screen(litBounds),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = scheme.primary,
      );
    }

    final selected = _canvas._c.selectedId;
    final sb = selected == null || selected == lit ? null : page.node(selected)?.bounds;
    if (sb != null) {
      final i = page.indexOf(selected!);
      var covered = false;
      for (var j = i + 1; j < page.nodes.length && !covered; j++) {
        final o = page.nodes[j].bounds;
        covered = o != null && boundsOverlap(sb, o);
      }
      if (covered) {
        canvas.drawRRect(
          screen(sb),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = scheme.primary,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PickOverlayPainter oldDelegate) => true;
}

/// Pointer events received during the latest tool session.
@immutable
final class _InputStats {
  const _InputStats(this.points, this.first, this.last);

  const _InputStats.start(Duration t) : this(1, t, t);

  final int points;
  final Duration first;
  final Duration last;

  _InputStats add(Duration t) => _InputStats(points + 1, first, t);

  @override
  String toString() {
    final seconds = (last - first).inMicroseconds / 1e6;
    final rate = seconds > 0 ? (points - 1) / seconds : 0;
    return 'Input: ${rate.round()} pts/s · $points pts · ${seconds.toStringAsFixed(2)} s';
  }
}

/// Debug builds only: how many pointer events the last stroke received, to
/// check that no input is lost on the device being tested.
class _InputReadout extends StatelessWidget {
  const _InputReadout({required this.stats});

  final ValueListenable<_InputStats?> stats;

  @override
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    return ValueListenableBuilder<_InputStats?>(
      valueListenable: stats,
      builder: (context, s, _) => s == null
          ? const SizedBox.shrink()
          : DecoratedBox(
              decoration: BoxDecoration(
                color: colors.readoutBackground,
                borderRadius: metrics.borderSm,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: metrics.space2,
                  vertical: metrics.space1,
                ),
                child: Text(
                  s.toString(),
                  style: NotedTypography.of(context).small.copyWith(
                    color: colors.onReadout,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
    );
  }
}
