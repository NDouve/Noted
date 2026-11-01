// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';

void main() {
  test('settings.json drops the old aiConnections on the next save and keeps every other field', () async {
    final dir = await Directory.systemTemp.createTemp('noted_settings');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    const connections = '[{"id":"0123456789abcdef","name":"Clauðe \\"Code\\"","hash":"ab12","created":1700000000000}]';
    const future = '{"a":true,"b":[1,2,{"c":null}]}';
    file.writeAsStringSync('{"format":1,"theme":"system","aiConnections":$connections,"future":$future}');

    final settings = AppSettings(file);
    expect(file.readAsStringSync(), contains('aiConnections'), reason: 'reading alone does not rewrite it');
    settings.theme = ThemeSetting.dark;
    settings.dispose();

    final text = file.readAsStringSync();
    expect(text, isNot(contains('aiConnections')));
    expect(text, contains('"future":$future'), reason: 'other unknown fields kept byte for byte');
    final json = jsonDecode(text) as Map;
    expect(json['theme'], 'dark');
    expect(json['format'], 1);
  });

  test('the one-time AI access note is remembered in settings.json', () async {
    final dir = await Directory.systemTemp.createTemp('noted_settings');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    final settings = AppSettings(file);
    expect(settings.aiAccessNoteShown, isFalse);
    settings.aiAccessNoteShown = true;
    settings.dispose();
    expect((jsonDecode(file.readAsStringSync()) as Map)['aiAccessNoteShown'], true);
    final again = AppSettings(file);
    expect(again.aiAccessNoteShown, isTrue);
    again.dispose();
  });
}
