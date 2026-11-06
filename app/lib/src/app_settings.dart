// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show ToolbarStyle;

import 'device_storage.dart';
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

/// This device's settings file, `settings.json`: beside `binders.json` on desktop,
/// in `<support>/Noted` on a device.
File defaultSettingsFile() {
  final support = deviceSupportDirectory();
  if (support != null) return File('${support.path}${Platform.pathSeparator}settings.json');
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

  /// Whether the one-time note about pages that lost AI access (the "page"
  /// value of older versions) has been shown on this device
  /// (`"aiAccessNoteShown"`).
  bool get aiAccessNoteShown => _raw['aiAccessNoteShown'] == true;

  /// The file existed but couldn't be read, so what is in memory is only the
  /// defaults. Nothing the app does by itself may save over it; only a
  /// setting the user changes does.
  bool _readFailed = false;

  /// Whether a note can be remembered here without replacing a file that
  /// couldn't be read.
  bool get canRememberNotes => !_readFailed;

  set aiAccessNoteShown(bool value) {
    if (aiAccessNoteShown == value || _readFailed) return;
    _raw = {..._raw, 'aiAccessNoteShown': value};
    notifyListeners();
    _write();
  }

  // A stored folder, as a path of this container (see [resolveStoredPath]).
  String? _folder(String key) {
    final v = _raw[key];
    return v is String && v.isNotEmpty ? resolveStoredPath(v) : null;
  }

  void _setFolder(String key, String? value) {
    if (_folder(key) == value) return;
    _raw = {..._raw};
    if (value == null) {
      _raw.remove(key);
    } else {
      _raw[key] = storedPath(value);
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
      if (json is! Map<String, dynamic>) {
        _readFailed = true;
        return;
      }
      _raw = Map<String, Object?>.of(json);
      _theme = ThemeSetting.parse(json['theme']) ?? ThemeSetting.system;
      _toolbar = ToolbarStyle.parse(json['toolbar']) ?? ToolbarStyle.tabs;
    } on Object {
      // Damaged: use the defaults; the file stays as it is.
      _readFailed = true;
      _raw = {};
      _theme = ThemeSetting.system;
      _toolbar = ToolbarStyle.tabs;
    }
  }

  // Returns false if the file couldn't be written. Fields this build doesn't
  // use are written back as they were read, except the old "aiConnections",
  // which nothing reads any more and which is dropped on a save.
  bool _write() {
    final f = file;
    if (f == null) return true;
    final format = _raw['format'];
    _raw = {
      ..._raw,
      'format': format is int ? format : settingsFormatVersion,
      'theme': _theme.value,
    }..remove('aiConnections');
    // The folders are saved in the stored form (an old absolute one is converted
    // here, at the first save after the change).
    for (final k in const ['defaultPageFolder', 'defaultBinderFolder']) {
      final v = _raw[k];
      if (v is String && v.isNotEmpty) _raw[k] = storedPath(resolveStoredPath(v));
    }
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
