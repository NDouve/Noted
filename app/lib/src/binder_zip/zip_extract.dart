// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The one extraction pass of opening a binder `.zip` (design t6 §4.5, A5,
// A6), synchronous, for the opening isolate. Every file is created at its
// final name in the private staging folder with `File.create(exclusive:
// true)`, then written in append mode, so nothing that exists is ever
// replaced or truncated; the identity of what was written is recorded as it
// is written, so a rollback removes only that.

import 'dart:io';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import '../import/import_limits.dart';
import '../import/zip_reader.dart';
import 'zip_check.dart';

/// A file this open created, with the identity of the bytes it wrote there.
final class CreatedFile {
  const CreatedFile(this.path, this.identity);

  final String path;
  final ContentIdentity identity;
}

/// What the extraction did: what it created, in creation order (each folder
/// before what is in it), and why it stopped, when it did.
final class ZipExtraction {
  ZipExtraction();

  final List<CreatedFile> files = [];
  final List<String> folders = [];

  /// The reason for "can't be opened", or null when every file was written.
  String? failure;

  /// The identity of the binder file as written, when it was.
  ContentIdentity? binderIdentity;
}

/// Creates the new file [path] exclusively and writes [bytes] to it in append
/// mode, flushed. Any [FileSystemException] from the create means it was not
/// created (an existing name, a case twin on a case-insensitive volume, a
/// folder of that name). [onWritten] is called once the file exists, with the
/// identity of what it then holds (nothing), and again at the end with the
/// identity of what was written: all of [bytes], or, when a write failed part
/// way, the bytes written before it. Throws a [FileSystemException] on
/// failure.
void createNewFile(String path, Uint8List bytes, void Function(ContentIdentity identity) onWritten) {
  File(path).createSync(exclusive: true);
  onWritten(ContentIdentity.ofBytes(const []));
  var written = 0;
  try {
    final raf = File(path).openSync(mode: FileMode.append);
    try {
      const step = 1024 * 1024;
      while (written < bytes.length) {
        final end = written + step < bytes.length ? written + step : bytes.length;
        raf.writeFromSync(bytes, written, end);
        written = end;
      }
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    // A chunk that failed may be partly written: the rollback then finds other
    // bytes and keeps the file, which is the safe side.
    onWritten(ContentIdentity.ofBytes(Uint8List.sublistView(bytes, 0, written)));
    rethrow;
  }
  onWritten(ContentIdentity.ofBytes(bytes));
}

/// Reads the zip at [zipPath] (a fresh reader, so each entry counts once),
/// checks that it still lists [plan]'s files as they were checked, and
/// writes them below [staging]: the folders, then each file, inflated once
/// and CRC checked, then [binderBytes] as the binder file, last.
ZipExtraction extractBinderZip(String zipPath, String staging, BinderZipPlan plan, Uint8List binderBytes) {
  final out = ZipExtraction();
  final sep = Platform.pathSeparator;
  String at(List<String> rel) => '$staging$sep${rel.join(sep)}';
  try {
    final bytes = File(zipPath).readAsBytesSync();
    final ZipReader reader;
    try {
      reader = ZipReader(bytes, binderZipReadLimits);
    } on ImportException {
      out.failure = "it can't be read";
      return out;
    }
    final listed = {for (final e in reader.entries) e.name: e};
    for (final f in plan.files) {
      final e = listed[f.archiveName];
      if (e == null || e.size != f.size || e.crc != f.crc) {
        out.failure = 'it changed while it was opened';
        return out;
      }
    }
    for (final d in plan.folders) {
      final p = at(d);
      if (FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound) {
        out.failure = '${d.join('/')} was there already';
        return out;
      }
      Directory(p).createSync();
      out.folders.add(p);
    }
    for (final f in plan.files) {
      final Uint8List data;
      try {
        data = reader.read(f.archiveName)!;
      } on ImportException {
        out.failure = '${f.relative.join('/')} is damaged';
        return out;
      }
      final p = at(f.relative);
      var made = false;
      final index = out.files.length;
      try {
        createNewFile(p, data, (id) {
          if (!made) {
            made = true;
            out.files.add(CreatedFile(p, id));
          } else {
            out.files[index] = CreatedFile(p, id);
          }
        });
      } on FileSystemException catch (e) {
        out.failure = made ? "${f.relative.join('/')} couldn't be written (${e.message})" : '${f.relative.join('/')} was not created';
        return out;
      }
    }
    final p = at([binderFileName]);
    var made = false;
    final index = out.files.length;
    try {
      createNewFile(p, binderBytes, (id) {
        if (!made) {
          made = true;
          out.files.add(CreatedFile(p, id));
        } else {
          out.files[index] = CreatedFile(p, id);
        }
      });
    } on FileSystemException catch (e) {
      out.failure = made ? "the binder file couldn't be written (${e.message})" : 'the binder file was not created';
      return out;
    }
    out.binderIdentity = out.files[index].identity;
  } on FileSystemException catch (e) {
    out.failure = e.message;
  }
  return out;
}

/// The longest path the open would make for [plan]: the staging folder
/// [stagingPath] with its files, or `<parent>/<name> (99)/<file>`.
int longestOpenPath(BinderZipPlan plan, {required String stagingPath, required String parent, required String name}) {
  final rel = plan.longestRelative;
  final staged = stagingPath.length + 1 + rel;
  final placed = parent.length + 1 + name.length + ' (99)'.length + 1 + rel;
  return staged > placed ? staged : placed;
}

/// The longest path Windows takes (`MAX_PATH` less its terminator).
const int maxOpenPath = 259;

/// The characters `Directory.createTemp` adds to a prefix on this platform, at
/// most.
int get createTempSuffixLength => Platform.isWindows ? 36 : 6;

/// A folder name for the binder from [candidates] (the top folder, the
/// zip's name, the binder's title), cut to 64 characters: the first that is
/// a usable name.
String binderZipFolderName(List<String> candidates) {
  for (final c in candidates) {
    var n = c.trim();
    if (n.length > 64) n = n.substring(0, 64);
    n = n.replaceAll(RegExp(r'[. ]+$'), '');
    if (n.startsWith('.')) continue;
    if (componentProblem(n) == null) return n;
  }
  return 'Binder';
}
