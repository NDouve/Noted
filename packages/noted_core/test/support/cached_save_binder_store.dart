// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// A test-only copy of the behaviour before binder writes were fixed (R-2):
/// a save writes the binder this store last read or wrote (the caller's cached
/// copy), never what is on disk now, and renames it over the file with no
/// comparison. Tests that must fail on that code run against it.
class CachedSaveBinderStore extends BinderStore {
  CachedSaveBinderStore(super.directory, this.cache);

  /// The cached binders by folder path, shared by every store of a notebook
  /// (as `BinderSection.binder` was).
  final Map<String, Binder> cache;

  @override
  Future<BinderRead> read() async {
    final r = await super.read();
    if (r is BinderFound) cache[directory.path] = r.binder;
    return r;
  }

  @override
  Future<BinderUpdate> update(
    Binder Function(Binder onDisk) change, {
    required String binderId,
    void Function()? beforeCompare,
    void Function()? beforeRename,
  }) async {
    final cached = cache[directory.path];
    if (cached == null) {
      return const BinderRefused(BinderRefusal.gone, 'nothing cached');
    }
    final next = change(cached);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(next.write(), flush: true);
    beforeRename?.call();
    await tmp.rename(file.path);
    cache[directory.path] = next;
    return BinderUpdated(next, next.write(), wrote: true);
  }
}
