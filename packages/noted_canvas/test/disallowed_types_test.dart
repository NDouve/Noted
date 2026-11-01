// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  BoxSizing get sizing => BoxSizing.growsWithContent;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// The editor is a TextField, the view a plain Text; `insert` is its command.
class _Module extends BoxModule<String> {
  const _Module(this.id, [this.affinity = 1]);
  final int affinity;
  final String id;
  @override
  BoxCodec<String> get codec => _Codec(id);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      TextField(controller: TextEditingController(text: box.data), onChanged: box.commit);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data, key: ValueKey('view-${box.boxId}'));
  @override
  List<Command> commands(CommandHost host) => [
    Command(id: '$id.insert', label: 'Insert $id', icon: Icons.add, text: () => 'Short $id', invoke: () {}),
  ];
  @override
  int fileAffinity(IncomingFile file) => affinity;
  @override
  Future<String?> convertAttachments(
    String data,
    AttachmentStorage to,
    AttachmentStore store,
    List<String> overLimit,
  ) async => 'converted';
  @override
  Future<(String, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async =>
      ('from file', const Size(100, 40));
}

void main() {
  late ModuleRegistry modules;

  setUp(() {
    modules = ModuleRegistry()
      ..register(const _Module('test.note'), alwaysOn: true, isDefault: true)
      ..register(const _Module('test.other', 2));
  });

  CanvasController controller() {
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)),
      modules,
    );
    c.insertBox(
      commitBox(
        createBox(const _Codec('test.other'), const Bounds(50, 50, 200, 60)),
        const _Codec('test.other'),
        'other text',
      ),
    );
    return c;
  }

  Future<GlobalKey<PageCanvasState>> pump(
    WidgetTester t,
    CanvasController c,
    Set<String> disallowed, [
    GlobalKey<PageCanvasState>? withKey,
  ]) async {
    final key = withKey ?? GlobalKey<PageCanvasState>();
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: key, controller: c, disallowedTypes: disallowed),
        ),
      ),
    );
    return key;
  }

  testWidgets('a disallowed type shows its snapshot read-only; allowing it restores the editor', (t) async {
    final c = controller();
    final id = c.page.nodes.single.id;
    final before = writePage(c.page);
    final key = await pump(t, c, {'test.other'});
    expect(find.byType(TextField), findsNothing);
    expect(find.text('other text'), findsOneWidget);
    expect(find.text('Not allowed on this page'), findsOneWidget);
    expect(find.byKey(ValueKey('view-$id')), findsNothing);
    expect(writePage(c.page), before, reason: 'nothing is changed or dropped');

    await pump(t, c, {}, key);
    await t.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Not allowed on this page'), findsNothing);
    expect(key.currentState, isNotNull);
    expect(writePage(c.page), before);
    c.dispose();
  });

  testWidgets('a disallowed type has its commands disabled, with a tooltip saying why', (t) async {
    final c = controller();
    final key = await pump(t, c, {'test.other'});
    var cmd = key.currentState!.commands['test.other.insert']!;
    expect(cmd.enabled, isFalse);
    expect(cmd.tooltip, contains('not allowed on this page'));
    expect(cmd.text?.call(), 'Short test.other', reason: 'the button keeps its text');
    expect(await key.currentState!.commands.invoke('test.other.insert'), isFalse);

    await pump(t, c, {}, key);
    cmd = key.currentState!.commands['test.other.insert']!;
    expect(cmd.enabled, isTrue);
    expect(cmd.tooltip, 'Insert test.other');
    c.dispose();
  });

  testWidgets('files are not taken by a disallowed type; the always-on type can not be disallowed', (t) async {
    final c = controller();
    final store = _NoStore();
    final key = GlobalKey<PageCanvasState>();
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            key: key,
            controller: c,
            attachments: store,
            disallowedTypes: const {'test.other', 'test.note'},
          ),
        ),
      ),
    );
    // The other module would win (higher affinity); it is off and the
    // note module (always on) can not be, so it wins.
    await key.currentState!.insertFiles([IncomingFile('a.txt', Uint8List.fromList(const [1]))]);
    await t.pump();
    final types = [for (final n in c.page.nodes) if (n is BoxRecord) n.typeId];
    expect(types, ['test.other', 'test.note']);
    c.dispose();
  });

  test('converting attachments leaves boxes of a disallowed type as they are', () async {
    final c = controller();
    final before = writePage(c.page);
    final r = await convertPageAttachments(
      c,
      _NoStore(),
      AttachmentStorage.embedded,
      skipTypes: {'test.other'},
    );
    expect(r.changed, 0);
    expect(writePage(c.page), before);
    // Without the skip the module converts it.
    final r2 = await convertPageAttachments(c, _NoStore(), AttachmentStorage.embedded);
    expect(r2.changed, 1);
    c.dispose();
  });

  testWidgets('a conflicted box of a disallowed type offers no manual edit', (t) async {
    final mine = commitBox(
      createBox(const _Codec('test.other'), const Bounds(50, 50, 200, 60), device: 'D'),
      const _Codec('test.other'),
      'mine',
    );
    final theirs = commitBox(
      createBox(const _Codec('test.other'), const Bounds(50, 50, 200, 60), device: 'L'),
      const _Codec('test.other'),
      'theirs',
    );
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)).insertNode(
        mine.withConflict(BoxConflict.other(node: theirs.withId(mine.id).toRaw(), at: 1, device: 'L')),
      ),
      modules,
    );
    final id = mine.id;
    Future<void> openDialog(Set<String> off) async {
      final key = GlobalKey<PageCanvasState>();
      await pump(t, c, off, key);
      await t.tap(find.byKey(ValueKey('conflict-badge-$id')));
      await t.pumpAndSettle();
    }

    await openDialog({'test.other'});
    expect(find.byKey(const ValueKey('conflict-keep-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict-edit')), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();

    // Allowed on the page, the same conflict offers it.
    await openDialog({});
    expect(find.byKey(const ValueKey('conflict-edit')), findsOneWidget);
    c.dispose();
  });
}

class _NoStore implements AttachmentStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
