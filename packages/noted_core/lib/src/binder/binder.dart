// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import '../json/raw_json.dart';
import '../model/ids.dart';

/// The binder file format version this build reads and writes.
const int binderFormatVersion = 1;

/// The name of the metadata file inside a binder's folder.
const String binderFileName = 'noted-binder.json';

/// The colors a binder can have, as `#AARRGGBB`. New binders take the next
/// one in turn.
const List<String> binderPalette = [
  '#FF3F51B5', // indigo
  '#FF00897B', // teal
  '#FF43A047', // green
  '#FFF9A825', // amber
  '#FFEF6C00', // orange
  '#FFE53935', // red
  '#FFD81B60', // pink
  '#FF8E24AA', // purple
];

/// The binder file isn't a readable Noted binder.
final class BinderFormatException implements Exception {
  const BinderFormatException(this.message);

  final String message;

  @override
  String toString() => 'BinderFormatException: $message';
}

/// The binder was written by a newer app with a format this build can't
/// read. The file must not be overwritten.
final class UnsupportedBinderFormatException extends BinderFormatException {
  const UnsupportedBinderFormatException(this.format)
    : super('binder format $format is newer than $binderFormatVersion');

  final int format;
}

/// A binder's metadata (0026): the contents of `noted-binder.json`.
///
/// Fields this build doesn't know are kept verbatim, in order, and written
/// back unchanged.
final class Binder {
  Binder._(
    this.fields, {
    required this.id,
    required this.title,
    required this.description,
    required this.owner,
    required this.color,
    required this.created,
    required this.format,
  });

  /// Creates a new binder. [id] defaults to a fresh random id and [created]
  /// to now.
  factory Binder.create({
    String? id,
    required String title,
    String description = '',
    String owner = '',
    required String color,
    DateTime? created,
  }) {
    final binderId = id ?? newId();
    final ms = (created ?? DateTime.now()).millisecondsSinceEpoch;
    final fields = RawObject([
      ('format', RawJson.encode(binderFormatVersion)),
      ('binderId', RawJson.encode(binderId)),
      ('title', RawJson.encode(title)),
      ('description', RawJson.encode(description)),
      ('owner', RawJson.encode(owner)),
      ('color', RawJson.encode(color)),
      ('created', RawJson.encode(ms)),
    ]);
    return tryRead(fields)!;
  }

  /// Reads a binder from its fields, or returns null if they are malformed.
  static Binder? tryRead(RawObject fields) {
    final id = fields.string('binderId');
    final format = fields.integer('format');
    if (id == null || id.isEmpty || format == null) return null;
    return Binder._(
      fields,
      id: id,
      title: fields.string('title') ?? '',
      description: fields.string('description') ?? '',
      owner: fields.string('owner') ?? '',
      color: fields.string('color') ?? binderPalette.first,
      created: fields.integer('created'),
      format: format,
    );
  }

  /// Parses the text of a binder file.
  ///
  /// Throws [BinderFormatException] if it isn't valid, and
  /// [UnsupportedBinderFormatException] if a newer app wrote it.
  static Binder parse(String source) {
    if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) {
      source = source.substring(1);
    }
    final RawObject fields;
    try {
      fields = RawObject.parse(source);
    } on FormatException catch (e) {
      throw BinderFormatException('not valid JSON: ${e.message}');
    }
    final binder = tryRead(fields);
    if (binder == null) throw const BinderFormatException('malformed binder file');
    if (binder.format > binderFormatVersion) {
      throw UnsupportedBinderFormatException(binder.format);
    }
    return binder;
  }

  final RawObject fields;
  final String id;
  final String title;
  final String description;
  final String owner;

  /// `#AARRGGBB`.
  final String color;

  /// When the binder was created, in milliseconds since the epoch.
  final int? created;
  final int format;

  DateTime? get createdAt =>
      created == null ? null : DateTime.fromMillisecondsSinceEpoch(created!);

  Binder withTitle(String value) => _with('title', value);
  Binder withDescription(String value) => _with('description', value);
  Binder withOwner(String value) => _with('owner', value);
  Binder withColor(String value) => _with('color', value);

  Binder _with(String key, String value) =>
      tryRead(fields.set(key, RawJson.encode(value)))!;

  /// The text of the binder file. Values that weren't changed are verbatim.
  String write() => '${fields.toRaw().text}\n';
}

/// The result of reading a folder's binder file.
sealed class BinderRead {
  const BinderRead();
}

final class BinderFound extends BinderRead {
  const BinderFound(this.binder);

  final Binder binder;
}

/// The folder has no binder file.
final class BinderMissing extends BinderRead {
  const BinderMissing();
}

/// The binder file couldn't be read. It is never overwritten.
final class BinderUnreadable extends BinderRead {
  const BinderUnreadable(this.reason);

  final String reason;
}

/// The binder file of one folder.
final class BinderStore {
  BinderStore(this.directory);

  final Directory directory;

  File get file => File('${directory.path}${Platform.pathSeparator}$binderFileName');

  /// Reads the folder's binder file.
  Future<BinderRead> read() async {
    final f = file;
    try {
      if (!await f.exists()) return const BinderMissing();
      return BinderFound(Binder.parse(await f.readAsString()));
    } on BinderFormatException catch (e) {
      return BinderUnreadable(e.message);
    } on FileSystemException catch (e) {
      return BinderUnreadable(e.message);
    }
  }

  /// Writes [binder] atomically: to a temporary file, then renamed over the
  /// old file. Call it only with a binder that was read from this file or
  /// made with [create].
  Future<void> save(Binder binder) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(binder.write(), flush: true);
    await tmp.rename(file.path);
  }

  /// Writes a new binder file. Throws [FileSystemException] if the folder
  /// already has one, which is never overwritten.
  Future<Binder> create(Binder binder) async {
    if (await file.exists()) {
      throw FileSystemException('binder file already exists', file.path);
    }
    await directory.create(recursive: true);
    await save(binder);
    return binder;
  }
}
