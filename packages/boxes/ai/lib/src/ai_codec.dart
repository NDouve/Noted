// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

/// An AI box's content: what a note box stores (`{"document": {...}}`, an
/// appflowy_editor document) plus an optional `"owner"`, the id of the AI
/// connection that owns the box. Any other top-level key is kept as it was.
final class AiBoxData {
  const AiBoxData(this.json);

  /// The stored map.
  final Map<String, Object?> json;

  /// The owning connection's id, or null.
  String? get owner => aiBoxOwner(json);

  /// The note document alone, as the note box's data (no owner, no other
  /// keys).
  NoteData get note => NoteData({'document': json['document']});

  /// The same data with [owner] (removed when null).
  AiBoxData withOwner(String? owner) {
    final next = <String, Object?>{...json};
    if (owner == null) {
      next.remove(aiOwnerKey);
    } else {
      next[aiOwnerKey] = owner;
    }
    return AiBoxData(next);
  }

  /// The same data with the note document of [note], keeping the owner and
  /// every other key.
  AiBoxData withNote(NoteData note) =>
      AiBoxData({...json, 'document': note.document['document']});
}

/// The data side of the AI box (run 2026-11-01-01).
final class AiCodec extends BoxCodec<AiBoxData> {
  const AiCodec();

  static const NoteCodec _note = NoteCodec();

  @override
  String get typeId => aiBoxTypeId;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;

  @override
  AiBoxData create() => AiBoxData(_note.create().document);

  @override
  AiBoxData decode(Object? json, int storedVersion) {
    if (json is! Map<String, Object?> ||
        json['document'] is! Map<String, Object?>) {
      throw const FormatException('not an AI box document');
    }
    return AiBoxData(json);
  }

  @override
  Object? encode(AiBoxData data) => data.json;

  @override
  String snapshotText(AiBoxData data) => noteToMarkdown(data.json, markAi: true);

  @override
  AiExposure aiExposure(AiBoxData data) => AiText(snapshotText(data));

  /// Never empty: the box was put there on purpose, and opening its
  /// "Connected AI" menu takes the focus from an empty box, which would
  /// otherwise remove it before an owner could be chosen.
  @override
  bool isEmpty(AiBoxData data) => false;

  @override
  String? aiOwner(AiBoxData data) => data.owner;

  /// Writes [write]'s markdown as note blocks, each marked as AI-written
  /// ([applyAiWrite], shared with the MCP server's closed-app write). The
  /// owner and every other key stay as they were.
  @override
  AiBoxData? aiWrite(AiBoxData data, AiWrite write) => AiBoxData(applyAiWrite(data.json, write));

  /// The note box's "only added on both sides" merge ([mergeNoteJson]) on the
  /// whole stored data, so the owner and every other key are three-way merged
  /// (a key both sides changed differently is a conflict). Blocks are never
  /// rewritten, so the AI-written marks of blocks either side added (a
  /// closed-app append included) stay on them.
  @override
  MergeResult<AiBoxData> merge(AiBoxData base, AiBoxData mine, AiBoxData theirs) {
    final merged = mergeNoteJson(base.json, mine.json, theirs.json);
    return merged == null ? const Conflicted() : Merged(AiBoxData(merged));
  }
}

/// [document] (`{"document": {...}}`) without the AI-written marks that no
/// longer match their block: the user changed the text or the block type. A
/// mark is kept on a top-level block only while [isAiWritten] holds. Returns
/// [document] itself when nothing changes; otherwise a copy (the maps it was
/// given are not changed).
Map<String, Object?> stripStaleAiMarks(Map<String, Object?> document) {
  final doc = document['document'];
  if (doc is! Map<String, Object?>) return document;
  final children = doc['children'];
  if (children is! List) return document;
  var changed = false;
  final next = <Object?>[];
  for (final c in children) {
    final s = c is Map<String, Object?> ? _strip(c, top: true) : c;
    if (!identical(s, c)) changed = true;
    next.add(s);
  }
  if (!changed) return document;
  return {
    ...document,
    'document': {...doc, 'children': next},
  };
}

// Marks live on top-level blocks only; a mark anywhere else is stale.
Map<String, Object?> _strip(Map<String, Object?> node, {required bool top}) {
  var out = node;
  final data = node['data'];
  if (data is Map && data.containsKey(aiWrittenKey)) {
    if (!(top && isAiWritten(node))) {
      out = {
        ...node,
        'data': {...data}..remove(aiWrittenKey),
      };
    }
  }
  final kids = node['children'];
  if (kids is List) {
    List<Object?>? copy;
    for (var i = 0; i < kids.length; i++) {
      final k = kids[i];
      if (k is! Map<String, Object?>) continue;
      final s = _strip(k, top: false);
      if (!identical(s, k)) {
        copy ??= [...kids];
        copy[i] = s;
      }
    }
    if (copy != null) out = {...out, 'children': copy};
  }
  return out;
}
