// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

/// A file offered for import. Its bytes are read only when it is used, so
/// its size can be checked first.
final class ImportSource {
  const ImportSource(this.name, {required this.length, required this.read});

  /// A file from a drop or the open dialog.
  factory ImportSource.fromFile(XFile f) =>
      ImportSource(f.name.split(RegExp(r'[\\/]')).last, length: f.length, read: f.readAsBytes);

  /// The name the user sees, with its extension.
  final String name;
  final Future<int> Function() length;
  final Future<Uint8List> Function() read;
}
