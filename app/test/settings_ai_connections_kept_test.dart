// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';

void main() {
  test('settings.json keeps the old aiConnections byte for byte when it is rewritten', () async {
    final dir = await Directory.systemTemp.createTemp('noted_settings');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    const connections =
        '[{"id":"0123456789abcdef","name":"Clauðe \\"Code\\"","hash":"ab12","created":1700000000000,'
        '"extra":{"keep":[1,2,3],"x":null}}]';
    file.writeAsStringSync('{"format":1,"theme":"system","aiConnections":$connections,"future":{"a":true}}');

    final settings = AppSettings(file);
    settings.theme = ThemeSetting.dark;
    settings.toolbar = settings.toolbar; // no change
    settings.defaultPageFolder = '${dir.path}/pages';
    settings.dispose();

    final text = file.readAsStringSync();
    expect(text, contains('"aiConnections":$connections'));
    final json = jsonDecode(text) as Map;
    expect(json['theme'], 'dark');
    expect(json['future'], {'a': true}, reason: 'other unknown fields too');
  });
}
