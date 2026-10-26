// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A toolbar layout: an ordered list of groups, each an ordered list of
/// command ids. Groups are separated by a divider. It is plain data (strings
/// and lists), so it can be stored as JSON and later edited by the user.
/// A command id that no registered command has (a module that is off, a
/// removed command) is skipped when the toolbar is drawn.
typedef ToolbarLayout = List<List<String>>;

/// The default toolbar, above the canvas: tools, the pen's colors and
/// widths, undo and redo, insertions, then Fit all and the zoom level.
const ToolbarLayout defaultToolbarLayout = [
  ['canvas.select', 'noted.drawing.pen', 'noted.drawing.eraser'],
  [
    'noted.drawing.color.0',
    'noted.drawing.color.1',
    'noted.drawing.color.2',
    'noted.drawing.color.3',
  ],
  ['noted.drawing.width.2', 'noted.drawing.width.4', 'noted.drawing.width.8'],
  ['canvas.undo', 'canvas.redo'],
  ['noted.note.insertTable', 'noted.note.insertEquation'],
  ['canvas.fitAll', 'canvas.zoomReset', 'canvas.pageBackground'],
];

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
