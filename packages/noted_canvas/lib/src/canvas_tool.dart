// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'canvas_controller.dart';
import 'noted_colors.dart';

/// A tool a box module adds to the canvas (Box API 0.2), such as the pen.
///
/// While a tool is active it receives every pointer that goes down on the
/// canvas (any button but the middle one, which still pans); boxes receive
/// none. The canvas itself knows nothing about what the tool does.
abstract class CanvasTool {
  const CanvasTool();

  /// Unique and stable, for example `noted.drawing.pen`.
  String get id;
  String get label;
  IconData get icon;

  /// Selects the tool when pressed while no box is being edited.
  LogicalKeyboardKey? get shortcut => null;

  MouseCursor get cursor => SystemMouseCursors.precise;

  /// Extra controls shown in the toolbar while the tool is active.
  Widget? buildOptions(BuildContext context) => null;

  /// A pointer went down with this tool active. Return a session to receive
  /// the rest of that pointer's events, or null to ignore the pointer.
  ToolSession? start(ToolContext context, ToolPointer pointer);
}

/// One pointer's use of a tool, from down to up.
///
/// The canvas holds the pointer for the whole session and doesn't change
/// the page's bounds until it ends (0016).
abstract class ToolSession {
  void update(ToolPointer pointer);

  /// The pointer went up. The session commits its result here, in the same
  /// frame the overlay stops showing it.
  void end();

  void cancel();

  /// Paints live feedback, for example the stroke being drawn, above
  /// everything on the page. [canvas] is in page coordinates; [scale] is the
  /// current zoom.
  void paint(Canvas canvas, double scale);
}

/// A pointer sample, in page coordinates.
@immutable
final class ToolPointer {
  const ToolPointer({
    required this.position,
    required this.kind,
    required this.time,
    this.pressure,
  });

  final Offset position;
  final PointerDeviceKind kind;

  /// The event's timestamp.
  final Duration time;

  /// 0 to 1 from a pressure-sensitive device; null for a mouse.
  final double? pressure;
}

/// What a tool session can use.
abstract interface class ToolContext {
  CanvasController get controller;

  /// The current zoom.
  double get scale;

  /// The theme's brightness, for feedback colored to suit it.
  Brightness get brightness;

  /// The theme's app-specific colors.
  NotedColors get colors;

  /// Repaints the session's overlay. Call after each update that changes it.
  void repaintOverlay();
}

/// Which tool is active. Shared across pages, so the choice survives a page
/// switch. Null is the built-in select/type tool.
class CanvasToolSelection extends ChangeNotifier {
  CanvasTool? _active;

  CanvasTool? get active => _active;

  void select(CanvasTool? tool) {
    if (identical(tool, _active)) return;
    _active = tool;
    notifyListeners();
  }
}
