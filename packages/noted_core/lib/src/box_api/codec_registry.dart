// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../json/raw_json.dart';
import '../model/bounds.dart';
import '../model/ids.dart';
import '../model/page.dart';
import 'box_codec.dart';

/// Why a box can't be edited on this device. It is shown from its snapshot,
/// and its data is left untouched (0035).
enum UnsupportedReason {
  /// No module for this type is installed.
  unknownType,

  /// The module is installed but switched off.
  disabled,

  /// The box was saved by a newer version of its module.
  newerDataVersion,

  /// The module couldn't decode the box's data.
  unreadable,
}

/// The result of looking up a box's module and decoding its data.
sealed class BoxResolution {
  const BoxResolution();
}

final class LiveBox extends BoxResolution {
  const LiveBox(this.codec, this.data);

  final BoxCodec<Object?> codec;
  final Object? data;
}

final class UnsupportedBox extends BoxResolution {
  const UnsupportedBox(this.reason);

  final UnsupportedReason reason;
}

/// The box codecs this build knows, and whether each one is switched on.
final class CodecRegistry {
  final Map<String, BoxCodec<Object?>> _codecs = {};
  final Set<String> _disabled = {};

  /// Registers [codec]. Throws if the type id is taken or the codec targets
  /// a Box API version this core can't host.
  void register(BoxCodec<Object?> codec, {bool enabled = true}) {
    if (!boxApiVersion.canHost(codec.apiVersion)) {
      throw StateError(
        '${codec.typeId} targets Box API ${codec.apiVersion}; '
        'this core implements $boxApiVersion',
      );
    }
    if (_codecs.containsKey(codec.typeId)) {
      throw StateError('${codec.typeId} is already registered');
    }
    _codecs[codec.typeId] = codec;
    if (!enabled) _disabled.add(codec.typeId);
  }

  void setEnabled(String typeId, bool enabled) {
    enabled ? _disabled.remove(typeId) : _disabled.add(typeId);
  }

  bool isEnabled(String typeId) =>
      _codecs.containsKey(typeId) && !_disabled.contains(typeId);

  /// The codec for [typeId] if it is registered and switched on.
  BoxCodec<Object?>? codecFor(String typeId) =>
      isEnabled(typeId) ? _codecs[typeId] : null;

  Iterable<BoxCodec<Object?>> get codecs => _codecs.values;

  /// Finds the module for [box] and decodes its data.
  BoxResolution resolve(BoxRecord box) {
    final codec = _codecs[box.typeId];
    if (codec == null) return const UnsupportedBox(UnsupportedReason.unknownType);
    if (_disabled.contains(box.typeId)) {
      return const UnsupportedBox(UnsupportedReason.disabled);
    }
    if (box.dataVersion > codec.dataVersion) {
      return const UnsupportedBox(UnsupportedReason.newerDataVersion);
    }
    try {
      return LiveBox(codec, codec.decode(box.data?.decode(), box.dataVersion));
    } on Object {
      return const UnsupportedBox(UnsupportedReason.unreadable);
    }
  }
}

/// Creates a record for a new box of [codec]'s type.
BoxRecord createBox(BoxCodec<Object?> codec, Bounds bounds) {
  final data = codec.create();
  return BoxRecord.create(
    id: newId(),
    typeId: codec.typeId,
    dataVersion: codec.dataVersion,
    bounds: bounds,
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: newId(),
  );
}

/// Returns [box] with [data] committed through [codec]: encoded, with a fresh
/// snapshot and a new revision.
BoxRecord commitBox(BoxRecord box, BoxCodec<Object?> codec, Object? data) {
  assert(box.typeId == codec.typeId);
  return box.withContent(
    data: RawJson.encode(codec.encode(data)),
    dataVersion: codec.dataVersion,
    snapshotText: codec.snapshotText(data),
    newRev: newId(),
  );
}
