// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Where an inherited setting (AI access, module availability) gets its
/// effective value from (0027).
enum ConfigSourceKind {
  /// The page itself.
  own,

  /// A parent page ([ConfigSource.pageId] says which).
  page,

  /// The binder the page is in.
  binder,

  /// Nothing was chosen anywhere: the app default.
  appDefault,
}

/// A [ConfigSourceKind], with the page id when it is [ConfigSourceKind.page].
final class ConfigSource {
  const ConfigSource._(this.kind, this.pageId);

  static const ConfigSource own = ConfigSource._(ConfigSourceKind.own, null);
  static const ConfigSource binder = ConfigSource._(ConfigSourceKind.binder, null);
  static const ConfigSource appDefault = ConfigSource._(ConfigSourceKind.appDefault, null);

  /// A parent page.
  const ConfigSource.page(String this.pageId) : kind = ConfigSourceKind.page;

  final ConfigSourceKind kind;
  final String? pageId;

  @override
  bool operator ==(Object other) =>
      other is ConfigSource && other.kind == kind && other.pageId == pageId;

  @override
  int get hashCode => Object.hash(kind, pageId);

  @override
  String toString() => pageId == null ? kind.name : '${kind.name}($pageId)';
}
