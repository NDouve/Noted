// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file operation seen by [countingIo].
class IoOp {
  const IoOp(this.kind, this.path);

  /// `read` (any way of reading the contents), `exists` (a directory checked
  /// with `exists()`), `write` (writing contents or
  /// opening for writing) or `rename` (the path is the one renamed to).
  final String kind;
  final String path;

  @override
  String toString() => '$kind $path';
}

/// Records the file reads, writes and renames made while a test runs.
class IoLog {
  final List<IoOp> ops = [];

  /// Contents reads of the files whose path ends with [suffix].
  int reads(String suffix) =>
      ops.where((o) => o.kind == 'read' && o.path.endsWith(suffix)).length;

  /// All contents reads.
  int get totalReads => ops.where((o) => o.kind == 'read').length;

  /// Existence checks of [path].
  int existsChecks(String path) =>
      ops.where((o) => o.kind == 'exists' && o.path == path).length;

  /// Renames onto [path] (the publish step of an atomic save).
  int renamesTo(String path) =>
      ops.where((o) => o.kind == 'rename' && o.path == path).length;

  /// Writes of contents to the files whose path ends with [suffix].
  int writes(String suffix) =>
      ops.where((o) => o.kind == 'write' && o.path.endsWith(suffix)).length;

  void clear() => ops.clear();
}

/// Runs [body] with every `File` and `Directory` made in it counted into
/// [log]. Files listed from a directory are counted too. Nothing else about
/// them changes: each call goes to the real file.
Future<T> countingIo<T>(IoLog log, Future<T> Function() body) =>
    IOOverrides.runWithIOOverrides(body, _CountingOverrides(log));

base class _CountingOverrides extends IOOverrides {
  _CountingOverrides(this.log);
  final IoLog log;

  // Makes the platform file or directory: the base class does that.
  static final IOOverrides _plain = _Plain();

  @override
  File createFile(String path) => _CountingFile(
    IOOverrides.runWithIOOverrides(() => File(path), _plain),
    log,
  );

  @override
  Directory createDirectory(String path) => _CountingDirectory(
    IOOverrides.runWithIOOverrides(() => Directory(path), _plain),
    log,
  );
}

base class _Plain extends IOOverrides {}

class _CountingFile implements File {
  _CountingFile(this._f, this._log);
  final File _f;
  final IoLog _log;

  void _note(String kind) => _log.ops.add(IoOp(kind, _f.path));

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    _note('read');
    return _f.readAsString(encoding: encoding);
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    _note('read');
    return _f.readAsStringSync(encoding: encoding);
  }

  @override
  Future<Uint8List> readAsBytes() {
    _note('read');
    return _f.readAsBytes();
  }

  @override
  Uint8List readAsBytesSync() {
    _note('read');
    return _f.readAsBytesSync();
  }

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) {
    _note('read');
    return _f.readAsLines(encoding: encoding);
  }

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) {
    _note('read');
    return _f.readAsLinesSync(encoding: encoding);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    _note('read');
    return _f.openRead(start, end);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    _note(mode == FileMode.read ? 'read' : 'write');
    return _f.open(mode: mode);
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    _note(mode == FileMode.read ? 'read' : 'write');
    return _f.openSync(mode: mode);
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    _note('write');
    return _f.openWrite(mode: mode, encoding: encoding);
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    _note('write');
    await _f.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _note('write');
    _f.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    _note('write');
    await _f.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    _note('write');
    _f.writeAsBytesSync(bytes, mode: mode, flush: flush);
  }

  @override
  Future<File> rename(String newPath) async {
    _log.ops.add(IoOp('rename', newPath));
    return _CountingFile(await _f.rename(newPath), _log);
  }

  @override
  File renameSync(String newPath) {
    _log.ops.add(IoOp('rename', newPath));
    return _CountingFile(_f.renameSync(newPath), _log);
  }

  @override
  Future<File> copy(String newPath) async =>
      _CountingFile(await _f.copy(newPath), _log);

  @override
  File copySync(String newPath) => _CountingFile(_f.copySync(newPath), _log);

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await _f.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _f.createSync(recursive: recursive, exclusive: exclusive);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _f.delete(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      _f.deleteSync(recursive: recursive);

  @override
  Future<int> length() => _f.length();
  @override
  int lengthSync() => _f.lengthSync();
  @override
  File get absolute => _CountingFile(_f.absolute, _log);
  @override
  Future<DateTime> lastAccessed() => _f.lastAccessed();
  @override
  DateTime lastAccessedSync() => _f.lastAccessedSync();
  @override
  Future<void> setLastAccessed(DateTime time) => _f.setLastAccessed(time);
  @override
  void setLastAccessedSync(DateTime time) => _f.setLastAccessedSync(time);
  @override
  Future<DateTime> lastModified() => _f.lastModified();
  @override
  DateTime lastModifiedSync() => _f.lastModifiedSync();
  @override
  Future<void> setLastModified(DateTime time) => _f.setLastModified(time);
  @override
  void setLastModifiedSync(DateTime time) => _f.setLastModifiedSync(time);
  @override
  String get path => _f.path;
  @override
  Uri get uri => _f.uri;
  @override
  Future<bool> exists() => _f.exists();
  @override
  bool existsSync() => _f.existsSync();
  @override
  Future<String> resolveSymbolicLinks() => _f.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => _f.resolveSymbolicLinksSync();
  @override
  Future<FileStat> stat() => _f.stat();
  @override
  FileStat statSync() => _f.statSync();
  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => _f.watch(events: events, recursive: recursive);
  @override
  bool get isAbsolute => _f.isAbsolute;
  @override
  Directory get parent => _CountingDirectory(_f.parent, _log);
}

class _CountingDirectory implements Directory {
  _CountingDirectory(this._d, this._log);
  final Directory _d;
  final IoLog _log;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    await for (final e in _d.list(
      recursive: recursive,
      followLinks: followLinks,
    )) {
      yield e is File ? _CountingFile(e, _log) : e;
    }
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => [
    for (final e in _d.listSync(recursive: recursive, followLinks: followLinks))
      e is File ? _CountingFile(e, _log) : e,
  ];

  @override
  Future<Directory> create({bool recursive = false}) async {
    await _d.create(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) =>
      _d.createSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _CountingDirectory(await _d.createTemp(prefix), _log);
  @override
  Directory createTempSync([String? prefix]) =>
      _CountingDirectory(_d.createTempSync(prefix), _log);
  @override
  Future<Directory> rename(String newPath) async =>
      _CountingDirectory(await _d.rename(newPath), _log);
  @override
  Directory renameSync(String newPath) =>
      _CountingDirectory(_d.renameSync(newPath), _log);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _d.delete(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      _d.deleteSync(recursive: recursive);
  @override
  Directory get absolute => _CountingDirectory(_d.absolute, _log);
  @override
  String get path => _d.path;
  @override
  Uri get uri => _d.uri;
  @override
  Future<bool> exists() {
    _log.ops.add(IoOp('exists', _d.path));
    return _d.exists();
  }

  @override
  bool existsSync() => _d.existsSync();
  @override
  Future<String> resolveSymbolicLinks() => _d.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => _d.resolveSymbolicLinksSync();
  @override
  Future<FileStat> stat() => _d.stat();
  @override
  FileStat statSync() => _d.statSync();
  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => _d.watch(events: events, recursive: recursive);
  @override
  bool get isAbsolute => _d.isAbsolute;
  @override
  Directory get parent => _CountingDirectory(_d.parent, _log);
}
