// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../binder/binder.dart';
import '../json/raw_json.dart';
import '../model/config_source.dart';
import '../model/page.dart';

/// What an AI may read of a page without a code (0100): the page AI access.
/// The values are ordered loosest to strictest.
///
/// - [open]: any AI may read the page from its saved file.
/// - [privileged]: invisible without a code; a page or binder code covering
///   the page can read it.
/// - [guarded]: invisible to every AI, codes included (box codes still reach
///   their own AI box).
enum AiAccess {
  open('open', 'Open'),
  privileged('privileged', 'Privileged'),
  guarded('guarded', 'Guarded');

  const AiAccess(this.value, this.label);

  /// How the access is written in a page header or binder file (`"ai"`).
  final String value;
  final String label;

  /// How strict this value is: 0 for the loosest.
  int get strictness => index;

  /// The stricter of [a] and [b].
  static AiAccess strictest(AiAccess a, AiAccess b) => b.index > a.index ? b : a;

  /// The access a stored [value] means, or null if nothing is stored (the
  /// page then follows its parent).
  ///
  /// `open`, `privileged` and `guarded` are read as named. The legacy `page`
  /// means [open]; the legacy `off` and `box` mean [guarded]. Any other
  /// present value is read as [guarded] (the safe side); it stays as written
  /// in the file until the user picks a value.
  static AiAccess? parse(Object? value) {
    if (value == null) return null;
    return switch (value) {
      'open' || 'page' => open,
      'privileged' => privileged,
      _ => guarded,
    };
  }
}

/// The key of the access in a page header's `noted` object and in a binder
/// file.
const String aiAccessKey = 'ai';

/// The access with nothing chosen anywhere.
const AiAccess defaultAiAccess = AiAccess.guarded;

/// The access on a page header.
extension PageAiAccess on PageMeta {
  /// The page's own choice (legacy and unknown values read as in
  /// [AiAccess.parse]), or null if it has none and follows its parent.
  AiAccess? get aiAccess => AiAccess.parse(fields[aiAccessKey]?.decode());

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawAiAccess => fields[aiAccessKey];

  /// Returns a copy with its own choice [value]; null removes it, so the
  /// page follows its parent again. Returns this page unchanged if it
  /// already stores that value.
  PageMeta withAiAccess(AiAccess? value) {
    if (value == null) {
      if (rawAiAccess == null) return this;
      return PageMeta.tryRead(fields.remove(aiAccessKey))!;
    }
    final raw = RawJson.encode(value.value);
    if (rawAiAccess == raw) return this;
    return PageMeta.tryRead(fields.set(aiAccessKey, raw))!;
  }
}

/// The access on a binder.
extension BinderAiAccess on Binder {
  /// The binder's choice, or null if it has none.
  AiAccess? get aiAccess => AiAccess.parse(fields[aiAccessKey]?.decode());

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawAiAccess => fields[aiAccessKey];

  /// Returns a copy with [value]; null removes the field.
  Binder withAiAccess(AiAccess? value) {
    if (value == null) {
      if (rawAiAccess == null) return this;
      return Binder.tryRead(fields.remove(aiAccessKey))!;
    }
    final raw = RawJson.encode(value.value);
    if (rawAiAccess == raw) return this;
    return Binder.tryRead(fields.set(aiAccessKey, raw))!;
  }
}

/// The AI access that applies to a page and where it comes from.
final class EffectiveAiAccess {
  const EffectiveAiAccess(this.value, this.source);

  final AiAccess value;
  final ConfigSource source;

  @override
  bool operator ==(Object other) =>
      other is EffectiveAiAccess && other.value == value && other.source == source;

  @override
  int get hashCode => Object.hash(value, source);

  @override
  String toString() => '${value.value} <- $source';
}

/// The AI access that applies to a page (configuration inheritance, 0027):
/// walk from the top of the chain down to the page.
///
/// [chain] is the page, then its parent pages, nearest first. The start is
/// the [binder]'s choice, or the app default ([defaultAiAccess]) if it has
/// none. A page in no binder (`binder` null) is the top of its own chain: its
/// top-level page may choose any value. Every lower level can only tighten:
/// the result is the strictest of what it inherits and its own choice, so a
/// looser own choice is ignored. The source is the level whose value ended
/// up in force.
EffectiveAiAccess effectiveAiAccess(Iterable<PageMeta> chain, {Binder? binder}) =>
    _resolveAiAccess(chain.toList(), binder, firstIsSelf: true);

/// What the page inherits from above (its parents, the binder, the app
/// default), or null if nothing limits it because it is the top of its chain:
/// a top-level page in no binder. The UI offers [allowedOwnAiAccess] of this.
EffectiveAiAccess? inheritedAiAccess(Iterable<PageMeta> chain, {Binder? binder}) {
  final list = chain.toList();
  if (binder == null && list.isNotEmpty && list.length == 1 && list.first.parentId == null) return null;
  return _resolveAiAccess(list.skip(1).toList(), binder, firstIsSelf: false);
}

/// The own values a page (or binder) may choose, given what it inherits
/// ([inheritedAiAccess]; null when nothing limits it, as for a binder). A
/// looser value would be ignored, so it isn't offered.
List<AiAccess> allowedOwnAiAccess(AiAccess? inherited) => [
  for (final a in AiAccess.values)
    if (inherited == null || a.strictness >= inherited.strictness) a,
];

EffectiveAiAccess _resolveAiAccess(
  List<PageMeta> chain,
  Binder? binder, {
  required bool firstIsSelf,
}) {
  var value = defaultAiAccess;
  var source = ConfigSource.appDefault;
  final fromBinder = binder?.aiAccess;
  if (fromBinder != null) {
    value = fromBinder;
    source = ConfigSource.binder;
  }
  for (var i = chain.length - 1; i >= 0; i--) {
    final own = chain[i].aiAccess;
    if (own == null) continue;
    // Only a page that records no parent is the top: one whose recorded parent
    // is missing or unreadable starts from the app default and can only tighten.
    final isTop = binder == null && i == chain.length - 1 && chain[i].parentId == null;
    if (isTop || own.strictness > value.strictness) {
      value = own;
      source = i == 0 && firstIsSelf ? ConfigSource.own : ConfigSource.page(chain[i].id);
    }
  }
  return EffectiveAiAccess(value, source);
}
