// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'drawing_module.dart';
import 'drawing_tools.dart';
import 'ink_color.dart';

/// Names of the pen colors, in the order of [PenSettings.colors].
const List<String> _colorNames = [
  'Default ink',
  'Blue',
  'Orange',
  'Green',
  'Purple',
];

/// Id of the command that chooses pen color number [index]
/// (`noted.drawing.color.0` ...).
String penColorCommandId(int index) => 'noted.drawing.color.$index';

/// Id of the command that chooses a pen width (`noted.drawing.width.4`).
String penWidthCommandId(double size) =>
    'noted.drawing.width.${size.toInt()}';

/// The drawing module's commands (Box API 0.4): one for each pen color and
/// each pen width. The pen and the eraser are tools, which the canvas
/// already exposes as the commands `noted.drawing.pen` and
/// `noted.drawing.eraser`.
///
/// Colors and widths are checked when they are the pen's current setting and
/// enabled only while the pen is the active tool, as they have no effect on
/// the eraser.
List<Command> drawingCommands(DrawingModule module, CommandHost host) {
  final settings = module.settings;
  final changes = Listenable.merge([settings, host.tools]);
  return [
    for (final (i, color) in PenSettings.colors.indexed)
      Command(
        id: penColorCommandId(i),
        label: 'Ink color: ${_colorNames[i]}',
        icon: Icons.circle,
        checked: () => settings.color == color,
        listenable: changes,
        iconBuilder: (context, checked) => Icon(
          checked ? Icons.radio_button_checked : Icons.circle,
          color: displayInkColor(color, Theme.of(context).brightness),
          size: NotedMetrics.of(context).icon,
        ),
        invoke: () {
          settings.color = color;
          host.tools.select(module.pen);
        },
      ),
    for (final size in PenSettings.sizes)
      Command(
        id: penWidthCommandId(size),
        label: 'Pen width ${size.toInt()}',
        icon: Icons.horizontal_rule,
        checked: () => settings.size == size,
        listenable: changes,
        iconBuilder: (context, checked) {
          final scheme = Theme.of(context).colorScheme;
          final metrics = NotedMetrics.of(context);
          return Container(
            width: metrics.icon,
            height: size + 1,
            decoration: BoxDecoration(
              color: checked ? scheme.primary : scheme.onSurfaceVariant,
              borderRadius: metrics.borderFull,
            ),
          );
        },
        invoke: () {
          settings.size = size;
          host.tools.select(module.pen);
        },
      ),
  ];
}
