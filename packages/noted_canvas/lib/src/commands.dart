// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// What a command does when invoked.
typedef CommandAction = FutureOr<void> Function();

/// Builds a command's icon when a plain [IconData] isn't enough, for example
/// an ink color swatch. [checked] is the command's current checked state.
typedef CommandIconBuilder =
    Widget Function(BuildContext context, bool checked);

/// One thing the user can do (Box API 0.4): the single description that
/// keyboard shortcuts, the toolbar and the menus are built from.
///
/// A command has a stable, namespaced [id] (`canvas.undo`,
/// `noted.drawing.pen`), a [label] and a default [icon], an optional
/// [shortcut], and what to do: [invoke]. Its state is observable: [enabled]
/// and [checked] are read live, and the command notifies its listeners when
/// either has changed since the last notification.
///
/// State changes reach the command in one of two ways: pass the [Listenable]s
/// the state depends on (the page controller, a settings object) as
/// [listenable], or call [refresh] after changing something it reads.
class Command extends ChangeNotifier {
  Command({
    required this.id,
    required this.label,
    required this.icon,
    required CommandAction invoke,
    this.shortcut,
    this.alternateShortcuts = const [],
    bool Function()? enabled,
    bool Function()? checked,
    Listenable? listenable,
    this.iconBuilder,
    this.text,
    this.showLabel = false,
    this.whileEditing = false,
    this.whileReadOnly = false,
    this.menu = const [],
  }) : _invoke = invoke,
       _enabled = enabled,
       _checked = checked,
       _listenable = listenable {
    _lastEnabled = this.enabled;
    _lastChecked = this.checked;
    _listenable?.addListener(refresh);
  }

  /// Unique and stable, namespaced: `canvas.zoomIn`, `noted.drawing.pen`.
  /// Saved layouts refer to commands by this id, so it never changes.
  final String id;
  final String label;
  final IconData icon;

  /// Replaces [icon] in a toolbar, for example with a color swatch.
  final CommandIconBuilder? iconBuilder;

  /// Text a toolbar shows instead of the icon (for example the zoom level),
  /// read live.
  final String Function()? text;

  /// A toolbar shows the label next to the icon.
  final bool showLabel;

  /// The key that invokes the command, shown in tooltips.
  final SingleActivator? shortcut;

  /// Further keys that invoke it without being shown.
  final List<SingleActivator> alternateShortcuts;

  /// The shortcut also works while a box's editor has keyboard focus. The
  /// editor owns its keys (0033), except for the few that are global, such
  /// as zoom and Escape.
  final bool whileEditing;

  /// The command also works on a read-only page.
  final bool whileReadOnly;

  /// Ids of the commands this one offers as a menu (a toolbar dropdown). A
  /// toolbar shows such a command as a button that opens the menu instead of
  /// invoking it; the listed commands come from the same registry.
  final List<String> menu;

  final CommandAction _invoke;
  final bool Function()? _enabled;
  final bool Function()? _checked;
  final Listenable? _listenable;
  late bool _lastEnabled;
  late bool? _lastChecked;

  /// Whether the command can be invoked now.
  bool get enabled => _enabled?.call() ?? true;

  /// Whether the command is "on" (the active tool, the chosen color); null
  /// for a command that has no such state.
  bool? get checked => _checked?.call();

  /// The label with its shortcut, as shown in a tooltip: `Pen (P)`.
  String get tooltip {
    final s = shortcut;
    return s == null ? label : '$label (${shortcutLabel(s)})';
  }

  /// Invokes the command unless it is disabled. True if it ran.
  Future<bool> run() async {
    if (!enabled) return false;
    await _invoke();
    return true;
  }

  /// True if [event] is one of this command's shortcuts.
  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final s = shortcut;
    if (s != null && s.accepts(event, keyboard)) return true;
    for (final a in alternateShortcuts) {
      if (a.accepts(event, keyboard)) return true;
    }
    return false;
  }

  /// Re-reads [enabled] and [checked] and notifies if either changed.
  void refresh() {
    final e = enabled;
    final c = checked;
    if (e == _lastEnabled && c == _lastChecked) return;
    _lastEnabled = e;
    _lastChecked = c;
    notifyListeners();
  }

  @override
  void dispose() {
    _listenable?.removeListener(refresh);
    super.dispose();
  }
}

/// A shortcut as shown to the user: `Ctrl+Shift+Z`, `P`, `Esc`.
String shortcutLabel(SingleActivator s) {
  final key = s.trigger;
  final name = key == LogicalKeyboardKey.escape
      ? 'Esc'
      : key.keyLabel.length == 1
      ? key.keyLabel.toUpperCase()
      : key.keyLabel;
  return [
    if (s.control) 'Ctrl',
    if (s.alt) 'Alt',
    if (s.shift) 'Shift',
    if (s.meta) 'Meta',
    name,
  ].join('+');
}

/// The commands of one context, by id.
///
/// Commands depend on context: undo acts on the open page, "insert table" on
/// the note that has focus. Rather than one global registry that has to
/// track what is current, each context has its own registry, built with the
/// things its commands act on:
///
/// - the canvas builds one per open page (`PageCanvas`): its own commands,
///   the modules' tools and the commands from `BoxModule.commands`. The
///   toolbar and the page's key handling are built from it;
/// - the app builds one per menu (a page row's, a binder's, the settings),
///   with the page or binder the menu is for.
///
/// The registry notifies its listeners when a command is added or when any
/// command's enabled or checked state changes, so a toolbar listens to one
/// object. It owns its commands and disposes them.
class CommandRegistry extends ChangeNotifier {
  final Map<String, Command> _commands = {};
  bool _disposed = false;

  /// The commands in registration order.
  Iterable<Command> get commands => _commands.values;

  /// The command with [id], or null.
  Command? operator [](String id) => _commands[id];

  /// Adds [command]. Ids are unique: a second command with the same id is
  /// refused with an [ArgumentError], whichever module it comes from.
  void register(Command command) {
    if (_commands.containsKey(command.id)) {
      throw ArgumentError.value(
        command.id,
        'command.id',
        'a command with this id is already registered',
      );
    }
    _commands[command.id] = command;
    command.addListener(notifyListeners);
    notifyListeners();
  }

  void registerAll(Iterable<Command> commands) {
    for (final c in commands) {
      register(c);
    }
  }

  /// Invokes the command with [id]. False if there is none or it is
  /// disabled.
  Future<bool> invoke(String id) async => await _commands[id]?.run() ?? false;

  /// The first enabled command that [event] triggers and that is allowed in
  /// the current context, or null (the key is then left to others).
  ///
  /// With [editing] (a box's editor has focus) only commands that work
  /// [Command.whileEditing] are considered; with [readOnly] only those that
  /// work [Command.whileReadOnly].
  Command? resolve(
    KeyEvent event, {
    bool editing = false,
    bool readOnly = false,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    for (final c in _commands.values) {
      if (editing && !c.whileEditing) continue;
      if (readOnly && !c.whileReadOnly) continue;
      if (c.enabled && c.matches(event)) return c;
    }
    return null;
  }

  /// Re-reads every command's state, notifying once if anything changed.
  void refresh() {
    for (final c in _commands.values) {
      c.refresh();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _commands.values) {
      c.removeListener(notifyListeners);
      c.dispose();
    }
    _commands.clear();
    super.dispose();
  }
}
