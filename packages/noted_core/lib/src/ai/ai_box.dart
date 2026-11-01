// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// The type id of the AI box module (run 2026-11-01-01).
const String aiBoxTypeId = 'noted.ai';

/// The key in a block's `data` that marks it as written by an AI. Its value
/// is the [aiTextFingerprint] of the block's text when the AI wrote it.
const String aiWrittenKey = 'noted_ai';

/// The key in an AI box's stored data that names the owning connection.
const String aiOwnerKey = 'owner';

// The AI box stores what a note box stores, `{"document": {...}}` (the
// appflowy_editor root node), plus an optional `"owner": "<connection id>"`.
// A top-level block an AI wrote carries `"noted_ai": "<fingerprint>"` in its
// `data`. The mark only counts while it matches the block's current text, so
// a block the user edits, or a block Enter copies from an AI block and the
// user types into, stops being AI-written without anyone clearing the mark.

/// The plain text of a block of an appflowy_editor document: its text runs
/// (`delta`), or the formula of an equation, followed by its children, and for
/// a table the text of all its cells. Parts are joined with newlines.
String aiBlockText(Map<Object?, Object?> node) {
  final parts = <String>[];
  final data = node['data'];
  if (data is Map) {
    final delta = data['delta'];
    if (delta is List) {
      final b = StringBuffer();
      for (final op in delta) {
        if (op is Map && op['insert'] is String) b.write(op['insert']);
      }
      if (b.isNotEmpty) parts.add(b.toString());
    }
    if (node['type'] == 'math_equation' && data['formula'] is String) {
      final f = data['formula']! as String;
      if (f.isNotEmpty) parts.add(f);
    }
  }
  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      if (c is! Map) continue;
      final t = aiBlockText(c);
      if (t.isNotEmpty) parts.add(t);
    }
  }
  return parts.join('\n');
}

final BigInt _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

/// FNV-1a (64 bit) of the UTF-8 bytes of [text], as 16 lowercase hex
/// characters.
String aiTextFingerprint(String text) {
  var h = _fnvOffset;
  for (final byte in utf8.encode(text)) {
    h = ((h ^ BigInt.from(byte)) * _fnvPrime) & _mask64;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// The mark for [node]: the [aiTextFingerprint] of its type, a newline and its
/// [aiBlockText]. Covering the type means turning an AI paragraph into a
/// heading or a list ends the mark. Styles, a to-do tick and other `data`
/// are deliberately not covered: bolding text or ticking a box keeps it. The
/// formula of an inline equation and the target of a link are content, so
/// changing either ends the mark too.
String aiBlockFingerprint(Map<Object?, Object?> node) {
  final inline = <String>[];
  _inlineContent(node, inline);
  final extra = inline.isEmpty ? '' : '\n\u0000${inline.join('\u0000')}';
  return aiTextFingerprint('${node['type']}\n${aiBlockText(node)}$extra');
}

// The inline formulas and link targets in [node] and its children, in order.
void _inlineContent(Map<Object?, Object?> node, List<String> out) {
  final data = node['data'];
  final delta = data is Map ? data['delta'] : null;
  if (delta is List) {
    for (final op in delta) {
      final attrs = op is Map ? op['attributes'] : null;
      if (attrs is! Map) continue;
      for (final key in const ['formula', 'href']) {
        final v = attrs[key];
        if (v is String) out.add('$key:$v');
      }
    }
  }
  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      if (c is Map) _inlineContent(c, out);
    }
  }
}

/// Whether [node] (a block) is AI-written: it has the mark, its text isn't
/// empty, and the mark equals its current [aiBlockFingerprint].
bool isAiWritten(Map<Object?, Object?> node) {
  final data = node['data'];
  if (data is! Map) return false;
  final tag = data[aiWrittenKey];
  if (tag is! String) return false;
  final text = aiBlockText(node);
  return text.isNotEmpty && tag == aiBlockFingerprint(node);
}

/// A copy of [node] marked as AI-written, with the mark taken from its
/// current text. The original is not changed.
Map<String, Object?> markAiWritten(Map<Object?, Object?> node) {
  final copy = <String, Object?>{
    for (final e in node.entries) e.key.toString(): e.value,
  };
  final data = node['data'];
  final newData = <String, Object?>{
    if (data is Map) for (final e in data.entries) e.key.toString(): e.value,
  };
  newData[aiWrittenKey] = aiBlockFingerprint(node);
  copy['data'] = newData;
  return copy;
}

/// The id of the connection that owns an AI box, from its stored [data], or
/// null.
String? aiBoxOwner(Object? data) {
  if (data is! Map) return null;
  final o = data[aiOwnerKey];
  return o is String && o.isNotEmpty ? o : null;
}
