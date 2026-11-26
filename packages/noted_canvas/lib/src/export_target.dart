// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'attachment_store.dart';
import 'canvas_controller.dart';

/// The page an export is for, captured when the user runs Export… and read
/// again before the bytes are made (Host only: it is not part of the Box
/// API). It holds what the canvas holds at that moment: the page's controller
/// (the box records the editor has committed), the attachment store and the
/// box types the page disallows. Only [PageCanvasState.captureExportTarget]
/// makes one.
final class ExportTarget {
  /// For the canvas that makes it.
  ExportTarget.internal({
    required this.controller,
    required this.pageId,
    required this.store,
    required this.disallowed,
    required this.check,
  });

  final CanvasController controller;
  final String pageId;

  /// The page's images and files, or null where there are none.
  final AttachmentStore? store;

  /// The box types the page disallowed when this was captured.
  final Set<String> disallowed;

  /// The canvas's own test of the target.
  final bool Function() check;

  /// Whether the page, controller and store are still the ones this was made
  /// for and the canvas is still on screen.
  bool get holds => check();
}
