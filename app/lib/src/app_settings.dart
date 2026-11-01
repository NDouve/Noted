// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show ToolbarStyle;
import 'package:noted_core/noted_core.dart'
    show
        AiConnectionInfo,
        aiConnectionsSettingKey,
        aiKeyMatches,
        isAiConnectionId,
        newAiToken,
        parseAiToken,
        readAiConnections;

import 'notebook.dart' show defaultPagesDirectory;

/// The settings file format version this build reads and writes.
const int settingsFormatVersion = 1;

/// Which theme the app uses.
enum ThemeSetting {
  system('system', 'Follow system', ThemeMode.system),
  light('light', 'Light', ThemeMode.light),
  dark('dark', 'Dark', ThemeMode.dark);

  const ThemeSetting(this.value, this.label, this.mode);

  /// How the setting is written in `settings.json`.
  final String value;
  final String label;
  final ThemeMode mode;

  static ThemeSetting? parse(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// This device's settings file, `settings.json`, next to `binders.json`.
File defaultSettingsFile() {
  final pages = defaultPagesDirectory().absolute;
  return File('${pages.parent.path}${Platform.pathSeparator}settings.json');
}

/// Settings that belong to this device, not to the notebook: kept in
/// `settings.json` as `{"format":1,"theme":"system"|"light"|"dark",
/// "toolbar":"tabs"|"contextual"}`.
///
/// Fields this build doesn't know are kept when the file is rewritten. A
/// missing, damaged or unreadable file gives the defaults and is left alone
/// until a setting is changed.
class AppSettings extends ChangeNotifier {
  /// Reads [file] (null: settings that aren't saved anywhere).
  AppSettings(this.file) {
    _read();
  }

  final File? file;

  ThemeSetting _theme = ThemeSetting.system;
  ToolbarStyle _toolbar = ToolbarStyle.tabs;

  /// Everything that was in the file, so unknown fields survive a rewrite.
  Map<String, Object?> _raw = {};

  final ValueNotifier<List<AiConnectionInfo>> _aiConnections = ValueNotifier(const []);

  /// The AI connections (`"aiConnections"`): ids and names only. The hash of
  /// each token stays in the settings file and is used by [verifyAiToken].
  ValueListenable<List<AiConnectionInfo>> get aiConnections => _aiConnections;

  // The stored entries ({id, name, hash, created}); a malformed or repeated
  // entry is skipped (and so dropped when the list is next written).
  List<Map<String, Object?>> _storedConnections() {
    final list = _raw[aiConnectionsSettingKey];
    if (list is! List) return [];
    final ids = readAiConnections(_raw).map((c) => c.id).toSet();
    return [
      for (final e in list)
        if (e is Map && ids.remove(e['id'])) {for (final x in e.entries) x.key.toString(): x.value},
    ];
  }

  // Another Noted on this computer may have changed the connections in the
  // file: take them from there, so this one neither brings back a revoked
  // token nor drops a new connection when it writes. A missing file has no
  // connections. Keeps what is in memory if the file can't be read, and then
  // returns false, so a token check fails safe instead of trusting a list
  // that may be stale.
  bool _refreshConnections() {
    final f = file;
    if (f == null) return true;
    try {
      final json = f.existsSync() ? jsonDecode(f.readAsStringSync()) : const <String, Object?>{};
      if (json is! Map) return false;
      final disk = json[aiConnectionsSettingKey];
      _raw = {..._raw};
      if (disk == null) {
        _raw.remove(aiConnectionsSettingKey);
      } else {
        _raw[aiConnectionsSettingKey] = disk;
      }
      final next = readAiConnections(_raw);
      if (!listEquals(next, _aiConnections.value)) _aiConnections.value = next;
      return true;
    } on Object {
      // Keep what we have.
      return false;
    }
  }

  /// Reads the connections from the settings file again, in case another
  /// Noted changed them (the dialog does this when it opens).
  void refreshAiConnections() {
    _refreshConnections();
  }

  // Applies [list] as the connections, or throws and leaves everything as it
  // was if the file can't be written.
  void _setConnections(List<Map<String, Object?>> list) {
    final before = _raw;
    final listed = _aiConnections.value;
    _raw = {..._raw, aiConnectionsSettingKey: list};
    _aiConnections.value = readAiConnections(_raw);
    if (!_write(refresh: false)) {
      _raw = before;
      _aiConnections.value = listed;
      throw const SettingsSaveException("Noted couldn't save its settings. Check that the settings folder can be written to.");
    }
  }

  /// Makes a connection called [name] and returns its token. The token is
  /// only in this return value: just a hash of it is kept. Throws a
  /// [SettingsSaveException], with nothing added, if the settings can't be
  /// saved.
  Future<String> addAiConnection(String name) async {
    final t = newAiToken();
    _refreshConnections();
    _setConnections([
      ..._storedConnections(),
      {
        'id': t.id,
        'name': name.trim(),
        'hash': t.hash,
        'created': DateTime.now().millisecondsSinceEpoch,
      },
    ]);
    return t.token;
  }

  /// Renames connection [id]. An empty name is ignored.
  void renameAiConnection(String id, String name) {
    final n = name.trim();
    if (n.isEmpty) return;
    _refreshConnections();
    final list = _storedConnections();
    final i = list.indexWhere((e) => e['id'] == id);
    if (i < 0 || list[i]['name'] == n) return;
    list[i] = {...list[i], 'name': n};
    _setConnections(list);
  }

  /// Removes connection [id]: its token stops working at once.
  void revokeAiConnection(String id) {
    _refreshConnections();
    final list = _storedConnections();
    final next = list.where((e) => e['id'] != id).toList();
    if (next.length != list.length) _setConnections(next);
  }

  bool _settingsUnreadable = false;

  /// Whether the last [verifyAiToken] refused because the settings file
  /// couldn't be read, rather than because the token was bad.
  bool get aiSettingsUnreadable => _settingsUnreadable;

  /// The connection [token] belongs to, or null if it is malformed, unknown
  /// or revoked. Looks at the current settings every time, and accepts
  /// nothing while the settings file can't be read (and a missing file has
  /// no connections).
  AiConnectionInfo? verifyAiToken(String token) {
    _settingsUnreadable = false;
    final parsed = parseAiToken(token);
    if (parsed == null || !isAiConnectionId(parsed.id)) return null;
    _settingsUnreadable = !_refreshConnections();
    if (_settingsUnreadable) return null;
    for (final e in _storedConnections()) {
      if (e['id'] != parsed.id) continue;
      final hash = e['hash'];
      if (hash is! String || !aiKeyMatches(parsed.key, hash)) return null;
      for (final c in _aiConnections.value) {
        if (c.id == parsed.id) return c;
      }
    }
    return null;
  }

  ThemeSetting get theme => _theme;

  ThemeMode get themeMode => _theme.mode;

  /// Which built-in toolbar the canvas shows (`"toolbar"`): Tabs unless
  /// chosen otherwise.
  ToolbarStyle get toolbar => _toolbar;

  set toolbar(ToolbarStyle value) {
    if (value == _toolbar && _raw['toolbar'] == value.value) return;
    _toolbar = value;
    _raw = {..._raw, 'toolbar': value.value};
    notifyListeners();
    _write();
  }

  /// The folder new top-level pages are created in, as chosen on this device
  /// (`"defaultPageFolder"`), or null for the built-in default.
  String? get defaultPageFolder => _folder('defaultPageFolder');

  set defaultPageFolder(String? value) => _setFolder('defaultPageFolder', value);

  /// The folder new binders are created in (`"defaultBinderFolder"`), or null
  /// for the built-in default.
  String? get defaultBinderFolder => _folder('defaultBinderFolder');

  set defaultBinderFolder(String? value) => _setFolder('defaultBinderFolder', value);

  String? _folder(String key) {
    final v = _raw[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  void _setFolder(String key, String? value) {
    if (_folder(key) == value) return;
    _raw = {..._raw};
    if (value == null) {
      _raw.remove(key);
    } else {
      _raw[key] = value;
    }
    notifyListeners();
    _write();
  }

  set theme(ThemeSetting value) {
    if (value == _theme && _raw['theme'] == value.value) return;
    _theme = value;
    notifyListeners();
    _write();
  }

  void _read() {
    final f = file;
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync());
      if (json is! Map<String, dynamic>) return;
      _raw = Map<String, Object?>.of(json);
      _theme = ThemeSetting.parse(json['theme']) ?? ThemeSetting.system;
      _toolbar = ToolbarStyle.parse(json['toolbar']) ?? ToolbarStyle.tabs;
      _aiConnections.value = readAiConnections(_raw);
    } on Object {
      // Damaged: use the defaults; the file stays as it is.
      _raw = {};
      _theme = ThemeSetting.system;
      _toolbar = ToolbarStyle.tabs;
      _aiConnections.value = const [];
    }
  }

  // Returns false if the file couldn't be written. The connections are taken
  // from the file first (unless [refresh] is false: the caller just did), so
  // a change to the theme never undoes another Noted's change to them.
  bool _write({bool refresh = true}) {
    final f = file;
    if (f == null) return true;
    if (refresh) _refreshConnections();
    final format = _raw['format'];
    _raw = {
      ..._raw,
      'format': format is int ? format : settingsFormatVersion,
      'theme': _theme.value,
    };
    try {
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_raw), flush: true);
      tmp.renameSync(f.path);
      return true;
    } on Object catch (e) {
      debugPrint('Noted: could not save settings: $e');
      return false;
    }
  }
}

/// The settings file couldn't be written; [message] is fit to show the user.
class SettingsSaveException implements Exception {
  const SettingsSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}
