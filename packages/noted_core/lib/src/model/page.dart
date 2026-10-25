// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../json/raw_json.dart';
import 'bounds.dart';

/// The page file format version this build reads and writes.
const int pageFormatVersion = 1;

/// Anything on a page: a Noted box, or a node Noted doesn't own.
sealed class CanvasNode {
  /// The node's id. A [ForeignNode] without a usable id gets a synthetic one
  /// that is never written to the file.
  String get id;

  /// Where the node sits on the page, or null if it has no usable geometry.
  Bounds? get bounds;

  /// The node as it will be written to the page file.
  RawJson toRaw();
}

/// A Noted box: a JSON Canvas node with a `noted` field.
///
/// The core reads only geometry and the `noted` header. The module's
/// `noted.data` and every field the core doesn't know are kept as raw text.
/// A record that hasn't been changed writes back its original text exactly.
final class BoxRecord extends CanvasNode {
  BoxRecord._({
    required this.fields,
    required this.noted,
    required this.id,
    required this.bounds,
    required this.typeId,
    required this.dataVersion,
    required this.rev,
    required this.baseRev,
    required this.snapshotText,
    this._source,
  });

  /// Creates a new box record.
  factory BoxRecord.create({
    required String id,
    required String typeId,
    required int dataVersion,
    required Bounds bounds,
    required RawJson data,
    required String snapshotText,
    required String rev,
  }) {
    final b = bounds.rounded();
    final noted = RawObject([
      ('type', RawJson.encode(typeId)),
      ('v', RawJson.encode(dataVersion)),
      ('rev', RawJson.encode(rev)),
      ('data', data),
    ]);
    final fields = RawObject([
      ('id', RawJson.encode(id)),
      ('type', const RawJson.trusted('"text"')),
      ..._geometryEntries(b),
      ('text', RawJson.encode(snapshotText)),
      ('noted', noted.toRaw()),
    ]);
    return BoxRecord._(
      fields: fields,
      noted: noted,
      id: id,
      bounds: b,
      typeId: typeId,
      dataVersion: dataVersion,
      rev: rev,
      baseRev: null,
      snapshotText: snapshotText,
    );
  }

  /// Reads a box from a node object, or returns null if the node isn't a
  /// well-formed Noted box.
  static BoxRecord? tryRead(RawObject fields, RawJson source) {
    final id = fields.string('id');
    final x = fields.number('x');
    final y = fields.number('y');
    final w = fields.number('width');
    final h = fields.number('height');
    final notedRaw = fields['noted'];
    if (id == null || x == null || y == null || w == null || h == null) {
      return null;
    }
    if (notedRaw == null || !notedRaw.isObject) return null;
    final noted = RawObject.parse(notedRaw.text);
    final typeId = noted.string('type');
    final v = noted.integer('v');
    if (typeId == null || v == null) return null;
    return BoxRecord._(
      fields: fields,
      noted: noted,
      id: id,
      bounds: Bounds(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()),
      typeId: typeId,
      dataVersion: v,
      rev: noted.string('rev'),
      baseRev: noted.string('baseRev'),
      snapshotText: fields.string('text') ?? '',
      source: source,
    );
  }

  /// Every field of the node, in file order.
  final RawObject fields;

  /// The `noted` header, in file order.
  final RawObject noted;

  final RawJson? _source;

  @override
  final String id;

  @override
  final Bounds bounds;

  /// The box type, for example `noted.note`.
  final String typeId;

  /// The version of the module's data schema this box was saved with.
  final int dataVersion;

  /// This box's content revision (0020).
  final String? rev;

  /// The revision this box's content was edited from (0020).
  final String? baseRev;

  /// The read-only text snapshot (0035), stored in the node's `text` field so
  /// the file stays readable in other JSON Canvas apps.
  final String snapshotText;

  /// The module's data, exactly as stored. Null if the field is absent.
  RawJson? get data => noted['data'];

  /// Returns a copy moved or resized to [next]. Content and revision are
  /// unchanged: geometry is resolved last-write-wins (0020).
  BoxRecord withBounds(Bounds next) {
    final b = next.rounded();
    if (b == bounds) return this;
    var f = fields;
    for (final (k, v) in _geometryEntries(b)) {
      f = f.set(k, v);
    }
    return BoxRecord._(
      fields: f,
      noted: noted,
      id: id,
      bounds: b,
      typeId: typeId,
      dataVersion: dataVersion,
      rev: rev,
      baseRev: baseRev,
      snapshotText: snapshotText,
    );
  }

  /// Returns a copy with new module data and snapshot. The current revision
  /// becomes the base revision and [newRev] the current one.
  BoxRecord withContent({
    required RawJson data,
    required int dataVersion,
    required String snapshotText,
    required String newRev,
  }) {
    var n = noted
        .set('v', RawJson.encode(dataVersion))
        .set('rev', RawJson.encode(newRev))
        .set('data', data);
    n = rev == null ? n.remove('baseRev') : n.set('baseRev', RawJson.encode(rev));
    final f = fields
        .set('text', RawJson.encode(snapshotText))
        .set('noted', n.toRaw());
    return BoxRecord._(
      fields: f,
      noted: n,
      id: id,
      bounds: bounds,
      typeId: typeId,
      dataVersion: dataVersion,
      rev: newRev,
      baseRev: rev,
      snapshotText: snapshotText,
    );
  }

  @override
  RawJson toRaw() => _source ?? fields.toRaw();

  static List<(String, RawJson)> _geometryEntries(Bounds b) => [
    ('x', RawJson.encode(b.x.toInt())),
    ('y', RawJson.encode(b.y.toInt())),
    ('width', RawJson.encode(b.width.toInt())),
    ('height', RawJson.encode(b.height.toInt())),
  ];
}

/// A node Noted doesn't own (no `noted` field, or a malformed one).
///
/// It is shown read-only and written back exactly as it was read.
final class ForeignNode extends CanvasNode {
  ForeignNode._(this.raw, this.id, this.bounds, this.text, this.nodeType);

  factory ForeignNode.read(RawJson raw, {required String fallbackId}) {
    if (!raw.isObject) {
      return ForeignNode._(raw, fallbackId, null, null, null);
    }
    final f = RawObject.parse(raw.text);
    final x = f.number('x');
    final y = f.number('y');
    final w = f.number('width');
    final h = f.number('height');
    final bounds = (x == null || y == null || w == null || h == null)
        ? null
        : Bounds(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
    return ForeignNode._(
      raw,
      f.string('id') ?? fallbackId,
      bounds,
      f.string('text'),
      f.string('type'),
    );
  }

  /// The node exactly as read.
  final RawJson raw;

  @override
  final String id;

  @override
  final Bounds? bounds;

  /// The node's `text` field, if any, for display.
  final String? text;

  /// The JSON Canvas node type, for example `text` or `file`.
  final String? nodeType;

  ForeignNode _withId(String newId) =>
      ForeignNode._(raw, newId, bounds, text, nodeType);

  @override
  RawJson toRaw() => raw;
}

/// The page header: the top-level `noted` object.
final class PageMeta {
  PageMeta._(
    this.fields, {
    required this.id,
    required this.parentId,
    required this.title,
    required this.order,
    required this.format,
  });

  factory PageMeta.create({
    required String id,
    String? parentId,
    required String title,
    required int order,
  }) {
    final fields = RawObject([
      ('format', RawJson.encode(pageFormatVersion)),
      ('pageId', RawJson.encode(id)),
      ('parentId', RawJson.encode(parentId)),
      ('title', RawJson.encode(title)),
      ('order', RawJson.encode(order)),
    ]);
    return PageMeta._(
      fields,
      id: id,
      parentId: parentId,
      title: title,
      order: order,
      format: pageFormatVersion,
    );
  }

  /// Reads a page header, or returns null if it is malformed.
  static PageMeta? tryRead(RawObject fields) {
    final id = fields.string('pageId');
    final format = fields.integer('format');
    if (id == null || format == null) return null;
    return PageMeta._(
      fields,
      id: id,
      parentId: fields.string('parentId'),
      title: fields.string('title') ?? '',
      order: fields.integer('order') ?? 0,
      format: format,
    );
  }

  final RawObject fields;
  final String id;

  /// The parent page's id; null for a top-level page (0027).
  final String? parentId;
  final String title;

  /// Position among siblings, ascending.
  final int order;
  final int format;

  PageMeta withTitle(String value) => _with('title', RawJson.encode(value));
  PageMeta withOrder(int value) => _with('order', RawJson.encode(value));

  PageMeta _with(String key, RawJson value) => PageMeta.tryRead(fields.set(key, value))!;
}

/// One page: its header, its nodes in z-order (first is bottom-most, as in
/// JSON Canvas) and any other top-level fields, kept verbatim.
final class Page {
  Page._(this.top, this.meta, List<CanvasNode> nodes)
    : nodes = List.unmodifiable(nodes);

  /// Creates an empty page.
  factory Page.create(PageMeta meta) => Page._(
    const RawObject([
      ('nodes', RawJson.trusted('[]')),
      ('edges', RawJson.trusted('[]')),
      ('noted', RawJson.trusted('{}')),
    ]),
    meta,
    const [],
  );

  /// Builds a page from parsed parts. Used by the page format reader.
  ///
  /// Nodes with duplicate ids are kept, but as [ForeignNode]s with synthetic
  /// ids so the canvas never confuses two nodes.
  factory Page.fromParts(RawObject top, PageMeta meta, List<CanvasNode> nodes) {
    final seen = <String>{};
    final unique = <CanvasNode>[];
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (!seen.add(n.id)) {
        final f = n is ForeignNode ? n : ForeignNode.read(n.toRaw(), fallbackId: '');
        n = f._withId('#dup$i');
      }
      unique.add(n);
    }
    return Page._(top, meta, unique);
  }

  /// Top-level fields of the file, in file order. The `nodes` and `noted`
  /// values here are stale; the writer substitutes [nodes] and [meta].
  final RawObject top;
  final PageMeta meta;
  final List<CanvasNode> nodes;

  String get id => meta.id;

  CanvasNode? node(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  int indexOf(String id) => nodes.indexWhere((n) => n.id == id);

  Page withMeta(PageMeta value) => Page._(top, value, nodes);

  Page replaceNode(CanvasNode node) {
    final i = indexOf(node.id);
    if (i < 0) return this;
    final next = [...nodes];
    next[i] = node;
    return Page._(top, meta, next);
  }

  /// Inserts [node] at [index] (clamped), or on top if [index] is null.
  Page insertNode(CanvasNode node, [int? index]) {
    final next = [...nodes];
    next.insert((index ?? next.length).clamp(0, next.length), node);
    return Page._(top, meta, next);
  }

  Page removeNode(String id) =>
      Page._(top, meta, nodes.where((n) => n.id != id).toList());

  /// The union of all node bounds, or null for an empty page.
  Bounds? get contentBounds {
    Bounds? u;
    for (final n in nodes) {
      final b = n.bounds;
      if (b == null) continue;
      u = u == null ? b : u.union(b);
    }
    return u;
  }
}
