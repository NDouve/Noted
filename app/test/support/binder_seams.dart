// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// Run the binder tests against the old cached write instead of the real store,
/// to see which of them fail on it:
/// `flutter test --dart-define=CACHED_SAVE=true`.
const bool cachedSaveByDefault = bool.fromEnvironment('CACHED_SAVE');

/// What the stores made by [SeamStore] do, shared by one test's notebook.
class Seams {
  /// Behave as before the fix (R-2): a write puts the binder this device last
  /// read or wrote (the caller's cached copy) over the file, with no comparison.
  bool useCached = cachedSaveByDefault;
  final Map<String, Binder> cache = {};

  /// Update number i (from 0) waits for gates[i] when it is there.
  final List<Completer<void>> gates = [];

  /// Every update throws a [FileSystemException] before it moves the file
  /// aside while this is above zero (counted down per try).
  int failMoves = 0;

  /// The next this-many temporary-file writes throw.
  int failTempWrites = 0;

  /// The next temporary-file write writes only the first half of its bytes,
  /// runs [afterPartialTemp] (to let someone else replace the file), and throws.
  bool partialTempWrite = false;
  void Function(File temp)? afterPartialTemp;

  /// Runs on every try of an update, before the file is moved aside / before the
  /// new file is published / after the aside's bytes were read.
  void Function()? beforeMoveAside;
  void Function()? beforePublish;
  void Function()? afterRead;

  /// Runs after each `sweepLeftovers`.
  void Function()? afterSweep;

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
}

/// A [BinderStore] with the seams of [Seams].
class SeamStore extends BinderStore {
  SeamStore(super.directory, this.seams) : super(retryDelay: Duration.zero);

  final Seams seams;

  @override
  Future<BinderSweep> sweepLeftovers({required bool restore}) async {
    final r = await super.sweepLeftovers(restore: restore);
    try {
      seams.cache[directory.path] = Binder.parse(utf8.decode(file.readAsBytesSync()));
    } on Object {
      // Not a binder.
    }
    seams.afterSweep?.call();
    return r;
  }

  @override
  Future<void> writeTemp(File temp, List<int> bytes) async {
    if (seams.partialTempWrite) {
      seams.partialTempWrite = false;
      await temp.writeAsBytes(bytes.sublist(0, (bytes.length / 2).floor()), flush: true);
      seams.afterPartialTemp?.call(temp);
      throw FileSystemException('simulated partial write', temp.path);
    }
    if (seams.failTempWrites > 0) {
      seams.failTempWrites--;
      throw FileSystemException('simulated write failure', temp.path);
    }
    return await super.writeTemp(temp, bytes);
  }

  @override
  Future<BinderUpdate> update(
    BinderDelta d, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) async {
    final n = seams.updates++;
    if (n < seams.gates.length) await seams.gates[n].future;
    if (seams.useCached) {
      final cached = seams.cache[directory.path];
      if (cached == null) return const BinderRefused(BinderRefusal.gone, 'nothing cached');
      final next = d.apply(cached);
      final tmp = File('${file.path}.tmp');
      try {
        if (seams.failMoves > 0) {
          seams.failMoves--;
          throw FileSystemException('simulated failure', file.path);
        }
        await tmp.writeAsString(next.write(), flush: true);
        await tmp.rename(file.path);
      } on FileSystemException catch (e) {
        return BinderRefused(BinderRefusal.inUse, 'The binder file is in use by another program (${e.message})');
      }
      seams.cache[directory.path] = next;
      return BinderUpdated(next, next.write(), wrote: true);
    }
    return super.update(
      d,
      beforeMoveAside: () {
        if (seams.failMoves > 0) {
          seams.failMoves--;
          throw FileSystemException('simulated move failure', file.path);
        }
        seams.beforeMoveAside?.call();
        beforeMoveAside?.call();
      },
      afterRead: () {
        seams.afterRead?.call();
        afterRead?.call();
      },
      beforePublish: () {
        seams.beforePublish?.call();
        beforePublish?.call();
      },
      beforeRestore: beforeRestore,
    );
  }
}
