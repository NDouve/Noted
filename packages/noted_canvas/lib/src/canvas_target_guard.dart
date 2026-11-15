// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'canvas_controller.dart';
import 'commands.dart';

/// What a command chosen from a menu must still find when it runs: the
/// canvas's controller and registry objects and the page's id, as they were
/// when the menu opened. A menu runs its command after the frame that closed
/// it; a page opened, a rebuilt registry or another controller in between
/// means the command would act on something the user didn't choose it for.
///
/// Host only. The menu bar and the canvas's context menus use it.
class CanvasTargetGuard {
  const CanvasTargetGuard({
    required this.controller,
    required this.pageId,
    required this.registry,
  });

  final CanvasController? controller;
  final String? pageId;
  final CommandRegistry? registry;

  /// True if [controller] is the same object and still shows page [pageId];
  /// with [registry] also if the registry is the one the guard holds.
  bool holds(
    CanvasController? controller,
    String? pageId, {
    CommandRegistry? registry,
    bool checkRegistry = true,
  }) {
    if (!identical(this.controller, controller) || this.pageId != pageId) return false;
    if (controller != null && controller.isDisposed) return false;
    if (checkRegistry && (this.registry == null || !identical(this.registry, registry))) {
      return false;
    }
    return true;
  }
}
