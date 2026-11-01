// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui' show Offset;

import 'attachment_store.dart';
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

  /// The page's images and files (Box API 0.7), or null where there are
  /// none.
  AttachmentStore? get attachments;

  /// The middle of the visible view in page coordinates, or null where there
  /// is no view (Box API 0.9). A command that adds a box can put it here.
  Offset? get viewCentre;

  /// Creates a box for each of [files] (Box API 0.7), each with the module
  /// that holds it best (`BoxModule.fileAffinity`), at the page point [at]
  /// or, if null, in the middle of the view; several are stacked.
  Future<void> insertFiles(List<IncomingFile> files, {Offset? at});
}
