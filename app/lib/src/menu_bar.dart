// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'about_dialog.dart';
import 'app_commands.dart';
import 'app_settings.dart';
import 'brand_mark.dart';
import 'microsoft_account.dart';
import 'notebook.dart';
import 'notebook_search.dart';
import 'shortcuts_dialog.dart';

/// The height of the menu bar row (`row`).
const double menuBarHeight = 32;

/// Below this window width only the brand mark shows, without "Noted".
const double wordmarkMinWidth = 600;

enum _Kind { app, header, page, binder, canvas }

// One entry of a menu, read from the commands when the menu is built.
sealed class _Entry {
  const _Entry();
}

class _Divider extends _Entry {
  const _Divider();
}

class _Sub extends _Entry {
  const _Sub(this.label, this.children);
  final String label;
  final List<_Entry> children;
}

class _Item extends _Entry {
  const _Item({
    required this.kind,
    required this.id,
    required this.label,
    required this.enabled,
    this.shortcut,
    this.checked,
    this.destructive = false,
    this.binderPath,
  });

  final _Kind kind;
  final String id;
  final String label;
  final bool enabled;
  final String? shortcut;
  final bool? checked;
  final bool destructive;

  /// For Binder: the folder the submenu was built for.
  final String? binderPath;
}

/// What an activated item must still find when it runs (Codex R-2): the page
/// or the cover it was chosen on, and, for a canvas item, the canvas registry.
class _Target {
  _Target({
    required this.controller,
    required this.pageId,
    required this.coverPath,
    required this.cover,
    required this.registry,
    required this.binderPath,
  });

  final CanvasController? controller;
  final String? pageId;
  final String? coverPath;
  final BinderSection? cover;
  final CommandRegistry? registry;
  final String? binderPath;

  bool holds(Notebook nb, CommandRegistry? registryNow, {required bool canvas}) {
    if (!identical(nb.current, controller) || nb.currentId != pageId) return false;
    if (nb.coverPath != coverPath || !identical(nb.cover, cover)) return false;
    if (canvas && (registry == null || !identical(registry, registryNow))) return false;
    final b = binderPath;
    if (b != null) {
      final id = nb.currentId;
      final open = id == null ? null : nb.binderOfPage(id);
      if (nb.coverPath != b && open != b) return false;
    }
    return true;
  }
}

/// The page tree's actions for the menu: forwarded to the tree, or, when the
/// tree is not on screen (the drawer of a narrow window is shut), after the
/// drawer has opened, and only if the menu's target still holds then.
class _TreeProxy implements PageTreeActions {
  _TreeProxy(this._tree, this._openDrawer);

  final PageTreeActions? Function() _tree;
  final void Function(VoidCallback then) _openDrawer;

  /// Set to the target's check before a command runs.
  bool Function() valid = () => true;

  Future<void> _go(Future<void> Function(PageTreeActions a) f) async {
    final tree = _tree();
    if (tree != null) return f(tree);
    final check = valid;
    _openDrawer(() {
      if (!check()) return;
      final a = _tree();
      if (a != null) unawaited(f(a));
    });
  }

  @override
  Future<void> newStandalonePage() => _go((a) => a.newStandalonePage());
  @override
  Future<void> newPageFromTemplate() => _go((a) => a.newPageFromTemplate());
  @override
  Future<void> newBinder() => _go((a) => a.newBinder());
  @override
  Future<void> newBinderInFolder() => _go((a) => a.newBinderInFolder());
  @override
  Future<void> openBinder() => _go((a) => a.openBinder());
  @override
  Future<void> newBinderFromTemplate() => _go((a) => a.newBinderFromTemplate());
  @override
  Future<void> newSubpage(PageMeta page) => _go((a) => a.newSubpage(page));
  @override
  Future<void> newSubpageFromTemplate(PageMeta page) => _go((a) => a.newSubpageFromTemplate(page));
  @override
  Future<void> saveAsTemplate(PageMeta page) => _go((a) => a.saveAsTemplate(page));
  @override
  Future<void> rename(PageMeta page) => _go((a) => a.rename(page));
  @override
  Future<void> indent(PageMeta page) => _go((a) => a.indent(page));
  @override
  Future<void> delete(PageMeta page) => _go((a) => a.delete(page));
  @override
  Future<void> moveToFolder(PageMeta page) => _go((a) => a.moveToFolder(page));
  @override
  Future<void> pageSettings(PageMeta page) => _go((a) => a.pageSettings(page));
  @override
  Future<void> binderNewPage(BinderSection binder) => _go((a) => a.binderNewPage(binder));
  @override
  Future<void> binderNewPageFromTemplate(BinderSection binder) =>
      _go((a) => a.binderNewPageFromTemplate(binder));
  @override
  Future<void> binderSaveAsTemplate(BinderSection binder) =>
      _go((a) => a.binderSaveAsTemplate(binder));
  @override
  Future<void> binderRemove(BinderSection binder) => _go((a) => a.binderRemove(binder));
  @override
  Future<void> binderSettings(BinderSection binder) => _go((a) => a.binderSettings(binder));
}

/// The menu bar row: the brand mark, then File, Edit, View and Help, built from
/// the commands (0067). Items show their shortcut and bind nothing; the keys
/// resolve where they did before. The bar never takes focus by pointer, so a
/// note being edited keeps its caret; keyboard entry (F10, a lone Alt,
/// Alt+letter) moves focus into the bar under an editor focus hold.
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({
    super.key,
    required this.notebook,
    required this.search,
    required this.treeActions,
    required this.openDrawer,
    required this.canvas,
    required this.panelShown,
    required this.onTogglePanel,
    required this.focusCanvas,
    this.settings,
    this.microsoft,
  });

  final Notebook notebook;
  final AppSettings? settings;
  final NotebookSearch search;
  final MicrosoftAccount? microsoft;

  /// The page tree's actions, or null while the tree is not on screen.
  final PageTreeActions? Function() treeActions;

  /// Opens the drawer that holds the tree (a narrow window) and runs the
  /// callback after the frame that builds it; runs it at once if the tree is
  /// there.
  final void Function(VoidCallback then) openDrawer;

  /// The open page canvas's registry, or null with no canvas.
  final ValueListenable<CommandRegistry?> canvas;

  /// Whether the contextual panel is shown, and how Contextual panel toggles it.
  final ValueListenable<bool> panelShown;
  final VoidCallback onTogglePanel;

  /// Puts the focus on the open page's canvas, if there is one.
  final VoidCallback focusCanvas;

  @override
  State<AppMenuBar> createState() => AppMenuBarState();
}

class AppMenuBarState extends State<AppMenuBar> {
  static const _titles = ['File', 'Edit', 'View', 'Help'];
  static const _letters = [
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyH,
  ];

  late final FocusScopeNode _bar = FocusScopeNode(
    debugLabel: 'menu bar',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );
  final List<FocusNode> _top = [for (final t in _titles) FocusNode(debugLabel: 'menu $t')];
  final List<MenuController> _controllers = [for (final _ in _titles) MenuController()];
  // The first focusable item of each menu, which a keyboard opening focuses.
  final List<FocusNode> _firstNode = [for (final t in _titles) FocusNode(debugLabel: 'first $t')];
  final List<bool> _isOpen = [false, false, false, false];
  late final _TreeProxy _proxy = _TreeProxy(() => widget.treeActions(), widget.openDrawer);
  final List<CommandRegistry> _appRegistries = [];
  late final AppLifecycleListener _lifecycle;
  final Object _group = Object();

  // Whether the bar's buttons and items can't take focus: true except from a
  // keyboard entry until the menu closes (pointer opening never clears it).
  bool _excluding = true;

  // The editor focus hold: while focus is in the bar, on the controller of the
  // page that was open when it started, with the node that had focus then.
  bool _holding = false;
  CanvasController? _holdController;
  FocusNode? _origin;
  bool _barFocused = false;

  bool _altArmed = false;
  bool _loadSucceeded = false;
  CommandRegistry? _registry;

  bool get _altKeys => defaultTargetPlatform != TargetPlatform.macOS;

  /// Whether focus is inside the bar or one of its menus (the home leaves
  /// the keys alone then).
  bool get hasFocus => _bar.hasFocus;

  /// Whether the bar holds the editor focus now.
  bool get holding => _holding;

  /// Whether the buttons and items are shut out of focus (pointer opening).
  bool get excludingFocus => _excluding;

  void _buildAppCommands() {
    final s = widget.settings;
    if (s != null) {
      _appRegistries
        ..add(themeCommands(s))
        ..add(toolbarCommands(s));
    }
    final r = CommandRegistry()
      ..register(searchCommand(widget.search))
      ..register(
        Command(
          id: AppCommands.viewPanel,
          label: 'Contextual panel',
          icon: Icons.view_sidebar_rounded,
          checked: () => widget.panelShown.value,
          listenable: widget.panelShown,
          invoke: widget.onTogglePanel,
        ),
      )
      ..register(
        Command(
          id: AppCommands.helpShortcuts,
          label: 'Keyboard shortcuts',
          icon: Icons.keyboard_rounded,
          invoke: () => showShortcutsDialog(context, _shortcutRegistries()),
        ),
      );
    final ms = widget.microsoft;
    if (ms != null) {
      r.register(
        Command(
          id: AppCommands.helpAbout,
          label: 'About Noted',
          icon: Icons.info_outline_rounded,
          invoke: () => showAboutNoted(context, ms),
        ),
      );
    }
    _appRegistries.add(r);
  }

  Command? _app(String id) {
    for (final r in _appRegistries) {
      final c = r[id];
      if (c != null) return c;
    }
    return null;
  }

  List<CommandRegistry?> _shortcutRegistries() {
    final header = _headerRegistry();
    // The header registry is read now and not kept.
    final rows = [widget.canvas.value, header, ..._appRegistries];
    Future<void>.microtask(header.dispose);
    return rows;
  }

  CommandRegistry _headerRegistry() => pagesHeaderCommands(widget.notebook, _proxy);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _windowLeft, onHide: _windowLeft);
    _buildAppCommands();

    _bar.addListener(_barChanged);
    widget.notebook.addListener(_notebookChanged);
    widget.canvas.addListener(_canvasChanged);
    _registry = widget.canvas.value;
    _registry?.addListener(_rebuild);
    widget.settings?.addListener(_rebuild);
    FocusManager.instance.addEarlyKeyEventHandler(_onKeyEarly);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    // TODO(task 6): replace with Notebook.firstLoadSucceeded once notebook.dart
    // has it (set in the _loadSucceeded callback, followed by _notifyLoad()).
    unawaited(
      widget.notebook.loadSucceeded.then((_) {
        if (!mounted) return;
        setState(() => _loadSucceeded = true);
      }),
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKeyEarly);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    widget.notebook.removeListener(_notebookChanged);
    widget.canvas.removeListener(_canvasChanged);
    widget.settings?.removeListener(_rebuild);
    _registry?.removeListener(_rebuild);
    _holdController?.editorFocusHold.release();
    _holdController = null;
    _lifecycle.dispose();
    _bar.removeListener(_barChanged);
    _bar.dispose();
    for (final n in [..._top, ..._firstNode]) {
      n.dispose();
    }
    for (final r in _appRegistries) {
      r.dispose();
    }
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.transientCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _notebookChanged() {
    // A page change or the cover ends a hold of the page that was open.
    if (_holding && !identical(widget.notebook.current, _holdController)) {
      _exit(restoreFocus: false);
    }
    _rebuild();
  }

  void _canvasChanged() {
    _registry?.removeListener(_rebuild);
    _registry = widget.canvas.value;
    _registry?.addListener(_rebuild);
    // The canvas went (or another took its place): the hold of the old
    // controller ends.
    if (_holding && (_registry == null || !identical(widget.notebook.current, _holdController))) {
      _exit(restoreFocus: false);
    }
    _rebuild();
  }

  // Window or app focus lost: the bar closes and releases at once.
  void _windowLeft() {
    _altArmed = false;
    if (_holding || _isOpen.contains(true)) _exit(restoreFocus: false);
  }

  void _barChanged() {
    if (_bar.hasFocus) {
      _barFocused = true;
      return;
    }
    // The focus left the bar for something other than the way back to the
    // origin (Tab out, a dialog, a press on another focusable): an exit.
    if (_holding && _barFocused) _exit(restoreFocus: false);
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _altArmed = false;
  }

  // The keyboard, before the focus tree sees it (so what is used is consumed): F10
  // and a lone Alt, Alt+letter, the arrows at the bar, and, for a menu opened by
  // pointer (focus unchanged), Escape, Up and Down and the keys that close it.
  KeyEventResult _onKeyEarly(KeyEvent e) {
    if (!mounted || e.synthesized) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final key = e.logicalKey;
    final isAlt = key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight;
    if (e is KeyUpEvent) {
      if (_altKeys && isAlt && _altArmed && !k.isControlPressed) {
        _altArmed = false;
        _toggle();
      }
      return KeyEventResult.ignored;
    }
    if (_altKeys && isAlt) {
      // A held Alt repeats: that is the same press.
      if (e is KeyDownEvent) {
        _altArmed = !k.isControlPressed && !k.isMetaPressed && !k.isShiftPressed;
      }
      return KeyEventResult.ignored;
    }

    _altArmed = false;
    if (_altKeys && e is KeyDownEvent) {
      if (key == LogicalKeyboardKey.f10 &&
          !k.isControlPressed &&
          !k.isAltPressed &&
          !k.isShiftPressed) {
        _toggle();
        return KeyEventResult.handled;
      }
      if (k.isAltPressed && !k.isControlPressed && !k.isMetaPressed && !k.isShiftPressed) {
        final i = _letters.indexOf(key);
        if (i >= 0) {
          _enter(index: i, open: true);
          return KeyEventResult.handled;
        }
      }
    }
    if (_holding) {
      return e is KeyDownEvent && _barKey(key) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (!_isOpen.contains(true)) return KeyEventResult.ignored;
    // A menu opened by pointer, the focus still where it was.
    if (key == LogicalKeyboardKey.escape) {
      _closeMenus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      _enter(index: _isOpen.indexOf(true), open: true);
      return KeyEventResult.handled;
    }
    final modifier =
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
    if (!modifier) _closeMenus();
    return KeyEventResult.ignored;
  }

  void _toggle() {
    if (_holding) {
      _exit(restoreFocus: true);
    } else {
      _enter(index: 0);
    }
  }

  void _closeMenus() {
    for (final c in _controllers) {
      c.close();
    }
  }

  // Keyboard entry: record the origin and the controller, hold, and only then
  // move the focus into the bar.
  void _enter({required int index, bool open = false}) {
    final wasOpen = _isOpen.indexOf(true);
    if (!_holding) {
      _origin = FocusManager.instance.primaryFocus;
      _holdController = widget.notebook.current;
      _holdController?.editorFocusHold.hold();
      _holding = true;
      _barFocused = false;
    }
    // A menu opened another way stays when it is the one asked for.
    if (wasOpen != index) _closeMenus();
    setState(() => _excluding = false);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_holding) return;
      _top[index].requestFocus();
      if (!open) return;
      _openAt(index);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  // Opens menu [index] and, once it is built, focuses its first item.
  void _openAt(int index) {
    if (!_isOpen[index]) _controllers[index].open();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _holding && _firstNode[index].context != null) {
        _firstNode[index].requestFocus();
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  // The arrows at a top-level button: Left and Right go to the next menu (open
  // when the one left was), Down and Up open the menu.
  // Returns whether the key was used.
  bool _barKey(LogicalKeyboardKey key) {
    final focus = FocusManager.instance.primaryFocus;
    final i = _top.indexWhere((n) => identical(n, focus));
    if (key == LogicalKeyboardKey.escape && !_isOpen.contains(true)) {
      // Escape at the bar (no menu open): back to where the focus was.
      _exit(restoreFocus: true);
      return true;
    }
    if (i < 0) return false;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft) {
      final j =
          (i + (key == LogicalKeyboardKey.arrowRight ? 1 : _titles.length - 1)) % _titles.length;
      final wasOpen = _isOpen[i];
      if (wasOpen) _controllers[i].close();
      _top[j].requestFocus();
      if (wasOpen) _openAt(j);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      _openAt(i);
      return true;
    }
    return false;
  }

  bool _usable(FocusNode? node) {
    if (node == null) return false;
    try {
      return node.context?.mounted == true && node.canRequestFocus;
    } on Object {
      return false;
    }
  }

  void _restoreFocus(FocusNode? origin) {
    if (_usable(origin)) {
      origin!.requestFocus();
    } else {
      widget.focusCanvas();
    }
  }

  // Ends the hold, once, on the controller it was taken on. With
  // [restoreFocus] the focus goes back to the origin first and the release
  // follows after the frame that applied it (so the editor regains focus
  // while still held); without it the release is at once.
  void _exit({required bool restoreFocus}) {
    _altArmed = false;

    _closeMenus();
    final was = _holding;
    final controller = _holdController;
    final origin = _origin;
    _holding = false;
    _holdController = null;
    _origin = null;
    _barFocused = false;
    final building = SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks;
    void finish() {
      if (mounted && !_excluding) setState(() => _excluding = true);
      controller?.editorFocusHold.release();
    }

    if (!was) {
      if (_excluding) return;
      if (building) {
        SchedulerBinding.instance.addPostFrameCallback((_) => finish());
      } else {
        finish();
      }
      return;
    }
    if (restoreFocus) {
      _restoreFocus(origin);
      SchedulerBinding.instance.addPostFrameCallback((_) => finish());
      SchedulerBinding.instance.scheduleFrame();
    } else {
      controller?.editorFocusHold.release();
      if (building) {
        SchedulerBinding.instance.addPostFrameCallback((_) => finish());
      } else if (mounted && !_excluding) {
        setState(() => _excluding = true);
      }
    }
  }

  void _outsidePress() {
    if (_holding) _exit(restoreFocus: false);
  }

  // Menu entries -----------------------------------------------------------

  _Target _target({String? binderPath}) {
    final nb = widget.notebook;
    return _Target(
      controller: nb.current,
      pageId: nb.currentId,
      coverPath: nb.coverPath,
      cover: nb.cover,
      registry: widget.canvas.value,
      binderPath: binderPath,
    );
  }

  _Item _fromCommand(
    _Kind kind,
    Command c, {
    bool enabled = true,
    bool destructive = false,
    String? binderPath,
    String? label,
  }) => _Item(
    kind: kind,
    id: c.id,
    label: label ?? c.label,
    enabled: enabled && c.enabled,
    shortcut: menuShortcutFor(c),
    checked: c.checked,
    destructive: destructive,
    binderPath: binderPath,
  );

  List<_Entry> _file() {
    final nb = widget.notebook;
    final ok = _loadSucceeded;
    final header = _headerRegistry();
    final items = <_Entry>[
      for (final c in header.commands) _fromCommand(_Kind.header, c, enabled: ok),
    ];
    header.dispose();
    final id = nb.currentId;
    final meta = id == null || nb.cover != null ? null : nb.treeOfPage(id)[id];
    if (meta != null) {
      final r = pageCommands(nb, meta, _proxy);
      items
        ..add(const _Divider())
        ..add(
          _Sub('Page', [
            for (final c in r.commands)
              _fromCommand(_Kind.page, c, enabled: ok, destructive: c.id == AppCommands.delete),
          ]),
        );
      r.dispose();
    }
    final binder = _binderShown();
    if (binder != null) {
      final r = binderCommands(nb, binder, _proxy);
      final hidden = {AppCommands.binderNewPage, AppCommands.binderNewPageFromTemplate};
      final children = <_Entry>[
        for (final c in r.commands)
          if (!hidden.contains(c.id))
            _fromCommand(_Kind.binder, c, enabled: ok, binderPath: binder.path),
      ];
      r.dispose();
      items.add(_Sub('Binder', children));
    }
    return items;
  }

  // The open page's binder, or the cover's; null for a standalone page.
  BinderSection? _binderShown() {
    final nb = widget.notebook;
    final path = nb.cover?.path ?? (nb.currentId == null ? null : nb.binderOfPage(nb.currentId!));
    if (path == null) return null;
    for (final b in nb.binders) {
      if (b.path == path) return b;
    }
    return null;
  }

  // The canvas registry the canvas items read: none on a cover or with no page.
  CommandRegistry? get _liveRegistry {
    final nb = widget.notebook;
    return nb.cover == null && nb.current != null ? widget.canvas.value : null;
  }

  _Item _canvasItem(String id, {String? label}) {
    final c = _liveRegistry?[id];
    if (c == null) {
      return _Item(kind: _Kind.canvas, id: id, label: label ?? _labelOf(id), enabled: false);
    }
    return _fromCommand(_Kind.canvas, c, label: label);
  }

  List<_Entry> _canvas(List<String> ids) => [for (final id in ids) _canvasItem(id)];

  // The label of a canvas command when there is no registry to read it from.
  String _labelOf(String id) => switch (id) {
    CanvasCommands.undo => 'Undo',
    CanvasCommands.redo => 'Redo',
    CanvasCommands.paste => 'Paste image or file',
    CanvasCommands.delete => 'Delete selected box',
    CanvasCommands.bringToFront => 'Bring to front',
    CanvasCommands.bringForward => 'Bring forward',
    CanvasCommands.sendBackward => 'Send backward',
    CanvasCommands.sendToBack => 'Send to back',
    CanvasCommands.find => 'Find on page',
    CanvasCommands.findNext => 'Find next',
    CanvasCommands.findPrevious => 'Find previous',
    CanvasCommands.zoomIn => 'Zoom in',
    CanvasCommands.zoomOut => 'Zoom out',
    CanvasCommands.zoomReset => 'Zoom to 100%',
    CanvasCommands.fitAll => 'Fit all',
    'canvas.showIssues' => 'Show page issues',
    _ => id,
  };

  _Item _appItem(String id) {
    final c = _app(id);
    if (c == null) return _Item(kind: _Kind.app, id: id, label: id, enabled: false);
    return _fromCommand(_Kind.app, c);
  }

  List<_Entry> _edit() => [
    ..._canvas([CanvasCommands.undo, CanvasCommands.redo]),
    const _Divider(),
    ..._canvas([CanvasCommands.paste, CanvasCommands.delete]),
    const _Divider(),
    ..._canvas([
      CanvasCommands.bringToFront,
      CanvasCommands.bringForward,
      CanvasCommands.sendBackward,
      CanvasCommands.sendToBack,
    ]),
    const _Divider(),
    ..._canvas([CanvasCommands.find, CanvasCommands.findNext, CanvasCommands.findPrevious]),
    _appItem(AppCommands.search),
  ];

  List<_Entry> _view() => [
    ..._canvas([
      CanvasCommands.zoomIn,
      CanvasCommands.zoomOut,
      CanvasCommands.zoomReset,
      CanvasCommands.fitAll,
    ]),
    const _Divider(),
    _Sub('Page background', [
      // Inside Page background the choices are named for the background alone.
      for (final b in PageBackground.values)
        _canvasItem(CanvasCommands.pageBackgroundOf(b), label: pageBackgroundLabel(b)),
    ]),
    ..._canvas(['canvas.showIssues']),
    const _Divider(),
    if (widget.settings != null) ...[
      _Sub('Theme', [for (final s in ThemeSetting.values) _appItem(AppCommands.themeId(s))]),
      _Sub('Toolbar', [for (final s in ToolbarStyle.values) _appItem(AppCommands.toolbarId(s))]),
    ],
    _appItem(AppCommands.viewPanel),
  ];

  List<_Entry> _help() => [
    _appItem(AppCommands.helpShortcuts),
    if (widget.microsoft != null) _appItem(AppCommands.helpAbout),
  ];

  // Choosing an item ---------------------------------------------------------

  // The menu closes, the focus goes back to where it was, and the command runs
  // after the frame, so it sees what a toolbar click leaves (0068) and the
  // target is checked again then.
  void _choose(_Item item) {
    final target = _target(binderPath: item.binderPath);
    final origin = _origin;
    final wasHolding = _holding;
    _exit(restoreFocus: wasHolding);
    SchedulerBinding.instance.addPostFrameCallback((_) => unawaited(_run(item, target, origin)));
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Test hook: awaited when a chosen command's deferred frame arrives, before
  /// its target is checked, so a test can change the world in that window.
  @visibleForTesting
  Future<void> Function()? debugBeforeRun;

  Future<void> _run(_Item item, _Target target, FocusNode? origin) async {
    if (!mounted) return;
    final gate = debugBeforeRun;
    if (gate != null) {
      await gate();
      if (!mounted) return;
    }

    final nb = widget.notebook;
    final registry = widget.canvas.value;
    final toPage = item.kind != _Kind.app;
    if (toPage && !target.holds(nb, registry, canvas: item.kind == _Kind.canvas)) return;
    if (toPage && item.kind != _Kind.canvas && !_loadSucceeded) return;
    _proxy.valid = () => mounted && target.holds(nb, widget.canvas.value, canvas: false);
    final temp = <CommandRegistry>[];
    try {
      final command = _resolve(item, temp, registry);
      if (command == null || command.id != item.id) return;
      await command.run();
    } finally {
      for (final r in temp) {
        r.dispose();
      }
    }
    // The box that held the focus was deleted (its editor goes at the next
    // frame): the canvas takes the focus, unless the command moved it to
    // something else (a dialog).
    if (origin == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _usable(origin)) return;
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null || _bar.hasFocus || identical(focus, FocusManager.instance.rootScope)) {
        widget.focusCanvas();
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  // The command an item stands for, made again now: page and binder commands
  // capture the page, the sibling position and the binder they were built for.
  Command? _resolve(_Item item, List<CommandRegistry> temp, CommandRegistry? registry) {
    final nb = widget.notebook;
    switch (item.kind) {
      case _Kind.app:
        return _app(item.id);
      case _Kind.canvas:
        return registry?[item.id];
      case _Kind.header:
        final r = _headerRegistry();
        temp.add(r);
        return r[item.id];
      case _Kind.page:
        final id = nb.currentId;
        final meta = id == null || nb.cover != null ? null : nb.treeOfPage(id)[id];
        if (meta == null) return null;
        final r = pageCommands(nb, meta, _proxy);
        temp.add(r);
        return r[item.id];
      case _Kind.binder:
        final b = _binderShown();
        if (b == null || b.path != item.binderPath) return null;
        final r = binderCommands(nb, b, _proxy);
        temp.add(r);
        return r[item.id];
    }
  }

  // Widgets ------------------------------------------------------------------

  ButtonStyle _itemStyle(BuildContext context, {bool destructive = false, bool bar = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = NotedColors.of(context);
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    return ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, bar ? menuBarHeight - 4 : m.rowSize)),
      maximumSize: const WidgetStatePropertyAll(Size.infinite),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: bar ? m.space2 : 10)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: m.borderMd)),
      textStyle: WidgetStatePropertyAll(type.body),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      foregroundColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return colors.textDisabled;
        return destructive ? scheme.error : scheme.onSurface;
      }),
      iconColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return colors.textDisabled;
        return destructive ? scheme.error : scheme.onSurface;
      }),
      overlayColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return null;
        if (s.contains(WidgetState.hovered) ||
            s.contains(WidgetState.focused) ||
            s.contains(WidgetState.pressed)) {
          return colors.surfaceHover;
        }
        return null;
      }),
      // Keyboard focus: a 2px accent outline.
      side: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.focused)) return BorderSide(color: scheme.primary, width: 2);
        return BorderSide.none;
      }),
    );
  }

  MenuStyle _panelStyle(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shadowColor: WidgetStatePropertyAll(m.shadowPopover.first.color),
      elevation: const WidgetStatePropertyAll(4),
      padding: WidgetStatePropertyAll(EdgeInsets.all(m.space1)),
      minimumSize: const WidgetStatePropertyAll(Size(notedMenuMinWidth, 0)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: m.borderLg,
          side: BorderSide(color: theme.colorScheme.outline),
        ),
      ),
    );
  }

  Widget _buildEntry(BuildContext context, _Entry e, {FocusNode? focusNode}) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    switch (e) {
      case _Divider():
        return Padding(
          padding: EdgeInsets.symmetric(vertical: m.space1),
          child: Divider(height: 1, thickness: 1, color: scheme.outline),
        );
      case _Sub():
        return SubmenuButton(
          key: ValueKey('menu-sub-${e.label}'),
          focusNode: focusNode,
          style: _itemStyle(context),
          menuStyle: _panelStyle(context),
          menuChildren: [for (final c in e.children) _buildEntry(context, c)],
          child: Text(e.label),
        );
      case _Item():
        return TapRegion(
          groupId: _group,
          child: MenuItemButton(
            key: ValueKey('menu-${e.id}'),
            focusNode: focusNode,
            requestFocusOnHover: false,
            style: _itemStyle(context, destructive: e.destructive),
            onPressed: e.enabled ? () => _choose(e) : null,
            leadingIcon: e.checked == null ? null : MenuCheckMark(checked: e.checked!),
            trailingIcon: e.shortcut == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(left: m.space4),
                    child: Text(
                      e.shortcut!,
                      key: const ValueKey('menu-shortcut'),
                      style: type.small.copyWith(
                        color: e.enabled
                            ? scheme.onSurfaceVariant
                            : NotedColors.of(context).textDisabled,
                      ),
                    ),
                  ),
            child: Text(e.label),
          ),
        );
    }
  }

  // The first entry a keyboard can focus: an enabled item or a submenu.
  int _firstFocusable(List<_Entry> entries) =>
      entries.indexWhere((e) => (e is _Item && e.enabled) || e is _Sub);

  Widget _topMenu(BuildContext context, int i, List<_Entry> entries) {
    final first = _firstFocusable(entries);
    return TapRegion(
      groupId: _group,
      child: MenuAnchor(
        controller: _controllers[i],
        childFocusNode: _top[i],
        style: _panelStyle(context),
        onOpen: () => _isOpen[i] = true,
        onClose: () => _isOpen[i] = false,
        menuChildren: [
          for (final (k, e) in entries.indexed)
            _buildEntry(context, e, focusNode: k == first ? _firstNode[i] : null),
        ],
        builder: (context, controller, child) => TextButton(
          key: ValueKey('menu-top-${_titles[i]}'),
          focusNode: _top[i],
          style: _itemStyle(context, bar: true),
          // With a menu open, pointing at another menu opens that one.
          onHover: (hovered) {
            if (hovered && !_isOpen[i] && _isOpen.contains(true)) {
              _closeMenus();
              controller.open();
            }
          },
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          child: Text(_titles[i]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wordmarkMinWidth;
    final menus = [_file(), _edit(), _view(), _help()];
    return SizedBox(
      height: menuBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: TapRegion(
          groupId: _group,
          onTapOutside: (_) => _outsidePress(),
          child: FocusScope(
            node: _bar,
            child: ExcludeFocus(
              excluding: _excluding,
              child: Row(
                children: [
                  SizedBox(width: m.space3),
                  BrandMark(showWordmark: wide),
                  SizedBox(width: m.space3),
                  for (var i = 0; i < 4; i++) _topMenu(context, i, menus[i]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
