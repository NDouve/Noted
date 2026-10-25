// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId);
  @override
  final String typeId;
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// An editor made of one text field, like a real module's.
class _Module extends BoxModule<String> {
  const _Module();
  @override
  BoxCodec<String> get codec => const _Codec('test.text');
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      _Field(box: box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

class _Field extends StatefulWidget {
  const _Field({required this.box});
  final BoxContext<String> box;
  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final TextEditingController _c = TextEditingController(text: widget.box.data);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(controller: _c, onChanged: widget.box.commit);
}

BoxRecord _box(String type, String text, {String? device, int? at}) => BoxRecord.create(
  id: 'a',
  typeId: type,
  dataVersion: 1,
  bounds: const Bounds(100, 100, 200, 60),
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$text',
  device: device,
  at: at,
);

void main() {
  late ModuleRegistry modules;
  late List<NotedPage> saved;
  final t1 = DateTime(2026, 10, 25, 9, 5).millisecondsSinceEpoch;
  final t2 = DateTime(2026, 10, 25, 10, 30).millisecondsSinceEpoch;

  setUp(() {
    modules = ModuleRegistry()..register(const _Module(), alwaysOn: true, isDefault: true);
    saved = [];
  });

  BoxRecord conflicted({String type = 'test.text', String? otherDevice = 'LAPTOP'}) {
    final mine = _box('test.text', 'mine', device: 'DESKTOP', at: t1);
    final theirs = _box(type, 'theirs', device: otherDevice, at: t2);
    return mine.withConflict(
      BoxConflict.other(node: theirs.toRaw(), at: t2, device: otherDevice),
    );
  }

  CanvasController controllerOf(BoxRecord b) => CanvasController(
    NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(b),
    modules,
    onChanged: saved.add,
    deviceName: 'DESKTOP',
    clock: () => 5000,
  );

  Future<void> open(WidgetTester t, CanvasController c) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(controller: c))));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
    await t.pumpAndSettle();
  }

  testWidgets('labels show device names and times', (t) async {
    final c = controllerOf(conflicted());
    await open(t, c);
    expect(find.text('This device (DESKTOP) · edited 2026-10-25 09:05'), findsOneWidget);
    expect(find.text('LAPTOP · saved 2026-10-25 10:30'), findsOneWidget);
  });

  testWidgets('an unknown other device is labelled Other device', (t) async {
    final c = controllerOf(conflicted(otherDevice: null));
    await open(t, c);
    expect(find.text('Other device · saved 2026-10-25 10:30'), findsOneWidget);
  });

  testWidgets('a deleted conflict says deleted and offers no manual edit', (t) async {
    final c = controllerOf(
      _box('test.text', 'mine', device: 'DESKTOP', at: t1).withConflict(BoxConflict.deleted(at: t2)),
    );
    await open(t, c);
    expect(find.text('Other device · deleted 2026-10-25 10:30'), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict-edit')), findsNothing);
  });

  testWidgets('not offered when this device cannot run the box', (t) async {
    final c = controllerOf(conflicted(type: 'other.unknown'));
    await open(t, c);
    expect(find.byKey(const ValueKey('conflict-keep-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict-edit')), findsNothing);
  });

  testWidgets('Edit manually opens both versions in editable panes', (t) async {
    final c = controllerOf(conflicted());
    await open(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-edit')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-edit-dialog')), findsOneWidget);
    Finder pane(String k) => find.descendant(
      of: find.byKey(ValueKey(k)),
      matching: find.byType(TextField),
    );
    expect(pane('conflict-edit-mine'), findsOneWidget);
    expect(pane('conflict-edit-theirs'), findsOneWidget);
    expect(t.widget<TextField>(pane('conflict-edit-mine')).controller!.text, 'mine');
    expect(t.widget<TextField>(pane('conflict-edit-theirs')).controller!.text, 'theirs');
    expect(find.text('This device (DESKTOP) · edited 2026-10-25 09:05'), findsOneWidget);
    expect(find.text('LAPTOP · saved 2026-10-25 10:30'), findsOneWidget);
  });

  testWidgets('using the other pane after editing it resolves with that data', (t) async {
    final c = controllerOf(conflicted());
    await open(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-edit')));
    await t.pumpAndSettle();
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('conflict-edit-theirs')),
        matching: find.byType(TextField),
      ),
      'theirs edited',
    );
    await t.pump();
    // Nothing reaches the page before a version is chosen.
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'mine');
    await t.tap(find.byKey(const ValueKey('conflict-use-theirs')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-edit-dialog')), findsNothing);
    final n = c.page.node('a')! as BoxRecord;
    expect(n.snapshotText, 'theirs edited');
    expect(n.data!.decode(), 'theirs edited');
    expect(n.isConflicted, isFalse);
    expect(n.device, 'DESKTOP');
    expect(n.editedAt, 5000);
    expect(saved, isNotEmpty);
    // One undo step brings the conflict back.
    c.undo();
    final back = c.page.node('a')! as BoxRecord;
    expect(back.snapshotText, 'mine');
    expect(back.isConflicted, isTrue);
    c.redo();
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'theirs edited');
  });

  testWidgets('using my pane unedited keeps my data and drops the conflict', (t) async {
    final c = controllerOf(conflicted());
    await open(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-edit')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('conflict-use-mine')));
    await t.pumpAndSettle();
    final n = c.page.node('a')! as BoxRecord;
    expect(n.snapshotText, 'mine');
    expect(n.isConflicted, isFalse);
  });

  testWidgets('Cancel in the manual view changes nothing', (t) async {
    final c = controllerOf(conflicted());
    final before = c.page.node('a')!.toRaw();
    await open(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-edit')));
    await t.pumpAndSettle();
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('conflict-edit-mine')),
        matching: find.byType(TextField),
      ),
      'changed',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('conflict-edit-cancel')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-edit-dialog')), findsNothing);
    expect(c.page.node('a')!.toRaw(), before);
    expect(saved, isEmpty);
    expect(c.canUndo, isFalse);
  });

  test('without a device name nothing is stamped', () {
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(
        _box('test.text', 'x'),
      ),
      modules,
    );
    c.commit('a', 'y');
    final n = c.page.node('a')! as BoxRecord;
    expect(n.device, isNull);
    expect(n.editedAt, isNull);
  });

  test('commit, editBox and createBoxAt stamp device and time', () {
    final c = controllerOf(_box('test.text', 'x'));
    c.commit('a', 'y');
    expect((c.page.node('a')! as BoxRecord).device, 'DESKTOP');
    expect((c.page.node('a')! as BoxRecord).editedAt, 5000);
    final made = c.createBoxAt(const Bounds(0, 0, 10, 10));
    expect(made.device, 'DESKTOP');
    expect(made.editedAt, 5000);
    final e = c.editBox('a', 'z')!;
    expect(e.device, 'DESKTOP');
  });
}
