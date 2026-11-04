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
    this.failed = 0,
  });

  /// How many boxes (by id, still on the page) could not be converted because
  /// their conversion threw, for example a file that could not be stored. They
  /// are left as they were; the other boxes are converted. Host only.
  final int failed;

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
  // id -> (the box as the conversion started from it, converted data, files
  // left in the folder for being over the limit)
  final next = <String, (_Stamp, Object, List<String>)>{};
  // Boxes that needed no change, with the same start stamp and over-limit
  // files; revalidated like [next], so a notice never names a file the box
  // no longer references.
  final unchanged = <String, (_Stamp, List<String>)>{};
  // Boxes whose conversion threw (a retry that succeeds removes the id).
  final failedIds = <String>{};
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
      final stamp = _stampOf(node);
      final over = <String>[];
      Object? data;
      try {
        data = await module.hostConvertAttachments(r.data, to, store, over);
      } on Exception {
        // This box is left as it is; the others still convert.
        failedIds.add(id);
        next.remove(id);
        unchanged.remove(id);
        continue;
      }
      failedIds.remove(id);
      if (data == null) {
        next.remove(id);
        unchanged[id] = (stamp, over);
      } else {
        unchanged.remove(id);
        next[id] = (stamp, data, over);
      }
    }
    // No await from here to the commit: a box edited (or replaced by sync)
    // while its files were read is converted again, never overwritten.
    work = [
      for (final e in next.entries)
        if (!_isCurrent(controller, e.key, e.value.$1)) e.key,
      for (final e in unchanged.entries)
        if (!_isCurrent(controller, e.key, e.value.$1)) e.key,
    ];
    for (final id in work) {
      next.remove(id);
      unchanged.remove(id);
    }
  }
  // Boxes that were still changing after the last attempt (a deleted box is
  // simply gone).
  final skipped = [
    for (final id in work)
      if (controller.page.node(id) is BoxRecord) id,
  ];
  final changed = next.isEmpty
      ? 0
      : controller.replaceBoxData({
          for (final e in next.entries) e.key: e.value.$2,
        });
  return AttachmentConversion(
    changed: changed,
    // Only boxes that were converted or needed nothing: not skipped or
    // deleted ones.
    overLimit: [
      for (final e in next.entries) ...e.value.$3,
      for (final e in unchanged.entries)
        if (controller.page.node(e.key) is BoxRecord) ...e.value.$2,
    ],
    skipped: skipped,
    failed: failedIds.where((id) => controller.page.node(id) is BoxRecord).length,
  );
}

/// How often a box that changed during its conversion is converted again.
const _maxAttempts = 3;

/// A box's revision and raw data: the revision alone can't tell edits apart
/// on a box without one (a hand-edited page).
typedef _Stamp = (String?, String?);

_Stamp _stampOf(BoxRecord box) => (box.rev, box.data?.text);

/// Whether box [id] is still the way [stamp] saw it.
bool _isCurrent(CanvasController controller, String id, _Stamp stamp) {
  final node = controller.page.node(id);
  return node is BoxRecord && _stampOf(node) == stamp;
}
