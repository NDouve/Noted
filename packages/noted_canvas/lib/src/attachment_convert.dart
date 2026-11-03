// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

import 'attachment_store.dart';
import 'canvas_controller.dart';

/// What converting a page's attachments did.
final class AttachmentConversion {
  const AttachmentConversion({
    required this.changed,
    required this.overLimit,
    this.skipped = const [],
  });

  /// How many boxes changed.
  final int changed;

  /// Ids of boxes left as they were because they kept changing (for example
  /// by sync) while their files were being converted. The caller tells the
  /// user to run the conversion again.
  final List<String> skipped;

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
  // Box ids still to convert; starts as every box.
  var work = <String>[
    for (final node in controller.page.nodes)
      if (node is BoxRecord) node.id,
  ];
  // id -> (rev the conversion started from, converted data)
  final next = <String, (String?, Object)>{};
  // id -> files left in the folder for being over the limit
  final overById = <String, List<String>>{};
  for (var attempt = 0; attempt < _maxAttempts && work.isNotEmpty; attempt++) {
    for (final id in work) {
      final node = controller.page.node(id);
      if (node is! BoxRecord) continue;
      // A type the page disallows is shown read-only: its data isn't touched.
      if (skipTypes.contains(node.typeId)) continue;
      final module = controller.modules.moduleFor(node.typeId);
      if (module == null) continue;
      final r = controller.modules.codecs.resolve(node);
      if (r is! LiveBox) continue;
      final over = <String>[];
      final data = await module.hostConvertAttachments(r.data, to, store, over);
      overById[id] = over;
      if (data == null) {
        next.remove(id);
      } else {
        next[id] = (node.rev, data);
      }
    }
    // No await from here to the commit: a box edited (or replaced by sync)
    // while its files were read is converted again, never overwritten.
    work = [
      for (final e in next.entries)
        if (_revOf(controller, e.key) != e.value.$1) e.key,
    ];
    for (final id in work) {
      next.remove(id);
    }
  }
  // Boxes that were still changing after the last attempt, and not deleted.
  final skipped = [
    for (final id in work)
      if (controller.page.node(id) is BoxRecord) id,
  ];
  final live = <String, Object?>{
    for (final e in next.entries)
      if (_revOf(controller, e.key) != null) e.key: e.value.$2,
  };
  final changed = live.isEmpty ? 0 : controller.replaceBoxData(live);
  return AttachmentConversion(
    changed: changed,
    overLimit: [for (final names in overById.values) ...names],
    skipped: skipped,
  );
}

/// How often a box that changed during its conversion is converted again.
const _maxAttempts = 3;

/// The revision of box [id] now, or null if it is gone.
String? _revOf(CanvasController controller, String id) {
  final node = controller.page.node(id);
  return node is BoxRecord ? node.rev : null;
}
