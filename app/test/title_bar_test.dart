// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_running_lock.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/menu_bar.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/title_bar.dart';
import 'package:noted/src/window_channel.dart';
import 'package:noted_core/noted_core.dart';

import 'support/notebook_folder.dart';

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

  Widget bare() => MaterialApp(
    theme: buildNotedTheme(Brightness.light, touch: false),
    home: Scaffold(body: Column(children: [TitleBar(window: window)])),
  );

  List<double> r(Rect x) => [x.left, x.top, x.right, x.bottom];

  testWidgets('the rects sent are the laid-out buttons, and follow a resize', (t) async {
    view(t);
    await t.pumpWidget(bare());
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

  // Spec section 2, physical pixels: N slot (x, y, size), wordmark (x, y).
  for (final (dpr, n, word) in [
    (1.0, (16.0, 12.0, 16.0), (38.0, 10.0)),
    (1.25, (20.0, 15.0, 20.0), (48.0, 13.0)),
    (1.5, (24.0, 18.0, 24.0), (57.0, 15.0)),
  ]) {
    testWidgets('the brand follows the spec table at ${dpr * 100}%', (t) async {
      view(t, dpr: dpr);
      await t.pumpWidget(bare());
      await t.pump();
      expect(t.getSize(find.byKey(const ValueKey('title-bar'))).height, 40);
      final mark = find.byKey(const ValueKey('brand-mark'));
      expect(t.getTopLeft(mark).dx * dpr, closeTo(n.$1, 1e-6));
      expect(t.getTopLeft(mark).dy * dpr, closeTo(n.$2, 1e-6));
      expect(t.getSize(mark).height * dpr, closeTo(n.$3, 1e-6));
      final w = t.getTopLeft(find.byKey(const ValueKey('title-bar-wordmark')));
      expect(w.dx * dpr, closeTo(word.$1, 1e-6));
      expect(w.dy * dpr, closeTo(word.$2, 1e-6));
    });
  }

  testWidgets('tapping the buttons calls the channel', (t) async {
    view(t);
    await t.pumpWidget(bare());
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
    await t.pumpWidget(bare());
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
    for (final b in ['minimize', 'maximize', 'close']) {
      expect(glyph(b).style!.color, scheme.onSurfaceVariant, reason: b);
    }
    expect(t.widget<Text>(find.byKey(const ValueKey('title-bar-wordmark'))).style!.color, scheme.onSurfaceVariant);
  });

  testWidgets('the brand is one semantics node named Noted', (t) async {
    view(t);
    await t.pumpWidget(bare());
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
  });

  testWidgets('a removed title bar leaves a newer owner of onState alone', (t) async {
    view(t);
    await t.pumpWidget(bare());
    void other(WindowFrameState _) {}
    window.onState = other;
    await t.pumpWidget(const SizedBox());
    expect(window.onState, same(other));
  });

  group('startCustomFrame', () {
    test('enable is called once and the channel is returned', () async {
      expect(await startCustomFrame(channel: window), same(window));
      expect(calls.map((c) => c.method), ['enable']);
      expect(calls.single.arguments, {'enabled': true});
    });

    test('no channel: nothing is called', () async {
      expect(await startCustomFrame(), isNull);
      expect(calls, isEmpty);
    });

    test('a runner that refuses keeps the native caption', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
      expect(await startCustomFrame(channel: window), isNull);
    });

    test('only Windows gets a channel', () {
      expect(windowChannelForPlatform(windows: false), isNull);
      expect(windowChannelForPlatform(windows: true), isA<WindowChannel>());
    });
  });

  group('openWhenOwned', () {
    late Directory dir;
    late Notebook nb;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_titlebar_own');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        bindersFile: File('${dir.path}/binders.json'),
        saveDelay: Duration.zero,
      );
    });

    tearDown(() {
      appWindow = null;
      nb.dispose();
      dir.deleteSync(recursive: true);
    });

    testWidgets('enable runs just before the app screen, with the window handed on', (t) async {
      final shown = <Widget>[];
      final callsAtShow = <List<String>>[];
      await t.runAsync(() async {
        appWindow = window;
        final r = await openWhenOwned(
          nb,
          dir,
          startLink: false,
          show: (w) {
            shown.add(w);
            callsAtShow.add([for (final c in calls) c.method]);
          },
        );
        addTearDown(() => r.lock?.dispose());
      });
      expect(shown.single, isA<NotedApp>());
      expect((shown.single as NotedApp).window, same(window));
      expect(callsAtShow.single, ['enable']);
    });

    testWidgets('the waiting screen keeps the native caption: no enable until the lock is held', (t) async {
      // Handles of one process only conflict on Windows.
      if (!Platform.isWindows) return;
      final shown = <Widget>[];
      final callsAtShow = <List<String>>[];
      await t.runAsync(() async {
        appWindow = window;
        final lock = File('${dir.path}/$aiRunningLockFileName')..writeAsStringSync('');
        final other = lock.openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
        final started = openWhenOwned(
          nb,
          dir,
          startLink: false,
          show: (w) {
            shown.add(w);
            callsAtShow.add([for (final c in calls) c.method]);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(shown.single, isA<WaitingForLockApp>());
        expect(calls.where((c) => c.method == 'enable'), isEmpty);
        other.closeSync();
        final res = await started.timeout(const Duration(seconds: 10));
        addTearDown(() => res.lock?.dispose());
      });
      expect(shown.last, isA<NotedApp>());
      expect(callsAtShow.last, ['enable']);
      expect(calls.where((c) => c.method == 'enable'), hasLength(1));
    });
  });

  group('in the app', () {
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
      await deleteTestFolder(dir);
    });

    Future<void> pumpApp(WidgetTester t, {double width = 1400, bool frame = true}) async {
      view(t, width: width);
      await t.pumpWidget(NotedApp(notebook: nb, window: frame ? window : null));
      await t.pump();
      await t.pump();
    }

    bool noInteractive() => rectCalls().every((c) => ((c.arguments as Map)['interactive'] as List).isEmpty);

    testWidgets('with the frame on: one title bar above the menu bar, and no brand in the menu bar', (t) async {
      await pumpApp(t);
      expect(find.byKey(const ValueKey('title-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('brand-mark')), findsOneWidget, reason: 'only the title bar has it');
      expect(find.byKey(const ValueKey('brand-wordmark')), findsNothing);
      expect(t.getTopLeft(find.byKey(const ValueKey('menu-top-File'))).dy, greaterThanOrEqualTo(40));
      // The menu bar shares the title bar's surface.
      final scheme = Theme.of(t.element(find.byType(TitleBar))).colorScheme;
      final bar = t.widget<DecoratedBox>(
        find.descendant(of: find.byType(AppMenuBar), matching: find.byType(DecoratedBox)).first,
      );
      expect((bar.decoration as BoxDecoration).color, scheme.surface);
    });

    testWidgets('without the frame (other platforms): no title bar, the menu bar keeps the brand', (t) async {
      await pumpApp(t, frame: false);
      expect(find.byType(TitleBar), findsNothing);
      expect(find.byKey(const ValueKey('brand-wordmark')), findsOneWidget);
    });

    testWidgets('a narrow window: the open drawer is below the bar and its search field takes the click', (t) async {
      await pumpApp(t, width: 700);
      await t.tap(find.byKey(const ValueKey('sidebar-menu')));
      await t.pumpAndSettle();
      final field = find.descendant(of: find.byType(Drawer), matching: find.byType(TextField)).first;
      expect(t.getTopLeft(field).dy, greaterThanOrEqualTo(40));
      await t.tap(field);
      await t.pump();
      expect(t.widget<TextField>(field).focusNode?.hasFocus ?? true, isTrue);
      // Only the three buttons are reported; nothing covers the strip.
      expect(noInteractive(), isTrue);
      expect(rectCalls(), hasLength(1));
    });

    testWidgets('a dialog does not stop the caption rects, or the buttons', (t) async {
      await pumpApp(t);
      final before = rectCalls().length;
      final done = showDialog<void>(
        context: t.element(find.byType(Scaffold).first),
        builder: (_) => const AlertDialog(title: Text('Hi')),
      );
      await t.pump();
      await t.pump();
      expect(find.text('Hi'), findsOneWidget);
      expect(find.byType(TitleBar), findsOneWidget);
      expect(noInteractive(), isTrue);
      expect(rectCalls().length, before, reason: 'the buttons stay where they were');
      await t.tap(find.byKey(const ValueKey('caption-minimize')));
      await t.pump();
      expect(calls.map((c) => c.method), contains('minimize'));
      Navigator.of(t.element(find.text('Hi'))).pop();
      await done;
    });

    testWidgets('an opaque page route leaves the bar in place', (t) async {
      await pumpApp(t);
      final nav = Navigator.of(t.element(find.byType(Scaffold).first));
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SafeArea(child: Text('Over'))))));
      await t.pumpAndSettle();
      expect(find.text('Over'), findsOneWidget);
      expect(find.byType(TitleBar), findsOneWidget);
      expect(t.getTopLeft(find.text('Over')).dy, greaterThanOrEqualTo(40));
      expect(t.getRect(find.byKey(const ValueKey('caption-close'))).top, 0);
    });

    testWidgets('a press on the title bar closes an open menu', (t) async {
      await pumpApp(t);
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      expect(find.text('New page'), findsWidgets);
      await fromNative('ncPointerDown', null);
      await t.pumpAndSettle();
      expect(find.text('New page'), findsNothing);
    });

    testWidgets("a press on the title bar releases the menu bar's editor hold", (t) async {
      await pumpApp(t);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await t.pump();
      final bar = t.state<AppMenuBarState>(find.byType(AppMenuBar));
      expect(bar.holding, isTrue);
      await fromNative('ncPointerDown', null);
      await t.pumpAndSettle();
      expect(bar.holding, isFalse);
    });

    testWidgets('a press on the title bar closes the drawer', (t) async {
      await pumpApp(t, width: 700);
      await t.tap(find.byKey(const ValueKey('sidebar-menu')));
      await t.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      await fromNative('ncPointerDown', null);
      await t.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets('a press on the title bar closes the Details overlay', (t) async {
      await pumpApp(t, width: 900);
      await t.tap(find.byKey(const ValueKey('details-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('context-panel-overlay')), findsOneWidget);
      await fromNative('ncPointerDown', null);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('context-panel-overlay')), findsNothing);
    });
  });
}
