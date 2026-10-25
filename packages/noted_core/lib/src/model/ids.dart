// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

final Random _random = Random.secure();

/// Returns a random 64-bit id as 16 lowercase hex digits, the id style
/// JSON Canvas files commonly use. Used for page ids, box ids and revisions.
String newId() {
  final b = StringBuffer();
  for (var i = 0; i < 8; i++) {
    b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}
