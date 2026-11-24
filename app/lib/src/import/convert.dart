// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:noted_canvas/noted_canvas.dart' show IncomingFile;
import 'package:noted_core/noted_core.dart';

import 'csv.dart';
import 'docx.dart';
import 'import_format.dart';
import 'import_limits.dart';
import 'import_result.dart';
import 'sheet_blocks.dart' show SheetData;
import 'txt.dart';
import 'xlsx.dart';

/// Runs [work] away from the UI isolate. Tests replace it.
typedef ImportRunner = Future<R> Function<R>(R Function() work);

/// The default runner: [Isolate.run].
Future<R> runInIsolate<R>(R Function() work) => Isolate.run(work);

/// Converts the source [bytes] of a file called [name] to note boxes' blocks
/// in an isolate. Everything is built there; the UI isolate only decodes the
/// JSON, as it decodes any saved note.
Future<ConvertedNotes> convertToNotes(
  ImportFormat format,
  String name,
  Uint8List bytes,
  ImportLimits limits, {
  ImportRunner run = runInIsolate,
}) => run(() => convertToNotesNow(format, name, bytes, limits));

/// [convertToNotes] in the calling isolate.
ConvertedNotes convertToNotesNow(ImportFormat format, String name, Uint8List bytes, ImportLimits limits) {
  try {
    final BlocksResult result;
    switch (format) {
      case ImportFormat.text:
        result = txtToBlocks(bytes);
      case ImportFormat.markdown:
        final blocks = markdownToNoteBlocks(utf8.decode(bytes, allowMalformed: true));
        if (blocks.isEmpty) throw const ImportException('has no text to import');
        result = BlocksResult(blocks);
      case ImportFormat.word:
        result = docxToBlocks(bytes, limits, name);
      case ImportFormat.sheet:
        result = xlsxToBlocks(bytes, limits, name);
      case ImportFormat.csv:
        final tab = name.toLowerCase().endsWith('.tsv');
        result = csvToBlocks(bytes, limits, name, delimiter: tab ? '\t' : ',');
      case ImportFormat.pdf || ImportFormat.slides || ImportFormat.image:
        throw const ImportException('can’t be imported as text');
    }
    if (result.blocks.isEmpty) throw const ImportException('has no text to import');
    final groups = groupNoteBlocks(
      result.blocks,
      maxBytes: limits.noteBytes,
      maxCells: limits.noteCells,
      maxGroups: limits.noteBoxes,
    );
    return ConvertedNotes(
      boxes: groups.groups,
      notices: [
        ...result.notices,
        if (groups.truncated) '"$name" is too long; the first part was imported.',
      ],
    );
  } on ImportException catch (e) {
    return ConvertedNotes(error: e.reason);
  } on Object {
    return const ConvertedNotes(error: 'can’t be read');
  }
}

/// The import file the note module takes for one note box.
IncomingFile noteImportFile(String name, List<Map<String, Object?>> blocks, int index, int count) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final label = count > 1 ? '$stem ${index + 1}' : stem;
  return IncomingFile('$label.noted-blocks.json', Uint8List.fromList(encodeNoteBlocksFile(blocks)));
}

/// The sheets of a workbook or a csv, for drawing as images.
final class ConvertedSheets {
  const ConvertedSheets({this.error, this.sheets = const [], this.notices = const []});

  final String? error;
  final List<SheetData> sheets;
  final List<String> notices;
}

/// Reads the sheets of an `.xlsx`, `.csv` or `.tsv` in an isolate, the empty
/// ones left out.
Future<ConvertedSheets> convertToSheets(
  ImportFormat format,
  String name,
  Uint8List bytes,
  ImportLimits limits, {
  ImportRunner run = runInIsolate,
}) => run(() => convertToSheetsNow(format, name, bytes, limits));

/// [convertToSheets] in the calling isolate.
ConvertedSheets convertToSheetsNow(ImportFormat format, String name, Uint8List bytes, ImportLimits limits) {
  try {
    final List<SheetData> all;
    switch (format) {
      case ImportFormat.sheet:
        all = xlsxSheets(bytes, limits);
      case ImportFormat.csv:
        final tab = name.toLowerCase().endsWith('.tsv');
        all = [csvSheet(utf8.decode(bytes, allowMalformed: true), limits, tab ? '\t' : ',')];
      default:
        throw const ImportException('can’t be imported as an image');
    }
    final rowsCut = [for (final s in all) if (s.rowsCut) s.name ?? ''];
    final colsCut = [for (final s in all) if (s.columnsCut) s.name ?? ''];
    String where(List<String> names) {
      final named = names.where((n) => n.isNotEmpty).toList();
      return named.isEmpty ? '' : ' in ${named.join(', ')}';
    }

    final parts = [
      if (rowsCut.isNotEmpty) 'rows past ${limits.rows}${where(rowsCut)}',
      if (colsCut.isNotEmpty) 'columns past ${limits.columns}${where(colsCut)}',
    ];
    final sheets = [for (final s in all) if (s.rows.isNotEmpty) s];
    if (sheets.isEmpty) throw const ImportException('has nothing to import');
    return ConvertedSheets(
      sheets: sheets,
      notices: [if (parts.isNotEmpty) '"$name": left out ${parts.join('; ')}.'],
    );
  } on ImportException catch (e) {
    return ConvertedSheets(error: e.reason);
  } on Object {
    return const ConvertedSheets(error: 'can’t be read');
  }
}
