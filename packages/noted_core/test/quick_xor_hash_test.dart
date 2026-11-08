// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

// The reference below is written from Microsoft's description, one bit at a
// time: bit k of byte n goes to bit (11 * n + k) mod 160 of the vector, and
// the length goes into the top 64 bits. It shares no code with the
// implementation. It reproduced all of rclone's published vectors
// (backend/onedrive/quickxorhash/quickxorhash_test.go, fetched 2026-11-08) when
// this was written; they aren't copied here.
String _reference(List<int> data) {
  final bits = List<int>.filled(160, 0);
  for (var n = 0; n < data.length; n++) {
    for (var k = 0; k < 8; k++) {
      bits[(11 * n + k) % 160] ^= (data[n] >> k) & 1;
    }
  }
  for (var k = 0; k < 64; k++) {
    bits[96 + k] ^= (data.length >> k) & 1;
  }
  final out = List<int>.filled(20, 0);
  for (var i = 0; i < 160; i++) {
    out[i >> 3] |= bits[i] << (i & 7);
  }
  return base64.encode(out);
}

List<int> _input(int size) =>
    List<int>.generate(size, (i) => (i * 31 + 7 + size) & 0xff);

void main() {
  final sizes = [for (var i = 0; i <= 64; i++) i, 111, 128, 222, 256, 333];

  test('literal expected values, so a change in both can not pass', () {
    expect(QuickXorHash.ofBytes(const []), 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    expect(
      QuickXorHash.ofBytes(utf8.encode('Noted')),
      'TngDHcpABgAAAAAABQAAAAAAAAA=',
    );
    expect(
      QuickXorHash.ofBytes(
        utf8.encode('The quick brown fox jumps over the lazy dog'),
      ),
      'bMSlbysmxJL6S75XwfMcQZOpcr4=',
    );
    expect(
      QuickXorHash.ofBytes(List<int>.generate(256, (i) => i)),
      'QkGEfSisZcA7k+FCh71r2dbCayY=',
    );
    expect(
      QuickXorHash.ofBytes(List<int>.filled(1000, 0xAB)),
      'nOEMZzjDGc5whjOcCQ9nk5vc5CY=',
    );
  });

  test('matches the reference for every size 0 to 64 and some larger', () {
    for (final size in sizes) {
      expect(
        QuickXorHash.ofBytes(_input(size)),
        _reference(_input(size)),
        reason: 'size $size',
      );
    }
  });

  test('gives the same hash for odd-sized chunks', () {
    for (final chunk in [1, 2, 3, 7, 19, 20, 21, 64, 100, 159, 161, 500]) {
      for (final size in sizes) {
        final data = _input(size);
        final h = QuickXorHash();
        for (var i = 0; i < data.length; i += chunk) {
          h.add(
            data.sublist(i, i + chunk > data.length ? data.length : i + chunk),
          );
        }
        expect(
          base64.encode(h.close()),
          _reference(data),
          reason: 'size $size chunk $chunk',
        );
      }
    }
  });

  test('ofStream reads chunks and an empty stream is all zero', () async {
    final data = _input(333);
    final chunks = Stream.fromIterable([
      data.sublist(0, 5),
      <int>[],
      data.sublist(5, 200),
      data.sublist(200),
    ]);
    expect(await QuickXorHash.ofStream(chunks), _reference(data));
    expect(
      await QuickXorHash.ofStream(const Stream.empty()),
      'AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
  });

  test('a long input beyond the 160-bit wrap matches the reference, from a file too', () async {
    final data = List<int>.generate(100000, (i) => (i * 31 + 7) & 0xff);
    final dir = await Directory.systemTemp.createTemp('qxh');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/x.bin')..writeAsBytesSync(data);
    expect(await QuickXorHash.ofStream(f.openRead()), _reference(data));
    expect(QuickXorHash.ofBytes(data), _reference(data));
  });

  test('close twice throws', () {
    final h = QuickXorHash()..close();
    expect(h.close, throwsStateError);
  });
}
