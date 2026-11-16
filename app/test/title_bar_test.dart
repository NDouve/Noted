// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/title_bar.dart';
import 'package:noted/src/window_channel.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('noted/window');
  late List<MethodCall> calls;
  late WindowChannel window;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    window = WindowChannel(channel: channel);
  });

  tearDown(() {
    window.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> fromNative(String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('noted/window', data, (_) {});
  }

  List<MethodCall> rectCalls() => calls.where((c) => c.method == 'setCaptionRects').toList();

  void view(WidgetTester t, {double width = 800, double dpr = 1}) {
    t.view.physicalSize = Size(width * dpr, 600 * dpr);
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.reset);
  }

  Widget app({VoidCallback? onNcPointerDown, Widget? below}) => MaterialApp(
    theme: buildNotedTheme(Brightness.light, touch: false),
    home: Scaffold(
      body: Column(
        children: [
          TitleBar(window: window, onNcPointerDown: onNcPointerDown),
          ?below,
        ],
      ),
    ),
  );

  List<double> r(Rect x) => [x.left, x.top, x.right, x.bottom];

  testWidgets('the rects sent are the laid-out buttons, and follow a resize', (t) async {
    view(t);
    await t.pumpWidget(app());
    await t.pump();
    Rect rect(String b) => t.getRect(find.byKey(ValueKey('caption-$b')));
    expect(rect('minimize'), const Rect.fromLTRB(662, 0, 708, 40));
    expect(rect('close'), const Rect.fromLTRB(754, 0, 800, 40));
    expect(rectCalls(), hasLength(1));
    expect(rectCalls().single.arguments, {
      'buttons': {
        'minimize': r(rect('minimize')),
        'maximize': r(rect('maximize')),
        'close': r(rect('close')),
      },
      'interactive': <List<double>>[],
    });

    view(t, width: 600);
    await t.pump();
    await t.pump();
    expect(rectCalls(), hasLength(2));
    final buttons = (rectCalls().last.arguments as Map)['buttons'] as Map;
    expect(buttons['close'], [554.0, 0.0, 600.0, 40.0]);

    // Nothing changed: nothing is sent again.
    await t.pump();
    expect(rectCalls(), hasLength(2));
  });

  testWidgets('the brand follows the spec table at 125%', (t) async {
    view(t, dpr: 1.25);
    await t.pumpWidget(app());
    await t.pump();
    expect(t.getSize(find.byKey(const ValueKey('title-bar'))).height, 40);
    // 125%: N slot at x=20 y=15 (physical), wordmark at x=48 y=13.
    final mark = t.getTopLeft(find.byKey(const ValueKey('brand-mark')));
    expect(mark.dx * 1.25, 20);
    expect(mark.dy * 1.25, 15);
    final word = t.getTopLeft(find.byKey(const ValueKey('title-bar-wordmark')));
    expect(word.dx * 1.25, 48);
    expect(word.dy * 1.25, 13);
  });

  testWidgets('a modal route sends one full-width interactive rect, then the buttons again', (t) async {
    view(t);
    await t.pumpWidget(app());
    await t.pump();
    final context = t.element(find.byType(TitleBar));
    final done = showDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('Hi')));
    await t.pump();
    await t.pump();
    expect(rectCalls().last.arguments, {
      'buttons': <String, Object?>{},
      'interactive': [
        [0.0, 0.0, 800.0, 40.0],
      ],
    });
    Navigator.of(context).pop();
    await done;
    await t.pumpAndSettle();
    final args = rectCalls().last.arguments as Map;
    expect((args['buttons'] as Map).keys, containsAll(['minimize', 'maximize', 'close']));
    expect(args['interactive'], isEmpty);
  });

  testWidgets('tapping the buttons calls the channel', (t) async {
    view(t);
    await t.pumpWidget(app());
    for (final b in ['minimize', 'maximize', 'close']) {
      await t.tap(find.byKey(ValueKey('caption-$b')));
    }
    await t.pump();
    expect(
      calls.map((c) => c.method).where((m) => m != 'setCaptionRects' && m != 'getState'),
      ['minimize', 'toggleMaximize', 'close'],
    );
  });

  testWidgets('state changes repaint: the glyph, the name, hover and inactive', (t) async {
    view(t);
    await t.pumpWidget(app());
    await t.pump();
    final close = find.descendant(
      of: find.byKey(const ValueKey('caption-close')),
      matching: find.byType(ColoredBox),
    );
    Color closeFill() => t.widget<ColoredBox>(close).color;
    Text glyph(String b) => t.widget<Text>(
      find.descendant(of: find.byKey(ValueKey('caption-$b')), matching: find.byType(Text)),
    );
    expect(glyph('maximize').data, '');
    expect(find.bySemanticsLabel('Maximise'), findsOneWidget);
    expect(closeFill(), const Color(0x00000000));

    await fromNative('state', {'maximized': true, 'active': true, 'hovered': 'close', 'pressed': 'none', 'dpi': 96});
    await t.pump();
    expect(glyph('maximize').data, '');
    expect(find.bySemanticsLabel('Restore'), findsOneWidget);
    expect(closeFill(), const Color(0xFFC42B1C));
    expect(glyph('close').style!.color, const Color(0xFFFFFFFF));

    final scheme = Theme.of(t.element(find.byType(TitleBar))).colorScheme;
    await fromNative('state', {'maximized': false, 'active': false, 'hovered': 'none', 'pressed': 'none', 'dpi': 96});
    await t.pump();
    expect(closeFill(), const Color(0x00000000));
    expect(glyph('minimize').style!.color, scheme.onSurfaceVariant);
    expect(t.widget<Text>(find.byKey(const ValueKey('title-bar-wordmark'))).style!.color, scheme.onSurfaceVariant);
  });

  testWidgets('the brand is one semantics node named Noted', (t) async {
    view(t);
    await t.pumpWidget(app());
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
  });

  testWidgets('ncPointerDown reaches the owner', (t) async {
    view(t);
    var downs = 0;
    await t.pumpWidget(app(onNcPointerDown: () => downs++));
    await fromNative('ncPointerDown', null);
    expect(downs, 1);
  });

  group('startCustomFrame', () {
    test('Windows: enable is called once', () async {
      final w = await startCustomFrame(windows: true, channel: window);
      expect(w, same(window));
      expect(calls.map((c) => c.method), ['enable']);
      expect(calls.single.arguments, {'enabled': true});
    });

    test('other platforms: nothing is called and there is no channel', () async {
      expect(await startCustomFrame(windows: false, channel: window), isNull);
      expect(calls, isEmpty);
    });
  });

  group('in the home', () {
    late Directory dir;
    late Notebook nb;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('noted_titlebar');
      nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
      await nb.load();
    });

    tearDown(() async {
      await nb.flush();
      nb.dispose();
      await busyRetry(() => dir.delete(recursive: true));
    });

    testWidgets('with the frame on: a title bar above the menu bar, and no brand in it', (t) async {
      view(t, width: 1400);
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb, window: window)));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('title-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('brand-mark')), findsOneWidget, reason: 'only the title bar has it');
      expect(find.byKey(const ValueKey('brand-wordmark')), findsNothing);
      expect(t.getTopLeft(find.byKey(const ValueKey('menu-top-File'))).dy, greaterThanOrEqualTo(40));
    });

    testWidgets('without it (other platforms): no title bar, the menu bar keeps the brand', (t) async {
      view(t, width: 1400);
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('title-bar')), findsNothing);
      expect(find.byKey(const ValueKey('brand-wordmark')), findsOneWidget);
    });

    testWidgets('a press on the title bar closes an open menu', (t) async {
      view(t, width: 1400);
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb, window: window)));
      await t.pump();
      await t.pump();
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      expect(find.text('New page'), findsWidgets);
      await fromNative('ncPointerDown', null);
      await t.pumpAndSettle();
      expect(find.text('New page'), findsNothing);
    });
  });
}
