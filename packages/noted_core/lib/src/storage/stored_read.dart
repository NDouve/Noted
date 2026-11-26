// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'coordination.dart';
import 'dataless.dart';

/// The one place the app reads a stored file (0190, 0183).
///
/// A file whose data is not on this device is never read, and never taken for
/// absent. Every reader here asks [notDownloaded] first, reads nothing when it
/// says so, and answers [StoredNotDownloaded]. A caller retires, deletes or
/// overwrites only on [StoredBytes] or [StoredMissing]; [StoredNotDownloaded]
/// and [StoredFailed] wait.
sealed class StoredRead {
  const StoredRead();
}

/// The file's bytes.
final class StoredBytes extends StoredRead {
  const StoredBytes(this.path, this.bytes);

  final String path;
  final Uint8List bytes;

  /// The bytes as strict UTF-8. Throws the [FileSystemException] that
  /// `File.readAsString` throws for bytes that aren't, never a
  /// [FormatException], so a handler written for `readAsString` stays right.
  String get text {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FileSystemException("Failed to decode data using encoding 'utf-8'", path);
    }
  }
}

/// The file is there (or its stub is) but its data is not on this device. Nothing
/// was read.
final class StoredNotDownloaded extends StoredRead {
  const StoredNotDownloaded(this.path);

  final String path;
}

/// There is no file and no stub at the path (its folder may be gone too: a
/// caller that retires on this checks the folder first).
final class StoredMissing extends StoredRead {
  const StoredMissing();
}

/// The read failed for another reason (locked, a permission, a bad link).
final class StoredFailed extends StoredRead {
  const StoredFailed(this.error);

  final FileSystemException error;
}

/// Asks the system to download the file at a path. Its result (null, or a
/// message when it can't) is only logged.
typedef DownloadAsk = Future<String?> Function(String path);

/// What an open gives: the opened thing, or why nothing was opened
/// ([StoredNotDownloaded], [StoredMissing] or [StoredFailed]).
sealed class StoredOpen<T> {
  const StoredOpen();
}

final class StoredOpened<T> extends StoredOpen<T> {
  const StoredOpened(this.value);

  final T value;
}

final class StoredRefused<T> extends StoredOpen<T> {
  const StoredRefused(this.result);

  final StoredRead result;
}

/// A read stream, as [openStoredRead] gives it. An error of the stream after a
/// file was evicted is a [StorageBusy] (`dataless`); any other error is the
/// stream's own.
typedef StoredStream = StoredOpen<Stream<List<int>>>;

/// A file open for reading.
typedef StoredFile = StoredOpen<RandomAccessFile>;

/// Called with the path of every file that is read here, after the check that
/// it is downloaded. A seam for tests that count reads; null in production.
void Function(String path)? storedReadObserver;

// Tells the observer of a file about to be read, when there is one to read: a
// read of a file that is not there opens nothing.
void _observe(String path) {
  final observer = storedReadObserver;
  if (observer == null) return;
  if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) return;
  observer(path);
}

/// The gate: whether the data of the file at [path] is not on this device (a
/// dataless file, or a stub with no file). Metadata only.
bool notDownloaded(String path) => isDataless(path);

/// Where a failed or refused ask is reported (a test seam; the app may set it to
/// its own log). It must not throw.
void Function(String message) storedReadLog = print;

/// Asks for a download without letting the ask reach the caller: an [ask] that
/// throws, here or later, is logged and dropped; so is a message it answers with.
void askSafely(String path, DownloadAsk? ask) {
  if (ask == null) return;
  unawaited(
    Future<String?>.sync(() => ask(path)).then<void>(
      (message) {
        if (message != null) storedReadLog('Noted: asking for the download of $path: $message');
      },
      onError: (Object e) => storedReadLog('Noted: asking for the download of $path failed: $e'),
    ),
  );
}

StoredRead _refusal(String path, FileSystemException e, DownloadAsk? ask) {
  // Evicted between the gate and the read.
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredNotDownloaded(path);
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
    return const StoredMissing();
  }
  return StoredFailed(e);
}

/// Reads the file at [path]. Nothing is read when it is not downloaded; [ask]
/// is then called once.
Future<StoredRead> readStored(String path, {DownloadAsk? ask}) async {
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredNotDownloaded(path);
  }
  _observe(path);
  try {
    return StoredBytes(path, await File(path).readAsBytes());
  } on FileSystemException catch (e) {
    return _refusal(path, e, ask);
  }
}

/// The synchronous form of [readStored].
StoredRead readStoredSync(String path, {DownloadAsk? ask}) {
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredNotDownloaded(path);
  }
  _observe(path);
  try {
    return StoredBytes(path, File(path).readAsBytesSync());
  } on FileSystemException catch (e) {
    return _refusal(path, e, ask);
  }
}

/// Opens the file at [path] as a stream of its bytes from [start] to [end].
Future<StoredStream> openStoredRead(
  String path, {
  int? start,
  int? end,
  DownloadAsk? ask,
}) async {
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredRefused(StoredNotDownloaded(path));
  }
  _observe(path);
  final RandomAccessFile raf;
  try {
    raf = await File(path).open();
  } on FileSystemException catch (e) {
    return StoredRefused(_refusal(path, e, ask));
  }
  return StoredOpened(_chunks(path, raf, start ?? 0, end, ask));
}

Stream<List<int>> _chunks(
  String path,
  RandomAccessFile raf,
  int start,
  int? end,
  DownloadAsk? ask,
) async* {
  try {
    await raf.setPosition(start);
    var left = end == null ? null : end - start;
    while (true) {
      final want = left == null ? 64 * 1024 : math.min(64 * 1024, left);
      if (want <= 0) break;
      final chunk = await raf.read(want);
      if (chunk.isEmpty) break;
      yield chunk;
      if (left != null) left -= chunk.length;
    }
  } on FileSystemException catch (e) {
    if (e is StorageBusy) rethrow;
    if (notDownloaded(path)) {
      askSafely(path, ask);
      throw StorageBusy(StorageBusyReason.dataless, [path]);
    }
    rethrow;
  } finally {
    await raf.close();
  }
}

/// Opens the file at [path] for reading (read mode only).
Future<StoredFile> openStoredFile(String path, {DownloadAsk? ask}) async {
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredRefused(StoredNotDownloaded(path));
  }
  _observe(path);
  try {
    return StoredOpened(await File(path).open());
  } on FileSystemException catch (e) {
    return StoredRefused(_refusal(path, e, ask));
  }
}

/// The synchronous form of [openStoredFile].
StoredFile openStoredFileSync(String path, {DownloadAsk? ask}) {
  if (notDownloaded(path)) {
    askSafely(path, ask);
    return StoredRefused(StoredNotDownloaded(path));
  }
  _observe(path);
  try {
    return StoredOpened(File(path).openSync());
  } on FileSystemException catch (e) {
    return StoredRefused(_refusal(path, e, ask));
  }
}
