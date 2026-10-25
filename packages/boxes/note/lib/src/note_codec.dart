// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports, so the codec can later
// move into a package a non-UI process can load.

import 'package:noted_core/noted_core.dart';

/// A plain note box's content: an appflowy_editor document in its native
/// JSON form (`{"document": {...}}`), as `Document.toJson()` produces it.
final class NoteData {
  const NoteData(this.document);

  final Map<String, Object?> document;
}

/// The data side of the plain note box (0015): grows with its content.
final class NoteCodec extends BoxCodec<NoteData> {
  const NoteCodec();

  static const String id = 'noted.note';

  @override
  String get typeId => id;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;

  @override
  NoteData create() => const NoteData({
    'document': {
      'type': 'page',
      'children': [
        {
          'type': 'paragraph',
          'data': {'delta': <Object?>[]},
        },
      ],
    },
  });

  @override
  NoteData decode(Object? json, int storedVersion) {
    if (json is! Map<String, Object?> ||
        json['document'] is! Map<String, Object?>) {
      throw const FormatException('not a note document');
    }
    return NoteData(json);
  }

  @override
  Object? encode(NoteData data) => data.document;

  /// One line per block, in document order.
  @override
  String snapshotText(NoteData data) {
    final lines = <String>[];
    _walk(data.document['document'], (node, text) {
      if (text != null) lines.add(text);
      return true;
    });
    return lines.join('\n');
  }

  /// Empty means only blank paragraphs: any other block (a divider, a
  /// table, an image) counts as content.
  @override
  bool isEmpty(NoteData data) {
    var empty = true;
    _walk(data.document['document'], (node, text) {
      final type = node['type'];
      if ((type != 'page' && type != 'paragraph') ||
          (text != null && text.trim().isNotEmpty)) {
        empty = false;
      }
      return empty;
    });
    return empty;
  }

  @override
  AiExposure aiExposure(NoteData data) => AiText(snapshotText(data));
}

/// Visits each block depth-first with its plain text (null if it has no
/// text). Stops when [visit] returns false.
bool _walk(
  Object? node,
  bool Function(Map<String, Object?> node, String? text) visit,
) {
  if (node is! Map<String, Object?>) return true;
  final data = node['data'];
  String? text;
  if (data is Map<String, Object?> && data['delta'] is List) {
    final b = StringBuffer();
    for (final op in data['delta']! as List) {
      if (op is Map && op['insert'] is String) b.write(op['insert']);
    }
    text = b.toString();
  }
  if (!visit(node, text)) return false;
  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      if (!_walk(c, visit)) return false;
    }
  }
  return true;
}
