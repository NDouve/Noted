// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// 0190: a file that is not downloaded is never read and never taken for
// absent, so every read of a stored file goes through `readStored` and its
// siblings (`packages/noted_core/lib/src/storage/stored_read.dart`). This test
// scans the source for a direct read and fails on one that is not listed.
//
// The scan strips comments and string text with a small tokenizer, keys each
// call by `file::declaration::call` (the declaration comes from brace depth, so
// moved lines and formatting don't matter), and compares the count of each key
// with the allow-list, exactly. A key that is not listed fails, and so does a
// listed key that no longer matches (no stale entries).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The calls that read a file's data, or open it (every `.open(` of anything:
/// write-only opens and opens of something that is not a file are listed too).
final RegExp _calls = RegExp(
  r'\.(readAsBytes|readAsString|readAsLines|openRead|copy|open)(Sync)?\b(?!\w)',
);

// -- The allow-list --------------------------------------------------------------
//
// Each entry is `file::declaration::call` with its exact count and a reason from
// one of the classes below. There are no whole-file entries.

const String _appState = 'app state in the data folder, never in a storage location';
const String _ownTemp = 'a temp this same call wrote';
const String _picked = 'a source the user or the OS picked (the OS downloads it first)';
const String _cache = 'local cache';
const String _hydrate = 'deliberate hydration';
const String _pullPrivate = "the in-app pull's private folder (nothing evicts there)";
const String _mcp = 'the MCP server: guarded just before (0190)';
const String _writeOnly = 'a write-only open (append or write mode, no read)';
const String _notFile = 'not a file';

typedef _Allowed = ({int count, String reason});

const Map<String, _Allowed> _allowed = {
  // App state in the data folder, never in a storage location.
  'app/lib/src/app_settings.dart::AppSettings._read::readAsStringSync': (count: 1, reason: _appState),
  'app/lib/src/notebook.dart::Notebook._readSettingsBytesInner::readAsBytes': (count: 1, reason: _appState),
  'app/lib/src/icloud_folders.dart::IcloudFolders._readList::readAsBytes': (count: 2, reason: _appState),
  'app/lib/src/ai/ai_access_service.dart::AiAccessService._rawLog::readAsBytesSync': (count: 1, reason: _appState),
  'app/lib/src/ai/ai_access_service.dart::AiAccessService.mcpLogEntries::readAsBytesSync': (count: 1, reason: _appState),
  'app/lib/src/ai/ai_link_server.dart::AiLinkServer.dispose::readAsStringSync': (count: 1, reason: _appState),
  'packages/noted_core/lib/src/ai/ai_access_store.dart::AiAccessStore.read::readAsStringSync': (count: 1, reason: _appState),
  'packages/noted_core/lib/src/ai/ai_activity_log.dart::AiActivityLog._read::readAsStringSync': (count: 1, reason: _appState),
  'app/lib/src/onedrive_sync.dart::OneDriveSync._loadChosen::readAsString': (count: 1, reason: _appState),
  'app/lib/src/webdav_sync.dart::WebDavSync._scan::readAsString': (count: 1, reason: _appState),
  'packages/noted_sync/lib/src/journal.dart::JournalStore.load::readAsString': (count: 1, reason: _appState),
  'packages/noted_sync/lib/src/journal.dart::BlobStore.put::copy': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._listNow::readAsString': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._listOnce::readAsBytes': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._migrate::readAsString': (count: 4, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._peek::readAsString': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._rekeyPass::readAsBytes': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._rekeyPass::readAsString': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore._settleTmps::readAsString': (count: 1, reason: _appState),
  'app/lib/src/recovery_store.dart::RecoveryStore.indexReadOnly::readAsString': (count: 1, reason: _appState),
  'app/lib/src/notebook.dart::Notebook._landFiles::copy': (count: 1, reason: _appState),

  // A temp this same call wrote.
  'app/lib/src/icloud_folders.dart::IcloudFolders._landLocked::readAsBytes': (count: 1, reason: _ownTemp),
  'app/lib/src/icloud_folders.dart::IcloudFolders._stage::readAsBytes': (count: 1, reason: _ownTemp),
  'app/lib/src/icloud_folders.dart::IcloudFolders._landPageVersion::readAsBytes': (count: 1, reason: _ownTemp),
  'app/lib/src/icloud_folders.dart::IcloudFolders._landAttachmentVersion::readAsBytes': (count: 1, reason: _ownTemp),
  'app/lib/src/notebook.dart::Notebook.putBackBinderCopy::readAsBytes': (count: 1, reason: _ownTemp),
  'app/lib/src/attachment_copy.dart::copyAttachmentFile::openRead': (count: 1, reason: _ownTemp),
  'app/lib/src/attachment_copy.dart::_createExclusive::openRead': (count: 2, reason: _ownTemp),

  // A source the user or the OS picked (the OS downloads it first).
  'app/lib/src/attachment_platform.dart::pickAttachments::readAsBytes': (count: 1, reason: _picked),
  'app/lib/src/attachment_platform.dart::readClipboardFiles::readAsBytes': (count: 1, reason: _picked),
  'app/lib/src/open_files.dart::openExistingFile::readAsString': (count: 1, reason: _picked),

  // Local cache.
  'packages/boxes/attachments/lib/src/image_module.dart::loadDisplayCopyChecked::readAsBytes': (count: 1, reason: _cache),
  // The temporary copy an embedded file is opened from, in the system temp folder:
  // an earlier open wrote it, and this one hashes it again before reusing it.
  'app/lib/src/page_attachments.dart::PageAttachments.open::openRead': (count: 1, reason: _cache),

  // Deliberate hydration (a Windows placeholder; Apple returns before it).
  'app/lib/src/notebook.dart::Notebook._hydrate::openRead': (count: 1, reason: _hydrate),

  // The in-app pull's private folder (nothing evicts there).
  'packages/noted_sync/lib/src/pull_engine.dart::PullEngine._quick::openRead': (count: 1, reason: _pullPrivate),
  'packages/noted_sync/lib/src/pull_engine.dart::PullEngine._confirmMoving::copy': (count: 1, reason: _pullPrivate),
  'packages/noted_sync/lib/src/pull_engine.dart::PullEngine._repath::copy': (count: 2, reason: _pullPrivate),

  // The MCP server (its own guarded funnel, behind isDataless).
  'packages/noted_mcp/lib/src/running_probe.dart::LockIdentity.readBytes::readAsBytes': (count: 1, reason: _mcp),
  'packages/noted_mcp/lib/src/running_probe.dart::LockGate.take::open': (count: 1, reason: _mcp),
  'packages/noted_mcp/lib/src/closed_writer.dart::ClosedWriter.replacePage::readAsBytes': (count: 3, reason: _mcp),

  // A binder .zip: the zip a share builds in its own temp folder, read back by
  // the same share (compacted, finished) and by its publish.
  // This key is appendZipEntries' open of the zip it builds: the scan doesn't
  // name a declaration whose return type is a record, so the call is keyed by
  // the declaration before it, _RafSink.close.
  'app/lib/src/binder_zip/zip_writer.dart::_RafSink.close::openSync': (count: 1, reason: _ownTemp),
  'app/lib/src/binder_zip/zip_writer.dart::compactZip::openSync': (count: 2, reason: _ownTemp),
  'app/lib/src/binder_zip/zip_writer.dart::finishZip::openSync': (count: 1, reason: _ownTemp),
  'app/lib/src/export/exclusive_create.dart::createExclusiveFromFile::openSync': (count: 1, reason: _ownTemp),
  'app/lib/src/export/exclusive_create.dart::createExclusiveFromFile::openRead': (count: 1, reason: _ownTemp),
  'app/lib/src/export/export_write.dart::ExportWriter._copyTo::openRead': (count: 1, reason: _ownTemp),

  // Write-only opens (append or write mode, no read).
  'app/lib/src/binder_zip/binder_share.dart::_copyOwn::openSync': (count: 1, reason: _writeOnly),
  'app/lib/src/binder_zip/zip_extract.dart::createNewFile::openSync': (count: 1, reason: _writeOnly),
  'app/lib/src/export/export_write.dart::ExportWriter._copyTo::open': (count: 1, reason: _writeOnly),
  'app/lib/src/ai/ai_access_service.dart::AiAccessService._hasRevoked::openSync': (count: 1, reason: _writeOnly),
  'app/lib/src/ai/ai_access_service.dart::AiAccessService.trimMcpLog::openSync': (count: 1, reason: _writeOnly),
  'app/lib/src/ai/ai_running_lock.dart::AiRunningLock._tryOnce::openSync': (count: 1, reason: _writeOnly),
  'app/lib/src/recovery_lock.dart::RecoveryLock._tryOnce::openSync': (count: 1, reason: _writeOnly),
  'packages/noted_core/lib/src/ai/locked_file.dart::withFileLock::openSync': (count: 1, reason: _writeOnly),
  'packages/noted_mcp/lib/src/closed_writer.dart::ClosedWriter.appendLog::open': (count: 1, reason: _writeOnly),
  'app/lib/src/attachment_copy.dart::_streamCopy::open': (count: 1, reason: _writeOnly),
  'app/lib/src/attachment_copy.dart::_createExclusive::open': (count: 1, reason: _writeOnly),

  // Not a file.
  'app/lib/src/menu_bar.dart::AppMenuBarState._openAt::open': (count: 1, reason: _notFile),
  'app/lib/src/menu_bar.dart::AppMenuBarState._topMenu::open': (count: 2, reason: _notFile),
  'packages/noted_canvas/lib/src/page_canvas.dart::PageCanvasState._takeFindRequest::open': (count: 1, reason: _notFile),
  'packages/noted_canvas/lib/src/page_canvas.dart::PageCanvasState.openFind::open': (count: 1, reason: _notFile),
  'packages/boxes/attachments/lib/src/file_module.dart::_FileBoxState._content::open': (count: 1, reason: _notFile),
  'app/lib/src/storage_check.dart::freeSpaceBytes::open': (count: 1, reason: _notFile),
  'packages/noted_core/lib/src/storage/exclusive_move.dart::_moveWindows::open': (count: 1, reason: _notFile),
  'packages/noted_core/lib/src/storage/exclusive_move.dart::syncRootOf::open': (count: 1, reason: _notFile),
  'packages/noted_core/lib/src/storage/exclusive_publish.dart::_moveWindows::open': (count: 1, reason: _notFile),
  'packages/noted_core/lib/src/storage/file_stamp.dart::rawFileInfo::open': (count: 1, reason: _notFile),
  'app/lib/src/home.dart::_HomeState._openResult::open': (count: 1, reason: _notFile),
  'app/lib/src/home.dart::_HomeState._showKeptPage::open': (count: 1, reason: _notFile),
  'app/lib/src/page_tree_view.dart::PageTreeViewState._row::open': (count: 1, reason: _notFile),
  'app/lib/src/open_files.dart::openExistingFile::open': (count: 1, reason: _notFile),
  'app/lib/src/import/folder_store.dart::_Forward.open::open': (count: 1, reason: _notFile),
  'app/lib/src/import/import_images.dart::renderPdfPages::open': (count: 1, reason: _notFile),

  'app/lib/src/import/import_source.dart::ImportSource.ImportSource.fromFile::readAsBytes': (count: 1, reason: _picked),
  'app/lib/src/notebook.dart::Notebook._mergeConflictCopy::open': (count: 1, reason: _notFile),
  'app/lib/src/notebook.dart::Notebook._postIncomplete::copy': (count: 4, reason: _notFile),
  'app/lib/src/notebook.dart::Notebook._undoDeleteNow::copy': (count: 1, reason: _notFile),
  'app/lib/src/notebook.dart::Notebook.pagesThatLostAiAccess::open': (count: 1, reason: _notFile),
  'app/lib/src/notebook.dart::_ReplayFailure.toString::copy': (count: 1, reason: _notFile),
  'packages/noted_mcp/lib/src/tools.dart::NotedTools._canRead::open': (count: 1, reason: _notFile),

};

void main() {
  group('the scanner', () {
    test('strips comments and string text, keeps interpolated code', () {
      const src = r'''
a.readAsString(); // b.readAsString()
/* c.readAsString() /* nested d.readAsString() */ still comment e.readAsString() */
final s = 'f.readAsString() // g.readAsString() /* h';
final t = "it's ${i.readAsString()} and ${'${j.readAsString()}'} k.open()";
final u = 'it\'s l.open() \' m.open()';
final v = "a\"b n.open()";
final w = r'o.open() \';
final x = """multi
p.open() """;
q.readAsBytes();
final tearOff = r.readAsBytes;
''';
      final code = stripSource(src);
      final found = [for (final m in _calls.allMatches(code)) code.substring(m.start - 1, m.start)];
      // Real calls: a (line 1), the two inside ${...}, and q.
      expect(_calls.allMatches(code).map((m) => code.substring(m.start - 1, m.end)).toList(), [
        'a.readAsString',
        'i.readAsString',
        'j.readAsString',
        'q.readAsBytes',
        'r.readAsBytes',
      ]);
      expect(found, ['a', 'i', 'j', 'q', 'r']);
      expect(code.length, src.length, reason: 'positions are kept');
    });

    test('keys a call by its declaration, from brace depth', () {
      const src = r'''
import 'dart:io';
Future<void> top() async {
  await File('a').readAsBytes();
  final f = () {
    File('b').readAsString();
  };
}
class Foo {
  final x = {1: 2};
  Future<String> member(String p) async {
    if (true) {
      return File(p).readAsString();
    }
    return '';
  }
  @override
  Future<List<int>> expr() => File('a').readAsBytes();
  String get g => File('a').readAsStringSync();
  static Future<void> gen<T>(Map<String, T> m, {int a = 1}) async {
    await File('a').readAsBytes();
  }
}
extension E on File {
  Future<void> viaExtension() async => File('a').openRead();
  void sync() { File('a').openSync(); }
}
''';
      expect(keysOf('x.dart', src), {
        'x.dart::top::readAsBytes': 1,
        'x.dart::top::readAsString': 1,
        'x.dart::Foo.member::readAsString': 1,
        'x.dart::Foo.expr::readAsBytes': 1,
        'x.dart::Foo.g::readAsStringSync': 1,
        'x.dart::Foo.gen::readAsBytes': 1,
        'x.dart::E.viaExtension::openRead': 1,
        'x.dart::E.sync::openSync': 1,
      });
    });
  });

  test('every read of a stored file goes through the routed read', () {
    final root = _repoRoot();
    final found = <String, int>{};
    for (final f in _sources(root)) {
      final rel = f.path.substring(root.length + 1).replaceAll(r'\', '/');
      if (rel == 'packages/noted_core/lib/src/storage/stored_read.dart') continue;
      keysOf(rel, f.readAsStringSync()).forEach((k, v) => found[k] = (found[k] ?? 0) + v);
    }
    final problems = <String>[
      for (final e in found.entries)
        if (!_allowed.containsKey(e.key))
          'not allowed: ${e.key} x${e.value}'
        else if (_allowed[e.key]!.count != e.value)
          'count differs: ${e.key} is ${e.value}, listed ${_allowed[e.key]!.count}',
      for (final k in _allowed.keys)
        if (!found.containsKey(k)) 'stale entry: $k',
    ]..sort();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('every reader in stored_read.dart asks notDownloaded( before it reads', () {
    final root = _repoRoot();
    final src = File('$root/packages/noted_core/lib/src/storage/stored_read.dart').readAsStringSync();
    final code = stripSource(src);
    final decls = declarationsOf(code);
    final reads = _calls.allMatches(code).toList();
    expect(reads, isNotEmpty);
    for (final m in reads) {
      final d = decls.lastWhere((d) => d.pos <= m.start);
      final from = code.lastIndexOf(RegExp(r'\n\S'), d.pos);
      final before = code.substring(from < 0 ? 0 : from, m.start);
      expect(before, contains('notDownloaded('), reason: '${d.name} reads without the gate');
    }
  });

  test('the allow-list reasons are one of the classes', () {
    const classes = {
      _appState,
      _ownTemp,
      _picked,
      _cache,
      _hydrate,
      _pullPrivate,
      _mcp,
      _writeOnly,
      _notFile,
    };
    for (final e in _allowed.entries) {
      expect(classes, contains(e.value.reason), reason: e.key);
    }
  });
}

// -- Finding the sources -----------------------------------------------------------

String _repoRoot() {
  var d = Directory.current.absolute;
  while (!File('${d.path}/app/pubspec.yaml').existsSync()) {
    final up = d.parent;
    if (up.path == d.path) fail('the repository root was not found');
    d = up;
  }
  return d.path;
}

Iterable<File> _sources(String root) sync* {
  final libs = <Directory>[Directory('$root/app/lib')];
  for (final group in [Directory('$root/packages')]) {
    for (final p in group.listSync().whereType<Directory>()) {
      libs.add(Directory('${p.path}/lib'));
      if (p.path.endsWith('boxes')) {
        for (final b in p.listSync().whereType<Directory>()) {
          libs.add(Directory('${b.path}/lib'));
        }
      }
    }
  }
  for (final d in libs) {
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.dart')) yield f;
    }
  }
}

// -- The tokenizer -----------------------------------------------------------------

class _Ctx {
  _Ctx.string(this.quote, this.triple, this.raw) : interp = false;
  _Ctx.interp() : quote = '', triple = false, raw = false, interp = true;

  final String quote;
  final bool triple;
  final bool raw;
  final bool interp;
  int braces = 0;
}

/// [src] with comments (`//` and nested `/* */`) and the text of string
/// literals blanked, and its length and line breaks kept. The code inside
/// `${...}` stays, nested strings in it included. The quotes stay; the `${`
/// and its closing `}` are blanked.
String stripSource(String src) {
  final n = src.length;
  final o = src.codeUnits.toList();
  void blank(int i) {
    if (i < n && o[i] != 0x0a && o[i] != 0x0d) o[i] = 0x20;
  }

  bool isIdent(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);
  final stack = <_Ctx>[];
  var i = 0;
  while (i < n) {
    final c = src[i];
    final next = i + 1 < n ? src[i + 1] : '';
    final top = stack.isEmpty ? null : stack.last;
    if (top == null || top.interp) {
      if (c == '/' && next == '/') {
        while (i < n && src[i] != '\n') {
          blank(i++);
        }
        continue;
      }
      if (c == '/' && next == '*') {
        var depth = 1;
        blank(i);
        blank(i + 1);
        i += 2;
        while (i < n && depth > 0) {
          if (src.startsWith('/*', i)) {
            depth++;
            blank(i);
            blank(i + 1);
            i += 2;
          } else if (src.startsWith('*/', i)) {
            depth--;
            blank(i);
            blank(i + 1);
            i += 2;
          } else {
            blank(i++);
          }
        }
        continue;
      }
      var raw = false;
      var j = i;
      if (c == 'r' && (next == "'" || next == '"') && (i == 0 || !isIdent(src[i - 1]))) {
        raw = true;
        j = i + 1;
      }
      if (src[j] == "'" || src[j] == '"') {
        final q = src[j];
        final triple = src.startsWith(q * 3, j);
        stack.add(_Ctx.string(q, triple, raw));
        i = j + (triple ? 3 : 1);
        continue;
      }
      if (top != null) {
        if (c == '{') {
          top.braces++;
        } else if (c == '}') {
          if (top.braces == 0) {
            blank(i);
            stack.removeLast();
            i++;
            continue;
          }
          top.braces--;
        }
      }
      i++;
      continue;
    }
    // Inside a string literal.
    final endLen = top.triple ? 3 : 1;
    if (top.raw) {
      if (src.startsWith(top.quote * endLen, i)) {
        stack.removeLast();
        i += endLen;
      } else {
        blank(i++);
      }
      continue;
    }
    if (c == r'\') {
      blank(i);
      blank(i + 1);
      i += 2;
      continue;
    }
    if (c == r'$' && next == '{') {
      blank(i);
      blank(i + 1);
      stack.add(_Ctx.interp());
      i += 2;
      continue;
    }
    if (src.startsWith(top.quote * endLen, i)) {
      stack.removeLast();
      i += endLen;
      continue;
    }
    blank(i++);
  }
  return String.fromCharCodes(o);
}

// -- Declarations ------------------------------------------------------------------

typedef ScanDecl = ({int pos, String name});

final RegExp _container = RegExp(r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*(class|mixin|extension|enum)\b');

String? _nameOf(String header) {
  var h = header.replaceAll(RegExp(r'@[A-Za-z_$][\w$.]*(\([^)]*\))?'), ' ').trim();
  if (h.isEmpty) return null;
  final paren = h.indexOf('(');
  final eq = RegExp(r'(?<![=!<>])=(?![=>])').firstMatch(h)?.start ?? -1;
  var cut = h.length;
  if (paren >= 0) cut = paren;
  if (eq >= 0 && eq < cut) cut = eq;
  h = h.substring(0, cut).trim();
  // A generic method: `name<T>`.
  var prev = '';
  while (prev != h) {
    prev = h;
    h = h.replaceAll(RegExp(r'<[^<>]*>\s*$'), '').trim();
  }
  return RegExp(r'([A-Za-z_$][\w$.]*)$').firstMatch(h)?.group(1);
}

/// The declarations of stripped source [code]: where each one's body (or `=>`)
/// begins and its name, `Owner.member` inside a class, mixin, extension or enum.
List<ScanDecl> declarationsOf(String code) {
  final out = <ScanDecl>[];
  String? owner;
  var depth = 0;
  var headStart = 0;
  for (var i = 0; i < code.length; i++) {
    final c = code[i];
    final level = owner == null ? 0 : 1;
    if (c == '{' || c == '(' || c == '[') {
      if (c == '{' && depth == level) {
        final header = code.substring(headStart, i);
        final h = header.replaceAll(RegExp(r'@[A-Za-z_$][\w$.]*(\([^)]*\))?'), ' ').trim();
        final m = _container.firstMatch(h);
        if (m != null && owner == null) {
          final kind = m.group(1);
          final name = kind == 'extension'
              ? RegExp(r'^extension\s+(?:type\s+)?(?!on\b)([A-Za-z_$][\w$]*)').firstMatch(h)?.group(1) ?? 'extension'
              : RegExp('$kind\\s+([A-Za-z_\$][\\w\$]*)').firstMatch(h)?.group(1) ?? kind!;
          owner = name;
          headStart = i + 1;
        } else {
          final n = _nameOf(header);
          if (n != null) out.add((pos: i, name: owner == null ? n : '$owner.$n'));
        }
      }
      depth++;
      continue;
    }
    if (c == '}' || c == ')' || c == ']') {
      depth--;
      if (c == '}' && depth == level) {
        headStart = i + 1;
      } else if (c == '}' && depth == 0 && owner != null) {
        owner = null;
        headStart = i + 1;
      }
      continue;
    }
    if (depth == level && c == ';') {
      headStart = i + 1;
    } else if (depth == level && c == '=' && i + 1 < code.length && code[i + 1] == '>') {
      final n = _nameOf(code.substring(headStart, i));
      if (n != null) out.add((pos: i, name: owner == null ? n : '$owner.$n'));
    }
  }
  return out;
}

/// The keys (`file::declaration::call`) of the matching calls in [src], with
/// their counts.
Map<String, int> keysOf(String file, String src) {
  final code = stripSource(src);
  final decls = declarationsOf(code);
  final out = <String, int>{};
  for (final m in _calls.allMatches(code)) {
    final d = decls.where((d) => d.pos <= m.start).lastOrNull;
    final key = '$file::${d?.name ?? '(top)'}::${m.group(1)}${m.group(2) ?? ''}';
    out[key] = (out[key] ?? 0) + 1;
  }
  return out;
}
