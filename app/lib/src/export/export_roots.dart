// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import '../app_settings.dart';
import '../device_storage.dart' show deviceSupportDirectory;
import '../notebook.dart';

/// Every folder an export must not write into (design: refused targets): the
/// notebook's storage locations, binder folders, recovery folder, cache and
/// app data ([Notebook.exportRefusedFolders]), the settings file's folder,
/// the device's support folder, and Noted's folder in the user's local app
/// data (`Noted`, with `mcp` inside it) wherever this platform keeps one.
List<String> exportRefusedRoots(
  Notebook notebook, {
  AppSettings? settings,
  Map<String, String>? environment,
  String? platform,
}) {
  final sep = Platform.pathSeparator;
  final env = environment ?? Platform.environment;
  final os = platform ?? Platform.operatingSystem;
  final out = <String>[...notebook.exportRefusedFolders];
  final file = settings?.file;
  if (file != null) out.add(file.absolute.parent.path);
  final support = deviceSupportDirectory();
  if (support != null) out.add(support.path);
  void add(String? base, List<String> below) {
    if (base == null || base.isEmpty) return;
    for (final name in below) {
      out.add('$base$sep$name');
    }
  }

  if (os == 'windows') {
    add(env['LOCALAPPDATA'], const ['Noted']);
    add(env['APPDATA'], const ['Noted']);
  } else if (os == 'macos') {
    add(env['HOME'], const ['Library/Application Support/Noted', 'Library/Caches/Noted', '.noted']);
  } else {
    add(env['XDG_DATA_HOME'] ?? (env['HOME'] == null ? null : '${env['HOME']}/.local/share'), const ['Noted']);
    add(env['XDG_CONFIG_HOME'] ?? (env['HOME'] == null ? null : '${env['HOME']}/.config'), const ['Noted']);
    add(env['HOME'], const ['.noted']);
    add(env['XDG_CACHE_HOME'] ?? (env['HOME'] == null ? null : '${env['HOME']}/.cache'), const ['Noted']);
  }
  return out;
}
