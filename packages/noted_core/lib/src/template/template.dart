// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Templates (0026): a page or a whole binder saved to be used again.
///
/// # File format
///
/// A template is one file, `<templateId>.notedtemplate`, holding one JSON
/// object:
///
/// ```json
/// {
///   "format": 1,
///   "templateId": "9f3c0a51d27e48b6",
///   "kind": "page",
///   "name": "Meeting notes",
///   "created": 1788000000000,
///   "extensions": {},
///   "page": { ...a complete page file object, as writePage writes it... }
/// }
/// ```
///
/// - `format`: the template format version ([templateFormatVersion]). A file
///   with a newer version is listed as unreadable and never overwritten.
/// - `templateId`: 16 hex digits, also the file name.
/// - `kind`: `"page"` or `"binder"`.
/// - `name`: the name shown in the template picker.
/// - `created`: milliseconds since the epoch.
/// - `extensions`: an object reserved for later use (AI rules, skills, ...).
///   This build never reads inside it; its content is kept verbatim.
/// - kind `"page"`: `page` is the page's file object: its boxes with their
///   contents, laid out as in a `.canvas` file. Subpages are not part of it.
/// - kind `"binder"`: `binder` holds the binder settings
///   (`{"title":...,"description":...,"owner":...,"color":"#AARRGGBB"}`) and
///   `pages` is a list of page file objects, the binder's page tree (each
///   page's `parentId` links to another page in the list).
///
/// Fields this build doesn't know are kept in order and verbatim. A template
/// that was read and not changed is written back as the exact text it was
/// read from.
///
/// Using a template never reuses its ids: [NotedTemplate.instantiatePage] and
/// [NotedTemplate.instantiateBinder] give pages, boxes and the binder new
/// ids, and new content revisions to boxes.
///
/// Where templates live is up to the app: app-wide templates in a
/// `templates` folder next to the app settings, a binder's own templates in
/// `templates` inside the binder's folder.
library;

import 'dart:io';

import '../binder/binder.dart';
import '../format/page_format.dart';
import '../json/raw_json.dart';
import '../model/ids.dart';
import '../model/page.dart';

/// The template format version this build reads and writes.
const int templateFormatVersion = 1;

/// The file extension of template files.
const String templateExtension = '.notedtemplate';

/// What a template creates.
enum TemplateKind {
  page,
  binder;

  static TemplateKind? parse(String? name) => switch (name) {
    'page' => TemplateKind.page,
    'binder' => TemplateKind.binder,
    _ => null,
  };
}

/// The template file isn't a readable Noted template.
final class TemplateFormatException implements Exception {
  const TemplateFormatException(this.message);

  final String message;

  @override
  String toString() => 'TemplateFormatException: $message';
}

/// The template was written by a newer app. The file must not be
/// overwritten.
final class UnsupportedTemplateFormatException extends TemplateFormatException {
  const UnsupportedTemplateFormatException(this.format)
    : super('template format $format is newer than $templateFormatVersion');

  final int format;
}

/// The settings a binder template carries.
final class TemplateBinderSettings {
  const TemplateBinderSettings({
    required this.title,
    required this.description,
    required this.owner,
    required this.color,
  });

  final String title;
  final String description;
  final String owner;

  /// `#AARRGGBB`.
  final String color;
}

/// A new binder made from a template: its metadata and page tree, with new
/// ids throughout.
final class BinderFromTemplate {
  const BinderFromTemplate(this.binder, this.pages);

  final Binder binder;
  final List<NotedPage> pages;
}

/// A template (see the library documentation for the file format).
final class NotedTemplate {
  NotedTemplate._(
    this.fields,
    this._text, {
    required this.id,
    required this.kind,
    required this.name,
    required this.created,
    required this.format,
    required NotedPage? page,
    required TemplateBinderSettings? settings,
    required List<NotedPage> pages,
  }) : _page = page, // ignore: prefer_initializing_formals
       _settings = settings, // ignore: prefer_initializing_formals
       _pages = List.unmodifiable(pages);

  /// A page template from [page], as it is now. The page is stored as a top
  /// level page.
  factory NotedTemplate.forPage({
    required String name,
    required NotedPage page,
    String? id,
    DateTime? created,
  }) {
    final top = page.withMeta(page.meta.withPlacement(parentId: null, order: 0));
    return _build(
      id: id,
      kind: TemplateKind.page,
      name: name,
      created: created,
      body: [('page', RawJson.trusted(_pageText(top)))],
    );
  }

  /// A binder template from the settings of [binder] and its [pages].
  factory NotedTemplate.forBinder({
    required String name,
    required Binder binder,
    required List<NotedPage> pages,
    String? id,
    DateTime? created,
  }) {
    final settings = RawObject([
      ('title', RawJson.encode(binder.title)),
      ('description', RawJson.encode(binder.description)),
      ('owner', RawJson.encode(binder.owner)),
      ('color', RawJson.encode(binder.color)),
    ]);
    return _build(
      id: id,
      kind: TemplateKind.binder,
      name: name,
      created: created,
      body: [
        ('binder', settings.toRaw()),
        ('pages', RawJson.trusted('[${pages.map(_pageText).join(',')}]')),
      ],
    );
  }

  static NotedTemplate _build({
    required String? id,
    required TemplateKind kind,
    required String name,
    required DateTime? created,
    required List<(String, RawJson)> body,
  }) {
    final fields = RawObject([
      ('format', RawJson.encode(templateFormatVersion)),
      ('templateId', RawJson.encode(id ?? newId())),
      ('kind', RawJson.encode(kind.name)),
      ('name', RawJson.encode(name)),
      ('created', RawJson.encode((created ?? DateTime.now()).millisecondsSinceEpoch)),
      ('extensions', const RawJson.trusted('{}')),
      ...body,
    ]);
    return _read(fields, null);
  }

  /// Parses the text of a template file.
  ///
  /// Throws [TemplateFormatException] if it isn't valid, and
  /// [UnsupportedTemplateFormatException] if a newer app wrote it.
  static NotedTemplate parse(String source) {
    if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) {
      source = source.substring(1);
    }
    final RawObject fields;
    try {
      fields = RawObject.parse(source);
    } on FormatException catch (e) {
      throw TemplateFormatException('not valid JSON: ${e.message}');
    }
    return _read(fields, source);
  }

  static NotedTemplate _read(RawObject fields, String? text) {
    final format = fields.integer('format');
    final id = fields.string('templateId');
    if (format == null || id == null || id.isEmpty) {
      throw const TemplateFormatException('malformed template file');
    }
    if (format > templateFormatVersion) throw UnsupportedTemplateFormatException(format);
    final kind = TemplateKind.parse(fields.string('kind'));
    if (kind == null) throw const TemplateFormatException('unknown template kind');
    NotedPage readOne(RawJson raw) {
      try {
        return readPage(raw.text);
      } on PageFormatException catch (e) {
        throw TemplateFormatException('a page in the template is unreadable: ${e.message}');
      }
    }

    NotedPage? page;
    TemplateBinderSettings? settings;
    final pages = <NotedPage>[];
    try {
      if (kind == TemplateKind.page) {
        final raw = fields['page'];
        if (raw == null || !raw.isObject) {
          throw const TemplateFormatException('the template has no page');
        }
        page = readOne(raw);
      } else {
        final raw = fields['binder'];
        final list = fields['pages'];
        if (raw == null || !raw.isObject || list == null || !list.isArray) {
          throw const TemplateFormatException('the template has no binder or pages');
        }
        final s = RawObject.parse(raw.text);
        settings = TemplateBinderSettings(
          title: s.string('title') ?? '',
          description: s.string('description') ?? '',
          owner: s.string('owner') ?? '',
          color: s.string('color') ?? binderPalette.first,
        );
        for (final item in JsonSpanReader.readArray(list.text)) {
          pages.add(readOne(item));
        }
      }
    } on FormatException catch (e) {
      throw TemplateFormatException('malformed template file: ${e.message}');
    }
    return NotedTemplate._(
      fields,
      text,
      id: id,
      kind: kind,
      name: fields.string('name') ?? '',
      created: fields.integer('created'),
      format: format,
      page: page,
      settings: settings,
      pages: pages,
    );
  }

  /// Every field of the file, in file order.
  final RawObject fields;
  final String? _text;
  final String id;
  final TemplateKind kind;
  final String name;

  /// When the template was made, in milliseconds since the epoch.
  final int? created;
  final int format;
  final NotedPage? _page;
  final TemplateBinderSettings? _settings;
  final List<NotedPage> _pages;

  /// The reserved `extensions` object, verbatim; null if absent.
  RawJson? get extensions => fields['extensions'];

  /// The page of a page template.
  NotedPage get page {
    final p = _page;
    if (p == null) throw StateError('not a page template');
    return p;
  }

  /// The settings of a binder template.
  TemplateBinderSettings get binderSettings {
    final s = _settings;
    if (s == null) throw StateError('not a binder template');
    return s;
  }

  /// The page tree of a binder template.
  List<NotedPage> get pages => _pages;

  /// The text of the template file. A template that was read from text and
  /// not changed gives that text back exactly.
  String write() {
    final t = _text;
    if (t != null) return t;
    final b = StringBuffer('{\n');
    final entries = fields.entries;
    for (var i = 0; i < entries.length; i++) {
      final (k, v) = entries[i];
      b.write('  ${RawJson.encode(k).text}: ${v.text}');
      b.write(i == entries.length - 1 ? '\n' : ',\n');
    }
    b.write('}\n');
    return b.toString();
  }

  /// A new page from a page template: new page id, new box ids and new box
  /// revisions, the boxes and their contents as in the template, and the
  /// template page's title unless [title] is given. It is placed under
  /// [parentId] (null: top level) at [order].
  NotedPage instantiatePage({String? parentId, required int order, String? title}) {
    var fresh = _freshPage(page, id: newId(), parentId: parentId, order: order);
    if (title != null) fresh = fresh.withMeta(fresh.meta.withTitle(title));
    return fresh;
  }

  /// A new binder from a binder template: the template's settings with a new
  /// binder id, and its page tree with new page and box ids (parent links
  /// follow the new ids).
  BinderFromTemplate instantiateBinder() {
    final s = binderSettings;
    final binder = Binder.create(
      title: s.title,
      description: s.description,
      owner: s.owner,
      color: s.color,
    );
    final ids = {for (final p in pages) p.id: newId()};
    final out = [
      for (final p in pages)
        _freshPage(
          p,
          id: ids[p.id]!,
          parentId: ids[p.meta.parentId],
          order: p.meta.order,
        ),
    ];
    return BinderFromTemplate(binder, out);
  }
}

String _pageText(NotedPage page) => writePage(page).trimRight();

NotedPage _freshPage(
  NotedPage src, {
  required String id,
  required String? parentId,
  required int order,
}) {
  final ids = <String, String>{};
  final nodes = <CanvasNode>[];
  for (final n in src.nodes) {
    final fresh = _freshNode(n, ids);
    nodes.add(fresh);
  }
  var meta = src.meta.withPlacement(parentId: parentId, order: order);
  meta = PageMeta.tryRead(meta.fields.set('pageId', RawJson.encode(id)))!;
  return NotedPage.fromParts(_remapEdges(src.top, ids), meta, nodes);
}

CanvasNode _freshNode(CanvasNode n, Map<String, String> ids) {
  switch (n) {
    case BoxRecord():
      final nid = newId();
      ids[n.id] = nid;
      var noted = n.noted.remove('baseRev').remove('conflicts');
      if (n.rev != null) noted = noted.set('rev', RawJson.encode(newId()));
      final fields = n.fields.set('id', RawJson.encode(nid)).set('noted', noted.toRaw());
      return BoxRecord.tryRead(fields, fields.toRaw()) ?? n;
    case ForeignNode():
      // Only a node that really has an id gets a new one.
      try {
        if (n.raw.isObject && RawObject.parse(n.raw.text).string('id') != null) {
          final nid = newId();
          final copy = n.copyWithId(nid);
          if (copy != null) {
            ids[n.id] = nid;
            return copy;
          }
        }
      } on FormatException {
        // Keep the node as it is.
      }
      return n;
  }
}

// Edges point at node ids; follow the new ids.
RawObject _remapEdges(RawObject top, Map<String, String> ids) {
  final raw = top['edges'];
  if (raw == null || !raw.isArray || ids.isEmpty) return top;
  try {
    var changed = false;
    final out = <String>[];
    for (final item in JsonSpanReader.readArray(raw.text)) {
      if (!item.isObject) {
        out.add(item.text);
        continue;
      }
      var o = RawObject.parse(item.text);
      var edited = false;
      for (final k in const ['fromNode', 'toNode']) {
        final v = o.string(k);
        final mapped = v == null ? null : ids[v];
        if (mapped != null) {
          o = o.set(k, RawJson.encode(mapped));
          edited = true;
        }
      }
      changed = changed || edited;
      out.add(edited ? o.toRaw().text : item.text);
    }
    return changed ? top.set('edges', RawJson.trusted('[${out.join(',')}]')) : top;
  } on FormatException {
    return top;
  }
}

/// The result of reading one template file.
sealed class TemplateEntry {
  const TemplateEntry(this.path);

  final String path;
}

final class ReadableTemplate extends TemplateEntry {
  const ReadableTemplate(super.path, this.template);

  final NotedTemplate template;
}

/// A file that couldn't be read as a template. The store never overwrites
/// it.
final class UnreadableTemplate extends TemplateEntry {
  const UnreadableTemplate(super.path, this.reason);

  final String reason;
}

/// The template files in one folder.
final class TemplateStore {
  TemplateStore(this.directory);

  final Directory directory;

  /// Reads every template file in the folder, newest first. A folder that
  /// doesn't exist has none; it is not created.
  Future<List<TemplateEntry>> scan() async {
    if (!await directory.exists()) return const [];
    final entries = <TemplateEntry>[];
    await for (final f in directory.list()) {
      if (f is! File || !f.path.endsWith(templateExtension)) continue;
      try {
        entries.add(ReadableTemplate(f.path, NotedTemplate.parse(await f.readAsString())));
      } on TemplateFormatException catch (e) {
        entries.add(UnreadableTemplate(f.path, e.message));
      } on FileSystemException catch (e) {
        entries.add(UnreadableTemplate(f.path, e.message));
      } on FormatException {
        entries.add(UnreadableTemplate(f.path, 'not valid UTF-8 text'));
      }
    }
    int created(TemplateEntry e) => e is ReadableTemplate ? e.template.created ?? 0 : 0;
    entries.sort((a, b) {
      final c = created(b).compareTo(created(a));
      return c != 0 ? c : a.path.compareTo(b.path);
    });
    return entries;
  }

  /// The file that holds (or will hold) the template [templateId].
  File fileFor(String templateId) =>
      File('${directory.path}${Platform.pathSeparator}$templateId$templateExtension');

  /// Writes [template] atomically: to a temporary file, then renamed. Throws
  /// [FileSystemException] if a file for its id already exists, which is
  /// never overwritten.
  Future<File> save(NotedTemplate template) async {
    final file = fileFor(template.id);
    if (await file.exists()) {
      throw FileSystemException('template file already exists', file.path);
    }
    await directory.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(template.write(), flush: true);
    await tmp.rename(file.path);
    return file;
  }

  /// Deletes the template file at [path], which must be a template file in
  /// this folder.
  Future<void> delete(String path) async {
    final f = File(path);
    if (!path.endsWith(templateExtension) || f.parent.absolute.path != directory.absolute.path) {
      throw ArgumentError.value(path, 'path', 'not a template file of this folder');
    }
    if (await f.exists()) await f.delete();
  }
}
