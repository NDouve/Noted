// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

import 'box_module.dart';

/// The box modules compiled into this build (stage 1 of 0034).
final class ModuleRegistry {
  final CodecRegistry codecs = CodecRegistry();
  final Map<String, BoxModule<Object?>> _modules = {};
  final Set<String> _alwaysOn = {};
  String? _defaultTypeId;

  /// Registers [module]. An [alwaysOn] module can't be switched off. The
  /// [isDefault] module is the box a click on empty canvas creates (0015).
  void register(
    BoxModule<Object?> module, {
    bool enabled = true,
    bool alwaysOn = false,
    bool isDefault = false,
  }) {
    final id = module.codec.typeId;
    codecs.register(module.codec, enabled: enabled || alwaysOn);
    _modules[id] = module;
    if (alwaysOn) _alwaysOn.add(id);
    if (isDefault) _defaultTypeId = id;
  }

  void setEnabled(String typeId, bool enabled) {
    if (!enabled && _alwaysOn.contains(typeId)) {
      throw StateError('$typeId is always on');
    }
    codecs.setEnabled(typeId, enabled);
  }

  /// The module for [typeId] if it is registered and switched on.
  BoxModule<Object?>? moduleFor(String typeId) =>
      codecs.isEnabled(typeId) ? _modules[typeId] : null;

  /// The module new boxes are created with.
  BoxModule<Object?> get defaultModule {
    final id = _defaultTypeId;
    final m = id == null ? null : moduleFor(id);
    if (m == null) throw StateError('no default box module registered');
    return m;
  }
}
