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

  /// When the running command was chosen from a context menu at a page point
  /// (Box API 0.16): that point and a validity check, during the synchronous
  /// start of `invoke` only, else null. Read it before your first `await`.
  /// After an `await`, insert nothing unless [CommandInvocation.isCurrent] is
  /// true.
  CommandInvocation? get invocation;
}

/// Where a context-menu command was chosen (Box API 0.16). Made by the host.
final class CommandInvocation {
  CommandInvocation(this.anchor, this._isCurrent);

  /// The page point the menu was opened at.
  final Offset anchor;

  final bool Function() _isCurrent;

  /// True while the canvas that made this is still open on the same page, with
  /// the same controller and commands, and the page can be changed. Check it
  /// after an `await` before inserting at [anchor].
  bool get isCurrent => _isCurrent();
}
