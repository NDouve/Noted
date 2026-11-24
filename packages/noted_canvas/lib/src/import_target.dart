// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/painting.dart';

import 'attachment_store.dart';

/// The notice for an import that stopped because the page it was for is no
/// longer the open one.
const String importStoppedNotice = 'Import stopped: the page changed.';

/// Where an import goes, captured when the user drops files or runs the
/// command and kept until the last box (Host only: it is not part of the Box
/// API). It wraps the canvas's paste target: the controller, the page, the
/// attachment store, the point and the types the page disallows. Only the
/// canvas that made it ([PageCanvasState.captureImportTarget]) reads it.
final class ImportTarget {
  /// For the canvas that makes it.
  ImportTarget.internal({
    required this.wrapped,
    required this.pageId,
    required this.store,
    required this.point,
    required this.disallowed,
    required this.check,
  });

  /// The canvas's own paste target; opaque to everyone else.
  final Object wrapped;

  /// The page the import is for.
  final String pageId;

  /// The box types the page disallowed when this was captured.
  final Set<String> disallowed;

  /// The page's attachment store, for notices.
  final AttachmentStore store;

  /// Where the next box goes. [PageCanvasState.insertImportInto] moves it on
  /// past what it placed, so the next call doesn't land on top.
  Offset point;

  /// The canvas's own test of the target.
  final bool Function() check;

  /// Whether the page, controller and store are still the ones this was made
  /// for, and the canvas can still be changed. Check it after a dialog, after
  /// a conversion and before each file and box.
  bool get holds => check();
}

/// What [PageCanvasState.insertImportInto] did.
final class ImportInsert {
  const ImportInsert({
    this.added = 0,
    this.failed = const [],
    this.unwritable = const [],
    this.stopped = false,
    this.refused = false,
  });

  /// Boxes added.
  final int added;

  /// Names of files the page's folder could not store (no box was made).
  final List<String> unwritable;

  /// Names of files no box could be made of.
  final List<String> failed;

  /// The target no longer held; the rest was not stored or added, and the
  /// user was told.
  final bool stopped;

  /// The module is switched off or the page doesn't allow its type, so
  /// nothing was done.
  final bool refused;
}
