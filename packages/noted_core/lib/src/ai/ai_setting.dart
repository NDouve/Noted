// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../binder/binder.dart';
import '../json/raw_json.dart';
import '../model/page.dart';

/// What an AI may read of a page (0028): the page AI setting.
///
/// - [off]: the page is invisible to AI: not listed, not searchable, not
///   linked to.
/// - [boxOnly]: the page is listed, but an AI reads only its own boxes (none
///   yet: AI boxes come later), so no box content is given out.
/// - [wholePage]: every box can be read.
enum AiSetting {
  off('off', 'Off'),
  boxOnly('box', 'Box only'),
  wholePage('page', 'Whole page');

  const AiSetting(this.value, this.label);

  /// How the setting is written in a page header or binder file (`"ai"`).
  final String value;
  final String label;

  /// The setting named [value], or null for a missing or unknown value (the
  /// page then follows its parent).
  static AiSetting? parse(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// The key of the setting in a page header's `noted` object and in a binder
/// file.
const String aiSettingKey = 'ai';

/// The setting with nothing chosen anywhere: AI sees nothing.
const AiSetting defaultAiSetting = AiSetting.off;

/// The setting on a page header.
extension PageAiSetting on PageMeta {
  /// The page's own choice, or null if it has none (or an unknown value,
  /// which is kept as written) and follows its parent.
  AiSetting? get aiSetting => AiSetting.parse(fields.string(aiSettingKey));

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawAiSetting => fields[aiSettingKey];

  /// Returns a copy with its own choice [value]; null removes it, so the
  /// page follows its parent again. Returns this page unchanged if it
  /// already stores that value.
  PageMeta withAiSetting(AiSetting? value) {
    if (value == null) {
      if (rawAiSetting == null) return this;
      return PageMeta.tryRead(fields.remove(aiSettingKey))!;
    }
    if (rawAiSetting?.text == RawJson.encode(value.value).text) return this;
    return PageMeta.tryRead(fields.set(aiSettingKey, RawJson.encode(value.value)))!;
  }
}

/// The setting on a binder.
extension BinderAiSetting on Binder {
  /// The binder's choice, or null if it has none (or an unknown value, kept
  /// as written).
  AiSetting? get aiSetting => AiSetting.parse(fields.string(aiSettingKey));

  /// Returns a copy with [value]; null removes the field.
  Binder withAiSetting(AiSetting? value) {
    final next = value == null
        ? fields.remove(aiSettingKey)
        : fields.set(aiSettingKey, RawJson.encode(value.value));
    return Binder.tryRead(next)!;
  }
}

/// The AI setting that applies to a page (configuration inheritance, 0027):
/// the first own choice among [chain] (the page, then its parent pages,
/// nearest first), then [binder]'s, then [defaultAiSetting] (Off).
AiSetting effectiveAiSetting(Iterable<PageMeta> chain, {Binder? binder}) {
  for (final p in chain) {
    final s = p.aiSetting;
    if (s != null) return s;
  }
  return binder?.aiSetting ?? defaultAiSetting;
}
