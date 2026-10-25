// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../json/raw_json.dart';
import '../model/page.dart';

/// The page file isn't a readable Noted page.
final class PageFormatException implements Exception {
  const PageFormatException(this.message);

  final String message;

  @override
  String toString() => 'PageFormatException: $message';
}

/// The page was written by a newer app with a format this build can't read.
/// The file must not be overwritten.
final class UnsupportedPageFormatException extends PageFormatException {
  const UnsupportedPageFormatException(this.format)
    : super('page format $format is newer than $pageFormatVersion');

  final int format;
}

/// Reads a page file (JSON Canvas 1.0 with Noted extra fields, 0006).
NotedPage readPage(String source) {
  const bom = 0xFEFF;
  if (source.isNotEmpty && source.codeUnitAt(0) == bom) {
    source = source.substring(1);
  }
  final RawObject top;
  try {
    top = RawObject.parse(source);
  } on FormatException catch (e) {
    throw PageFormatException('not valid JSON: ${e.message} at ${e.offset}');
  }

  final notedRaw = top['noted'];
  if (notedRaw == null || !notedRaw.isObject) {
    throw const PageFormatException('no Noted page header');
  }
  final meta = PageMeta.tryRead(RawObject.parse(notedRaw.text));
  if (meta == null) throw const PageFormatException('malformed page header');
  if (meta.format > pageFormatVersion) {
    throw UnsupportedPageFormatException(meta.format);
  }

  final nodesRaw = top['nodes'];
  final items = nodesRaw == null
      ? const <RawJson>[]
      : nodesRaw.isArray
      ? JsonSpanReader.readArray(nodesRaw.text)
      : throw const PageFormatException('"nodes" is not an array');

  final nodes = <CanvasNode>[];
  for (var i = 0; i < items.length; i++) {
    final raw = items[i];
    BoxRecord? box;
    if (raw.isObject) box = BoxRecord.tryRead(RawObject.parse(raw.text), raw);
    nodes.add(box ?? ForeignNode.read(raw, fallbackId: '#node$i'));
  }
  return NotedPage.fromParts(top, meta, nodes);
}

/// Writes a page file. Top-level fields keep their order, each node is
/// written on its own line, and every value the core didn't change is
/// emitted verbatim.
String writePage(NotedPage page) {
  final out = <(String, String)>[];
  var wroteNodes = false;
  var wroteMeta = false;
  for (final (k, v) in page.top.entries) {
    if (k == 'nodes') {
      if (wroteNodes) continue;
      out.add((k, _nodes(page)));
      wroteNodes = true;
    } else if (k == 'noted') {
      if (wroteMeta) continue;
      out.add((k, page.meta.fields.toRaw().text));
      wroteMeta = true;
    } else {
      out.add((k, v.text));
    }
  }
  if (!wroteNodes) out.insert(0, ('nodes', _nodes(page)));
  if (!wroteMeta) out.add(('noted', page.meta.fields.toRaw().text));

  final b = StringBuffer('{\n');
  for (var i = 0; i < out.length; i++) {
    final (k, v) = out[i];
    b.write('  ${RawJson.encode(k).text}: $v');
    b.write(i == out.length - 1 ? '\n' : ',\n');
  }
  b.write('}\n');
  return b.toString();
}

String _nodes(NotedPage page) {
  if (page.nodes.isEmpty) return '[]';
  final b = StringBuffer('[\n');
  for (var i = 0; i < page.nodes.length; i++) {
    b.write('    ${page.nodes[i].toRaw().text}');
    b.write(i == page.nodes.length - 1 ? '\n' : ',\n');
  }
  b.write('  ]');
  return b.toString();
}
