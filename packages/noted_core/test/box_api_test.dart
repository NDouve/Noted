// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

class _TextCodec extends BoxCodec<String> {
  const _TextCodec({this.api = boxApiVersion});

  final BoxApiVersion api;

  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 2;
  @override
  BoxApiVersion get apiVersion => api;
  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) {
    if (storedVersion == 1) return 'v1:$json';
    return json! as String;
  }

  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

BoxRecord record({String type = 'test.text', int v = 2, Object? data = 'hi'}) =>
    BoxRecord.create(
      id: 'b',
      typeId: type,
      dataVersion: v,
      bounds: Bounds.zero,
      data: RawJson.encode(data),
      snapshotText: '',
      rev: 'r',
    );

void main() {
  test('API versions: 0.x needs an exact match, 1.x a newer host minor', () {
    expect(const BoxApiVersion(0, 1).canHost(const BoxApiVersion(0, 1)), isTrue);
    expect(const BoxApiVersion(0, 2).canHost(const BoxApiVersion(0, 1)), isFalse);
    expect(boxApiVersion, const BoxApiVersion(0, 3));
    expect(const BoxApiVersion(1, 3).canHost(const BoxApiVersion(1, 1)), isTrue);
    expect(const BoxApiVersion(1, 1).canHost(const BoxApiVersion(1, 3)), isFalse);
    expect(const BoxApiVersion(2, 0).canHost(const BoxApiVersion(1, 0)), isFalse);
  });

  test('registry rejects incompatible and duplicate codecs', () {
    final r = CodecRegistry();
    expect(
      () => r.register(const _TextCodec(api: BoxApiVersion(9, 0))),
      throwsStateError,
    );
    r.register(const _TextCodec());
    expect(() => r.register(const _TextCodec()), throwsStateError);
  });

  test('resolve explains why a box is unsupported', () {
    final r = CodecRegistry()..register(const _TextCodec());
    expect(r.resolve(record()), isA<LiveBox>());
    expect((r.resolve(record(v: 1)) as LiveBox).data, 'v1:hi');

    UnsupportedReason reason(BoxRecord b) => (r.resolve(b) as UnsupportedBox).reason;
    expect(reason(record(type: 'nope')), UnsupportedReason.unknownType);
    expect(reason(record(v: 3)), UnsupportedReason.newerDataVersion);
    expect(reason(record(data: 42)), UnsupportedReason.unreadable);
    r.setEnabled('test.text', false);
    expect(reason(record()), UnsupportedReason.disabled);
    expect(r.codecFor('test.text'), isNull);
  });

  test('createBox and commitBox go through the codec', () {
    const codec = _TextCodec();
    final box = createBox(codec, const Bounds(1, 2, 3, 4));
    expect(box.typeId, 'test.text');
    expect(box.data!.text, '""');
    final next = commitBox(box, codec, 'hello');
    expect(next.data!.text, '"hello"');
    expect(next.snapshotText, 'hello');
    expect(next.baseRev, box.rev);
    expect(next.rev, isNot(box.rev));
  });
}
