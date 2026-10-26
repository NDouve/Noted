// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'command_host.dart';
import 'commands.dart';

/// Ids of the canvas's own commands.
abstract final class CanvasCommands {
  static const String select = 'canvas.select';
  static const String undo = 'canvas.undo';
  static const String redo = 'canvas.redo';
  static const String delete = 'canvas.delete';
  static const String escape = 'canvas.escape';
  static const String zoomIn = 'canvas.zoomIn';
  static const String zoomOut = 'canvas.zoomOut';
  static const String zoomReset = 'canvas.zoomReset';
  static const String fitAll = 'canvas.fitAll';
  static const String pageBackground = 'canvas.pageBackground';
  static const String find = 'canvas.find';
  static const String findNext = 'canvas.findNext';
  static const String findPrevious = 'canvas.findPrevious';

  /// The command that chooses [b]: `canvas.pageBackground.dots`.
  static String pageBackgroundOf(PageBackground b) => 'canvas.pageBackground.${b.name}';
}

/// What the canvas's commands act on: the open page canvas.
abstract interface class CanvasCommandTarget implements CommandHost {
  /// The page can't be changed (a read-only page or controller).
  bool get isReadOnly;

  /// The current zoom (1 is 100%).
  double get scale;

  void zoomBy(double factor);
  void zoomTo(double scale);
  void fitAll();

  /// Find on page: the find bar is showing.
  bool get isFindOpen;

  /// Opens the find bar (or focuses it if it is open).
  void openFind();

  /// Closes the find bar and clears the highlights.
  void closeFind();

  /// Steps to the next (1) or previous (-1) match.
  void stepFind(int delta);

  /// Moves keyboard focus from a box's editor to the canvas.
  void focusCanvas();
}

const double _zoomStep = 1.25;

SingleActivator _key(LogicalKeyboardKey k, {bool ctrl = false, bool shift = false}) =>
    SingleActivator(k, control: ctrl, shift: shift);

/// The canvas's commands for [t]: select, undo, redo, delete, escape, the
/// zoom commands and Fit all, plus one command for each tool of the
/// modules that are on (same id, label, icon and shortcut as the tool,
/// checked while it is the active tool).
///
/// They read [t] when they run, so they stay right as the page changes; the
/// state they show is refreshed from the page controller and the tool
/// selection.
List<Command> buildCanvasCommands(CanvasCommandTarget t) {
  final c = t.controller;
  final tools = t.tools;
  final both = Listenable.merge([c, tools]);
  return [
    Command(
      id: CanvasCommands.select,
      label: 'Select and type',
      icon: Icons.text_fields_rounded,
      shortcut: _key(LogicalKeyboardKey.keyV),
      checked: () => tools.active == null,
      listenable: tools,
      invoke: () => tools.select(null),
    ),
    for (final tool in c.modules.tools)
      Command(
        id: tool.id,
        label: tool.label,
        icon: tool.icon,
        shortcut: tool.shortcut == null ? null : _key(tool.shortcut!),
        checked: () => identical(tools.active, tool),
        listenable: tools,
        invoke: () => tools.select(tool),
      ),
    Command(
      id: CanvasCommands.undo,
      label: 'Undo',
      icon: Icons.undo_rounded,
      shortcut: _key(LogicalKeyboardKey.keyZ, ctrl: true),
      enabled: () => !t.isReadOnly && c.canUndo,
      listenable: c,
      invoke: c.undo,
    ),
    Command(
      id: CanvasCommands.redo,
      label: 'Redo',
      icon: Icons.redo_rounded,
      shortcut: _key(LogicalKeyboardKey.keyY, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.keyZ, ctrl: true, shift: true)],
      enabled: () => !t.isReadOnly && c.canRedo,
      listenable: c,
      invoke: c.redo,
    ),
    Command(
      id: CanvasCommands.delete,
      label: 'Delete selected box',
      icon: Icons.delete_outline_rounded,
      shortcut: _key(LogicalKeyboardKey.delete),
      alternateShortcuts: [_key(LogicalKeyboardKey.backspace)],
      enabled: () => !t.isReadOnly && c.selectedId != null,
      listenable: c,
      invoke: () {
        final id = c.selectedId;
        if (id != null) c.delete(id);
      },
    ),
    Command(
      id: CanvasCommands.escape,
      label: 'Deselect',
      icon: Icons.deselect_rounded,
      shortcut: _key(LogicalKeyboardKey.escape),
      whileEditing: true,
      enabled: () => !t.isReadOnly,
      listenable: both,
      invoke: () {
        // In an editor: back to the canvas and the Select tool. Otherwise the first Escape
        // leaves the tool, the next clears the selection.
        if (t.isFindOpen) {
          // The find bar closes first, then the highlights are gone.
          t.closeFind();
        } else if (c.editingId != null) {
          t.focusCanvas();
          tools.select(null);
        } else if (tools.active != null) {
          tools.select(null);
        } else {
          c.select(null);
        }
      },
    ),
    Command(
      id: CanvasCommands.zoomIn,
      label: 'Zoom in',
      icon: Icons.zoom_in_rounded,
      shortcut: _key(LogicalKeyboardKey.equal, ctrl: true),
      alternateShortcuts: [
        _key(LogicalKeyboardKey.equal, ctrl: true, shift: true),
        _key(LogicalKeyboardKey.numpadAdd, ctrl: true),
      ],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.zoomBy(_zoomStep),
    ),
    Command(
      id: CanvasCommands.zoomOut,
      label: 'Zoom out',
      icon: Icons.zoom_out_rounded,
      shortcut: _key(LogicalKeyboardKey.minus, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.numpadSubtract, ctrl: true)],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.zoomBy(1 / _zoomStep),
    ),
    Command(
      id: CanvasCommands.zoomReset,
      label: 'Zoom to 100%',
      icon: Icons.search_rounded,
      shortcut: _key(LogicalKeyboardKey.digit0, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.numpad0, ctrl: true)],
      whileEditing: true,
      whileReadOnly: true,
      text: () => '${(t.scale * 100).round()}%',
      readout: true,
      invoke: () => t.zoomTo(1),
    ),
    Command(
      id: CanvasCommands.fitAll,
      label: 'Fit all',
      icon: Icons.fit_screen_rounded,
      showLabel: true,
      whileReadOnly: true,
      invoke: t.fitAll,
    ),
    // Find on page. These work in a note editor too (appflowy has no Ctrl+F
    // of its own in this build), and on a read-only page.
    Command(
      id: CanvasCommands.find,
      label: 'Find on page',
      icon: Icons.find_in_page_rounded,
      shortcut: _key(LogicalKeyboardKey.keyF, ctrl: true),
      alternateShortcuts: [
        SingleActivator(LogicalKeyboardKey.keyF, meta: true),
      ],
      whileEditing: true,
      whileReadOnly: true,
      invoke: t.openFind,
    ),
    Command(
      id: CanvasCommands.findNext,
      label: 'Find next',
      icon: Icons.keyboard_arrow_down_rounded,
      shortcut: _key(LogicalKeyboardKey.f3),
      alternateShortcuts: [_key(LogicalKeyboardKey.keyG, ctrl: true)],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.isFindOpen ? t.stepFind(1) : t.openFind(),
    ),
    Command(
      id: CanvasCommands.findPrevious,
      label: 'Find previous',
      icon: Icons.keyboard_arrow_up_rounded,
      shortcut: _key(LogicalKeyboardKey.f3, shift: true),
      alternateShortcuts: [
        _key(LogicalKeyboardKey.keyG, ctrl: true, shift: true),
      ],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.isFindOpen ? t.stepFind(-1) : t.openFind(),
    ),
    Command(
      id: CanvasCommands.pageBackground,
      label: 'Page background',
      icon: pageBackgroundIcon(c.page.meta.background),
      iconBuilder: (_, _) => Icon(pageBackgroundIcon(c.page.meta.background)),
      enabled: () => !t.isReadOnly,
      listenable: c,
      menu: [
        for (final b in PageBackground.values) CanvasCommands.pageBackgroundOf(b),
      ],
      invoke: () {},
    ),
    for (final b in PageBackground.values)
      Command(
        id: CanvasCommands.pageBackgroundOf(b),
        label: 'Page background: ${pageBackgroundLabel(b)}',
        icon: pageBackgroundIcon(b),
        enabled: () => !t.isReadOnly,
        checked: () => c.page.meta.background == b,
        listenable: c,
        invoke: () => c.setBackground(b),
      ),
  ];
}

/// The user-facing name of [b], as in `Page background: Dots`.
String pageBackgroundLabel(PageBackground b) => switch (b) {
  PageBackground.plain => 'Plain',
  PageBackground.dots => 'Dots',
  PageBackground.graph => 'Graph',
  PageBackground.ruled => 'Ruled',
};

/// The icon for [b], shown on the toolbar's page background button.
IconData pageBackgroundIcon(PageBackground b) => switch (b) {
  PageBackground.plain => Icons.crop_square_rounded,
  PageBackground.dots => Icons.blur_on_rounded,
  PageBackground.graph => Icons.grid_on_rounded,
  PageBackground.ruled => Icons.view_headline_rounded,
};
