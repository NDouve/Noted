// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'binder.dart';

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
