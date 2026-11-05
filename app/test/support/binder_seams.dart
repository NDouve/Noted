// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// Run the binder tests against the old cached save instead of the real
/// store, to see which of them fail on it:
/// `flutter test --dart-define=CACHED_SAVE=true`.
const bool cachedSaveByDefault = bool.fromEnvironment('CACHED_SAVE');

/// What the stores made by [SeamStore] do, shared by one test's notebook.
class Seams {
  /// Behave as before the fix (R-2): a save writes the binder this device last
  /// read or wrote, with no comparison.
  bool useCached = cachedSaveByDefault;
  final Map<String, Binder> cache = {};

  /// Update number i (from 0) waits for gates[i] when it is there.
  final List<Completer<void>> gates = [];

  /// The next this-many renames throw a [FileSystemException].
  int failRenames = 0;

  /// Reads fail with an I/O error while true.
  bool failReads = false;

  void Function()? beforeCompare;
  void Function()? beforeRename;
  int updates = 0;

  /// Holds the next update that has not been held yet: it waits until the
  /// returned completer is completed.
  Completer<void> holdNext() {
    while (gates.length < updates) {
      gates.add(Completer<void>()..complete());
    }
    final c = Completer<void>();
    gates.add(c);
    return c;
  }

  /// Runs after a new binder file is written and before it is published.
  void Function()? beforePublish;
}

/// A [BinderStore] with the seams of [Seams].
class SeamStore extends BinderStore {
  SeamStore(super.directory, this.seams) : super(retryDelay: Duration.zero);

  final Seams seams;

  @override
  Future<BinderRead> read() async {
    if (seams.failReads) return const BinderReadFailed('simulated read error');
    final r = await super.read();
    if (r is BinderFound) seams.cache[directory.path] = r.binder;
    return r;
  }

  @override
  Future<BinderCreated> create(Binder binder, {void Function()? beforePublish}) async {
    final r = await super.create(
      binder,
      beforePublish: () {
        seams.beforePublish?.call();
        beforePublish?.call();
      },
    );
    if (r == BinderCreated.created) seams.cache[directory.path] = binder;
    return r;
  }

  @override
  Future<BinderUpdate> update(
    Binder Function(Binder onDisk) change, {
    required String binderId,
    void Function()? beforeCompare,
    void Function()? beforeRename,
  }) async {
    final n = seams.updates++;
    if (n < seams.gates.length) await seams.gates[n].future;
    void rename() {
      seams.beforeRename?.call();
      if (seams.failRenames > 0) {
        seams.failRenames--;
        throw FileSystemException('simulated rename failure', file.path);
      }
    }

    if (seams.useCached) {
      final cached = seams.cache[directory.path];
      if (cached == null) return const BinderRefused(BinderRefusal.gone, 'nothing cached');
      final next = change(cached);
      final tmp = File('${file.path}.tmp');
      try {
        await tmp.writeAsString(next.write(), flush: true);
        rename();
        await tmp.rename(file.path);
      } on FileSystemException catch (e) {
        return BinderRefused(BinderRefusal.inUse, 'The binder file is in use by another program (${e.message})');
      }
      seams.cache[directory.path] = next;
      return BinderUpdated(next, next.write(), wrote: true);
    }
    return super.update(
      change,
      binderId: binderId,
      beforeCompare: () {
        seams.beforeCompare?.call();
        beforeCompare?.call();
      },
      beforeRename: () {
        rename();
        beforeRename?.call();
      },
    );
  }
}
