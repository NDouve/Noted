// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/export_names.dart';
import 'package:noted/src/page_attachments.dart' show safeOpenFileName;

void main() {
  test('an ordinary name is kept', () {
    expect(safeExportFileName('Plan - Note.txt'), 'Plan - Note.txt');
    expect(safeExportFileName('Quarterly report.md'), 'Quarterly report.md');
  });

  test('device names fall back, including after trimming dots and spaces', () {
    for (final n in ['CON', 'con.txt', 'Nul.tar', 'COM1.pdf', 'lpt9', 'AUX.']) {
      expect(safeExportFileName(n), anyOf('file', startsWith('file.')), reason: n);
    }
    expect(safeExportFileName('CON .txt'), 'file.txt');
    expect(safeExportFileName('CON. .txt'), 'file.txt');
    expect(safeExportFileName(' nul  .md'), 'file.md');
    expect(safeExportFileName('COM10.pdf'), 'COM10.pdf');
  });

  test('separators are replaced', () {
    expect(safeExportFileName(r'a/b\c:d.txt'), 'a_b_c_d.txt');
    expect(safeExportFileName('../x.txt'), '.._x.txt');
  });

  test('control characters 0-31, DEL and C1 are replaced', () {
    for (final code in [...List.generate(32, (i) => i), 0x7F, 0x80, 0x85, 0x9F]) {
      final out = safeExportFileName('a${String.fromCharCode(code)}b.txt');
      expect(out, 'a_b.txt', reason: 'U+${code.toRadixString(16)}');
    }
  });

  test('direction marks are replaced', () {
    for (final code in [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]) {
      final out = safeExportFileName('gnp${String.fromCharCode(code)}txt.txt');
      expect(out, 'gnp_txt.txt', reason: 'U+${code.toRadixString(16)}');
    }
  });

  test('a name is cut to the byte cap, the extension kept, room left for .cas-verified', () {
    final long = '${'é' * 300}.docx';
    final out = safeExportFileName(long);
    expect(utf8.encode(out).length, lessThanOrEqualTo(exportNameMaxBytes));
    expect(out, endsWith('.docx'));
    expect(exportNameMaxBytes, 255 - 48);
    // The longest name derived from it: <name>.<pid>-<random>.cas-verified.
    final derived = '$out.12345678-ffffffff-ffffffff.cas-verified';
    expect(utf8.encode(derived).length, lessThanOrEqualTo(255));
    // A cut never splits a character.
    expect(() => utf8.decode(utf8.encode(out)), returnsNormally);
    // A name that fits is left alone.
    expect(safeExportFileName('a' * 100), 'a' * 100);
  });

  test('names Noted uses itself get (export) before the extension', () {
    expect(safeExportFileName('page.canvas'), 'page (export).canvas');
    expect(safeExportFileName('Page.CANVAS'), 'Page (export).CANVAS');
    expect(safeExportFileName('noted-binder.json'), 'noted-binder (export).json');
    expect(safeExportFileName('noted-binder-abc.json'), 'noted-binder-abc (export).json');
    expect(safeExportFileName('binders.json'), 'binders (export).json');
    expect(safeExportFileName('settings.json'), 'settings (export).json');
    expect(safeExportFileName('ai-access.json'), 'ai-access (export).json');
    expect(safeExportFileName('folder-access.json'), 'folder-access (export).json');
    expect(safeExportFileName('x.notedtemplate'), 'x (export).notedtemplate');
    expect(safeExportFileName('setup.exe'), 'setup (export).exe');
    final hash = 'a1' * 32;
    expect(safeExportFileName('$hash.png'), '$hash (export).png');
    expect(safeExportFileName(hash), '$hash (export)');
    expect(safeExportFileName('settings.txt'), 'settings.txt');
  });

  test('safeOpenFileName keeps its own rules', () {
    expect(safeOpenFileName('CON .txt'), 'CON .txt');
    expect(safeOpenFileName('a\u0001b.txt'), 'a\u0001b.txt');
    expect(safeOpenFileName('CON.txt'), 'file.txt');
  });

  test('the suggested name is <page title> - <box>.<ext>, made safe', () {
    expect(
      suggestedExportName(pageTitle: 'Plan', boxLabel: 'Note', extension: 'md'),
      'Plan - Note.md',
    );
    expect(
      suggestedExportName(pageTitle: 'a/b', boxLabel: 'Note', extension: 'html'),
      'a_b - Note.html',
    );
    expect(suggestedExportName(pageTitle: '  ', boxLabel: 'Drawing', extension: 'svg'), 'Untitled - Drawing.svg');
    expect(
      suggestedExportName(pageTitle: 'P', boxLabel: 'File', extension: '', original: 'Report.pdf'),
      'Report.pdf',
    );
    expect(
      suggestedExportName(pageTitle: 'P', boxLabel: 'File', extension: '', original: 'settings.json'),
      'settings (export).json',
    );
  });
}
