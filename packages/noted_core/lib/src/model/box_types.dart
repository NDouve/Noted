// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../binder/binder.dart';
import '../json/raw_json.dart';
import 'config_source.dart';
import 'page.dart';

/// The key of the module availability map in a page header's `noted` object
/// and in a binder file: `{"<typeId>": false|true}`.
///
/// A type that is absent inherits. `false` means the type is not allowed
/// here: the module behaves as switched off for the page (0035), so its boxes
/// render from their snapshot, read-only, and nothing is deleted. A value
/// that isn't a boolean counts as absent (inherit) and is kept as written, as
/// are keys this build doesn't know.
const String boxTypesKey = 'boxTypes';

/// The choices in a stored `boxTypes` value: only the boolean ones.
Map<String, bool> _choices(RawJson? raw) {
  final entries = _entries(raw);
  final out = <String, bool>{};
  for (final (k, v) in entries.entries) {
    final d = v.decode();
    if (d is bool) out[k] = d;
  }
  return out;
}

RawObject _entries(RawJson? raw) {
  if (raw == null || !raw.isObject) return RawObject.empty;
  try {
    return RawObject.parse(raw.text);
  } on FormatException {
    return RawObject.empty;
  }
}

// [raw] with [typeId] set to [allowed] (null removes it). Other entries keep
// their text and order. An empty map is removed. A stored value that isn't an
// object is replaced when a choice is set.
RawJson? _withChoice(RawJson? raw, String typeId, bool? allowed) {
  final entries = _entries(raw);
  final current = entries[typeId];
  if (allowed == null) {
    if (current == null) return raw;
    final rest = entries.remove(typeId);
    return rest.entries.isEmpty ? null : rest.toRaw();
  }
  final value = RawJson.encode(allowed);
  if (current == value) return raw;
  return entries.set(typeId, value).toRaw();
}

/// Module availability on a page header.
extension PageBoxTypes on PageMeta {
  /// The page's own boolean choices by type id.
  Map<String, bool> get boxTypeChoices => _choices(fields[boxTypesKey]);

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawBoxTypes => fields[boxTypesKey];

  /// The page's own choice for [typeId], or null (inherit).
  bool? boxTypeChoice(String typeId) => boxTypeChoices[typeId];

  /// Returns a copy with its choice for [typeId] set to [allowed]; null
  /// removes the choice. Returns this page unchanged if nothing changes.
  PageMeta withBoxType(String typeId, bool? allowed) {
    final next = _withChoice(rawBoxTypes, typeId, allowed);
    if (next == rawBoxTypes) return this;
    return PageMeta.tryRead(
      next == null ? fields.remove(boxTypesKey) : fields.set(boxTypesKey, next),
    )!;
  }
}

/// Module availability on a binder.
extension BinderBoxTypes on Binder {
  /// The binder's own boolean choices by type id.
  Map<String, bool> get boxTypeChoices => _choices(fields[boxTypesKey]);

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawBoxTypes => fields[boxTypesKey];

  /// The binder's own choice for [typeId], or null (inherit).
  bool? boxTypeChoice(String typeId) => boxTypeChoices[typeId];

  /// Returns a copy with its choice for [typeId] set to [allowed]; null
  /// removes the choice. Returns this binder unchanged if nothing changes.
  Binder withBoxType(String typeId, bool? allowed) {
    final next = _withChoice(rawBoxTypes, typeId, allowed);
    if (next == rawBoxTypes) return this;
    return Binder.tryRead(
      next == null ? fields.remove(boxTypesKey) : fields.set(boxTypesKey, next),
    )!;
  }
}

/// Whether a box type is allowed on a page, and, when it isn't, the level
/// that disallowed it.
final class BoxTypeAvailability {
  const BoxTypeAvailability.allowed() : allowed = true, source = null;

  const BoxTypeAvailability.disallowed(ConfigSource this.source) : allowed = false;

  final bool allowed;

  /// The highest level that disallows the type; null if [allowed].
  final ConfigSource? source;

  @override
  bool operator ==(Object other) =>
      other is BoxTypeAvailability && other.allowed == allowed && other.source == source;

  @override
  int get hashCode => Object.hash(allowed, source);

  @override
  String toString() => allowed ? 'allowed' : 'disallowed by $source';
}

/// Whether [typeId] is allowed on a page (configuration inheritance, 0027):
/// allowed unless the page, one of its parent pages or the binder disallows
/// it. [chain] is the page, then its parent pages, nearest first. Only the
/// binder and a top-level page in no binder can say `true` to anything: it
/// has no effect lower down, because lower levels can only disallow.
BoxTypeAvailability effectiveBoxTypeAllowed(
  String typeId,
  Iterable<PageMeta> chain, {
  Binder? binder,
}) => _resolveBoxType(typeId, chain.toList(), binder, firstIsSelf: true);

/// What the page inherits for [typeId] from its parents and the binder. The
/// UI offers "allowed" for a page only when this is allowed.
BoxTypeAvailability inheritedBoxTypeAllowed(
  String typeId,
  Iterable<PageMeta> chain, {
  Binder? binder,
}) => _resolveBoxType(typeId, chain.skip(1).toList(), binder, firstIsSelf: false);

BoxTypeAvailability _resolveBoxType(
  String typeId,
  List<PageMeta> chain,
  Binder? binder, {
  required bool firstIsSelf,
}) {
  if (binder?.boxTypeChoice(typeId) == false) {
    return const BoxTypeAvailability.disallowed(ConfigSource.binder);
  }
  for (var i = chain.length - 1; i >= 0; i--) {
    if (chain[i].boxTypeChoice(typeId) == false) {
      return BoxTypeAvailability.disallowed(
        i == 0 && firstIsSelf ? ConfigSource.own : ConfigSource.page(chain[i].id),
      );
    }
  }
  return const BoxTypeAvailability.allowed();
}

/// Whether [box] is encrypted (binder passwords, a later phase): an encrypted
/// box type, or a header that says so. Its data is never read.
bool isEncryptedBox(BoxRecord box) =>
    box.typeId.contains('encrypt') ||
    box.noted.containsKey('encrypted') ||
    box.noted.containsKey('cipher');
