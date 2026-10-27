// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter imports, so the codec can be loaded by a process
// that has no UI (such as a future MCP server, 0034).

import 'dart:convert';

import 'package:noted_core/noted_core.dart';

/// The names a sticky label's colour can have. The stored value is the name,
/// never an ARGB number, so the module picks the shade for the current theme
/// (light or dark) when it draws.
const List<String> stickyLabelColors = ['blue', 'orange', 'green', 'purple'];

/// The colour a new label has, and the one shown for a name this version
/// doesn't know (the unknown name itself is still kept in the data).
const String defaultStickyLabelColor = 'blue';

/// A sticky label's content: one line of text and a colour name.
///
/// Immutable. [extra] holds every key found in the stored data that this
/// version doesn't know (for example a field added by a newer version of the
/// module on another device). It is written back unchanged by
/// [StickyLabelCodec.encode].
final class StickyLabelData {
  const StickyLabelData({
    this.text = '',
    this.color = defaultStickyLabelColor,
    this.extra = const {},
  });

  final String text;

  /// One of [stickyLabelColors], or a name written by another version.
  final String color;

  /// Unknown keys, kept as decoded JSON values.
  final Map<String, Object?> extra;

  StickyLabelData copyWith({String? text, String? color}) =>
      StickyLabelData(
        text: text ?? this.text,
        color: color ?? this.color,
        extra: extra,
      );
}

/// The data side of the sticky label box. Every member of [BoxCodec] without
/// a default is implemented here, with a note on what it is for.
final class StickyLabelCodec extends BoxCodec<StickyLabelData> {
  const StickyLabelCodec();

  /// The box type id: namespaced, stable and permanent once boxes of the type
  /// exist in users' pages (0005). When you copy this module, change it.
  static const String id = 'noted.template.sticky-label';

  @override
  String get typeId => id;

  /// The version of the stored data schema. Bump it when [encode]'s output
  /// changes shape; [decode] must then still accept every older version.
  /// A box saved by a newer version than this one is not opened for editing:
  /// the canvas shows its snapshot and leaves its data alone.
  @override
  int get dataVersion => 1;

  /// The Box API version this module was written against. The registry
  /// refuses to register a codec the host can't run
  /// (`BoxApiVersion.canHost`), so a module built for another version fails
  /// at start-up instead of misbehaving later.
  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  /// A label has a fixed size: the user sets it and the text scrolls inside.
  /// `growsWithContent` is for boxes that should grow as they fill.
  @override
  BoxSizing get sizing => BoxSizing.fixed;

  /// The data of a newly created, empty box.
  @override
  StickyLabelData create() => const StickyLabelData();

  /// Reads stored data defensively. Data from another device or a newer
  /// version of this module may be incomplete or have the wrong types, so
  /// each field falls back on its own and nothing here throws: a non-object
  /// becomes an empty label, a missing or mistyped field takes its default.
  /// Keys this version doesn't know go to [StickyLabelData.extra].
  @override
  StickyLabelData decode(Object? json, int storedVersion) {
    if (json is! Map) return create();
    final text = json['text'];
    final color = json['color'];
    return StickyLabelData(
      text: text is String ? text : '',
      color: color is String ? color : defaultStickyLabelColor,
      extra: {
        for (final e in json.entries)
          if (e.key is String && e.key != 'text' && e.key != 'color')
            e.key as String: e.value,
      },
    );
  }

  /// Encodes to JSON-compatible values. This is the only path by which the
  /// box's content reaches the page file. The known keys come first, then
  /// the unknown keys exactly as they were read.
  @override
  Object? encode(StickyLabelData data) => {
    'text': data.text,
    'color': data.color,
    ...data.extra,
  };

  /// The read-only text snapshot (0035). It is what other devices show when
  /// this module is off or missing, and what search and the AI read. Keep it
  /// accurate and free of anything that must stay secret.
  @override
  String snapshotText(StickyLabelData data) => data.text;

  /// An empty label is removed when it loses focus, so a stray click leaves
  /// nothing behind.
  @override
  bool isEmpty(StickyLabelData data) => data.text.trim().isEmpty;

  /// What an AI may see (0028). The text of a label is ordinary content, so
  /// it is shown as text; a box type with private content would use
  /// [AiPlaceholder] or [AiHidden] instead. There is no default.
  @override
  AiExposure aiExposure(StickyLabelData data) => AiText(data.text);

  /// Three-way merge of concurrent edits (0020), field by field: a side that
  /// changed a field wins over a side that didn't; if both changed the same
  /// field differently the box is marked conflicted and the user chooses.
  @override
  MergeResult<StickyLabelData> merge(
    StickyLabelData base,
    StickyLabelData mine,
    StickyLabelData theirs,
  ) {
    final text = _pick(base.text, mine.text, theirs.text);
    final color = _pick(base.color, mine.color, theirs.color);
    final extra = _pick(
      _canon(base.extra),
      _canon(mine.extra),
      _canon(theirs.extra),
    );
    if (text == null || color == null || extra == null) {
      return const Conflicted();
    }
    return Merged(
      StickyLabelData(
        text: text,
        color: color,
        extra: _canon(mine.extra) == extra ? mine.extra : theirs.extra,
      ),
    );
  }

  /// The merged value of one field, or null if both sides changed it
  /// differently.
  static T? _pick<T>(T base, T mine, T theirs) {
    if (mine == theirs || theirs == base) return mine;
    if (mine == base) return theirs;
    return null;
  }

  /// A comparable form of the unknown keys.
  static String _canon(Map<String, Object?> extra) => jsonEncode(extra);

  /// A label needs nothing special: no network, no files. A module that
  /// does must declare it here (0034).
  @override
  Set<BoxPermission> get permissions => const {};
}
