// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The checks an archive passes before anything of it is written (design t6
// §4.2, A4). Synchronous, for the opening isolate.

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import '../import/import_limits.dart';
import '../import/zip_reader.dart';
import 'binder_set.dart';

/// Why a binder `.zip` can't be opened, or a share can't be made: the notice.
class BinderZipException implements Exception {
  const BinderZipException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// "This .zip can't be opened as a binder: [reason]."
BinderZipException zipRefused(String reason) =>
    BinderZipException("This .zip can't be opened as a binder: $reason.");

/// "This .zip has no binder in it."
const BinderZipException zipHasNoBinder = BinderZipException('This .zip has no binder in it.');

/// The limits a binder `.zip` is read with.
const ImportLimits binderZipReadLimits = ImportLimits(
  sourceBytes: BinderZipLimits.archiveBytes,
  entryBytes: BinderZipLimits.fileBytes,
  archiveBytes: BinderZipLimits.totalBytes,
  entries: BinderZipLimits.entries,
);

final RegExp _reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])$', caseSensitive: false);
final RegExp _badChar = RegExp(r'[\x00-\x1f\x7f<>"|?*:]');

/// Why the path component [c] can't be a file or folder name on every
/// platform (A4), or null: empty, `.` or `..`, a control character or one of
/// `<>"|?*:`, a trailing dot or space, a reserved device name (with any
/// extension), or over 255 UTF-16 units. This covers `checkWindowsName`.
String? componentProblem(String c) {
  if (c.isEmpty || c == '.' || c == '..') return 'empty';
  if (_badChar.hasMatch(c) || c.contains('/') || c.contains(r'\')) return 'character';
  if (c.endsWith('.') || c.endsWith(' ')) return 'ending';
  if (_reserved.hasMatch(c.split('.').first.trimRight())) return 'reserved';
  if (c.length > 255) return 'length';
  return null;
}

/// One file of the archive to write: its archive name and its path below the
/// binder folder.
final class PlannedFile {
  const PlannedFile(this.archiveName, this.relative, this.size, this.crc);

  final String archiveName;
  final List<String> relative;
  final int size;
  final int crc;
}

/// What the checks found: the binder set to write and the binder file.
final class BinderZipPlan {
  const BinderZipPlan({
    required this.top,
    required this.files,
    required this.folders,
    required this.binderEntry,
    required this.binderBytes,
    required this.binderId,
    required this.title,
    required this.guarded,
    required this.skipped,
  });

  /// The top folder's name, or null when the binder file is at the root.
  final String? top;

  /// The files to write, in the archive's order, the binder file left out.
  final List<PlannedFile> files;

  /// The folders to make (each a path below the binder folder), parents
  /// first, from directory entries and from the files' paths.
  final List<List<String>> folders;

  /// The binder file's archive name.
  final String binderEntry;

  /// The binder file's bytes, inflated and CRC checked.
  final Uint8List binderBytes;
  final String binderId;
  final String title;

  /// Whether the binder file says Guarded (`ai` absent counts as Guarded).
  final bool guarded;

  /// Files outside the binder set, `__MACOSX/` and `.DS_Store`: not written.
  final int skipped;

  /// The longest path below the binder folder, in characters, with one
  /// separator between components.
  int get longestRelative {
    var n = binderFileName.length;
    for (final f in files) {
      final l = f.relative.join('/').length;
      if (l > n) n = l;
    }
    for (final d in folders) {
      final l = d.join('/').length;
      if (l > n) n = l;
    }
    return n;
  }
}

String _quote(String name) => '"${name.length > 80 ? '${name.substring(0, 80)}…' : name}"';

/// Checks the archive [bytes] against every rule of A4 and reads its binder
/// file (inflated, CRC checked, read as a binder, no top-level key twice).
/// Throws a [BinderZipException] with the notice when it can't be opened.
BinderZipPlan checkBinderZip(Uint8List bytes) {
  final ZipReader reader;
  try {
    reader = ZipReader(bytes, binderZipReadLimits);
  } on ImportException catch (e) {
    throw zipRefused(e.reason.contains('parts') ? 'it has too many files' : "it can't be read");
  }
  // Each entry by itself.
  final names = <(ZipEntryInfo, List<String>, bool)>[];
  var total = 0;
  for (final e in reader.entries) {
    if (e.encrypted) throw zipRefused('it is encrypted');
    if (e.diskStart != 0) throw zipRefused('it spans several disks');
    if (e.method != 0 && e.method != 8) throw zipRefused("it uses a compression Noted can't read");
    if (!e.utf8Name && e.rawName.any((b) => b >= 0x80)) throw zipRefused('a name in it is not UTF-8');
    var name = e.name.replaceAll(r'\', '/');
    if (name.startsWith('/') || name.contains(':') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw zipRefused('${_quote(e.name)} is not a name Noted can use');
    }
    final dir = name.endsWith('/');
    if (dir) name = name.substring(0, name.length - 1);
    final parts = name.split('/');
    for (final c in parts) {
      if (componentProblem(c) != null) throw zipRefused('${_quote(e.name)} is not a name Noted can use');
    }
    final host = e.madeBy >> 8;
    if (host == 3) {
      final type = (e.externalAttributes >> 16) & 0xF000;
      if (type != 0 && type != 0x8000 && type != 0x4000) throw zipRefused('${_quote(e.name)} is a link or a special file');
      if (type == 0x4000 && !dir) throw zipRefused('${_quote(e.name)} is a link or a special file');
    }
    if (e.externalAttributes & 0x400 != 0) throw zipRefused('${_quote(e.name)} is a link or a special file');
    if (dir && e.size != 0) throw zipRefused("it can't be read");
    if (e.size > BinderZipLimits.fileBytes) throw zipRefused('it is too large');
    total += e.size;
    if (total > BinderZipLimits.totalBytes) throw zipRefused('it is too large');
    names.add((e, parts, dir));
  }
  // Twins and files at a folder's path, after case folding.
  final seen = <String, String>{};
  final files = <String, String>{};
  final folders = <String>{};
  for (final (e, parts, dir) in names) {
    final key = parts.join('/').toLowerCase();
    final before = seen[key];
    if (before != null) {
      throw zipRefused(
        before == e.name ? '${_quote(e.name)} is in it twice' : '${_quote(before)} and ${_quote(e.name)} differ only in case',
      );
    }
    seen[key] = e.name;
    if (!dir) files[key] = e.name;
    for (var i = 1; i < parts.length; i++) {
      folders.add(parts.sublist(0, i).join('/').toLowerCase());
    }
    if (dir) folders.add(key);
  }
  for (final f in files.keys) {
    if (folders.contains(f)) throw zipRefused('${_quote(files[f]!)} is both a file and a folder');
  }

  // The top folder: every entry that counts under one first component that
  // holds the binder file.
  bool macJunk(List<String> parts) => parts.first == '__MACOSX' || parts.last == '.DS_Store';
  final counted = [for (final n in names) if (!macJunk(n.$2)) n];
  String? top;
  final atRoot = counted.any((n) => !n.$3 && n.$2.length == 1 && n.$2.single == binderFileName);
  if (!atRoot) {
    final firsts = {for (final n in counted) n.$2.first};
    if (firsts.length != 1) throw zipHasNoBinder;
    top = firsts.single;
    final has = counted.any((n) => !n.$3 && n.$2.length == 2 && n.$2[0] == top && n.$2[1] == binderFileName);
    if (!has) throw zipHasNoBinder;
  }

  final planned = <PlannedFile>[];
  final folderList = <List<String>>[];
  final folderSeen = <String>{};
  void addFolder(List<String> rel) {
    for (var i = 1; i <= rel.length; i++) {
      final p = rel.sublist(0, i);
      if (folderSeen.add(p.join('/'))) folderList.add(p);
    }
  }

  var skipped = 0;
  ZipEntryInfo? binderEntry;
  for (final (e, parts, dir) in names) {
    if (macJunk(parts)) {
      if (!dir) skipped++;
      continue;
    }
    final rel = top == null ? parts : parts.sublist(1);
    if (rel.isEmpty) continue; // the top folder's own entry
    if (dir) {
      if (folderInBinderSet(rel)) addFolder(rel);
      continue;
    }
    if (rel.length == 1 && rel.single == binderFileName) {
      binderEntry = e;
      continue;
    }
    if (!inBinderSet(rel)) {
      skipped++;
      continue;
    }
    if (rel.length > 1) addFolder(rel.sublist(0, rel.length - 1));
    planned.add(PlannedFile(e.name, rel, e.size, e.crc));
  }
  if (binderEntry == null) throw zipHasNoBinder;

  // The binder file: inflated (its CRC checked) and read as a binder.
  final Uint8List binderBytes;
  try {
    binderBytes = reader.read(binderEntry.name)!;
  } on ImportException {
    throw zipRefused("its binder file can't be read");
  }
  final String text;
  final Binder binder;
  try {
    text = utf8.decode(binderBytes);
    binder = Binder.parse(text);
  } on FormatException {
    throw zipRefused("its binder file can't be read");
  } on BinderFormatException {
    throw zipRefused("its binder file can't be read");
  }
  final body = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
  final keys = <String>{};
  for (final (k, _) in RawObject.parse(body).entries) {
    if (!keys.add(k)) throw zipRefused('its binder file has a field twice');
  }
  return BinderZipPlan(
    top: top,
    files: planned,
    folders: folderList,
    binderEntry: binderEntry.name,
    binderBytes: binderBytes,
    binderId: binder.id,
    title: binder.title,
    guarded: (binder.aiAccess ?? defaultAiAccess) == AiAccess.guarded,
    skipped: skipped,
  );
}

/// The binder file [bytes] with AI access set to Guarded through the field
/// patch binder settings use (0165: unknown fields keep their bytes), or null
/// when the file can't be read as a binder.
Uint8List? guardedBinderBytes(Uint8List bytes) {
  try {
    final b = Binder.parse(utf8.decode(bytes));
    return Uint8List.fromList(utf8.encode(b.withAiAccess(AiAccess.guarded).write()));
  } on FormatException {
    return null;
  } on BinderFormatException {
    return null;
  }
}
