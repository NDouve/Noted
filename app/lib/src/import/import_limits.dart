// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a file import may read and build. Plain numbers, so it crosses to
/// the conversion isolate.
final class ImportLimits {
  const ImportLimits({
    required this.sourceBytes,
    required this.entryBytes,
    required this.archiveBytes,
    this.entries = 2000,
    this.xmlDepth = 256,
    this.rows = 500,
    this.columns = 50,
    this.noteBoxes = 20,
    this.noteBytes = 256 * 1024,
    this.noteCells = 2000,
  });

  /// Desktop: a source of 100 MiB, 64 MiB per zip entry and 256 MiB per zip.
  static const ImportLimits desktop = ImportLimits(
    sourceBytes: 100 * _mib,
    entryBytes: 64 * _mib,
    archiveBytes: 256 * _mib,
  );

  /// iOS and Android: 50, 16 and 64 MiB.
  static const ImportLimits mobile = ImportLimits(
    sourceBytes: 50 * _mib,
    entryBytes: 16 * _mib,
    archiveBytes: 64 * _mib,
  );

  static const int _mib = 1024 * 1024;

  /// The largest source file read at all.
  final int sourceBytes;

  /// The most a zip entry may inflate to, and all entries read of one zip.
  final int entryBytes;
  final int archiveBytes;

  /// The most entries a zip may list.
  final int entries;

  /// The deepest XML element nesting.
  final int xmlDepth;

  /// The most rows and columns of a sheet that are read.
  final int rows;
  final int columns;

  /// The most note boxes one import makes, and what one holds: text bytes
  /// and table cells.
  final int noteBoxes;
  final int noteBytes;
  final int noteCells;
}

/// A source the import refuses, or part of one it can't read. [reason]
/// follows the file's name: `"<name>" <reason>`.
final class ImportException implements Exception {
  const ImportException(this.reason);

  final String reason;

  @override
  String toString() => 'ImportException: $reason';
}
