// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

import 'attachment_store.dart';
import 'canvas_controller.dart';

/// What converting a page's attachments did.
final class AttachmentConversion {
  const AttachmentConversion({required this.changed, required this.overLimit});

  /// How many boxes changed.
  final int changed;

  /// Names of files that stayed in the folder because they are over
  /// [embedLimitBytes].
  final List<String> overLimit;
}

/// Keeps every image and file on [controller]'s page the [to] way ("Embed
/// attachments", "Move attachments to folder"), as one undo step. Each box
/// is converted by its own module (`BoxModule.convertAttachments`); files
/// over [embedLimitBytes] and files that haven't arrived yet stay in the
/// folder. Boxes whose type is in [skipTypes] (types the page disallows) are
/// left as they are.
Future<AttachmentConversion> convertPageAttachments(
  CanvasController controller,
  AttachmentStore store,
  AttachmentStorage to, {
  Set<String> skipTypes = const {},
}) async {
  final overLimit = <String>[];
  final next = <String, Object?>{};
  for (final node in controller.page.nodes) {
    if (node is! BoxRecord) continue;
    // A type the page disallows is shown read-only: its data isn't touched.
    if (skipTypes.contains(node.typeId)) continue;
    final module = controller.modules.moduleFor(node.typeId);
    if (module == null) continue;
    final r = controller.modules.codecs.resolve(node);
    if (r is! LiveBox) continue;
    final data = await module.hostConvertAttachments(r.data, to, store, overLimit);
    if (data != null) next[node.id] = data;
  }
  final changed = next.isEmpty ? 0 : controller.replaceBoxData(next);
  return AttachmentConversion(changed: changed, overLimit: overLimit);
}
