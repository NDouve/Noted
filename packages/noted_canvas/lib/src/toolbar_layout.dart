// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A toolbar layout: an ordered list of groups, each an ordered list of
/// command ids. Groups are separated by a divider. It is plain data (strings
/// and lists), so it can be stored as JSON and later edited by the user.
/// A command id that no registered command has (a module that is off, a
/// removed command) is skipped when the toolbar is drawn.
typedef ToolbarLayout = List<List<String>>;

/// Reads a layout from decoded JSON (a list of lists of strings), or returns
/// null if [json] isn't one.
ToolbarLayout? toolbarLayoutFromJson(Object? json) {
  if (json is! List) return null;
  final groups = <List<String>>[];
  for (final g in json) {
    if (g is! List || g.any((id) => id is! String)) return null;
    groups.add(g.cast<String>().toList());
  }
  return groups;
}

/// The built-in toolbars, chosen per device in the settings.
enum ToolbarStyle {
  tabs('tabs', 'Tabs'),
  contextual('contextual', 'Contextual');

  const ToolbarStyle(this.value, this.label);

  /// How the choice is written in `settings.json`.
  final String value;
  final String label;

  /// The built-in layout for this style.
  ToolbarArrangement get layout => switch (this) {
    ToolbarStyle.tabs => tabbedToolbarLayout,
    ToolbarStyle.contextual => contextualToolbarLayout,
  };

  static ToolbarStyle? parse(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// A whole toolbar: which commands it shows, where, and when. Plain data
/// made of [ToolbarLayout]s, ids and labels, written to and read from JSON
/// with [toJson] and [ToolbarArrangement.fromJson].
sealed class ToolbarArrangement {
  const ToolbarArrangement();

  Map<String, Object?> toJson();

  /// Reads an arrangement written by [toJson], or returns null if [json]
  /// isn't one.
  static ToolbarArrangement? fromJson(Object? json) {
    if (json is! Map) return null;
    final leading = toolbarLayoutFromJson(json['leading']);
    final trailing = toolbarLayoutFromJson(json['trailing']);
    if (leading == null || trailing == null) return null;
    switch (json['kind']) {
      case 'tabs':
        final tabs = json['tabs'];
        if (tabs is! List) return null;
        final out = <ToolbarTab>[];
        for (final t in tabs) {
          if (t is! Map) return null;
          final (id, label) = (t['id'], t['label']);
          final groups = toolbarLayoutFromJson(t['groups']);
          if (id is! String || label is! String || groups == null) return null;
          out.add(ToolbarTab(id: id, label: label, groups: groups));
        }
        return TabbedToolbarLayout(
          leading: leading,
          tabs: out,
          trailing: trailing,
        );
      case 'contextual':
        final sections = json['sections'];
        if (sections is! List) return null;
        final out = <ContextualSection>[];
        for (final s in sections) {
          if (s is! Map) return null;
          final (id, checked, enabled) =
              (s['id'], s['whileChecked'], s['whileEnabled'] ?? false);
          final groups = toolbarLayoutFromJson(s['groups']);
          if (id is! String ||
              groups == null ||
              (checked != null && checked is! String) ||
              enabled is! bool) {
            return null;
          }
          out.add(
            ContextualSection(
              id: id,
              groups: groups,
              whileChecked: checked as String?,
              whileEnabled: enabled,
            ),
          );
        }
        return ContextualToolbarLayout(
          leading: leading,
          sections: out,
          trailing: trailing,
        );
    }
    return null;
  }
}

/// One tab of a [TabbedToolbarLayout]: its label and its commands.
final class ToolbarTab {
  const ToolbarTab({
    required this.id,
    required this.label,
    required this.groups,
  });

  /// Stable: tests and a saved layout refer to the tab by it.
  final String id;
  final String label;
  final ToolbarLayout groups;

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'groups': groups};
}

/// A row of tabs above the commands of the chosen tab. [leading] (left of
/// the tabs) and [trailing] (at the right end) are always visible.
final class TabbedToolbarLayout extends ToolbarArrangement {
  const TabbedToolbarLayout({
    this.leading = const [],
    required this.tabs,
    this.trailing = const [],
  });

  final ToolbarLayout leading;
  final List<ToolbarTab> tabs;
  final ToolbarLayout trailing;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'tabs',
    'leading': leading,
    'tabs': [for (final t in tabs) t.toJson()],
    'trailing': trailing,
  };
}

/// One middle section of a [ContextualToolbarLayout] and when it shows.
///
/// The first section whose condition holds is shown; a section with no
/// condition always holds, so it belongs last.
final class ContextualSection {
  const ContextualSection({
    required this.id,
    required this.groups,
    this.whileChecked,
    this.whileEnabled = false,
  });

  final String id;
  final ToolbarLayout groups;

  /// Shown while the command with this id is checked (the pen is the active
  /// tool).
  final String? whileChecked;

  /// Shown while any of the section's own commands is enabled (the text
  /// commands are enabled only while the caret is in a note).
  final bool whileEnabled;

  bool get unconditional => whileChecked == null && !whileEnabled;

  Map<String, Object?> toJson() => {
    'id': id,
    'groups': groups,
    'whileChecked': ?whileChecked,
    if (whileEnabled) 'whileEnabled': true,
  };
}

/// One bar: [leading] at the left and [trailing] at the right are always
/// visible; between them a shaded section swaps with the context (see
/// [ContextualSection]).
final class ContextualToolbarLayout extends ToolbarArrangement {
  const ContextualToolbarLayout({
    required this.leading,
    required this.sections,
    required this.trailing,
  });

  final ToolbarLayout leading;
  final List<ContextualSection> sections;
  final ToolbarLayout trailing;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'contextual',
    'leading': leading,
    'sections': [for (final s in sections) s.toJson()],
    'trailing': trailing,
  };
}

// The built-in layouts. Ids of commands that don't exist yet (image, AI
// box, highlighter...) have disabled placeholders (toolbar_placeholders.dart).

const List<String> _undoRedo = ['canvas.undo', 'canvas.redo'];
const List<String> _tools = [
  'canvas.select',
  'noted.drawing.pen',
  'noted.drawing.eraser',
];
const List<String> _inkColors = [
  'noted.drawing.color.0',
  'noted.drawing.color.1',
  'noted.drawing.color.2',
  'noted.drawing.color.3',
  'noted.drawing.color.4',
];
const List<String> _inkWidths = [
  'noted.drawing.width.2',
  'noted.drawing.width.4',
  'noted.drawing.width.8',
];
const ToolbarLayout _textTools = [
  [
    'noted.note.style.paragraph',
    'noted.note.style.heading1',
    'noted.note.style.heading2',
    'noted.note.style.heading3',
  ],
  [
    'noted.note.bold',
    'noted.note.italic',
    'noted.note.underline',
    'noted.note.strikethrough',
    'noted.note.highlight',
    'noted.note.textColor',
  ],
  [
    'noted.note.bulletedList',
    'noted.note.numberedList',
    'noted.note.checkList',
    'noted.note.outdent',
    'noted.note.indent',
  ],
  ['noted.note.link', 'noted.note.clearFormatting'],
];
const ToolbarLayout _insertTools = [
  [
    'noted.note.insertTable',
    'noted.note.insertEquation',
    'noted.note.link',
    'noted.note.insertDateTime',
  ],
  [
    'noted.image.insert',
    'noted.file.insert',
    'noted.ai.insert',
    'noted.encrypted.insert',
  ],
];

/// Tabs (OneNote-style): Home, Insert, Draw and View, with Undo and Redo
/// left of the tabs and Search all pages at the right, always visible.
const TabbedToolbarLayout tabbedToolbarLayout = TabbedToolbarLayout(
  leading: [_undoRedo],
  tabs: [
    ToolbarTab(id: 'home', label: 'Home', groups: _textTools),
    ToolbarTab(id: 'insert', label: 'Insert', groups: _insertTools),
    ToolbarTab(
      id: 'draw',
      label: 'Draw',
      groups: [
        [..._tools, 'noted.drawing.highlighter', 'noted.drawing.lasso'],
        _inkColors,
        _inkWidths,
      ],
    ),
    ToolbarTab(
      id: 'view',
      label: 'View',
      groups: [
        ['canvas.zoomOut', 'canvas.zoomReset', 'canvas.zoomIn', 'canvas.fitAll'],
        ['canvas.pageBackground', 'canvas.find'],
      ],
    ),
  ],
  trailing: [
    ['app.search'],
  ],
);

/// Contextual: one bar. Tools and Undo/Redo at the left; at the right
/// Search, Fit all, the zoom level and the page background; between them
/// the pen's colors and widths while the pen is active, the text tools
/// while the caret is in a note, and the insert tools otherwise.
const ContextualToolbarLayout contextualToolbarLayout = ContextualToolbarLayout(
  leading: [_tools, _undoRedo],
  sections: [
    ContextualSection(
      id: 'pen',
      whileChecked: 'noted.drawing.pen',
      groups: [_inkColors, _inkWidths],
    ),
    ContextualSection(
      id: 'text',
      whileEnabled: true,
      // The most used of Home's text tools, so the bar fits a canvas about
      // 1100 px wide without scrolling. Table and equation insert at the
      // caret, so they come along.
      groups: [
        [
          'noted.note.bold',
          'noted.note.italic',
          'noted.note.underline',
          'noted.note.strikethrough',
          'noted.note.highlight',
        ],
        [
          'noted.note.bulletedList',
          'noted.note.numberedList',
          'noted.note.checkList',
          'noted.note.outdent',
          'noted.note.indent',
          'noted.note.clearFormatting',
        ],
        ['noted.note.insertTable', 'noted.note.insertEquation'],
      ],
    ),
    ContextualSection(id: 'insert', groups: _insertTools),
  ],
  trailing: [
    ['app.search', 'canvas.fitAll', 'canvas.zoomReset', 'canvas.pageBackground'],
  ],
);
