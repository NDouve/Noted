// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

/// OneDrive's `quickXorHash`, written from Microsoft's description of the
/// algorithm (a 160-bit value; each byte is XORed into it at a bit position
/// that advances by 11 bits per byte and wraps around; the total length, as 64
/// bits little-endian, is XORed into the last 8 bytes at the end).
///
/// Use it as a sink: [add] any number of chunks of any size, then [close] once.
class QuickXorHash {
  static const int _bytes = 20;
  static const int _bits = _bytes * 8;
  static const int _shift = 11;

  final Uint8List _state = Uint8List(_bytes);
  int _bitPos = 0;
  int _length = 0;
  bool _closed = false;

  /// Feeds [chunk] into the hash.
  void add(List<int> chunk) {
    if (_closed) throw StateError('QuickXorHash is closed');
    var pos = _bitPos;
    for (var i = 0; i < chunk.length; i++) {
      final v = (chunk[i] & 0xff) << (pos & 7);
      final at = pos >> 3;
      _state[at] ^= v & 0xff;
      _state[(at + 1) % _bytes] ^= v >> 8;
      pos += _shift;
      if (pos >= _bits) pos -= _bits;
    }
    _bitPos = pos;
    _length += chunk.length;
  }

  /// Finishes the hash and returns its 20 bytes.
  Uint8List close() {
    if (_closed) throw StateError('QuickXorHash is closed');
    _closed = true;
    final out = Uint8List.fromList(_state);
    var n = _length;
    for (var i = 0; i < 8; i++) {
      out[_bytes - 8 + i] ^= n & 0xff;
      n = n >> 8;
    }
    return out;
  }

  /// The hash of [bytes] in OneDrive's form (base64 of the 20 bytes).
  static String ofBytes(List<int> bytes) {
    final h = QuickXorHash()..add(bytes);
    return base64.encode(h.close());
  }

  /// The hash of a stream of chunks in OneDrive's form, without holding the
  /// whole stream.
  static Future<String> ofStream(Stream<List<int>> chunks) async {
    final h = QuickXorHash();
    await for (final c in chunks) {
      h.add(c);
    }
    return base64.encode(h.close());
  }
}
