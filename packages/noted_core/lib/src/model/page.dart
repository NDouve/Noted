// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../json/raw_json.dart';
import 'bounds.dart';

/// The page file format version this build reads and writes.
const int pageFormatVersion = 1;

/// How a page's canvas is drawn behind its boxes. Decoration only: it is a
/// page header field and never part of a box snapshot or the text snapshot.
enum PageBackground {
  plain,
  dots,
  graph,
  ruled;

  /// The background named [value]; null or an unknown name is [plain].
  static PageBackground parse(String? value) {
    for (final b in values) {
      if (b.name == value) return b;
    }
    return plain;
  }
}

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
    String? device,
    int? at,
  }) {
    final b = bounds.rounded();
    final noted = RawObject([
      ('type', RawJson.encode(typeId)),
      ('v', RawJson.encode(dataVersion)),
      ('rev', RawJson.encode(rev)),
      ('data', data),
      if (device != null) ('device', RawJson.encode(device)),
      if (at != null) ('at', RawJson.encode(at)),
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

  /// The computer that last wrote this box's content (`noted.device`), or
  /// null if unknown.
  String? get device => noted.string('device');

  /// When this box's content was last written (`noted.at`, ms since the
  /// epoch), or null if unknown.
  int? get editedAt => noted.integer('at');

  /// The user set this box's height. A box whose type grows with its content
  /// stops growing and scrolls internally instead. Stored as
  /// `"fixedHeight": true` in the `noted` header; absent means false.
  bool get fixedHeight => noted['fixedHeight']?.text == 'true';

  /// Returns a copy with [fixedHeight] set to [value].
  BoxRecord withFixedHeight(bool value) {
    if (value == fixedHeight) return this;
    return _withNoted(
      value
          ? noted.set('fixedHeight', const RawJson.trusted('true'))
          : noted.remove('fixedHeight'),
    );
  }

  /// The other versions of this box recorded by merges (0020), in the order
  /// they were recorded. Empty if the box isn't conflicted.
  List<BoxConflict> get conflicts {
    final raw = noted['conflicts'];
    if (raw == null || !raw.isArray) return const [];
    try {
      return [
        for (final item in JsonSpanReader.readArray(raw.text))
          ?BoxConflict.tryRead(item),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Whether a merge left another version of this box unresolved.
  bool get isConflicted => noted.containsKey('conflicts') && conflicts.isNotEmpty;

  /// Returns a copy with [conflict] added to [conflicts]. Every other field
  /// is kept as written.
  BoxRecord withConflict(BoxConflict conflict) =>
      withConflicts([...conflicts, conflict]);

  /// Returns a copy whose [conflicts] are [value]; empty removes the field.
  BoxRecord withConflicts(List<BoxConflict> value) {
    if (value.isEmpty) return withoutConflicts();
    final text = '[${value.map((c) => c.raw.text).join(',')}]';
    if (noted['conflicts']?.text == text) return this;
    return _withNoted(noted.set('conflicts', RawJson.trusted(text)));
  }

  /// Returns a copy without [conflicts].
  BoxRecord withoutConflicts() =>
      noted.containsKey('conflicts') ? _withNoted(noted.remove('conflicts')) : this;

  /// Returns a copy with another id; nothing else changes.
  BoxRecord withId(String value) {
    if (value == id) return this;
    return BoxRecord._(
      fields: fields.set('id', RawJson.encode(value)),
      noted: noted,
      id: value,
      bounds: bounds,
      typeId: typeId,
      dataVersion: dataVersion,
      rev: rev,
      baseRev: baseRev,
      snapshotText: snapshotText,
    );
  }

  BoxRecord _withNoted(RawObject n) => BoxRecord._(
    fields: fields.set('noted', n.toRaw()),
    noted: n,
    id: id,
    bounds: bounds,
    typeId: typeId,
    dataVersion: dataVersion,
    rev: rev,
    baseRev: baseRev,
    snapshotText: snapshotText,
  );

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
  ///
  /// [device] and [at] stamp who wrote the content and when; a stamp left
  /// null is removed, so the header never describes older content.
  BoxRecord withContent({
    required RawJson data,
    required int dataVersion,
    required String snapshotText,
    required String newRev,
    String? device,
    int? at,
  }) {
    var n = noted
        .set('v', RawJson.encode(dataVersion))
        .set('rev', RawJson.encode(newRev))
        .set('data', data);
    n = device == null ? n.remove('device') : n.set('device', RawJson.encode(device));
    n = at == null ? n.remove('at') : n.set('at', RawJson.encode(at));
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

/// Another version of a box that a merge couldn't combine (0020), recorded in
/// the box's `noted` header as `"conflicts":[...]`:
///
/// - `{"node":<the other version's whole node>,"at":<ms since epoch>}`, plus
///   `"device":"<computer name>"` when the other version's box says which
///   computer wrote it
/// - `{"deleted":true,"at":<ms>}` when the other side deleted the box while
///   this one edited it.
///
/// The node is kept as raw text, so a device that can't run the box carries
/// it through untouched.
final class BoxConflict {
  const BoxConflict._(this.raw, this.node, this.deleted, this.at, this.device);

  /// The other version of the box, saved at [at] (ms since the epoch) on the
  /// computer called [device], if known.
  factory BoxConflict.other({required RawJson node, required int at, String? device}) =>
      BoxConflict._(
        RawJson.trusted(
          '{"node":${node.text},"at":$at'
          '${device == null ? '' : ',"device":${RawJson.encode(device).text}'}}',
        ),
        node,
        false,
        at,
        device,
      );

  /// The other side deleted the box.
  factory BoxConflict.deleted({required int at}) =>
      BoxConflict._(RawJson.trusted('{"deleted":true,"at":$at}'), null, true, at, null);

  /// Reads one entry of a `conflicts` array, or returns null if malformed.
  static BoxConflict? tryRead(RawJson raw) {
    if (!raw.isObject) return null;
    try {
      final o = RawObject.parse(raw.text);
      final node = o['node'];
      final deleted = o['deleted']?.text == 'true';
      if (node == null && !deleted) return null;
      return BoxConflict._(raw, node, deleted, o.integer('at') ?? 0, o.string('device'));
    } on FormatException {
      return null;
    }
  }

  /// The entry exactly as stored.
  final RawJson raw;

  /// The other version's node; null if [deleted].
  final RawJson? node;

  /// The other side deleted the box.
  final bool deleted;

  /// When the other version was saved, in ms since the epoch.
  final int at;

  /// The computer that wrote the other version, if it said so.
  final String? device;

  @override
  bool operator ==(Object other) => other is BoxConflict && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

/// Whether any box on [page] has an unresolved conflict (0020).
bool hasConflicts(NotedPage page) =>
    page.nodes.any((n) => n is BoxRecord && n.isConflicted);

/// Reads one node of a page: a [BoxRecord] if it is a well-formed Noted box,
/// otherwise a [ForeignNode].
CanvasNode readNode(RawJson raw, {required String fallbackId}) {
  BoxRecord? box;
  if (raw.isObject) {
    try {
      box = BoxRecord.tryRead(RawObject.parse(raw.text), raw);
    } on FormatException {
      box = null;
    }
  }
  return box ?? ForeignNode.read(raw, fallbackId: fallbackId);
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

  /// Returns a copy with another id, written into the node's `id` field.
  /// Null if the node isn't a JSON object.
  ForeignNode? copyWithId(String newId) {
    if (!raw.isObject) return null;
    final o = RawObject.parse(raw.text).set('id', RawJson.encode(newId));
    return ForeignNode.read(o.toRaw(), fallbackId: newId);
  }

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

  /// Returns a copy under [value] (null: top level). Only the `parentId`
  /// header value changes; every other field is kept as written.
  PageMeta withParent(String? value) => _with('parentId', RawJson.encode(value));

  /// Returns a copy with a new parent and position among siblings.
  PageMeta withPlacement({required String? parentId, required int order}) =>
      withParent(parentId).withOrder(order);

  /// The page background (`"background"` in the header). A missing value, a
  /// value that isn't a string and a value this build doesn't know all read
  /// as [PageBackground.plain]; the stored value is left as written until the
  /// user picks a background ([withBackground]).
  PageBackground get background =>
      PageBackground.parse(fields.string('background'));

  /// The stored `background` value exactly as written, or null if absent.
  RawJson? get rawBackground => fields['background'];

  /// Returns a copy with [value] chosen. Plain removes the key (so a plain
  /// page's header is the same as before backgrounds existed); the others
  /// write `"dots"`, `"graph"` or `"ruled"`. Choosing what the page already
  /// shows with the same stored text keeps it unchanged. Every other header
  /// field is kept as written.
  PageMeta withBackground(PageBackground value) {
    final raw = rawBackground;
    if (value == PageBackground.plain) {
      if (raw == null || raw.text == '"plain"') return this;
      return withRawBackground(null);
    }
    if (raw != null && raw.text == '"${value.name}"') return this;
    return withRawBackground(RawJson.encode(value.name));
  }

  /// Returns a copy whose stored `background` is [raw] (null removes the
  /// key). For undo, which restores whatever was stored, unknown values
  /// included.
  PageMeta withRawBackground(RawJson? raw) => PageMeta.tryRead(
    raw == null ? fields.remove('background') : fields.set('background', raw),
  )!;

  PageMeta _with(String key, RawJson value) => PageMeta.tryRead(fields.set(key, value))!;
}

/// One page: its header, its nodes in z-order (first is bottom-most, as in
/// JSON Canvas) and any other top-level fields, kept verbatim.
final class NotedPage {
  NotedPage._(this.top, this.meta, List<CanvasNode> nodes)
    : nodes = List.unmodifiable(nodes);

  /// Creates an empty page.
  factory NotedPage.create(PageMeta meta) => NotedPage._(
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
  factory NotedPage.fromParts(RawObject top, PageMeta meta, List<CanvasNode> nodes) {
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
    return NotedPage._(top, meta, unique);
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

  NotedPage withMeta(PageMeta value) => NotedPage._(top, value, nodes);

  NotedPage replaceNode(CanvasNode node) {
    final i = indexOf(node.id);
    if (i < 0) return this;
    final next = [...nodes];
    next[i] = node;
    return NotedPage._(top, meta, next);
  }

  /// Inserts [node] at [index] (clamped), or on top if [index] is null.
  NotedPage insertNode(CanvasNode node, [int? index]) {
    final next = [...nodes];
    next.insert((index ?? next.length).clamp(0, next.length), node);
    return NotedPage._(top, meta, next);
  }

  NotedPage removeNode(String id) =>
      NotedPage._(top, meta, nodes.where((n) => n.id != id).toList());

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
