// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'canvas_controller.dart';
import 'canvas_tool.dart';

/// What a box module sees of the canvas when it makes its commands
/// (Box API 0.4, `BoxModule.commands`).
///
/// One host exists per open page canvas; the commands a module makes for it
/// live as long as that canvas does.
abstract interface class CommandHost {
  /// The open page.
  CanvasController get controller;

  /// Which tool is active, shared across pages. Select a tool with
  /// [CanvasToolSelection.select], or read [CanvasToolSelection.active] to
  /// make a command that is only available with a given tool.
  CanvasToolSelection get tools;
}
