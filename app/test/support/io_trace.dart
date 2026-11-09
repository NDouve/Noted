// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Test-only tracing of file operations, to explain a Windows sharing
/// violation (errno 32, and its relatives 5, 33 and 145).
///
/// Off unless the environment variable `NOTED_IO_TRACE` is `1` (the Windows CI
/// job sets it). Then every `File` and `Directory` the tests make is wrapped
/// by [TracingIoOverrides]: each read, write, rename, copy and delete is noted
/// with its path, when it started and ended, and the application code that
/// called it. When one fails with a sharing error, [IoTrace.report] prints
/// what else touched that path just before, and what was still running on it.
///
/// Only paths, operation names, times and the calling source lines are
/// recorded. Page content and file names beyond the last two path segments
/// never are. Each report line starts with `[io-trace]`, so the CI annotation
/// can keep them whole.
bool get ioTraceEnabled => Platform.environment['NOTED_IO_TRACE'] == '1';

/// Windows errors that mean "another handle has this file or folder":
/// 5 access denied, 32 sharing violation, 33 lock violation, 145 directory
/// not empty (something wrote into it as it was removed).
const Set<int> _busyCodes = {5, 32, 33, 145};

class _Event {
  _Event(this.id, this.op, this.path, this.to, this.startUs, this.label);
  final int id;
  final String op;
  final String path;
  final String? to;
  final int startUs;
  final String label;
  int? endUs;
  String? error;
}

/// The recent file operations of this test process.
class IoTrace {
  IoTrace({this.keep = 3000, this.window = const Duration(seconds: 3)});

  /// The process-wide trace that [TracingIoOverrides] writes to.
  static final IoTrace instance = IoTrace();

  /// How many operations are remembered.
  final int keep;

  /// How far back a report looks.
  final Duration window;

  final Queue<_Event> _events = Queue();
  final Stopwatch _clock = Stopwatch()..start();
  int _next = 0;

  /// Reports printed so far (for a test).
  final List<String> reports = [];

  /// Where a report goes: the test's own output.
  void Function(String line) sink = (line) => debugPrint(line);

  int begin(String op, String path, {String? to}) {
    final e = _Event(_next++, op, _norm(path), to == null ? null : _norm(to), _clock.elapsedMicroseconds, _caller());
    _events.add(e);
    while (_events.length > keep) {
      _events.removeFirst();
    }
    return e.id;
  }

  void end(int id, [Object? error]) {
    // Newest first: an operation usually ends soon after it started.
    for (final e in _events.toList().reversed) {
      if (e.id != id) continue;
      e.endUs = _clock.elapsedMicroseconds;
      if (error != null) e.error = _code(error);
      return;
    }
  }

  /// Notes the failure [error] of [op] on [path], and prints a report when
  /// it is a sharing error.
  void failed(int id, String op, String path, Object error, {String? to}) {
    end(id, error);
    if (error is! FileSystemException) return;
    final code = error.osError?.errorCode;
    if (code == null || !_busyCodes.contains(code)) return;
    report(op, path, code, to: to);
  }

  /// Prints, and returns, what touched [path] in the last [window].
  String report(String op, String path, int code, {String? to}) {
    final text = describe(op, path, code, to: to);
    reports.add(text);
    for (final line in text.split('\n')) {
      sink(line);
    }
    return text;
  }

  String describe(String op, String path, int code, {String? to}) {
    final now = _clock.elapsedMicroseconds;
    final p = _norm(path);
    final related = {p, if (to != null) _norm(to)};
    bool touches(_Event e) =>
        related.contains(e.path) ||
        (e.to != null && related.contains(e.to)) ||
        // A folder operation touches everything under it, and a file the
        // folder it is in.
        related.any((r) => e.path.startsWith('$r/') || r.startsWith('${e.path}/'));
    final out = StringBuffer('[io-trace] $op failed with errno $code on ${_short(p)}');
    if (to != null) out.write(' (to ${_short(_norm(to))})');
    final hits = _events.where(touches).where((e) => now - e.startUs <= window.inMicroseconds).toList();
    final busy = hits.where((e) => e.endUs == null && e.op.startsWith('read') || e.endUs == null && e.op == 'openRead').toList();
    if (hits.isEmpty) {
      out.write('\n[io-trace]   nothing else in this process touched it in the last ${window.inSeconds} s');
    }
    for (final e in busy) {
      out.write('\n[io-trace]   STILL RUNNING: ${_line(e, now)}');
    }
    for (final e in hits.skip(hits.length > 25 ? hits.length - 25 : 0)) {
      if (busy.contains(e)) continue;
      out.write('\n[io-trace]   ${_line(e, now)}');
    }
    return out.toString();
  }

  String _line(_Event e, int now) {
    final ago = ((now - e.startUs) / 1000).round();
    final took = e.endUs == null ? 'not finished' : 'took ${((e.endUs! - e.startUs) / 1000).toStringAsFixed(1)} ms';
    final err = e.error == null ? '' : ', failed ${e.error}';
    final to = e.to == null ? '' : ' -> ${_short(e.to!)}';
    return '-$ago ms ${e.op} ${_short(e.path)}$to ($took$err) from ${e.label}';
  }

  // The file's own name and its folder's: enough to tell the files apart, and
  // no user-folder path.
  static String _short(String p) {
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    return parts.length <= 2 ? p : '.../${parts.sublist(parts.length - 2).join('/')}';
  }

  static String _norm(String p) => p.replaceAll('\\', '/');

  static String _code(Object error) {
    if (error is FileSystemException) {
      final c = error.osError?.errorCode;
      return c == null ? 'FileSystemException' : 'errno $c';
    }
    return error.runtimeType.toString();
  }

  static final RegExp _frame = RegExp(r'^#\d+\s+(\S+)\s+\((package:[^)]*)\)');

  /// The first frames in the application's or the packages' code.
  static String _caller() {
    final found = <String>[];
    for (final line in StackTrace.current.toString().split('\n')) {
      final m = _frame.firstMatch(line);
      if (m == null) continue;
      final where = m.group(2)!;
      if (!(where.startsWith('package:noted') || where.startsWith('package:noted_'))) continue;
      final file = where.split('/').last.replaceAll(RegExp(r':\d+\)?$'), '');
      found.add('${m.group(1)} $file');
      if (found.length == 2) break;
    }
    return found.isEmpty ? 'test code' : found.join(' < ');
  }
}

/// Wraps the files and folders made while it is the zone's overrides.
base class TracingIoOverrides extends IOOverrides {
  TracingIoOverrides([IoTrace? trace]) : trace = trace ?? IoTrace.instance;
  final IoTrace trace;

  static final IOOverrides _plain = _Plain();

  @override
  File createFile(String path) =>
      TracingFile(IOOverrides.runWithIOOverrides(() => File(path), _plain), trace);

  @override
  Directory createDirectory(String path) =>
      TracingDirectory(IOOverrides.runWithIOOverrides(() => Directory(path), _plain), trace);
}

base class _Plain extends IOOverrides {}

class TracingFile implements File {
  TracingFile(this._f, this._t);
  final File _f;
  final IoTrace _t;

  Future<T> _run<T>(String op, Future<T> Function() f, {String? to}) async {
    final id = _t.begin(op, _f.path, to: to);
    try {
      final r = await f();
      _t.end(id);
      return r;
    } catch (e) {
      _t.failed(id, op, _f.path, e, to: to);
      rethrow;
    }
  }

  T _runSync<T>(String op, T Function() f, {String? to}) {
    final id = _t.begin(op, _f.path, to: to);
    try {
      final r = f();
      _t.end(id);
      return r;
    } catch (e) {
      _t.failed(id, op, _f.path, e, to: to);
      rethrow;
    }
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _run('read', () => _f.readAsString(encoding: encoding));
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _runSync('readSync', () => _f.readAsStringSync(encoding: encoding));
  @override
  Future<Uint8List> readAsBytes() => _run('read', _f.readAsBytes);
  @override
  Uint8List readAsBytesSync() => _runSync('readSync', _f.readAsBytesSync);
  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) =>
      _run('read', () => _f.readAsLines(encoding: encoding));
  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      _runSync('readSync', () => _f.readAsLinesSync(encoding: encoding));

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    final id = _t.begin('openRead', _f.path);
    return _f.openRead(start, end).transform(
      StreamTransformer.fromHandlers(
        handleError: (e, s, sink) {
          _t.failed(id, 'openRead', _f.path, e);
          sink.addError(e, s);
        },
        handleDone: (sink) {
          _t.end(id);
          sink.close();
        },
      ),
    );
  }

  // The returned handle is not followed: it stays in the trace as opened.
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _run(mode == FileMode.read ? 'open' : 'openWrite', () => _f.open(mode: mode));
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _runSync(mode == FileMode.read ? 'openSync' : 'openWriteSync', () => _f.openSync(mode: mode));

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    final id = _t.begin('openWrite', _f.path);
    final sink = _f.openWrite(mode: mode, encoding: encoding);
    unawaited(
      sink.done.then<void>(
        (_) => _t.end(id),
        onError: (Object e) => _t.failed(id, 'openWrite', _f.path, e),
      ),
    );
    return sink;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await _run('write', () => _f.writeAsString(contents, mode: mode, encoding: encoding, flush: flush));
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _runSync(
    'writeSync',
    () => _f.writeAsStringSync(contents, mode: mode, encoding: encoding, flush: flush),
  );

  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    await _run('write', () => _f.writeAsBytes(bytes, mode: mode, flush: flush));
    return this;
  }

  @override
  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) =>
      _runSync('writeSync', () => _f.writeAsBytesSync(bytes, mode: mode, flush: flush));

  @override
  Future<File> rename(String newPath) async =>
      TracingFile(await _run('rename', () => _f.rename(newPath), to: newPath), _t);
  @override
  File renameSync(String newPath) => TracingFile(_runSync('renameSync', () => _f.renameSync(newPath), to: newPath), _t);

  @override
  Future<File> copy(String newPath) async =>
      TracingFile(await _run('copy', () => _f.copy(newPath), to: newPath), _t);
  @override
  File copySync(String newPath) => TracingFile(_runSync('copySync', () => _f.copySync(newPath), to: newPath), _t);

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await _run('create', () => _f.create(recursive: recursive, exclusive: exclusive));
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _runSync('createSync', () => _f.createSync(recursive: recursive, exclusive: exclusive));

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _run('delete', () => _f.delete(recursive: recursive));
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) => _runSync('deleteSync', () => _f.deleteSync(recursive: recursive));

  @override
  Future<int> length() => _f.length();
  @override
  int lengthSync() => _f.lengthSync();
  @override
  File get absolute => TracingFile(_f.absolute, _t);
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
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      _f.watch(events: events, recursive: recursive);
  @override
  bool get isAbsolute => _f.isAbsolute;
  @override
  Directory get parent => TracingDirectory(_f.parent, _t);
}

class TracingDirectory implements Directory {
  TracingDirectory(this._d, this._t);
  final Directory _d;
  final IoTrace _t;

  Future<T> _run<T>(String op, Future<T> Function() f, {String? to}) async {
    final id = _t.begin(op, _d.path, to: to);
    try {
      final r = await f();
      _t.end(id);
      return r;
    } catch (e) {
      _t.failed(id, op, _d.path, e, to: to);
      rethrow;
    }
  }

  T _runSync<T>(String op, T Function() f, {String? to}) {
    final id = _t.begin(op, _d.path, to: to);
    try {
      final r = f();
      _t.end(id);
      return r;
    } catch (e) {
      _t.failed(id, op, _d.path, e, to: to);
      rethrow;
    }
  }

  FileSystemEntity _wrap(FileSystemEntity e) => e is File ? TracingFile(e, _t) : e;

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    await for (final e in _d.list(recursive: recursive, followLinks: followLinks)) {
      yield _wrap(e);
    }
  }

  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => [
    for (final e in _d.listSync(recursive: recursive, followLinks: followLinks)) _wrap(e),
  ];

  @override
  Future<Directory> create({bool recursive = false}) async {
    await _d.create(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) => _d.createSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async => TracingDirectory(await _d.createTemp(prefix), _t);
  @override
  Directory createTempSync([String? prefix]) => TracingDirectory(_d.createTempSync(prefix), _t);
  @override
  Future<Directory> rename(String newPath) async =>
      TracingDirectory(await _run('renameDir', () => _d.rename(newPath), to: newPath), _t);
  @override
  Directory renameSync(String newPath) =>
      TracingDirectory(_runSync('renameDirSync', () => _d.renameSync(newPath), to: newPath), _t);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _run('deleteDir', () => _d.delete(recursive: recursive));
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      _runSync('deleteDirSync', () => _d.deleteSync(recursive: recursive));
  @override
  Directory get absolute => TracingDirectory(_d.absolute, _t);
  @override
  String get path => _d.path;
  @override
  Uri get uri => _d.uri;
  @override
  Future<bool> exists() => _d.exists();
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
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      _d.watch(events: events, recursive: recursive);
  @override
  bool get isAbsolute => _d.isAbsolute;
  @override
  Directory get parent => TracingDirectory(_d.parent, _t);
}
