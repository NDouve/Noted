// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A canvas with three overlapping boxes, a few fake box modules and helpers
// for the context menu tests.

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class TCodec extends BoxCodec<String> {
  const TCodec(this.typeId);
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
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// The focus node of the fake editor of `test.editor`.
final FocusNode editorNode = FocusNode(debugLabel: 'fake editor');

/// Secondary taps the fake editor took itself.
int editorSecondaryTaps = 0;

/// Files created by `test.file`, in the order their creation completes.
class FileGate {
  final List<Completer<void>> waiting = [];
  final List<String> created = [];
  bool wait = false;
}

FileGate fileGate = FileGate();

/// What the fake insert commands saw and wait for: like the image and file
/// modules, they read `invocation`, wait for a picker, then insert.
class PickGate {
  final List<Completer<List<IncomingFile>>> pickers = [];
  final List<CommandInvocation?> seen = [];
  CommandInvocation? afterAwait;
  bool armed = false;
}

PickGate pickGate = PickGate();

Future<void> _insert(CommandHost host, String id) async {
  final gate = pickGate;
  if (!gate.armed) return;
  final inv = host.invocation;
  gate.seen.add(inv);
  final picker = Completer<List<IncomingFile>>();
  gate.pickers.add(picker);
  final files = await picker.future;
  gate.afterAwait = host.invocation;
  if (inv != null && !inv.isCurrent) return;
  await host.insertFiles(files, at: inv?.anchor);
}

class TModule extends BoxModule<String> {
  const TModule(this.id, [this.kind = '']);
  final String id;
  final String kind;

  @override
  BoxCodec<String> get codec => TCodec(id);

  @override
  List<Command> commands(CommandHost host) => kind == 'insert'
      ? [
          Command(
            id: 'noted.image.insert',
            label: 'Insert image',
            icon: Icons.image_rounded,
            enabled: () => host.attachments != null && !host.controller.readOnly,
            listenable: host.controller,
            invoke: () => _insert(host, 'noted.image.insert'),
          ),
          Command(
            id: 'noted.file.insert',
            label: 'Insert file',
            icon: Icons.attach_file_rounded,
            enabled: () => host.attachments != null && !host.controller.readOnly,
            listenable: host.controller,
            invoke: () => _insert(host, 'noted.file.insert'),
          ),
        ]
      : const [];

  @override
  int fileAffinity(IncomingFile file) =>
      kind == 'file' ? 1 : (kind == 'image' && file.name.endsWith('.png') ? 2 : 0);

  @override
  bool linkAt(String boxId, Offset global) => kind == 'link';

  @override
  Future<(String, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async {
    if (kind != 'file' && kind != 'image') return null;
    final gate = fileGate;
    if (gate.wait) {
      final c = Completer<void>();
      gate.waiting.add(c);
      await c.future;
    }
    await store.put(file.bytes, extension: file.extension);
    gate.created.add(file.name);
    return (file.name, const Size(100, 40));
  }

  Widget _body(BuildContext context, BoxContext<String> box) {
    switch (kind) {
      case 'editor':
        // Like the note editor: a focusable thing with a secondary tap of its own.
        return Focus(
          focusNode: editorNode,
          child: GestureDetector(
            onSecondaryTapUp: (_) => editorSecondaryTaps++,
            child: SizedBox.expand(child: Text(box.data)),
          ),
        );
      case 'field':
        return TextField(controller: TextEditingController(text: box.data), maxLines: null);
      default:
        return Text(box.data);
    }
  }

  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => _body(context, box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => _body(context, box);
}

class TPen extends CanvasTool {
  TPen(this.id, this.stylusRole);
  @override
  final String id;
  @override
  final StylusRole stylusRole;
  int started = 0;
  @override
  String get label => id;
  @override
  IconData get icon => Icons.edit;
  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) {
    started++;
    return _Session();
  }
}

class _Session extends ToolSession {
  @override
  void update(ToolPointer pointer) {}
  @override
  void end() {}
  @override
  void cancel() {}
  @override
  void paint(Canvas canvas, double scale) {}
}

class TDrawModule extends BoxModule<String> {
  const TDrawModule(this.tools);
  @override
  BoxCodec<String> get codec => const TCodec('test.draw');
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  final List<CanvasTool> tools;
}

/// A store that records files and notices.
class TStore implements AttachmentStore {
  final List<String> notices = [];
  final List<String> stored = [];
  bool failPut = false;

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async {
    if (failPut) throw const FileSystemException('The page is closed');
    final name = 'f${stored.length}.$extension';
    stored.add(name);
    return StoredAttachment(hash: contentHash(bytes), fileName: name);
  }

  @override
  void notify(String message) => notices.add(message);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

BoxRecord tbox(String id, String type, Bounds at, String text) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: at,
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$id',
);

/// Three boxes stacked on each other, a at the bottom: all contain (250, 250).
const Bounds ba = Bounds(100, 100, 300, 200);
const Bounds bb = Bounds(150, 150, 300, 200);
const Bounds bc = Bounds(200, 200, 300, 200);
const Offset overlapPoint = Offset(250, 250);

NotedPage tpage(List<CanvasNode> nodes, {String id = 'p'}) {
  var p = NotedPage.create(PageMeta.create(id: id, title: '', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

List<CanvasNode> threeBoxes() => [
  tbox('a', 'test.text', ba, 'alpha words'),
  tbox('b', 'test.text', bb, 'bravo words'),
  tbox('c', 'test.text', bc, 'charlie words'),
];

const Offset toolbarOffset = Offset(0, CommandToolbar.height);

/// The world one test builds: its controller, canvas and tools.
class World {
  World(this.t);

  final WidgetTester t;
  late CanvasController c;
  late CanvasToolSelection selection;
  late TPen pen;
  late TPen eraser;
  TStore? store;
  List<NotedPage> saved = [];
  final GlobalKey<PageCanvasState> key = GlobalKey<PageCanvasState>();
  bool readOnly = false;
  Set<String> disallowed = const {};
  ContextMenuStyle style = ContextMenuStyle.list;
  Size size = const Size(1200, 800);
  double textScale = 1;
  ThemeData? theme;
  /// Space above the canvas, changed under an open menu to move the canvas rect.
  final ValueNotifier<double> topInset = ValueNotifier(0);
  bool disableAnimations = true;
  bool boldText = false;
  late ModuleRegistry modules;

  PageCanvasState get state => key.currentState!;
  CanvasView get view => state.view!;
  Offset at(Offset world) => toolbarOffset + view.toScreen(world);
  List<String> get order => [for (final n in c.page.nodes) n.id];

  Future<void> pump({
    List<CanvasNode>? nodes,
    bool pen = false,
    bool withStore = false,
    bool modulesOff = false,
    Set<String> disallowed = const {},
    bool readOnly = false,
    ContextMenuStyle style = ContextMenuStyle.list,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    fileGate = FileGate();
    pickGate = PickGate();
    editorSecondaryTaps = 0;
    saved = [];
    this.pen = TPen('noted.drawing.pen', StylusRole.pen);
    eraser = TPen('noted.drawing.eraser', StylusRole.eraser);
    store = withStore ? TStore() : null;
    this.readOnly = readOnly;
    this.disallowed = disallowed;
    this.style = style;
    modules = ModuleRegistry()
      ..register(const TModule('test.text'), isDefault: true)
      ..register(const TModule('test.editor', 'editor'))
      ..register(const TModule('test.field', 'field'))
      ..register(const TModule('test.link', 'link'))
      ..register(const TModule('test.off'))
      ..register(const TModule('test.insert', 'insert'))
      ..register(const TModule('test.file', 'file'))
      ..register(const TModule('test.image', 'image'))
      ..register(TDrawModule(pen ? [this.pen, eraser] : const []));
    c = CanvasController(
      tpage(nodes ?? threeBoxes()),
      modules,
      onChanged: saved.add,
    )..disallowedTypes = disallowed;
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(_app());
    await t.pump();
    state.zoomTo(1);
    await t.pump();
  }

  Widget _app({CanvasController? controller, CanvasToolSelection? tools}) => MaterialApp(
    theme: theme,
    // Above the Navigator, so the menu routes see these settings too.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
        boldText: boldText,
      ),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: ValueListenableBuilder<double>(
          valueListenable: topInset,
          builder: (context, inset, canvas) => Padding(padding: EdgeInsets.only(top: inset), child: canvas),
          child: PageCanvas(
          key: key,
          controller: controller ?? c,
          tools: tools ?? selection,
          readOnly: readOnly,
          attachments: store,
          disallowedTypes: disallowed,
          contextMenuStyle: style,
          boxTypeName: (id) => id == 'test.text' ? 'Note' : null,
          toolbar: const ContextualToolbarLayout(
            leading: [],
            sections: [],
            trailing: [
              [CanvasCommands.select],
            ],
          ),
        ),
        ),
      ),
    ),
  );

  /// Rebuilds the canvas with changed inputs.
  Future<void> rebuild({
    CanvasController? controller,
    CanvasToolSelection? tools,
    bool? readOnly,
    Set<String>? disallowed,
  }) async {
    if (readOnly != null) this.readOnly = readOnly;
    if (disallowed != null) {
      this.disallowed = disallowed;
      (controller ?? c).disallowedTypes = disallowed;
    }
    await t.pumpWidget(_app(controller: controller, tools: tools));
  }

  Future<void> rightClick(Offset p, {int buttons = kSecondaryMouseButton}) async {
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse, buttons: buttons);
    await g.up();
    await g.removePointer();
    await t.pump();
  }

  Future<void> shiftF10() async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    await t.pump();
  }

  Future<TestGesture> hold(
    Offset p, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
    int pointer = 1,
    Duration time = const Duration(milliseconds: 600),
  }) async {
    final g = await t.startGesture(p, kind: kind, pointer: pointer);
    await t.pump(time);
    return g;
  }

  Finder get menu => find.byKey(const ValueKey('context-menu'));
  Finder get ring => find.byKey(const ValueKey('radial-menu'));
  Finder item(String id) => find.byKey(ValueKey('context-$id'));
  Finder slot(String id) => find.byKey(ValueKey('radial-$id'));
  Finder get focusOutline => find.byKey(const ValueKey('context-focus'));

  bool get open => menu.evaluate().isNotEmpty || ring.evaluate().isNotEmpty;

  /// Whether the entry [id] of the open menu or ring takes a tap.
  bool enabled(String id) {
    final f = menu.evaluate().isNotEmpty ? item(id) : slot(id);
    return t.widget<GestureDetector>(f).onTap != null;
  }

  Future<void> choose(String id) async {
    final f = menu.evaluate().isNotEmpty ? item(id) : slot(id);
    await t.tap(f);
    await t.pump();
    await t.pump();
    await t.pump();
    await t.pump();
  }

  /// The ids of the entries shown (rows of the list, or slots of the ring).
  List<String> entries() {
    final prefix = menu.evaluate().isNotEmpty ? 'context-' : 'radial-';
    final root = menu.evaluate().isNotEmpty ? menu : ring;
    return [
      for (final w in t.widgetList<GestureDetector>(
        find.descendant(of: root, matching: find.byType(GestureDetector)),
      ))
        if (w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix))
          (w.key! as ValueKey<String>).value.substring(prefix.length),
    ];
  }

  /// The label of the entry the focus outline is on.
  String? focused() {
    final o = focusOutline;
    if (o.evaluate().isEmpty) return null;
    final texts = find.descendant(of: o, matching: find.byType(Text));
    return t.widget<Text>(texts.first).data;
  }
}
