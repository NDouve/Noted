// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

/// One job at a time per folder. A job is a single store call (a scan, a
/// compare-and-swap write or delete) and never awaits another locked call on
/// its folder. Nested [run] calls on the same folder queue behind the running
/// job, as any other call would.
///
/// Share one instance between the notebook and anything else that writes page
/// files in the same folders, so their jobs exclude each other.
class FolderLocks {
  final Map<String, Future<void>> _tails = {};

  static const Object _zoneKey = #notedFolderLocksHeld;

  /// The same folder under any spelling: a trailing separator, case on
  /// Windows, symbolic links when the folder exists.
  static String keyOf(Directory folder) {
    var p = _normalize(folder.path);
    try {
      if (folder.existsSync()) p = _normalize(folder.resolveSymbolicLinksSync());
    } on FileSystemException {
      // Keep the normalised path.
    }
    final k = File(p).absolute.path.replaceAll(r'\', '/');
    return Platform.isWindows ? k.toLowerCase() : k;
  }

  static String _normalize(String path) {
    var p = Directory(path).absolute.path;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\')) && !p.endsWith(r':\')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// Runs [job] after every earlier job on [folder] has finished. An error in
  /// one job doesn't block the next. The entry is removed when idle.
  Future<T> run<T>(Directory folder, Future<T> Function() job) {
    final key = keyOf(folder);
    final held = <String>{...?(Zone.current[_zoneKey] as Set<String>?), key};
    final run = (_tails[key] ?? Future<void>.value()).then(
      (_) => runZoned(job, zoneValues: {_zoneKey: held}),
    );
    final done = run.then<void>((_) {}, onError: (_) {});
    _tails[key] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_tails[key], done)) _tails.remove(key);
      }),
    );
    return run;
  }

  /// Whether the current code runs inside a job on [folder] (any instance).
  static bool isHeld(Directory folder) =>
      (Zone.current[_zoneKey] as Set<String>?)?.contains(keyOf(folder)) ?? false;

  /// How many folders have a job running or queued.
  int get busyCount => _tails.length;
}
