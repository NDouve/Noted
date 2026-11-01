// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../json/raw_json.dart';
import '../model/page.dart';
import 'page_format.dart';

/// Replaces the content of the box [boxId] in the page file [pageText] and
/// returns the new file text, or null if there is no such box or the file
/// can't be read (damaged, or written by a newer format: such a file must
/// not be changed).
///
/// This is a splice, not a rewrite: only the text of that one box record is
/// replaced, and every other byte of [pageText], including the whitespace and
/// layout of the other boxes, is kept exactly as it was (invariant 2). The
/// record is changed the way `commitBox` changes it: `data`, `v` (the data
/// version), the snapshot text, a new revision [newRev] with the old one as
/// `baseRev`, and the edited-by [device] and edited-at [at] stamps (a stamp
/// left null is removed). Geometry and every field the core doesn't know are
/// kept.
String? spliceBoxContent(
  String pageText,
  String boxId, {
  required RawJson data,
  required int dataVersion,
  required String snapshotText,
  required String newRev,
  String? device,
  int? at,
}) {
  try {
    final bom = pageText.isNotEmpty && pageText.codeUnitAt(0) == 0xFEFF ? 1 : 0;
    final source = bom == 0 ? pageText : pageText.substring(bom);
    // Reading the page first applies the same checks as opening it.
    readPage(source);
    final top = JsonSpanReader.objectEntrySpans(source);
    (String, int, int)? nodes;
    for (final e in top) {
      if (e.$1 == 'nodes') {
        nodes = e;
        break;
      }
    }
    if (nodes == null) return null;
    final array = source.substring(nodes.$2, nodes.$3);
    for (final (start, end) in JsonSpanReader.arrayItemSpans(array)) {
      final raw = RawJson.trusted(array.substring(start, end));
      if (!raw.isObject) continue;
      final box = BoxRecord.tryRead(RawObject.parse(raw.text), raw);
      if (box == null || box.id != boxId) continue;
      final next = box.withContent(
        data: data,
        dataVersion: dataVersion,
        snapshotText: snapshotText,
        newRev: newRev,
        device: device,
        at: at,
      );
      final from = bom + nodes.$2 + start;
      final to = bom + nodes.$2 + end;
      return pageText.replaceRange(from, to, next.toRaw().text);
    }
  } on FormatException {
    return null;
  } on PageFormatException {
    return null;
  }
  return null;
}
