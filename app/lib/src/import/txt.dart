// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import 'import_limits.dart';
import 'import_result.dart';

/// A `.txt` as UTF-8 (malformed bytes replaced): each run of non-empty lines
/// is one paragraph, its lines joined by line breaks; blank lines separate
/// paragraphs. No markdown.
BlocksResult txtToBlocks(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
  final blocks = <Map<String, Object?>>[];
  var lines = <String>[];
  void flush() {
    if (lines.isNotEmpty) blocks.add(notePlainParagraph(lines.join('\n')));
    lines = [];
  }

  for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
    if (line.trim().isEmpty) {
      flush();
    } else {
      lines.add(line);
    }
  }
  flush();
  if (blocks.isEmpty) throw const ImportException('has no text to import');
  return BlocksResult(blocks);
}
