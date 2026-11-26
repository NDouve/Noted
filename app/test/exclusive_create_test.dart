// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/exclusive_create.dart';

/// A descriptor on a real file that writes at most [chunk] bytes at a time and
/// fails after [failAfter] bytes have been written (null: never).
class _IoFile implements ExclusiveFile {
  _IoFile(this.raf, {this.chunk = 1 << 20, this.failAfter});

  final RandomAccessFile raf;
  final int chunk;
  final int? failAfter;
  var written = 0;
  bool synced = false, closed = false;

  @override
  int write(Uint8List bytes, int offset) {
    final limit = failAfter;
    if (limit != null && written >= limit) throw const FileSystemException('disk full');
    var n = bytes.length - offset;
    if (n > chunk) n = chunk;
    if (limit != null && written + n > limit) n = limit - written;
    raf.writeFromSync(bytes, offset, offset + n);
    written += n;
    return n;
  }

  @override
  void sync() {
    raf.flushSync();
    synced = true;
  }

  @override
  void close() {
    raf.closeSync();
    closed = true;
  }
}

void main() {
  late Directory dir;
  late String path;
  late List<_IoFile> opened;

  ExclusiveOpener opener({int chunk = 1 << 20, int? failAfter}) => (p) {
    final f = File(p);
    try {
      f.createSync(exclusive: true);
    } on PathExistsException {
      return null;
    }
    final file = _IoFile(f.openSync(mode: FileMode.writeOnly), chunk: chunk, failAfter: failAfter);
    opened.add(file);
    return file;
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted_exclusive_create');
    path = '${dir.path}${Platform.pathSeparator}out.txt';
    opened = [];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 251));

  test('creates the file with every byte, flushes and closes the one descriptor', () async {
    final r = await createExclusive(path, bytes, open: opener(chunk: 300));
    expect(r, ExclusiveOutcome.created);
    expect(File(path).readAsBytesSync(), bytes);
    expect(opened, hasLength(1));
    expect(opened.single.synced, isTrue);
    expect(opened.single.closed, isTrue);
  });

  test('a taken name is left untouched', () async {
    File(path).writeAsBytesSync([1, 2, 3]);
    final r = await createExclusive(path, bytes, open: opener());
    expect(r, ExclusiveOutcome.taken);
    expect(File(path).readAsBytesSync(), [1, 2, 3]);
  });

  test('a failed write removes the partial file when it matches the bytes written', () async {
    await expectLater(
      createExclusive(path, bytes, open: opener(chunk: 100, failAfter: 250)),
      throwsA(isA<ExclusiveWriteFailed>().having((e) => e.left, 'left', isFalse)),
    );
    expect(File(path).existsSync(), isFalse);
    expect(opened.single.closed, isTrue);
  });

  test('a partial file that no longer matches what was written stays', () async {
    final open = opener(chunk: 100, failAfter: 250);
    // Another writer changes the file after Noted's last write and before the
    // cleanup compares it.
    ExclusiveFile? swapping(String p) {
      final f = open(p);
      if (f == null) return null;
      return _Swapping(f as _IoFile, p);
    }

    await expectLater(
      createExclusive(path, bytes, open: swapping),
      throwsA(isA<ExclusiveWriteFailed>().having((e) => e.left, 'left', isTrue)),
    );
    expect(File(path).readAsBytesSync(), [9, 9, 9]);
  });

  test('in the sandbox a partial file is left in place and named', () async {
    await expectLater(
      createExclusive(path, bytes, open: opener(chunk: 100, failAfter: 250), sandboxed: true),
      throwsA(
        isA<ExclusiveWriteFailed>()
            .having((e) => e.message, 'message', 'out.txt may be incomplete.')
            .having((e) => e.left, 'left', isTrue),
      ),
    );
    expect(File(path).lengthSync(), 250);
  });

  test('a failure to open is a FileSystemException, not "taken"', () async {
    await expectLater(
      createExclusive(path, bytes, open: (p) => throw FileSystemException('no folder', p)),
      throwsA(isA<FileSystemException>()),
    );
  });
}

/// Writes other bytes into the file at the moment the write fails.
class _Swapping implements ExclusiveFile {
  _Swapping(this.inner, this.path);

  final _IoFile inner;
  final String path;

  @override
  int write(Uint8List bytes, int offset) {
    try {
      return inner.write(bytes, offset);
    } on FileSystemException {
      inner.raf.closeSync();
      File(path).writeAsBytesSync([9, 9, 9]);
      rethrow;
    }
  }

  @override
  void sync() => inner.sync();

  @override
  void close() {
    try {
      inner.close();
    } on FileSystemException {
      // Already closed by the swap.
    }
  }
}
