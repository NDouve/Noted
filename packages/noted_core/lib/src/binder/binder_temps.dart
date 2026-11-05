// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import '../storage/exclusive_publish.dart';
import '../storage/replace_if_unchanged.dart';
import 'binder.dart';

/// A temporary file of an interrupted binder write that holds something other
/// than the current binder file. It is kept, never promoted.
final class KeptBinderTemp {
  const KeptBinderTemp(this.path, this.bytes, {required this.complete});

  final String path;

  /// What the file held when it was found.
  final List<int> bytes;

  /// The bytes are a readable binder file of a format this build supports.
  final bool complete;
}

/// Whether [name] is the name of a binder temporary file: `noted-binder.json.`
/// then anything, ending in `.tmp` (the current names are
/// `noted-binder.json.<micros>-<n>.tmp`; older builds used the fixed
/// `noted-binder.json.tmp`).
bool isBinderTempName(String name) =>
    name.startsWith('$binderFileName.') && name.endsWith('.tmp');

/// Whether [name] is the binder file or one of its temporary files, the names
/// whose set-aside files the binder sweep puts back.
bool _isBinderName(String name) => name == binderFileName || isBinderTempName(name);

/// Tidies the leftovers of interrupted binder writes in [directory]. Run it
/// under the folder lock.
///
/// It looks only at the binder file's temporary files and their `.cas-old` /
/// `.cas-verified` set-aside files (which it puts back, see
/// [sweepAsideFiles]). A temporary file younger than [minAge] by modification
/// time is skipped: it may be a write in flight on another device. An older one
/// whose bytes equal the current binder file is deleted (with
/// [deleteFileIfUnchanged]). Any other is **kept, never promoted**, and
/// returned.
Future<List<KeptBinderTemp>> sweepBinderTemps(
  Directory directory, {
  Duration minAge = const Duration(minutes: 10),
  DateTime? now,
}) async {
  final kept = <KeptBinderTemp>[];
  if (!await directory.exists()) return kept;
  try {
    await sweepAsideFiles(directory, extension: '', only: _isBinderName);
  } on FileSystemException {
    // Locked for now; the next sweep tries again.
  }
  final clock = now ?? DateTime.now();
  final sep = Platform.pathSeparator;
  List<int>? current;
  try {
    current = await File('${directory.path}$sep$binderFileName').readAsBytes();
  } on FileSystemException {
    current = null;
  }
  final temps = <File>[];
  try {
    await for (final f in directory.list(followLinks: false)) {
      if (f is File && isBinderTempName(_nameOf(f.path))) {
        temps.add(f);
      }
    }
  } on FileSystemException {
    return kept;
  }
  temps.sort((a, b) => a.path.compareTo(b.path));
  for (final f in temps) {
    try {
      final age = clock.difference(await f.lastModified());
      if (age < minAge) continue;
      final bytes = await f.readAsBytes();
      if (current != null && _same(bytes, current)) {
        await deleteFileIfUnchanged(f.path, bytes);
        continue;
      }
      kept.add(KeptBinderTemp(f.path, bytes, complete: _parses(bytes)));
    } on FileSystemException {
      // Gone or locked; the next sweep looks again.
    }
  }
  return kept;
}

/// Puts the complete temporary file [tempPath] (which must hold [expected])
/// back as the binder file of [directory], through [publishExclusive]: never
/// over an existing file. Returns false if a binder file is there now, or the
/// temporary file changed or is not a complete binder. Run it under the folder
/// lock.
Future<bool> putBackBinderTemp(
  Directory directory,
  String tempPath,
  List<int> expected,
) async {
  final sep = Platform.pathSeparator;
  final target = '${directory.path}$sep$binderFileName';
  final tmp = File(tempPath);
  if (!isBinderTempName(_nameOf(tempPath))) return false;
  final List<int> bytes;
  try {
    bytes = await tmp.readAsBytes();
  } on FileSystemException {
    return false;
  }
  if (!_same(bytes, expected) || !_parses(bytes)) return false;
  return publishExclusive(tmp, target);
}

String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;

bool _parses(List<int> bytes) {
  try {
    Binder.parse(utf8.decode(bytes));
    return true;
  } on FormatException {
    return false;
  } on BinderFormatException {
    return false;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
