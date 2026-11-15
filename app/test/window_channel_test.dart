// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/window_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late List<MethodCall> calls;
  late WindowChannel window;

  setUp(() {
    channel = const MethodChannel('noted/window');
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getState') {
            return {
              'maximized': true,
              'active': false,
              'hovered': 'close',
              'pressed': 'none',
              'dpi': 144,
            };
          }
          return null;
        });
    window = WindowChannel(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> fromNative(String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('noted/window', data, (_) {});
  }

  test('the frame is off until enable is called', () async {
    expect(calls, isEmpty);
    await window.enable();
    expect(calls.single.method, 'enable');
    expect(calls.single.arguments, {'enabled': true});
    await window.enable(false);
    expect(calls.last.arguments, {'enabled': false});
  });

  test('setCaptionRects sends [l, t, r, b] lists', () async {
    await window.setCaptionRects(
      minimize: const Rect.fromLTRB(1, 0, 47, 40),
      maximize: const Rect.fromLTRB(47, 0, 93, 40),
      close: const Rect.fromLTRB(93, 0, 139, 40),
      interactive: const [Rect.fromLTRB(200, 4, 300, 36)],
    );
    expect(calls.single.method, 'setCaptionRects');
    expect(calls.single.arguments, {
      'buttons': {
        'minimize': [1.0, 0.0, 47.0, 40.0],
        'maximize': [47.0, 0.0, 93.0, 40.0],
        'close': [93.0, 0.0, 139.0, 40.0],
      },
      'interactive': [
        [200.0, 4.0, 300.0, 36.0],
      ],
    });
  });

  test('window commands call the channel', () async {
    await window.minimize();
    await window.toggleMaximize();
    await window.close();
    expect(calls.map((c) => c.method), ['minimize', 'toggleMaximize', 'close']);
  });

  test('state and ncPointerDown from native reach the callbacks', () async {
    final states = <WindowFrameState>[];
    var downs = 0;
    window.onState = states.add;
    window.onNcPointerDown = () => downs++;
    await fromNative('state', {
      'maximized': true,
      'active': false,
      'hovered': 'maximize',
      'pressed': 'maximize',
      'dpi': 120,
    });
    await fromNative('ncPointerDown', null);
    expect(downs, 1);
    expect(
      states.single,
      const WindowFrameState(
        maximized: true,
        active: false,
        hovered: CaptionButton.maximize,
        pressed: CaptionButton.maximize,
        dpi: 120,
      ),
    );
    expect(window.state, states.single);
  });

  test('an unknown button name reads as none', () {
    final s = WindowFrameState.fromMap({'hovered': 'bogus'});
    expect(s.hovered, CaptionButton.none);
    expect(s.active, isTrue);
  });

  test('refreshState reads getState', () async {
    final s = await window.refreshState();
    expect(s.maximized, isTrue);
    expect(s.active, isFalse);
    expect(s.hovered, CaptionButton.close);
    expect(s.dpi, 144);
  });

  test('calls are no-ops without a native side', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await window.enable();
    await window.setCaptionRects();
    expect((await window.refreshState()).maximized, isFalse);
  });
}
