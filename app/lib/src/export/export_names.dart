// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:noted_core/noted_core.dart';

import '../page_attachments.dart' show safeOpenFileName;

/// The longest name Noted writes for an export, in UTF-8 bytes: 255 less the
/// room of the longest name derived from it, `<name>.<pid>-<random>.cas-verified`
/// (about 45 bytes of suffix, so 48).
const int exportNameMaxBytes = 255 - 48;

final RegExp _device = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false);

/// Control characters (0–31, DEL, C1) and the direction marks (U+200E, U+200F,
/// U+061C, U+202A–202E, U+2066–2069).
final RegExp _unsafe = RegExp(
  '[\\u0000-\\u001F\\u007F-\\u009F\\u200E\\u200F\\u061C\\u202A-\\u202E\\u2066-\\u2069]',
);

/// Names Noted uses itself in a folder that holds its data (0057, 0171).
final List<RegExp> _ownNames = [
  RegExp(r'\.canvas$', caseSensitive: false),
  RegExp(r'^noted-binder.*\.json$', caseSensitive: false),
  RegExp(r'^(binders|settings|ai-access|folder-access)\.json$', caseSensitive: false),
  RegExp(r'\.notedtemplate$', caseSensitive: false),
  RegExp(r'^[0-9a-f]{64}(\.[a-z0-9]+)?$', caseSensitive: false),
  RegExp(r'\.exe$', caseSensitive: false),
];

/// [name] as a file name Noted may write for an export. It replaces path
/// separators, control characters and direction marks, treats a stem that is
/// a device name after trimming dots and spaces as one (`CON .txt`), falls
/// back to `file.<extension>` where [safeOpenFileName] does, puts ` (export)`
/// before the extension of a name Noted uses itself, and caps the name at
/// [exportNameMaxBytes] UTF-8 bytes with its extension kept.
String safeExportFileName(String name) {
  var n = name.replaceAll(_unsafe, '_');
  final dot = n.indexOf('.');
  final stem = (dot < 0 ? n : n.substring(0, dot)).replaceAll(RegExp(r'[. ]+$'), '').replaceAll(RegExp(r'^[. ]+'), '');
  if (_device.hasMatch(stem.trim())) {
    final ext = normalizedExtension(n);
    n = ext.isEmpty ? 'file' : 'file.$ext';
  }
  n = safeOpenFileName(n);
  if (_ownNames.any((r) => r.hasMatch(n))) {
    final i = n.lastIndexOf('.');
    n = i <= 0 ? '$n (export)' : '${n.substring(0, i)} (export)${n.substring(i)}';
  }
  return _capBytes(n, exportNameMaxBytes);
}

/// [name] cut to [max] UTF-8 bytes, the extension kept (a stem is cut on a
/// character boundary).
String _capBytes(String name, int max) {
  if (utf8.encode(name).length <= max) return name;
  final i = name.lastIndexOf('.');
  var ext = i <= 0 ? '' : name.substring(i);
  if (utf8.encode(ext).length > 16) ext = '';
  final stem = ext.isEmpty ? name : name.substring(0, i);
  var room = max - utf8.encode(ext).length;
  final b = StringBuffer();
  for (final rune in stem.runes) {
    final s = String.fromCharCode(rune);
    final len = utf8.encode(s).length;
    if (len > room) break;
    b.write(s);
    room -= len;
  }
  return '$b$ext';
}

/// The name an export is first offered: `<page title> - <box>.<ext>`, made safe.
/// An original keeps [original], its own display name.
String suggestedExportName({
  required String pageTitle,
  required String boxLabel,
  required String extension,
  String? original,
}) {
  if (original != null && original.isNotEmpty) return safeExportFileName(original);
  final title = pageTitle.trim().isEmpty ? 'Untitled' : pageTitle.trim();
  final ext = extension.isEmpty ? '' : '.$extension';
  return safeExportFileName('$title - $boxLabel$ext');
}
