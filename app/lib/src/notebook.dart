// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'ai/ai_access_service.dart';
import 'ai/ai_link_authority.dart';
import 'ai/ai_merge_service.dart';
import 'app_settings.dart';
import 'attachment_copy.dart';
import 'device_storage.dart';
import 'page_attachments.dart';
import 'recovery_lock.dart';
import 'recovery_store.dart';
import 'save_trouble.dart';
import 'search_scope.dart';
import 'storage_check.dart';

/// Where page files live in Prototype 1: one local folder (0007).
///
/// Override with `--dart-define=NOTED_PAGES_DIR=<path>`. The default avoids
/// Documents, which is often redirected into a cloud-synced folder.
Directory defaultPagesDirectory() {
  const override = String.fromEnvironment('NOTED_PAGES_DIR');
  if (override.isNotEmpty) return Directory(override);
  final device = devicePagesDirectory();
  if (device != null) return device;
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows && env['APPDATA'] != null) {
    return Directory('${env['APPDATA']}${sep}Noted${sep}pages');
  }
  return Directory('${env['HOME'] ?? '.'}$sep.noted${sep}pages');
}

/// The built-in default folder for new binders: `binders` next to the default
/// pages folder (`%APPDATA%\Noted\binders` on Windows, `~/.noted/binders`
/// elsewhere).
Directory defaultBindersDirectory() {
  final pages = defaultPagesDirectory().absolute;
  return Directory('${pages.parent.path}${Platform.pathSeparator}binders');
}

/// A folder name for a binder called [name]: characters that are invalid in
/// Windows file names become `_`, trailing dots and spaces go, and reserved
/// device names get a `_` appended. An empty result is "New binder".
String binderFolderName(String name) {
  var n = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  n = n.replaceAll(RegExp(r'[. ]+$'), '');
  if (n.isEmpty) return 'New binder';
  final stem = n.split('.').first.trim().toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) n = '${n}_';
  return n;
}

/// The file listing the binder folders the app knows (0026): `binders.json`
/// next to the default pages folder.
File defaultBindersFile() {
  final pages = defaultPagesDirectory().absolute;
  return File('${pages.parent.path}${Platform.pathSeparator}binders.json');
}

/// An operation on the notebook failed; [message] is fit to show the user.
class NotebookException implements Exception {
  const NotebookException(this.message, {this.needsAction = false});

  final String message;

  // Whether the user has something to do about it (it stays on screen until
  // closed, instead of fading).
  final bool needsAction;

  @override
  String toString() => message;
}

// A conflict copy or its original changed while it was being merged.
class _SourceChanged implements Exception {
  const _SourceChanged();
}

// How a compare-and-swap page write ended: whether it landed, the identity
// published (null when nobody asked and the feed wasn't live), and whether
// nothing was written because the page's file is at another path.
class _WriteOutcome {
  const _WriteOutcome({required this.landed, this.identity, this.pathMoved = false});
  final bool landed;
  final ContentIdentity? identity;
  final bool pathMoved;
}

// Why a recovery entry could not be applied; it is kept and listed.
class _ReplayFailure implements Exception {
  _ReplayFailure(this.why, {this.detail});

  // The plain reason shown to the user, and the technical detail for the log.
  final String why;
  final String? detail;

  @override
  String toString() => why;
}

// The kept files landed, but others stay in the kept folder.
/// An attachments folder could not be moved because the target holds
/// different files under some of its names; nothing was written over them.
class _IncompleteAttachments extends FileSystemException {
  _IncompleteAttachments(this.copy, this.leftover, String path, {this.cause})
    : super(
        cause != null
            ? 'moving the attachments stopped: ${cause.message}; the originals were kept'
            : '${copy.differing.length + copy.stillChanging.length + (leftover ? 1 : 0)} attachment '
                  'file(s) could not be moved completely (different or changing files at the destination, or files '
                  'left behind); the originals were kept',
        path,
      );

  /// An ordinary file error that stopped the move after it had begun (so what
  /// it had already done, e.g. a file kept aside, is still reported).
  final FileSystemException? cause;

  /// What the move did before it stopped, so its notices are still posted.
  final AttachmentCopy copy;

  /// The source still held files after the verified ones were removed.
  final bool leftover;

  /// Only different files at the destination stopped it.
  bool get onlyDiffering => cause == null && copy.stillChanging.isEmpty && !leftover;
}

class _KeptFolderNotEmpty implements Exception {
  _KeptFolderNotEmpty(this.left);

  final List<String> left;
}

// A kept file that is in place under [name] with verified content.
class _LandedFile {
  const _LandedFile(this.source, this.name, this.target);

  final File source;
  final String name;
  final File target;
}

// A save of a closed page was refused; [response] says why.
class _SaveRefused implements Exception {
  const _SaveRefused(this.response);

  final AiLinkResponse response;
}

// A kept entry written under a move's target folder, paired with the old one
// until the page has settled.
class _Rekey {
  _Rekey(this.id, this.old, this.freshGen, this.preexisting);

  final String id;
  final RecoveryEntry old;
  final String freshGen;

  // The target already held an entry for the page: the new key was merged
  // into it, so it is never deleted as the page's own copy.
  final bool preexisting;
}

/// A delete that failed part way could not put back some pages, and recovery
/// did not take them either. They are held in memory in [deleted], and
/// [Notebook.undoDelete] writes them back (never over a file that is there).
class PagesNotRestoredException extends NotebookException {
  const PagesNotRestoredException(super.message, this.deleted) : super(needsAction: true);

  final DeletedPages deleted;
}

/// Leaving a page was cancelled by the user: nothing was changed.
class LeaveCancelled extends NotebookException {
  const LeaveCancelled() : super('Nothing was changed.');
}

// The kept edits of a page shown read-only in its place.
class _Preview {
  _Preview(this.id, this.loc, this.entries, this.reason, {this.unlandable = false});

  final String id;
  final String loc;
  final List<RecoveryEntry> entries;
  String reason;
  bool unlandable;
}
/// A save failed because the page's folder isn't there.
class FolderUnavailableException extends NotebookException {
  const FolderUnavailableException() : super('That folder was not found.');
}

/// Pages removed by one delete, held in full so the delete can be undone.
class DeletedPages {
  DeletedPages._(this.pages, this.openId, this._location, this._assets, {this.keptNote, Set<String>? keepTrash})
    : _keepTrash = {...?keepTrash};

  /// What to tell the user when pages were not deleted because their files
  /// changed after they were read (they stay as they are), or null.
  final String? keptNote;

  /// The deleted page and its subpages, parents before children.
  final List<NotedPage> pages;

  /// The deleted page that was open, if any.
  final String? openId;

  final String _location;

  // Each deleted page's assets folder, set aside until the delete is undone
  // (moved back) or forgotten (removed).
  final Map<String, Directory> _assets;

  // Set-aside folders (their own paths) that could not be put back whole and
  // that the user was told about: a discard never removes them, nor the shared
  // trash folder that holds them; it removes the other folders in it one by one.
  final Set<String> _keepTrash;

  // Held pages already written beside their place at exit.
  final Set<String> _copied = {};

  // Pages an Undo already put back: a retried Undo and the exit copies leave
  // them alone, so the snapshot never overwrites what was edited since.
  final Set<String> _restored = {};

  // Exit copies being written, by page id: a second exit attempt waits for the
  // write instead of starting another.
  final Map<String, Future<String?>> _copying = {};
}

/// Whether a binder's folder could be used.
enum BinderStatus {
  available,

  /// The folder is gone or can't be read, e.g. it is on another device
  /// (0027). It stays in the list.
  unavailable,

  /// The folder's binder file is damaged or from a newer app. It is never
  /// overwritten.
  unreadable,
}

/// One binder the app knows: its folder, metadata and page tree.
class BinderSection {
  BinderSection._(
    this.path,
    this.status, {
    this.binder,
    this.store,
    this.reason,
    this.unreadable = const [],
    this.missing = false,
  }) : tree = PageTree.build(const []);

  /// The binder's folder.
  final String path;
  BinderStatus status;
  Binder? binder;
  PageStore? store;

  /// Why the binder is unavailable or unreadable.
  String? reason;

  /// The binder's folder isn't there (e.g. it is on another device). The app
  /// looks for it again. While it is away the pages stay listed, read-only,
  /// and nothing is written to the folder.
  bool missing;

  /// Page files in the folder that couldn't be read.
  List<UnreadablePage> unreadable;
  PageTree tree;

  /// The latest modification of the binder file or one of its page files.
  DateTime? lastEdited;

  bool get available => status == BinderStatus.available;

  /// The binder file can't be read: the pages are listed and can be viewed,
  /// but nothing in the binder can be changed.
  bool get readOnly => status == BinderStatus.unreadable;

  String get title {
    final t = binder?.title.trim() ?? '';
    return t.isNotEmpty ? t : _folderName(path);
  }

  /// `#AARRGGBB`.
  String get color => binder?.color ?? binderPalette.first;
}

/// An extra folder of standalone pages besides the default one (0027). Its
/// pages appear in the "Pages" section.
class StandaloneFolder {
  StandaloneFolder._(
    this.path, {
    required this.available,
    this.store,
    this.reason,
    this.unreadable = const [],
    this.missing = false,
  });

  /// The folder.
  final String path;

  /// False if the folder is gone or can't be used, e.g. on another device.
  bool available;

  /// The folder isn't there (as opposed to being unusable). The app looks
  /// for it again, and uses it when it comes back.
  bool missing;
  PageStore? store;

  /// Why the folder is unavailable.
  String? reason;

  /// Page files in the folder that couldn't be read.
  List<UnreadablePage> unreadable;

  String get name => _folderName(path);
}

/// A template found in a templates folder.
class TemplateItem {
  const TemplateItem(this.template, this.path, this.binderPath);

  final NotedTemplate template;

  /// The template file.
  final String path;

  /// The binder the template belongs to; null for an app-wide template.
  final String? binderPath;
}

/// A template file that can't be read. It is listed and never touched.
class UnreadableTemplateItem {
  const UnreadableTemplateItem(this.path, this.reason, this.binderPath);

  final String path;
  final String reason;
  final String? binderPath;
}

/// The templates available for one use.
class TemplateListing {
  const TemplateListing(this.items, this.unreadable);

  final List<TemplateItem> items;
  final List<UnreadableTemplateItem> unreadable;

  bool get isEmpty => items.isEmpty && unreadable.isEmpty;
}

String _folderName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _normalizePath(String path) {
  var p = Directory(path).absolute.path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\')) && !p.endsWith(':\\')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// The location of standalone pages; binder pages use the binder's path.
const String _standalone = '';

/// The open notebook: standalone pages and binders (0026), the page on
/// screen, and autosave.
class Notebook extends ChangeNotifier implements AiLinkHost, AiMergeHost {
  Notebook(
    this.store,
    this.modules, {
    this.saveDelay = const Duration(milliseconds: 500),
    this.bindersFile,
    this.pickFolder,
    this.storeFactory = PageStore.new,
    this.watchFiles = false,
    this.watchDebounce = const Duration(milliseconds: 300),
    this.deviceName,
    this.templatesDirectory,
    this.folderCheckInterval = const Duration(seconds: 3),
    this.recoveryDirectory,
    this.settings,
    this.aiAccess,
    this.aiTimings = const AiLinkTimings(),
    this.cacheDirectory,
    this.attachmentPicker,
    this.attachmentOpener,
    this.recoveryLock,
    this.busyReadWindow = const Duration(seconds: 10),
    this.leaveSaveLimit = const Duration(seconds: 5),
    this.backoffFirst = const Duration(seconds: 2),
    this.backoffMax = const Duration(seconds: 30),
    this.discoveryDebounce = const Duration(seconds: 1),
    this.settingsRetryFirst = const Duration(seconds: 2),
    this.settingsAbsentConfirm = const Duration(seconds: 30),
    FolderLocks? folderLocks,
    this.folderWaitNote = const Duration(seconds: 3),
    List<String> readOnlyRoots = const [],
  }) : folderLocks = folderLocks ?? FolderLocks(),
       _readOnlyRoots = [for (final r in readOnlyRoots) _normalizePath(r)] {
    _chain.onDetachedJobEnded = _oldJobEnded;
  }

  // Folders whose working copy another program (the OneDrive pull) writes and
  // this notebook only reads. Empty on a device that never pulls.
  final List<String> _readOnlyRoots;

  /// Whether [loc] is at or under a read-only root: a pull-only location. It
  /// stays available, but nothing in it is written (G1 of the stage-3 design).
  bool _pullOnly(String loc) => _readOnlyRootOf(loc) != null;

  // The read-only root (as its key) that [loc] is at or under, or null.
  String? _readOnlyRootOf(String loc) {
    if (_readOnlyRoots.isEmpty || loc == _standalone) return null;
    final k = _key(loc);
    for (final r in _readOnlyRoots) {
      final rk = _key(r);
      if (k == rk || k.startsWith(rk.endsWith('/') ? rk : '$rk/')) return rk;
    }
    return null;
  }

  static const String _pullOnlyMessage = 'This OneDrive folder is read-only on this device for now.';

  /// What every place that refuses a change to a pull-only location says.
  static const String pullOnlyMessage = _pullOnlyMessage;

  /// The per-folder lock the notebook's page-file writes and scans run under.
  /// Share one with anything else that writes page files in the same folders.
  final FolderLocks folderLocks;

  /// How long a user action waits for a folder's lock before
  /// [waitingForFolder] turns on.
  final Duration folderWaitNote;

  static const Object _userActionKey = #notedUserAction;
  int _folderWaiters = 0; // user actions past [folderWaitNote], still queued
  final ValueNotifier<bool> _waitingForFolder = ValueNotifier<bool>(false);

  /// Whether a user action (New page, Undo, a move) has waited more than
  /// [folderWaitNote] for a folder's lock. Off again when the wait ends.
  ValueListenable<bool> get waitingForFolder => _waitingForFolder;

  // Runs [action] as a user action: its waits for a folder lock count toward
  // [waitingForFolder] (see _lockRun).
  Future<T> _asUser<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_userActionKey: true});

  // The one wait point: every folder job goes through here. A user action's
  // wait for its turn longer than [folderWaitNote] shows the note.
  Future<T> _lockRun<T>(Directory folder, Future<T> Function() job) {
    if (Zone.current[_userActionKey] != true) return folderLocks.run(folder, job);
    var counted = false;
    var started = false;
    final timer = Timer(folderWaitNote, () {
      if (started || _disposed) return;
      counted = true;
      if (++_folderWaiters == 1) _waitingForFolder.value = true;
    });
    return folderLocks.run(folder, () {
      started = true;
      timer.cancel();
      if (counted && --_folderWaiters == 0 && !_disposed) _waitingForFolder.value = false;
      return job();
    });
  }

  final StreamController<LocalChange> _changes = StreamController<LocalChange>.broadcast();

  /// The page and binder files this notebook wrote or deleted, in the folder
  /// lock's order for locked writes. Delivered asynchronously; nothing is
  /// emitted without a listener. Closed by [dispose]. Not reported: sweep
  /// restores, kept copies, attachments, templates, and the app's own
  /// settings, binders and recovery files.
  Stream<LocalChange> get localChanges => _changes.stream;

  bool get _feedLive => !_disposed && !_changes.isClosed && _changes.hasListener;

  /// Hashes the bytes of a written text; a seam so a test can count the calls.
  @visibleForTesting
  ContentIdentity Function(List<int> bytes) identityOfForTest = ContentIdentity.ofBytes;

  // The identity of [text] when the feed is live or the caller [want]s it,
  // else null (no hashing for nobody).
  ContentIdentity? _identityOf(String Function() text, {bool want = false}) =>
      want || _feedLive ? identityOfForTest(utf8.encode(text())) : null;

  // Reports a landed write. Never throws: the write has landed.
  // [identity] null means it wasn't computed (no listener then): [text] is
  // hashed only if a listener has appeared since.
  void _emitPublished(String path, ContentIdentity? identity, [String Function()? text]) {
    if (!_feedLive) return;
    try {
      final id = identity ?? (text == null ? null : identityOfForTest(utf8.encode(text())));
      if (id != null) _changes.add(LocalChange(LocalChangeKind.published, path, id));
    } on Object {
      // The feed is advisory.
    }
  }

  void _emitDeleted(String path) {
    if (!_feedLive) return;
    try {
      _changes.add(LocalChange(LocalChangeKind.deleted, path));
    } on Object {
      // The feed is advisory.
    }
  }

  /// The AI codes and activity log (`ai-access.json`, `ai-activity.json` in
  /// the data folder). Null: no AI code is accepted.
  final AiAccessService? aiAccess;

  /// Asks the user to allow a new AI session or a write (the app shows a
  /// dialog). Null: nobody can be asked, so those requests are refused.
  AiApprover? aiApprover;

  /// The time limits of AI requests (questions, the whole request, the pause
  /// after a Deny).
  final AiLinkTimings aiTimings;

  /// Where derived files (image display copies) are cached; never in a page
  /// folder, so never synced. Null: `cache` next to [bindersFile], or a
  /// temporary folder.
  final Directory? cacheDirectory;

  /// Asks the user for files to attach (Insert → Image, Insert → File).
  final FilePicker? attachmentPicker;

  /// Opens an attachment with the system's default app.
  final FileOpener? attachmentOpener;

  // This app's own folder (beside binders.json), or a temporary one.
  Directory get _appDir =>
      bindersFile?.parent ?? Directory('${Directory.systemTemp.path}${Platform.pathSeparator}noted-app');

  Directory get _cacheDir => cacheDirectory ?? Directory('${_appDir.path}${Platform.pathSeparator}cache');

  // Assets folders of deleted pages, kept until the delete can't be undone.
  Directory get _deletedAssetsDir => Directory('${_appDir.path}${Platform.pathSeparator}deleted-attachments');

  final StreamController<String> _notices = StreamController<String>.broadcast();

  /// One-line notices about attachments (a file too large to embed).
  Stream<String> get attachmentNotices => _notices.stream;

  PageAttachments? _attachments;

  /// The open page's images and files, or null with no page open.
  PageAttachments? get attachments => _attachments;

  /// This device's settings; they hold the default page and binder folders.
  /// Null: the built-in defaults.
  final AppSettings? settings;

  // Which title field should take the caret next: a page id, or
  // `cover:<binder path>`. Set after creating a page or binder.
  String? _titleFocus;

  /// Asks the title field of [target] (a page id, or `cover:<binder path>`)
  /// to take focus when it is shown.
  void requestTitleFocus(String target) => _titleFocus = target;

  /// True once if the title field of [target] was asked to take focus.
  bool takeTitleFocus(String target) {
    if (_titleFocus != target) return false;
    _titleFocus = null;
    return true;
  }

  /// Where edits that can't be saved are kept (see [RecoveryStore]). Null:
  /// `recovery` next to [bindersFile]; with neither, nothing is kept.
  final Directory? recoveryDirectory;

  RecoveryStore? get _recovery => _recoveryStore;

  late final RecoveryStore? _recoveryStore = () {
    final d = recoveryDirectory ?? (bindersFile == null ? null : defaultRecoveryDirectory(bindersFile!));
    return d == null ? null : RecoveryStore(d);
  }();

  List<String> _recoveryProblems = const [];

  // Entries that were read but couldn't be applied, by the entry's path
  // without extension and its time (a newer generation in the same file starts
  // clean): the path and why. Cleared once the entry is replayed (0077).
  final Map<String, ({String path, String why})> _replayProblems = {};

  // Pages whose recovered edits landed and were retired, but whose page was
  // changed right after (or couldn't be read back), by page id. One-off: the
  // entry is gone, so the next pass must not prune it; cleared when the user
  // opens the page.
  final Map<String, ({String path, String why})> _landedProblems = {};

  // Kept `<id>.assets` folders that couldn't be landed, or whose page isn't
  // there, by the folder's path: why (0098).
  final Map<String, String> _keptProblems = {};

  // Whether a kept folder with a page failed to land, so the periodic folder
  // check tries it again.
  bool _keptRetry = false;

  // Landing runs one after another.
  Future<void> _landChain = Future<void>.value();

  /// Recovery files that couldn't be read or applied. They are kept, never
  /// deleted.
  List<String> get recoveryProblems => [
    ..._recoveryProblems,
    for (final p in _replayProblems.values) '${p.path}: ${p.why}',
    for (final p in _landedProblems.values) '${p.path}: ${p.why}',
    for (final p in _keptProblems.entries) '${p.key}: ${p.value}',
  ];

  List<UnreadablePage> _recoveryDamaged = const [];

  /// [recoveryProblems] as sidebar entries (path and reason). They stay
  /// until fixed or removed outside the app.
  List<UnreadablePage> get recoveryDamaged => [..._recoveryDamaged, ...recoveryOwnDamaged];

  /// The part of [recoveryDamaged] that is not an unreadable recovery file:
  /// entries that couldn't be applied and kept files that couldn't be landed.
  List<UnreadablePage> get recoveryOwnDamaged => [
    for (final p in _replayProblems.values)
      UnreadablePage(p.path, "Recovery can't finish: ${p.why}${p.why.endsWith(')') ? '' : '.'}"),
    for (final p in _landedProblems.values) UnreadablePage(p.path, '${p.why}.'),
    for (final p in _keptProblems.entries) UnreadablePage(p.key, p.value),
  ];

  /// Whether the file at [path] has a notice of its own (a recovered page that
  /// landed and was then changed); the sidebar lists that notice, not also the
  /// file as unreadable.
  bool hasLandedNotice(String path) {
    final k = _key(path);
    return _landedProblems.values.any((p) => _key(p.path) == k);
  }

  /// Test seam: [_editsIn].
  @visibleForTesting
  static bool editsInForTest(NotedPage eb, NotedPage ep, NotedPage nb) => _editsIn(eb, ep, nb);

  /// Test seam: runs a replay pass over the pages that are not open, as the
  /// backoff and the folder checks do.
  @visibleForTesting
  Future<void> recoverNowForTest() => _recoverPending();

  /// Test seam: the recovery store this notebook writes through.
  @visibleForTesting
  RecoveryStore? get recoveryStoreForTest => _recovery;

  /// Test seam: writes [page] for recovery as a closed writer does (3.4.2),
  /// against [base], for the page folder [folder] (which may be gone).
  @visibleForTesting
  Future<KeepOutcome> keepClosedForTest(NotedPage page, NotedPage base, String folder) =>
      _keepForRecovery(_standalone, PageStore(Directory(folder)), page, base: base);

  /// Test seam: lists the recovery folder so the index holds what a test
  /// wrote to it from outside.
  @visibleForTesting
  Future<void> refreshRecoveryIndexForTest() async {
    await _recovery?.list();
  }

  /// The recovery entries and unreadable recovery files waiting now.
  ///
  /// Read from the index in memory, so quitting doesn't wait for the disk:
  /// entries that landed and wait to be deleted are not edits waiting.
  Future<RecoveryListing> pendingRecovery() async {
    final rec = _recovery;
    if (rec == null) return const RecoveryListing([], []);
    if (!rec.indexed) return rec.list();
    return RecoveryListing(
      [for (final e in rec.indexEntries) if (!rec.isLanded(e.gen)) e],
      _recoveryProblems,
      _recoveryDamaged,
    );
  }

  /// How often, with [watchFiles] on, the standalone folders are checked for
  /// having disappeared or come back (a watcher can't watch a folder that
  /// isn't there). [Duration.zero] turns the timer off; [checkFolders] still
  /// works.
  final Duration folderCheckInterval;

  /// The folder of app-wide templates. Null: `templates` next to
  /// [bindersFile]; with neither, templates can't be saved.
  final Directory? templatesDirectory;

  /// This computer's name, stamped on box content written here (0020).
  final String? deviceName;

  /// Watch the storage folders for page files changed by someone else, for
  /// example a sync client (0020). Off by default; the app turns it on.
  final bool watchFiles;

  /// How long a file must stay quiet before a change to it is looked at.
  final Duration watchDebounce;

  /// The store of standalone pages.
  final PageStore store;
  final ModuleRegistry modules;
  final Duration saveDelay;

  /// Where the list of binder folders is kept; null keeps it in memory only.
  final File? bindersFile;

  /// Asks the user for a folder (null if cancelled). Null: no folder picker,
  /// so binders can't be created from the sidebar.
  final Future<String?> Function()? pickFolder;

  /// Makes the store for a binder folder.
  final PageStore Function(Directory) storeFactory;

  /// The active canvas tool, kept when switching pages.
  final CanvasToolSelection tools = CanvasToolSelection();

  final Map<String, PageMeta> _metas = {};
  // Where each page's file lives: _standalone or a binder's path.
  final Map<String, String> _loc = {};
  final Map<String, BinderSection> _binders = {};
  // Extra standalone folders by path; their pages' location is that path.
  final Map<String, StandaloneFolder> _folders = {};
  List<UnreadablePage> _unreadable = const [];
  PageTree _tree = PageTree.build(const []);
  CanvasController? _current;
  // The open page as last read from or written to disk: the base of the
  // three-way merge when its file changes (0020).
  NotedPage? _base;
  // The exact text last written or read for each page file (by path key), so
  // the app's own writes aren't taken for outside changes.
  final Map<String, String> _known = {};
  // Page id of each page file (by path key).
  final Map<String, String> _pathId = {};
  // Pages with a conflicted box (0020).
  final Set<String> _conflicts = {};
  // The exact text last written or read for each binder file (by the key of
  // the binder's folder).
  final Map<String, String> _binderText = {};
  // Conflict copies found by a scan, to be merged once the folders are set up.
  final List<String> _pendingCopies = [];
  // Page files chosen by [adoptUnlistedPageFile], by page id, for this session.
  final Map<String, String> _adoptedFiles = {};
  // Chosen files seen missing once, by page id: forgotten (and a duplicate
  // promoted) only when a later check finds them still gone.
  final Map<String, String> _goneChosen = {};
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final Map<String, Timer> _debounce = {};
  Future<void> _checking = Future.value();

  // Binders found by id (0050) -------------------------------------------------

  // The binder id of each listed binder, by the key of its folder.
  final Map<String, String> _binderIds = {};
  // Ids of binders this device took out of its list (oldest first): discovery
  // never adds them again.
  final List<String> _removedBinders = [];
  // What the settings file looked like at load (see [_SettingsKind]).
  _SettingsKind _settingsKind = _SettingsKind.fresh;
  // Folders (by key) a binder is being made in: discovery leaves them alone.
  final Set<String> _claims = {};
  Future<void>? _discovering;
  bool _discoverAgain = false;
  final Set<Future<void>> _discoveryJobs = {};
  // Found adds in progress, by folder key, with the removed ids each took out.
  final Map<String, List<String>> _foundAdds = {};
  // Candidate reads reused while the binder file is unchanged, by file path.
  final Map<String, ({int size, int time, _Candidate read})> _candidateReads = {};
  // What the last pass saw of ids listed here: copies beside the listed folder
  // (by the key of the listed folder) and where an unavailable one went.
  Map<String, List<String>> _alsoIn = const {};
  Map<String, List<String>> _movedTo = const {};
  // Ids found in more than one folder in the last pass, with those folders.
  Map<String, ({String title, List<String> folders})> _duplicateIds = const {};
  // Binders recorded as removed by the first pass of an upgrade, shown this
  // session, by id.
  final Map<String, ({String title, String folder})> _upgradeNotes = {};
  // Subfolders of the roots seen without a binder file yet, by key, with the
  // time they were first seen.
  final Map<String, ({String path, DateTime since})> _freshFolders = {};
  final Map<String, StreamSubscription<FileSystemEvent>> _rootWatchers = {};
  final Set<String> _rootsRefused = {};
  final Set<String> _rootsCut = {};
  Timer? _rootDebounce;
  int _folderTicks = 0;
  // How many folder ticks until the next backstop pass: 10, longer after slow passes.
  int _backstopTicks = 10;
  int _rootCap = 20;
  int _folderCap = 1000;
  bool _rootsTruncated = false;
  // What the last pass cut short because of the caps, shown under "Can't open".
  List<UnreadablePage> _capNotes = const [];
  Duration _slowPass = const Duration(seconds: 5);
  // Folders that events reported in a root, looked at by the next pass.
  final Set<String> _eventFolders = {};

  /// Test seams: lower caps and the time after which a pass counts as slow.
  @visibleForTesting
  void setDiscoveryLimitsForTest({int? roots, int? folders, Duration? slowPass, int? removed}) {
    _removedCap = removed ?? _removedCap;
    _rootCap = roots ?? _rootCap;
    _folderCap = folders ?? _folderCap;
    _slowPass = slowPass ?? _slowPass;
  }

  @visibleForTesting
  int get backstopTicksForTest => _backstopTicks;
  // While above zero, rescans made by the checks of a found add never sweep.
  int _sweepOff = 0;

  /// Test seam for binder discovery and adding: called at named points
  /// (`candidate-read` just before a candidate's binder file is read: throw a
  /// [FileSystemException] to make the read fail; `job` as an add job starts,
  /// `recheck` after its rechecks and before the folder is read; `opened`
  /// after the folder was scanned and before the binder is listed; `adopted`
  /// after the binder file of a listed folder was taken over; `root-list` before
  /// a root is listed (throw to make that fail); `claimed`
  /// in a template's creation after its binder file was written; `settings-read`
  /// before every read of `binders.json`: throw a [FileSystemException] to make
  /// it fail as a lock; `load-open` before each listed binder is opened by load;
  /// `settings-loaded` just after load settled the hold, before the tree is built;
  /// `settings-adopt` before each open when a retry adopts the list;
  /// `settings-publish` before a new list is published after an absence).
  @visibleForTesting
  Future<void> Function(String point, String path)? binderHook;

  Future<void> _binderSeam(String point, String path) async {
    final h = binderHook;
    if (h != null) await h(point, path);
  }

  NotedPage? _pendingSave;
  int _pendingSeq = 0;
  Timer? _saveTimer;
  final List<String> _unfinished = []; // queued writes not yet done, for unsavedDescription
  DeletedPages? _lastDeleted;

  // Failed deletes that left pages only in memory (not in the folder, not in recovery): kept
  // until they are restored or the user lets them go.
  final List<DeletedPages> _held = [];

  // Undos that are running (exit waits for them).
  final Map<Future<void>, DeletedPages> _undoRuns = {};

  // The same Undos by entry: a second Undo of it waits, and no discard reaches
  // an entry whose Undo runs.
  final Map<DeletedPages, Future<void>> _undoing = {};
  String? _coverPath;
  RawObject _settings = RawObject.empty;
  // Why binder list changes are refused now (null: they are accepted). It starts
  // as pending and is settled by load once the listed binders and folders are
  // open.
  _SettingsHold? _settingsHeld = _SettingsHold.pending;
  // The open page is being left: it takes no edits until the leave is over, so
  // nothing typed meanwhile can fall between the save and recovery.
  int _leaving = 0;
  bool _disposed = false;
  Timer? _folderTimer;
  // The default folder disappeared while the app was running.
  bool _defaultGone = false;
  // The location of the open page when that folder went away: the page stays
  // open, read-only, although it is no longer in the tree. And why the open
  // page is read-only now.
  String? _orphanLoc;
  String? _readOnlyReason;
  // The open page whose file on disk was replaced by something this app can't
  // read (damaged, a newer format, or a read error): its saves are blocked
  // and it is read-only, until a readable version appears on disk.
  String? _diskBlockId;
  String? _diskBlockReason;
  // The short cause of the block (it isn't a valid page file, ...).
  String? _diskBlockWhy;

  // R-1 v5: failed saves never lose edits ------------------------------------

  /// The recovery lock this process holds (null: none is needed, as in tests).
  /// While it isn't held, every recovery write and replay is refused.
  final RecoveryLock? recoveryLock;

  /// How long a locked page file is reread quietly before the page is blocked.
  final Duration busyReadWindow;

  /// How long leaving a page waits for its last save.
  final Duration leaveSaveLimit;

  /// The first and the longest wait of the retry backoff.
  final Duration backoffFirst;
  final Duration backoffMax;

  /// The pause after a change in a folder that may hold binders before
  /// discovery looks again.
  final Duration discoveryDebounce;

  // L1, the save chain.
  final SaveChain _chain = SaveChain();

  // The open page's saves (null: no page, or a preview).
  SaveSession? _session;

  // The kept edits shown read-only in place of the page, if any.
  _Preview? _preview;

  // Pages that must not be replayed, opened for editing, deleted or moved now,
  // by id: why. A page leaves this when what held it ends.
  final Map<String, String> _busy = {};

  // Old-chain jobs still running, by page.
  final Map<String, int> _detached = {};

  TroubleState _trouble = TroubleState.saved;
  late final SaveBackoff _backoff = SaveBackoff(
    first: backoffFirst,
    max: backoffMax,
    onTick: () => unawaited(_backoffTick()),
  );

  // The recovery index must be rebuilt before the next transaction (the lock
  // was taken late or again).
  bool _relist = false;

  // What the last block (an unreadable page file) did with the edits.
  KeepOutcome? _blockKeep;

  // Pages the user was told about in this failure streak.
  final Set<String> _told = {};

  /// Asks the user a question (the window shows it). Null: nobody can be
  /// asked, so the answer is no.
  Future<bool> Function(UserQuestion question, String title)? questioner;

  final StreamController<KeptNotice> _keptNotices = StreamController<KeptNotice>.broadcast();

  /// Edits put in recovery on leaving a page: the window shows a notice.
  Stream<KeptNotice> get keptNotices => _keptNotices.stream;

  /// Whether page [id] is held by something (replaying, a save left behind, a
  /// delete, a move, a discard): it is not replayed, deleted or moved now, and
  /// opening it gives the preview.
  bool isBusy(String id) => _busy.containsKey(id);

  /// Test seam: called at named points of a conflict-copy merge (`copy-merged`
  /// just before the copy is revalidated for deletion, `original-read` just
  /// before the original is revalidated for replacing; `closed-reread` and
  /// `closed-before-write` around the rereads of a closed page that is being
  /// saved) so a test can make the sync writer change the file at that exact
  /// moment.
  @visibleForTesting
  Future<void> Function(String point, String path)? syncHook;

  /// Test seam: makes the notebook think page [id] is in [loc] (null: in none),
  /// as a move or a vanished folder would, without touching any file.
  @visibleForTesting
  void debugRelocate(String id, String? loc) {
    if (loc == null) {
      _loc.remove(id);
    } else {
      _loc[id] = loc;
    }
  }

  /// Called with a page and its location (the key search uses to group pages)
  /// whenever the page's content is written by the app or read after a change
  /// on disk, so the in-memory search index stays current. Null: nobody
  /// listens.
  void Function(String location, NotedPage page)? onPageContent;

  /// Everything search can read now, and what it has to skip and why:
  /// unavailable folders, binders that are away or damaged, and page files
  /// that can't be read. Pages are loaded through their stores.
  SearchScope searchScope() {
    final pages = <SearchablePage>[];
    final skipped = <NotSearched>[];
    for (final e in _loc.entries) {
      // A pull-only page is locked for writing only: it is still searched.
      if (_isLocked(e.value) && !_pullOnly(e.value)) continue;
      final PageStore st;
      try {
        st = _storeOf(e.value);
      } on NotebookException {
        continue;
      }
      pages.add(SearchablePage(e.key, e.value, () => _loadPage(st, e.key)));
    }
    if (_defaultGone) {
      skipped.add(const NotSearched('Pages', 'Folder not found. It may be on another device.'));
    }
    for (final f in _folders.values) {
      if (!f.available) {
        skipped.add(NotSearched(f.name, f.reason ?? 'Folder not available.'));
      }
    }
    for (final b in _binders.values) {
      if (!b.available) {
        skipped.add(
          NotSearched(
            b.title,
            b.reason ??
                (b.readOnly ? "The binder's file can't be read." : 'The binder is not available.'),
          ),
        );
      }
    }
    for (final u in [...unreadable, for (final b in _binders.values) ...b.unreadable]) {
      skipped.add(NotSearched(_folderName(u.path), u.reason));
    }
    return SearchScope(pages, skipped);
  }

  /// Where page [id] sits, for showing a search result: the binder's title
  /// (`Pages` for a standalone page), then its parents, then its own title.
  List<String> pagePath(String id) {
    final loc = _loc[id];
    final tree = _treeOf(loc ?? _standalone);
    final titles = <String>[];
    String? cur = id;
    while (cur != null) {
      final t = _metas[cur]?.title ?? '';
      titles.add(t.isEmpty ? 'Untitled page' : t);
      cur = tree.parentIdOf(cur);
    }
    return [_binders[loc]?.title ?? 'Pages', ...titles.reversed];
  }

  /// The standalone pages' tree.
  PageTree get tree => _tree;

  /// False if the default folder of standalone pages disappeared while the app
  /// was running. Its pages are gone from the tree until it comes back.
  bool get defaultFolderAvailable => !_defaultGone;

  /// Why the open page can't be edited, or null if it can. The page is shown
  /// read-only when its binder's file can't be read or its folder isn't
  /// available.
  String? get readOnlyReason => _readOnlyReason;

  /// Whether the page [id] can't be changed, moved, renamed or deleted: it is
  /// in a binder whose file can't be read, or in a folder that isn't there.
  bool isReadOnlyPage(String id) {
    final loc = _loc[id];
    return loc != null && _isLocked(loc);
  }

  /// Whether the location [loc] (a binder's folder or a standalone folder) is
  /// pull-only: at or under a read-only root. It is available and readable,
  /// but nothing in it is written, moved, renamed or deleted here.
  bool isPullOnlyLocation(String loc) => _pullOnly(loc);

  /// Whether page [id] is in a pull-only location.
  bool isPullOnlyPage(String id) {
    final loc = _loc[id];
    return loc != null && _pullOnly(loc);
  }

  // A location whose files must not be written.
  bool _isLocked(String loc) {
    if (_pullOnly(loc)) return true;
    if (loc == _standalone) return _defaultGone;
    final f = _folders[loc];
    if (f != null) return !f.available;
    final s = _binders[loc];
    return s == null || !s.available;
  }

  String _lockedMessage(String loc) {
    if (_pullOnly(loc)) return _pullOnlyMessage;
    final s = _binders[loc];
    if (s != null && s.readOnly) {
      return "This binder's file can't be read, so its pages are read-only.";
    }
    if (s != null) return 'That binder is not available.';
    return 'That folder is not available.';
  }

  void _assertWritable(String loc) {
    if (_isLocked(loc)) throw NotebookException(_lockedMessage(loc));
  }

  /// Standalone page files that couldn't be read. They are listed, never
  /// overwritten.
  List<UnreadablePage> get unreadable => [
    ..._unreadable,
    for (final f in _folders.values) ...f.unreadable,
  ];

  /// The binders, in the order of the list.
  List<BinderSection> get binders => List.unmodifiable(_binders.values);

  /// The extra standalone folders, in the order of the list.
  List<StandaloneFolder> get standaloneFolders => List.unmodifiable(_folders.values);

  /// The default folder of standalone pages.
  String get defaultFolderPath => _normalizePath(store.directory.path);

  /// The folder a new top-level standalone page goes to: the "Default page
  /// folder" setting, or the built-in default folder ([defaultFolderPath]).
  String get newPageFolderPath {
    final s = settings?.defaultPageFolder;
    return s == null ? defaultFolderPath : _normalizePath(s);
  }

  /// The built-in default folder for new binders: `binders` next to the
  /// settings file.
  String get builtinBinderFolderPath {
    final parent = bindersFile?.absolute.parent ?? store.directory.absolute.parent;
    return _normalizePath('${parent.path}${Platform.pathSeparator}binders');
  }

  /// The folder new binders are created in (one subfolder per binder): the
  /// "Default binder folder" setting, or [builtinBinderFolderPath].
  String get defaultBinderFolderPath {
    final s = settings?.defaultBinderFolder;
    return s == null ? builtinBinderFolderPath : _normalizePath(s);
  }

  CanvasController? get current => _current;
  String? get currentId => _current?.page.id;

  /// The binder whose cover is shown instead of a page, if any.
  String? get coverPath => _coverPath;
  BinderSection? get cover => _coverPath == null ? null : _binders[_coverPath];

  /// The tree [id] belongs to.
  PageTree treeOfPage(String id) => _treeOf(_loc[id] ?? _standalone);

  /// The folder of the binder holding [id]; null for a standalone page.
  String? binderOfPage(String id) {
    final l = _loc[id];
    return l == null || _isStandaloneLoc(l) ? null : l;
  }

  /// The folder holding page [id]'s file: its binder's folder, or the
  /// standalone folder it is in. Null if the page is unknown.
  String? folderOfPage(String id) {
    final l = _loc[id];
    if (l == null) return null;
    return l == _standalone ? defaultFolderPath : l;
  }

  /// Whether [deleted] is the delete that Undo can still bring back.
  bool isPendingDelete(DeletedPages deleted) => identical(_lastDeleted, deleted) || _held.contains(deleted);

  /// Whether [deleted] is held after a failed delete or Undo: its pages are in
  /// memory only, and only the user letting go (or Undo) ends that.
  bool isHeldDelete(DeletedPages deleted) => _held.contains(deleted);

  /// Drops the delete that Undo could still bring back and waits until its
  /// set-aside attachments are removed. For closing the app: a snack bar that
  /// is torn down with the window never reports that it closed.
  Future<void> discardPendingDelete() async {
    final last = _lastDeleted;
    if (last == null) return;
    _lastDeleted = null;
    if (_undoing.containsKey(last)) return; // its Undo is copying from the set-aside
    await _removeSetAside(last);
  }

  // Standalone pages from every standalone folder share one tree.
  bool _isStandaloneLoc(String loc) => loc == _standalone || _folders.containsKey(loc);

  PageTree _treeOf(String loc) =>
      _isStandaloneLoc(loc) ? _tree : (_binders[loc]?.tree ?? _tree);

  PageStore _storeOf(String loc) {
    if (loc == _standalone) return store;
    final f = _folders[loc];
    if (f != null) {
      final st = f.store;
      if (!f.available || st == null) {
        throw NotebookException(_pullOnly(loc) ? _pullOnlyMessage : 'That folder is not available.');
      }
      return st;
    }
    // A binder whose file can't be read keeps its store, for reading.
    final st = _binders[loc]?.store;
    if (st == null) {
      throw NotebookException(_pullOnly(loc) ? _pullOnlyMessage : 'That binder is not available.');
    }
    return st;
  }

  /// Reads the folders and opens the first standalone page, creating one if
  /// there is none.
  Future<void> load() async {
    try {
      await _load();
    } finally {
      // A load that stopped before the list was settled leaves it held.
      if (_settingsHeld == _SettingsHold.pending) _settingsHeld = _SettingsHold.locked;
      if (!_loaded.isCompleted) _loaded.complete();
      _armSettingsTimer();
    }
  }

  // Completes when the first load is over; AI writes wait for it.
  final Completer<void> _loaded = Completer<void>();

  Future<void> _load() async {
    final entries = await _scan(store);
    _metas.clear();
    _loc.clear();
    _binders.clear();
    _folders.clear();
    _defaultGone = false;
    _adoptDefault(entries);
    _binderIds.clear();
    _removedBinders.clear();
    _settingsKind = _SettingsKind.fresh;
    _SettingsHold? launchHold;
    var adopted = (listed: const <String>[], recorded: const <String, String>{});
    final settingsFile = bindersFile;
    if (settingsFile != null) {
      final read = await _readSettingsBytes(settingsFile);
      if (read.file case final f?) {
        adopted = _adoptSettings(f);
      } else if (!read.notFound) {
        // No file at all is a new install; anything else is held.
        launchHold = read.hold;
        debugPrint('Reading ${settingsFile.path} failed: ${read.error}');
      }
    }
    await _openListed(adopted, 'load-open');
    // A default page folder chosen in the settings is a standalone folder in
    // use, so the pages already there are listed.
    await _openListedFolders();
    // The list is trusted (or refused) only now: until every listed binder
    // and folder is open, a hand change would be saved over what isn't there
    // yet.
    _settingsHeld = launchHold;
    await _binderSeam('settings-loaded', settingsFile?.path ?? '');
    _rebuildTree();
    _syncWatchers();
    _startFolderTimer();
    await _mergePendingCopies();
    await _recoverPending();
    if (_tree.roots.isEmpty) {
      await _createFallbackPage();
    } else {
      // The first page shown at start is not the user looking at a notice.
      final notices = {..._landedProblems};
      await open(_tree.roots.first.id);
      _landedProblems.addAll(notices);
    }
    // Binders other devices made are looked for once the notebook is shown;
    // found binders are added in their own jobs, never inside startup.
    unawaited(discoverBinders());
  }

  // The binder list on hold (the launch read, and retries) -----------------------

  /// How long after a load that left the list held its first retry waits. Each
  /// failed retry doubles the wait, up to a minute.
  final Duration settingsRetryFirst;

  /// How long after a first "no such file" a later one confirms that the list
  /// was deleted.
  final Duration settingsAbsentConfirm;

  /// Test seam: the clock that times the confirmation of a missing list.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// The wait after [d] when a retry fails: doubled, up to a minute.
  @visibleForTesting
  static Duration nextSettingsDelay(Duration d) {
    final doubled = d * 2;
    return doubled > const Duration(seconds: 60) ? const Duration(seconds: 60) : doubled;
  }

  /// Why binder and folder changes are refused now: `pending` (the launch read
  /// is not settled), `locked`, `damaged`, or null.
  @visibleForTesting
  String? get settingsHoldForTest => _settingsHeld?.name;

  /// The wait before the next timed retry, if one is armed.
  @visibleForTesting
  Duration? get settingsDelayForTest => _settingsDelay;

  /// Calls [_saveSettings], to show that a held list is never written.
  @visibleForTesting
  Future<void> saveSettingsForTest() => _saveSettings();

  /// Whether the retry timer is armed.
  @visibleForTesting
  bool get settingsTimerActiveForTest => _settingsTimer?.isActive ?? false;

  /// How many times a retry has asked the open page to leave.
  @visibleForTesting
  int leaveAttemptsForTest = 0;

  Future<bool>? _retrying;
  Timer? _settingsTimer;
  Duration? _settingsDelay;
  // Set when a retry has chosen the next wait itself, so the timer keeps it.
  bool _settingsDelaySet = false;
  // When the file was first not found, while that is unconfirmed.
  DateTime? _absentSince;
  // The page that couldn't be left when a retry adopted the list, while it
  // stays open with its save failing: no retry runs meanwhile.
  String? _blockedPageId;
  bool _adoptBlocked = false;
  // What the last attempt to start a new list said, for the notice.
  String? _heldDetail;

  // One read of `binders.json`: the parsed file, "not found", or why it can't
  // be read (locked, or damaged: not valid text or JSON).
  Future<_SettingsRead> _readSettingsBytes(File f) async {
    try {
      await _binderSeam('settings-read', f.path);
      final bytes = await f.readAsBytes();
      return _SettingsRead.read(RawObject.parse(utf8.decode(bytes)));
    } on PathNotFoundException catch (e) {
      return _SettingsRead.notFound(e);
    } on FileSystemException catch (e) {
      return _SettingsRead.failed(_SettingsHold.locked, e);
    } on FormatException catch (e) {
      return _SettingsRead.failed(_SettingsHold.damaged, e);
    }
  }

  // Takes the lists, ids and removed ids out of the settings file [f] into
  // memory, replacing anything an earlier, interrupted adoption left. Returns
  // the listed binder folders and the ids the file records for them.
  _Adopted _adoptSettings(RawObject f) {
    for (final path in _binders.keys.toList()) {
      _undoOpen(path);
      if (_coverPath == path) _coverPath = null;
    }
    _binders.clear();
    _binderIds.clear();
    _removedBinders.clear();
    _settings = f;
    _settingsKind = f.containsKey('binderIds') ? _SettingsKind.current : _SettingsKind.upgrade;
    final removed = f['removedBinders']?.decode();
    for (final id in removed is List ? removed : const []) {
      if (id is String && id.isNotEmpty && !_removedBinders.contains(id)) _removedBinders.add(id);
    }
    final list = f['binders']?.decode();
    final listed = [
      for (final p in list is List ? list : const [])
        if (p is String && p.isNotEmpty) resolveStoredPath(p),
    ];
    // An older build removed a binder after the ids were recorded: its path
    // left `binders` but its id is still a key of `binderIds`. That is a removal
    // (before the key is pruned by the next write).
    final listedKeys = {for (final p in listed) _key(p)};
    final recorded = _readRecordedIds();
    for (final e in recorded.entries) {
      if (!listedKeys.contains(_key(e.key))) _markRemoved(e.value);
    }
    return (listed: listed, recorded: recorded);
  }

  // Opens each listed binder. [point] is the test seam called before each.
  Future<void> _openListed(_Adopted a, String point) async {
    for (final path in a.listed) {
      await _binderSeam(point, path);
      if (_disposed) return;
      final section = await _openBinder(path);
      if (_disposed) return;
      _binders[path] = section;
      final id = a.recorded.entries.where((e) => _key(e.key) == _key(path)).firstOrNull?.value;
      if (id != null) _binderIds[_key(path)] = id;
      _recordBinderId(path, section.binder);
    }
  }

  // Opens the standalone folders the settings list and the default page folder
  // chosen there; one that is a binder, or open already, is skipped.
  Future<void> _openListedFolders([String? point]) async {
    final chosen = settings?.defaultPageFolder;
    for (final raw in [..._readFolderPaths(), ?chosen]) {
      final path = _normalizePath(raw);
      if (path == defaultFolderPath || _folders.containsKey(path)) continue;
      if (_binders.keys.any((b) => _key(b) == _key(path))) continue;
      if (point != null) await _binderSeam(point, path);
      if (_disposed) return;
      final folder = await _openFolder(path);
      if (_disposed) return;
      _folders[path] = folder;
    }
  }

  /// Reads `binders.json` again while binder and folder changes are refused,
  /// and when it can be read, adopts it and lifts the refusal. Only one runs at
  /// a time: a call while one runs returns that call's result. True once the
  /// list is adopted. Never throws.
  Future<bool> retrySettings() {
    final running = _retrying;
    if (running != null) return running;
    final held = _settingsHeld;
    if (_disposed || held == null || held == _SettingsHold.pending) return Future.value(false);
    final run = _retryOnce();
    _retrying = run;
    unawaited(run.whenComplete(() {
      if (identical(_retrying, run)) _retrying = null;
    }));
    return run;
  }

  Future<bool> _retryOnce() async {
    try {
      // Outside the queue: during load the queue is busy with the merges of
      // conflict copies, which a job waiting for load would deadlock.
      await loaded;
      if (_disposed || _settingsHeld == null) return false;
      return await _queued<bool>(_retryJob) ?? false;
    } on Object catch (e, s) {
      debugPrint('Reading the binder list again failed: $e\n$s');
      return false;
    }
  }

  void _armSettingsTimer() {
    _settingsTimer?.cancel();
    _settingsTimer = null;
    final held = _settingsHeld;
    if (_disposed || held == null || held == _SettingsHold.pending) return;
    final delay = _settingsDelay ??= settingsRetryFirst;
    _settingsTimer = Timer(delay, () async {
      _settingsTimer = null;
      _settingsDelaySet = false;
      final ok = await retrySettings();
      if (ok || _disposed || _settingsHeld == null) return;
      // A retry that chose the wait itself (a first "not found") keeps it.
      if (!_settingsDelaySet) _settingsDelay = nextSettingsDelay(delay);
      _settingsDelaySet = false;
      _armSettingsTimer();
    });
  }

  // One retry, inside the queue.
  Future<bool> _retryJob() async {
    final f = bindersFile;
    final held = _settingsHeld;
    if (_disposed || f == null || held == null || held == _SettingsHold.pending) return false;
    // The page that couldn't be left stays; nothing changes until it saves or
    // another page is opened.
    final blocked = _blockedPageId;
    if (blocked != null) {
      if (currentId == blocked && _trouble.isTrouble && _trouble.pageId == blocked) return false;
      _blockedPageId = null;
      _adoptBlocked = false;
    }
    final read = await _readSettingsBytes(f);
    if (_disposed) return false;
    var file = read.file;
    if (file == null) {
      if (!read.notFound) {
        _absentSince = null;
        _heldDetail = null;
        _settingsHeld = read.hold;
        debugPrint('Reading ${f.path} failed: ${read.error}');
        notifyListeners();
        return false;
      }
      file = await _settleAbsence(f);
      if (file == null) return false;
    } else {
      _absentSince = null;
    }
    return _adoptRead(file);
  }

  // The file was not found. Returns the bytes of a new empty list if its
  // absence is confirmed and it was created, else null with the hold kept.
  Future<RawObject?> _settleAbsence(File f) async {
    // A folder that is gone or can't be listed says nothing about the file.
    try {
      if (!await f.parent.exists()) throw FileSystemException('The folder was not found', f.parent.path);
      await f.parent.list().isEmpty;
    } on FileSystemException {
      _absentSince = null;
      notifyListeners();
      return null;
    }
    final t = now();
    final since = _absentSince;
    if (since == null) {
      // A sync client may be replacing the file: look again soon.
      _absentSince = t;
      _settingsDelay = settingsRetryFirst;
      _settingsDelaySet = true;
      _armSettingsTimer();
      notifyListeners();
      return null;
    }
    if (t.difference(since) < settingsAbsentConfirm) return null;
    const text = '{"format":1,"binders":[],"binderIds":{}}';
    final tmp = File('${f.path}.$pid-${_randomHex()}.tmp');
    Future<void> dropTemp() async {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException catch (e) {
        debugPrint('Removing ${tmp.path} failed: $e');
      }
    }

    try {
      await tmp.writeAsString(text, flush: true);
      await _binderSeam('settings-publish', f.path);
      if (!await publishExclusive(tmp, f.path)) {
        // Something arrived: the next retry reads it.
        await dropTemp();
        _absentSince = null;
        notifyListeners();
        return null;
      }
    } on FileSystemException catch (e) {
      await dropTemp();
      _absentSince = null;
      _settingsHeld = _SettingsHold.locked;
      _heldDetail = 'Starting a new list failed: ${e.osError?.message ?? e.message}.';
      notifyListeners();
      return null;
    } on Object {
      await dropTemp();
      rethrow;
    }
    _absentSince = null;
    return RawObject.parse(text);
  }

  static String _randomHex() {
    final r = Random.secure();
    return [for (var i = 0; i < 4; i++) r.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')].join();
  }

  // Takes the readable list [f] over, in load's order, while the hold keeps
  // hand changes out, then lifts the hold. False if it stopped (the hold stays).
  Future<bool> _adoptRead(RawObject f) async {
    // 1. Folders and binders already open come out first, as load has them
    // not yet open: a page in both a binder and the chosen folder is then
    // chosen as load chooses it, and the page on screen is saved first.
    final here = {..._folders.keys, ..._binders.keys};
    bool openHere() {
      final id = currentId;
      return (id != null && here.contains(_loc[id])) || (_orphanLoc != null && here.contains(_orphanLoc));
    }

    String? wasOpen;
    var left = false;
    if (openHere()) {
      wasOpen = currentId;
      leaveAttemptsForTest++;
      if (!await _leaveOpenPage(stayIfUnsafe: true)) {
        // Its edits are safe nowhere: nothing is asked and nothing changed.
        if (_disposed) return false;
        _blockedPageId = wasOpen;
        _adoptBlocked = true;
        notifyListeners();
        return false;
      }
      if (_disposed) return false;
      if (currentId == wasOpen) {
        _disposeCurrent();
      } else if (openHere()) {
        _blockedPageId = currentId;
        _adoptBlocked = true;
        notifyListeners();
        return false;
      }
      left = true;
    }
    _blockedPageId = null;
    _adoptBlocked = false;
    for (final path in _folders.keys.toList()) {
      final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
      for (final id in ids) {
        _forgetPage(id);
      }
      _folders.remove(path);
      final key = _key(path);
      _pendingCopies.removeWhere((p) => _key(File(p).parent.path) == key);
    }
    _rebuildTree();
    _syncWatchers();
    notifyListeners();
    // 2. and 3. The lists, ids and removed ids.
    final adopted = _adoptSettings(f);
    // 4. Open, in load's order.
    await _openListed(adopted, 'settings-adopt');
    if (_disposed) return false;
    await _openListedFolders('settings-adopt');
    if (_disposed) return false;
    // 5. Every restored location, binders and folders alike.
    _rebuildTree();
    _syncWatchers();
    await _mergePendingCopies(inQueue: true);
    for (final loc in [..._binders.keys, ..._folders.keys]) {
      if (_disposed) return false;
      await _recoverPending(onlyLoc: loc);
    }
    if (_disposed) return false;
    // Release.
    _settingsHeld = null;
    _heldDetail = null;
    _absentSince = null;
    _settingsTimer?.cancel();
    _settingsTimer = null;
    _settingsDelay = null;
    notifyListeners();
    unawaited(discoverBinders());
    // 6. The page the user was on, or a fallback if it is gone. The hold is
    // lifted, so a page made in the chosen folder is not refused.
    if (left && _current == null && _orphanLoc == null) {
      try {
        if (wasOpen != null && _metas.containsKey(wasOpen)) {
          await open(wasOpen);
        } else {
          await _openFallback(_standalone);
        }
      } on Object catch (e) {
        debugPrint('Reopening a page after the binder list was read failed: $e');
      }
    }
    return true;
  }

  // The notice for the "Can't open" list while the list is held.
  List<UnreadablePage> get _heldNotes {
    final held = _settingsHeld;
    final f = bindersFile;
    if (held == null || held == _SettingsHold.pending || f == null) return const [];
    const locked =
        "Noted can't read its binder list (binders.json) right now, so binders and extra page folders are "
        'hidden. They will appear when it can be read.';
    final String text;
    if (_adoptBlocked) {
      text =
          'Noted can read its binder list, but the open page cannot be saved yet, so binders and extra page '
          'folders stay hidden. They will appear once the open page saves or another page is opened.';
    } else if (_absentSince != null) {
      text = 'Noted is checking whether its binder list was deleted.';
    } else if (held == _SettingsHold.locked) {
      text = _heldDetail == null ? locked : '$locked $_heldDetail';
    } else if (isMobilePlatform) {
      text = "Noted can't read its binder list. Binders and extra page folders stay hidden until it can be read.";
    } else {
      text =
          "Noted's binder list (binders.json in ${f.parent.path}) is damaged, so binders and extra page folders "
          "are hidden and can't be added or removed. Put back a readable copy, or delete the file to start a new "
          'list; your binder and page folders are not changed.';
    }
    return [UnreadablePage(f.path, text)];
  }

  // A page for an empty notebook: in the default page folder, or in the
  // built-in folder if the chosen one can't be used.
  Future<void> _createFallbackPage() async {
    try {
      await createPage();
    } on NotebookException {
      if (_key(newPageFolderPath) == _key(defaultFolderPath)) rethrow;
      await createPage(folderPath: defaultFolderPath);
    }
  }

  /// Whether the scan entry at [path] for page [id] is a file other than the
  /// one chosen for that id (see [adoptUnlistedPageFile]) while the chosen
  /// file still exists or its page is open: it is then a duplicate.
  bool _otherThanChosen(String id, String path) {
    final c = _adoptedFiles[id];
    if (c == null || _key(c) == _key(path)) return false;
    return _choiceHeld(id);
  }

  /// Whether the file chosen for page [id] still holds the choice: the page is
  /// open or busy, the file exists (locked and damaged files count), it was
  /// seen missing once, no check has seen it vanish yet, or its folder is away.
  /// A released choice has no entry, so nothing is held.
  bool _choiceHeld(String id) {
    final b = _adoptedFiles[id];
    if (b == null) return false;
    if (id == currentId || _busy.containsKey(id)) return true;
    if (FileSystemEntity.typeSync(b) != FileSystemEntityType.notFound) return true;
    if (_goneChosen.containsKey(id)) return true;
    if (_pathId[_key(b)] == id) return true;
    return !Directory(File(b).parent.path).existsSync();
  }

  // Ids whose choice was released by a scan or a check and whose page may now
  // fall to a duplicate; [_promoteReleased] settles them.
  final Set<String> _released = {};

  /// Lets go of the choice of page [id] (file [path]): the page is no longer
  /// held to that file. Never for the open or a busy page. A page still listed
  /// from that file is dropped, as when the file is gone.
  void _releaseChoice(String id, String path, {PageStore? store}) {
    final k = _key(path);
    if (_adoptedFiles[id] case final a? when _key(a) == k) _adoptedFiles.remove(id);
    if (_goneChosen[id] case final g? when _key(g) == k) _goneChosen.remove(id);
    final loc = _locationOf(path);
    if (store != null) {
      store.unadopt(id);
    } else if (loc != null) {
      try {
        _storeOf(loc).unadopt(id);
      } on NotebookException {
        // Nothing to tell.
      }
    }
    _released.add(id);
    if (_pathId[k] == id) {
      _pathId.remove(k);
      _known.remove(k);
      if (!_pathId.containsValue(id) && _loc.containsKey(id)) {
        final at = _loc[id]!;
        _metas.remove(id);
        _loc.remove(id);
        _conflicts.remove(id);
        _touch(at);
        _rebuildTree();
      }
    }
    // The file may hold another page now: a check lists it without waiting for
    // a watcher event.
    if (!_disposed) unawaited(checkFile(path));
  }

  /// Promotes a duplicate for every page whose choice was released, once the
  /// caller has applied its entries.
  Future<void> _promoteReleased() async {
    while (_released.isNotEmpty && !_disposed) {
      final id = _released.first;
      _released.remove(id);
      if (!_pathId.containsValue(id)) await _promoteDuplicate(id);
    }
  }

  // The pages found in the default folder.
  void _adoptDefault(List<PageEntry> entries) {
    final dupes = <UnreadablePage>[];
    for (final e in entries.whereType<ReadablePage>()) {
      if (_otherThanChosen(e.meta.id, e.path)) {
        dupes.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
        continue;
      }
      _metas[e.meta.id] = e.meta;
      _loc[e.meta.id] = _standalone;
      _pathId[_key(e.path)] = e.meta.id;
      if (e.conflicted) _conflicts.add(e.meta.id);
    }
    _unreadable = [...entries.whereType<UnreadablePage>(), ...dupes];
    _pendingCopies.addAll(entries.whereType<ConflictCopyPage>().map((c) => c.path));
  }

  /// Makes the page file at [path] (holding page [id]) the file listed for
  /// that id, when it sits in a folder or binder already joined but was never
  /// listed (it arrived after the folder was scanned, before any watcher event
  /// reached it). A different file listed for the id becomes a duplicate, as a
  /// scan would list it. Nothing is written, renamed or deleted. Does nothing
  /// for a file that is listed already (as a page or as unreadable), a sync
  /// client's conflict copy (merged the usual way) or a folder not joined.
  Future<void> adoptUnlistedPageFile(String path, String id) async {
    final k = _key(path);
    if (_pathId.containsKey(k)) return;
    final listed = [
      ..._unreadable,
      for (final f in _folders.values) ...f.unreadable,
      for (final b in _binders.values) ...b.unreadable,
    ];
    // A file listed only as a duplicate of the id is treated as unlisted;
    // any other reason (damaged, newer format) stays refused.
    if (listed.any((u) => _key(u.path) == k && !u.reason.startsWith('duplicate page id'))) return;
    final loc = _locationOf(path);
    if (loc == null) return;
    final NotedPage page;
    final String text;
    try {
      text = await File(path).readAsString();
      page = readPage(text);
    } on Object {
      return; // the usual checks report it
    }
    if (page.id != id) return;
    // A sync client's conflict copy of a listed page is merged the usual way.
    if (await PageStore.findConflictOriginal(path, page) != null) return;
    final st = _storeOf(loc);
    await flush();
    String? blockedWhy;
    final closedId = id == currentId ? id : null;
    if (id == currentId) {
      // The page on screen is closed first (its edits are flushed above), so a
      // later autosave can't write its old content over the file asked for.
      if (_diskBlockId == id) blockedWhy = _diskBlockWhy;
      await _closeCurrent();
      if (_diskBlockId == id) _clearDiskBlock();
    }
    await syncHook?.call('adopt-closed', path);
    // Everything above waited: the file and its folder must still be as read.
    var unchanged = false;
    try {
      unchanged = _locationOf(path) == loc &&
          identical(_storeOf(loc), st) &&
          File(path).readAsStringSync() == text;
    } on Object {
      unchanged = false;
    }
    if (!unchanged) {
      // The page that was closed for the swap is shown again.
      if (closedId != null && _current == null) {
        try {
          await open(closedId);
        } on Object {
          // The next open picks a page.
        }
      }
      throw const NotebookException('That file changed while it was being opened. Try again.');
    }
    final oldLoc = _loc[id];
    String? oldKey;
    for (final e in _pathId.entries) {
      if (e.value == id) oldKey = e.key;
    }
    if (oldLoc != null && oldKey != null) {
      final oldPath = _storeOf(oldLoc).pathFor(id);
      if (File(oldPath).existsSync()) {
        _known.remove(oldKey);
        _knownUnreadable(oldLoc, oldKey, oldPath, blockedWhy ?? 'duplicate page id $id');
      } else {
        _fileGone(oldLoc, oldKey, oldPath);
      }
    }
    _dropUnreadable(loc, path, rebuild: false);
    // The choice moves: the file chosen before is forgotten by its store too.
    if (_adoptedFiles[id] case final before? when _key(before) != k) {
      final beforeLoc = _locationOf(before);
      if (beforeLoc != null) {
        try {
          _storeOf(beforeLoc).unadopt(id);
        } on NotebookException {
          // Nothing to tell.
        }
      }
    }
    _adoptedFiles[id] = path;
    _goneChosen.remove(id);
    st.adopt(id, path);
    _pathId[k] = id;
    _known[k] = text;
    _metas[id] = page.meta;
    _loc[id] = loc;
    _setConflict(id, hasConflicts(page));
    _touch(loc);
    onPageContent?.call(loc, page);
    _rebuildTree();
  }

  Future<void> open(String id) async {
    try {
      await _open(id);
    } on LeaveCancelled {
      return; // the user chose to stay on this page
    }
    // Only once the page is open: a failed open leaves the notice for the next
    // look.
    if (_landedProblems.remove(id) != null) notifyListeners();
  }

  Future<void> _open(String id) async {
    if (_coverPath != null) {
      _coverPath = null;
      notifyListeners();
    }
    if (id == currentId) return;
    // A page of a binder whose folder is away can't be read.
    if (_binders[_loc[id]]?.missing ?? false) {
      throw NotebookException(isPullOnlyPage(id) ? _pullOnlyMessage : 'That binder is not available.');
    }
    await _closeCurrent();
    await _openFresh(id);
  }
  PageAttachments _makeAttachments(String id, String loc) => PageAttachments(
    pageFolder: _storeOf(loc).directory,
    pageId: id,
    storage: () => attachmentStorageFor(id),
    cacheDirectory: _cacheDir,
    recoveryDirectory: _recovery?.directory,
    onNotice: _notices.add,
    picker: attachmentPicker,
    opener: attachmentOpener,
    watch: watchFiles,
    readOnly: _pullOnly(loc),
  );

  // The page AI access (0100) -------------------------------------------------

  /// Page [id]'s header, then its parents' up to the top, nearest first. The
  /// open page's header comes from its controller.
  List<PageMeta> _metaChain(String id) {
    final tree = _treeOf(_loc[id] ?? _standalone);
    final chain = <PageMeta>[];
    final seen = <String>{};
    String? at = id;
    while (at != null && seen.add(at)) {
      final m = (at == currentId ? _current?.page.meta : null) ?? _metas[at];
      if (m == null) break;
      chain.add(m);
      at = tree.parentIdOf(at);
    }
    return chain;
  }

  Binder? _binderOf(String id) => _binders[_loc[id] ?? _standalone]?.binder;

  /// The AI access that applies to page [id], and where it comes from: the
  /// binder's (or, in no binder, the top page's) choice, tightened by each
  /// page down to this one, else the app default (Guarded).
  EffectiveAiAccess aiAccessFor(String id) => effectiveAiAccess(_metaChain(id), binder: _binderOf(id));

  /// The pages whose own stored AI value is the legacy `page` (as written)
  /// and that are no longer Open because of what they inherit: they lost
  /// access when it was replaced by Open, Privileged and Guarded.
  ///
  /// Pages in a location that is not readable and writable are left out.
  List<String> pagesThatLostAiAccess() => [
    for (final e in _metas.entries)
      if (e.value.rawAiAccess?.decode() == 'page' &&
          !isReadOnlyPage(e.key) &&
          aiAccessFor(e.key).value != AiAccess.open)
        e.key,
  ];

  /// Whether every binder and standalone folder was read in full: none is
  /// away or has a damaged binder file, and no page file is unreadable. What
  /// depends on the whole notebook (the access-loss note) waits for this.
  bool get everythingReadable =>
      _settingsHeld == null &&
      !_defaultGone &&
      _unreadable.isEmpty &&
      _folders.values.every((f) => f.available && f.unreadable.isEmpty) &&
      _binders.values.every((b) => b.available && b.unreadable.isEmpty);

  /// Completes when the first load is over.
  Future<void> get loaded => _loaded.future;

  /// What page [id] would have without its own choice: its parents', its
  /// binder's or the app default. A top-level page in no binder inherits
  /// nothing, so the app default is shown.
  EffectiveAiAccess inheritedAiAccessFor(String id) =>
      inheritedAiAccess(_metaChain(id), binder: _binderOf(id)) ??
      const EffectiveAiAccess(defaultAiAccess, ConfigSource.appDefault);

  /// The own values page [id] may choose (a looser one would be ignored).
  List<AiAccess> allowedOwnAiAccessFor(String id) =>
      allowedOwnAiAccess(inheritedAiAccess(_metaChain(id), binder: _binderOf(id))?.value);

  /// Page [id]'s own AI choice, or null if it follows its parent.
  AiAccess? ownAiAccess(String id) =>
      ((id == currentId ? _current?.page.meta : null) ?? _metas[id])?.aiAccess;

  /// Sets page [id]'s own AI choice (null: follow the parent). Only the
  /// header changes.
  Future<void> setAiAccess(String id, AiAccess? value) async {
    final loc = _loc[id] ?? _standalone;
    _assertWritable(loc);
    final c = _current;
    if (c != null && c.page.id == id) {
      final meta = c.page.meta.withAiAccess(value);
      if (identical(meta, c.page.meta)) return;
      c.updateMeta(meta);
      _metas[id] = meta;
      notifyListeners();
      return;
    }
    final next = await _updateClosedPage(loc, id, (page) {
      final meta = page.meta.withAiAccess(value);
      return identical(meta, page.meta) ? null : page.withMeta(meta);
    });
    if (next == null) return;
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  // Saves the binder file of folder [path] and reports it. `BinderStore.save`
  // is a blind write outside the folder lock (left for a later stage).
  Future<void> _saveBinderFile(String path, Binder binder) async {
    final store = BinderStore(Directory(path));
    final text = binder.write();
    final identity = _identityOf(() => text);
    await store.save(binder);
    _emitPublished(store.file.path, identity, () => text);
  }

  /// The AI access binder [path] has chosen, or null (the app default).
  AiAccess? binderAiAccess(String path) => _binders[path]?.binder?.aiAccess;

  /// Sets binder [path]'s AI choice (null: the app default, Guarded), which
  /// its pages follow and may only tighten.
  Future<void> setBinderAiAccess(String path, AiAccess? value) async {
    final s = _binders[path];
    final b = s?.binder;
    if (s == null || b == null || !s.available || _isLocked(path)) return;
    final next = b.withAiAccess(value);
    if (identical(next, b)) return;
    s.binder = next;
    notifyListeners();
    await _afterSaves(() async {
      final latest = s.binder;
      if (latest != null) {
        await _saveBinderFile(path, latest);
        _binderText[_key(path)] = latest.write();
      }
    }, what: 'binder AI access of $path').catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
  }

  /// The title of page [id] as the settings panel names it, or null if the
  /// page isn't known.
  String? pageTitleOf(String id) =>
      ((id == currentId ? _current?.page.meta : null) ?? _metas[id])?.title;

  // Box types allowed per page and binder (module availability) --------------

  /// The box types a page or binder can allow or disallow: the modules that
  /// are on and can be switched off (not the note box), in registration order.
  List<String> get switchableBoxTypes => [
    for (final m in modules.enabled)
      if (modules.isSwitchable(m.codec.typeId)) m.codec.typeId,
  ];

  /// Whether [typeId] is allowed on page [id], and which level disallows it
  /// otherwise.
  BoxTypeAvailability boxTypeAvailabilityFor(String id, String typeId) =>
      effectiveBoxTypeAllowed(typeId, _metaChain(id), binder: _binderOf(id));

  /// What page [id] would have for [typeId] without its own choice.
  BoxTypeAvailability inheritedBoxTypeFor(String id, String typeId) =>
      inheritedBoxTypeAllowed(typeId, _metaChain(id), binder: _binderOf(id));

  /// Page [id]'s own choice for [typeId], or null (inherit).
  bool? ownBoxType(String id, String typeId) =>
      ((id == currentId ? _current?.page.meta : null) ?? _metas[id])?.boxTypeChoice(typeId);

  /// The box types page [id] doesn't allow, which its canvas treats as
  /// switched-off modules.
  Set<String> disallowedBoxTypesFor(String id) => {
    for (final t in switchableBoxTypes)
      if (!boxTypeAvailabilityFor(id, t).allowed) t,
  };

  /// Sets page [id]'s own choice for [typeId] (null: inherit). Only the
  /// header changes; boxes of the type stay as they are.
  Future<void> setBoxType(String id, String typeId, bool? allowed) async {
    final loc = _loc[id] ?? _standalone;
    _assertWritable(loc);
    final c = _current;
    if (c != null && c.page.id == id) {
      final meta = c.page.meta.withBoxType(typeId, allowed);
      if (identical(meta, c.page.meta)) return;
      c.updateMeta(meta);
      _metas[id] = meta;
      notifyListeners();
      return;
    }
    final next = await _updateClosedPage(loc, id, (page) {
      final meta = page.meta.withBoxType(typeId, allowed);
      return identical(meta, page.meta) ? null : page.withMeta(meta);
    });
    if (next == null) return;
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  /// Binder [path]'s own choice for [typeId], or null (allowed).
  bool? binderBoxType(String path, String typeId) => _binders[path]?.binder?.boxTypeChoice(typeId);

  /// Sets binder [path]'s choice for [typeId] (null: no choice, so allowed),
  /// which its pages follow and may only tighten.
  Future<void> setBinderBoxType(String path, String typeId, bool? allowed) async {
    final s = _binders[path];
    final b = s?.binder;
    if (s == null || b == null || !s.available || _isLocked(path)) return;
    final next = b.withBoxType(typeId, allowed);
    if (identical(next, b)) return;
    s.binder = next;
    notifyListeners();
    await _afterSaves(() async {
      final latest = s.binder;
      if (latest != null) {
        await _saveBinderFile(path, latest);
        _binderText[_key(path)] = latest.write();
      }
    }, what: 'binder box types of $path').catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
  }

  // Attachments (images and files) -----------------------------------------

  /// The "Store images and files" setting that applies to page [id]: its
  /// own, else its nearest parent page's, else its binder's, else folder
  /// (configuration inheritance, 0027).
  AttachmentStorage attachmentStorageFor(String id) {
    final loc = _loc[id] ?? _standalone;
    final tree = _treeOf(loc);
    final chain = <PageMeta>[];
    final seen = <String>{};
    String? at = id;
    while (at != null && seen.add(at)) {
      final m = (at == currentId ? _current?.page.meta : null) ?? _metas[at];
      if (m == null) break;
      chain.add(m);
      at = tree.parentIdOf(at);
    }
    return effectiveAttachmentStorage(chain, binder: _binders[loc]?.binder);
  }

  /// Page [id]'s own "Store images and files" choice, or null if it follows
  /// its parent.
  AttachmentStorage? ownAttachmentStorage(String id) =>
      ((id == currentId ? _current?.page.meta : null) ?? _metas[id])?.attachmentStorage;

  /// What page [id] would store its images and files as without its own
  /// choice, and where that comes from: its nearest parent page's choice, its
  /// binder's, else the app default (a folder).
  (AttachmentStorage, ConfigSource) inheritedAttachmentStorageFor(String id) {
    for (final p in _metaChain(id).skip(1)) {
      final s = p.attachmentStorage;
      if (s != null) return (s, ConfigSource.page(p.id));
    }
    final b = _binderOf(id)?.attachmentStorage;
    if (b != null) return (b, ConfigSource.binder);
    return (AttachmentStorage.folder, ConfigSource.appDefault);
  }

  /// Sets page [id]'s own choice (null: follow the parent). Only the header
  /// changes; existing boxes keep their files where they are (see
  /// [convertAttachments]).
  Future<void> setAttachmentStorage(String id, AttachmentStorage? value) async {
    final loc = _loc[id] ?? _standalone;
    _assertWritable(loc);
    final c = _current;
    if (c != null && c.page.id == id) {
      final meta = c.page.meta.withAttachmentStorage(value);
      if (identical(meta, c.page.meta)) return;
      c.updateMeta(meta);
      _metas[id] = meta;
      notifyListeners();
      return;
    }
    final next = await _updateClosedPage(loc, id, (page) {
      final meta = page.meta.withAttachmentStorage(value);
      return identical(meta, page.meta) ? null : page.withMeta(meta);
    });
    if (next == null) return;
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  /// Sets binder [path]'s "Store images and files" choice, which its pages
  /// follow unless they have their own.
  Future<void> setBinderAttachmentStorage(String path, AttachmentStorage value) async {
    final s = _binders[path];
    final b = s?.binder;
    if (s == null || b == null || !s.available || _isLocked(path)) return;
    if (b.attachmentStorage == value) return;
    s.binder = b.withAttachmentStorage(value);
    notifyListeners();
    await _afterSaves(() async {
      final latest = s.binder;
      if (latest != null) {
        await _saveBinderFile(path, latest);
        _binderText[_key(path)] = latest.write();
      }
    }, what: 'binder attachment storage of $path').catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
  }

  /// "Embed attachments" / "Move attachments to folder" on page [id]
  /// (opened first if it isn't): every image and file box keeps its file
  /// the [to] way, as one undo step. Files over [embedLimitBytes] stay in
  /// the folder and are listed in the result.
  Future<AttachmentConversion> convertAttachments(String id, AttachmentStorage to) async {
    _assertWritable(_loc[id] ?? _standalone);
    if (currentId != id) await open(id);
    final c = _current;
    final store = _attachments;
    if (c == null || store == null || c.readOnly) {
      return const AttachmentConversion(changed: 0, overLimit: []);
    }
    return convertPageAttachments(c, store, to, skipTypes: disallowedBoxTypesFor(id));
  }

  Directory _assetsDir(String loc, String id) =>
      Directory('${_storeOf(loc).directory.path}${Platform.pathSeparator}${assetsFolderName(id)}');

  /// Copies the files of [from] into [to] (made if needed) without replacing
  /// anything; see [copyAttachmentTree]. [into] collects what happened.
  static Future<void> _copyDir(
    Directory from,
    Directory to, {
    AttachmentCopy? into,
    bool sweepSource = true,
  }) => copyAttachmentTree(from, to, into ?? AttachmentCopy(), sweepSource: sweepSource);

  /// [_copyDir] for a copy that has no rollback of its own (templates): what it
  /// kept aside or left alone is posted to [attachmentNotices], also when it
  /// throws.
  Future<void> _copyDirNotify(Directory from, Directory to, String targetPlace, String sourcePlace) async {
    final copy = AttachmentCopy();
    try {
      // A pull-only source is only read: its leftovers are not swept (G15).
      await _copyDir(from, to, into: copy, sweepSource: !_pullOnly(from.path));
    } finally {
      _postCopyNotices(copy, targetPlace, sourcePlace);
    }
  }

  /// Moves [from] to [to]: a rename, or a copy and delete across drives.
  ///
  /// It fails ([_IncompleteAttachments], carrying what was done) on every
  /// incomplete move: a destination file that differs or is still changing, or,
  /// with [fromTrash] (a set-aside folder being put back, where nothing should
  /// stay), a source that still holds files after the verified ones were
  /// removed. A complete move returns what the copy did. The notices
  /// ([damagedKept], [stillChanging]) are for the caller to post.
  static Future<AttachmentCopy> _moveDir(Directory from, Directory to, {required bool fromTrash}) async {
    final copy = AttachmentCopy();
    if (!await from.exists()) return copy;
    await to.parent.create(recursive: true);
    try {
      if (forceCopyMoveForTest) throw const FileSystemException('forced');
      await from.rename(to.path);
    } on FileSystemException {
      try {
        await _copyDir(from, to, into: copy);
        if (copy.differing.isNotEmpty || copy.stillChanging.isNotEmpty) {
          throw _IncompleteAttachments(copy, false, to.path);
        }
        await removeVerifiedSources(copy, from);
        if (fromTrash && await _holdsFile(from)) throw _IncompleteAttachments(copy, true, to.path);
      } on _IncompleteAttachments {
        rethrow;
      } on FileSystemException catch (e) {
        // Carries what was done so far (a file set aside stays reported).
        throw _IncompleteAttachments(copy, false, to.path, cause: e);
      }
    }
    return copy;
  }

  static Future<bool> _holdsFile(Directory d) async {
    if (!await d.exists()) return false;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is! Directory) return true;
      }
    } on FileSystemException {
      return true; // can't tell: treated as not empty
    }
    return false;
  }

  /// The notices for what a copy kept or left alone (see [_moveDir]).
  static List<String> _copyNotices(AttachmentCopy c, String targetPlace, String sourcePlace) {
    String shown(Iterable<String> names) {
      final l = names.toList();
      return l.length <= 3
          ? l.map((n) => '"$n"').join(', ')
          : '${l.take(3).map((n) => '"$n"').join(', ')} and ${l.length - 3} more';
    }

    final out = <String>[];
    for (final incomplete in [false, true]) {
      for (final replaced in [true, false]) {
        final of = c.damagedKept.where((k) => k.incomplete == incomplete && k.replaced == replaced).toList();
        if (of.isEmpty) continue;
        final one = of.length == 1;
        final what = '${one ? 'A' : '${of.length}'} ${incomplete ? 'incomplete' : 'damaged'} '
            '${one ? 'copy' : 'copies'} of ${shown(of.map((k) => k.name))} in $targetPlace '
            '${one ? 'was' : 'were'} kept as ${shown(of.map((k) => k.aside))}';
        out.add(
          replaced
              ? '$what, and the good ${one ? 'copy was' : 'copies were'} used.'
              : "$what; the good ${one ? "copy wasn't" : "copies weren't"} put in "
                    "${one ? 'its' : 'their'} place and ${one ? 'stays' : 'stay'} in $sourcePlace.",
        );
      }
    }
    if (c.stillChanging.isNotEmpty) {
      final one = c.stillChanging.length == 1;
      out.add(
        '${shown(c.stillChanging.map(_baseName))} ${one ? 'is' : 'are'} still changing in $targetPlace, so '
        '${one ? 'it was' : 'they were'} not moved; the ${one ? 'original stays' : 'originals stay'} in $sourcePlace.',
      );
    }
    return out;
  }

  /// What a move that stopped says: what [_copyNotices] says, the files that
  /// differ from what is at the destination, and files left in the source.
  void _postIncomplete(_IncompleteAttachments e, String targetPlace, String sourcePlace) {
    _postCopyNotices(e.copy, targetPlace, sourcePlace);
    if (_notices.isClosed) return;
    if (e.copy.differing.isNotEmpty) {
      final n = e.copy.differing.length;
      _notices.add(
        '${n == 1 ? 'An attachment file' : '$n attachment files'} ("${_baseName(e.copy.differing.first)}"'
        '${n == 1 ? '' : ' and others'}) could not be moved: $targetPlace already has '
        '${n == 1 ? 'a different file' : 'different files'} with ${n == 1 ? 'that name' : 'those names'}. '
        'The original${n == 1 ? '' : 's'} stay in $sourcePlace.',
      );
    }
    if (e.leftover) {
      _notices.add('Some attachment files could not be moved out of $sourcePlace, so they were left there.');
    }
  }

  /// A put-back that failed: what [_postIncomplete] says for an incomplete move,
  /// and always where what could not be put back is kept.
  void _postKept(Object e, Directory kept, String targetPlace, String sourcePlace) {
    if (e is _IncompleteAttachments) _postIncomplete(e, targetPlace, sourcePlace);
    if (_notices.isClosed) return;
    _notices.add(
      'Attachments could not be put back in $targetPlace${e is _IncompleteAttachments && e.cause == null ? '' : ' (${describeError(e is _IncompleteAttachments ? e.cause! : e)})'}. '
      'What could not be put back is still saved in ${kept.path}.',
    );
  }

  void _postCopyNotices(AttachmentCopy c, String targetPlace, String sourcePlace) {
    if (_notices.isClosed) return;
    for (final n in _copyNotices(c, targetPlace, sourcePlace)) {
      _notices.add(n);
    }
  }

  // What to tell the user when attachment files stayed because the target
  // already holds something else under their name.
  static String _attachmentsNote(
    List<String> differing,
    List<String> keptAside,
    String targetPlace,
    String sourcePlace, {
    List<DamagedKept> damagedKept = const [],
    List<String> stillChanging = const [],
  }) {
    String shown(List<String> paths) {
      final names = paths.map(_baseName).toList();
      return names.length <= 3
          ? names.map((n) => '"$n"').join(', ')
          : '${names.take(3).map((n) => '"$n"').join(', ')} and ${names.length - 3} more';
    }

    final parts = <String>[];
    if (differing.isNotEmpty) {
      final one = differing.length == 1;
      parts.add(
        'the attachment ${one ? 'file' : 'files'} ${shown(differing)} could not be moved: $targetPlace already has '
        '${one ? 'a different file' : 'different files'} with ${one ? 'that name' : 'those names'}. '
        '${one ? 'It was' : 'They were'} left as ${one ? 'it is' : 'they are'}, and '
        '${one ? 'the original stays' : 'the originals stay'} in $sourcePlace.',
      );
    }
    if (keptAside.isNotEmpty) {
      final one = keptAside.length == 1;
      parts.add(
        '${one ? 'a leftover temporary file' : '${keptAside.length} leftover temporary files'} '
        '(${shown(keptAside)}) in $sourcePlace could not be checked or put back, so '
        '${one ? 'it was' : 'they were'} left there.',
      );
    }
    final extra = AttachmentCopy()
      ..damagedKept.addAll(damagedKept)
      ..stillChanging.addAll(stillChanging);
    for (final n in _copyNotices(extra, targetPlace, sourcePlace)) {
      parts.add('${n.substring(0, 1).toLowerCase()}${n.substring(1)}');
    }
    return parts.join(' Also, ');
  }

  /// Makes [_moveDir] skip the rename, as a move across drives does.
  @visibleForTesting
  static bool forceCopyMoveForTest = false;

  static Future<void> _removeDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Removing ${d.path} failed: $e');
    }
  }

  // Makes the open page read-only if its location can't be written, and
  // writable again when it can.
  void _syncReadOnly() {
    final c = _current;
    if (_diskBlockId != null && c?.page.id != _diskBlockId) {
      _diskBlockId = null; // another page is open now; the block was this page's
      _diskBlockReason = null;
      _diskBlockWhy = null;
    }
    String? why;
    if (c != null) {
      final loc = _loc[c.page.id];
      if (loc == null) {
        why = _orphanLoc == null
            ? null
            : _pullOnly(_orphanLoc!)
            ? _pullOnlyMessage
            : "This page's folder isn't available, so it is read-only.";
      } else if (_pullOnly(loc)) {
        why = _pullOnlyMessage;
      } else if (_isLocked(loc)) {
        why = _binders[loc]?.readOnly ?? false
            ? "This binder's file can't be read, so this page is read-only."
            : "This page's folder isn't available, so it is read-only.";
      }
      if (why == null && _diskBlockId == c.page.id) why = _diskBlockReason;
      // Kept changes shown in place of the page are never edited or saved.
      if (why == null && _preview != null) why = 'These are changes kept in recovery that are not saved to this page yet.';
      if (why == null && _busy[c.page.id] == _busyDiscarding) why = 'Noted is discarding the unsaved changes of this page.';
      if (why == null && _leaving > 0) why = 'Noted is saving this page before leaving it.';
      c.readOnly = why != null || _leaving > 0;
    }
    if (why != _readOnlyReason) {
      _readOnlyReason = why;
      if (!_disposed) notifyListeners();
    }
  }

  /// Creates a page and opens it. A subpage when [parentId] is given, in its
  /// parent's location; otherwise a top-level page in the binder [binderPath]
  /// (null: standalone). Giving a page its first subpage makes it a divider
  /// (0025).
  ///
  /// A top-level standalone page goes to the default folder, or to
  /// [folderPath] (remembered as a standalone folder, see
  /// [addStandaloneFolder]).
  ///
  /// With [focusTitle] the page's title field is asked to take the caret when
  /// the page is shown (see [requestTitleFocus]).
  ///
  /// While one createPage is pending for the same place, another call is not
  /// queued: it returns the pending one's result, so stacked clicks make one
  /// page.
  Future<String> createPage({
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) {
    final key = '$parentId|$binderPath|$folderPath';
    final pending = _pendingCreates[key];
    if (pending != null) return pending;
    final run = _asUser(
      () => _createPageNow(parentId, binderPath, folderPath, focusTitle),
    );
    _pendingCreates[key] = run;
    void clear() {
      if (identical(_pendingCreates[key], run)) _pendingCreates.remove(key);
    }

    run.then<void>((_) => clear(), onError: (Object _) => clear());
    return run;
  }

  final Map<String, Future<String>> _pendingCreates = {};

  Future<String> _createPageNow(
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle,
  ) async {
    final loc = await _placeFor(parentId, binderPath, folderPath);
    final meta = PageMeta.create(
      id: newId(),
      parentId: parentId,
      title: 'Untitled page',
      order: _treeOf(loc).nextOrder(parentId),
    );
    final page = NotedPage.create(meta);
    await _writeNewPage(loc, page);
    _touch(loc);
    _metas[meta.id] = meta;
    _loc[meta.id] = loc;
    if (focusTitle) requestTitleFocus(meta.id);
    await open(meta.id);
    return meta.id;
  }

  // The location a new page goes to; throws if it is not available.
  Future<String> _placeFor(String? parentId, String? binderPath, String? folderPath) async {
    final String loc;
    if (parentId != null) {
      loc = _loc[parentId] ?? _standalone;
    } else if (binderPath != null) {
      loc = binderPath;
    } else if (folderPath != null) {
      loc = await addStandaloneFolder(folderPath);
    } else {
      // The default page folder. Unlike a chosen folder, the built-in one is
      // created when it is missing (see PageStore.scan).
      loc = await addStandaloneFolder(newPageFolderPath);
    }
    _assertWritable(loc); // throws if the binder or folder can't be written
    _storeOf(loc);
    return loc;
  }

  Future<void> rename(String id, String title) async {
    _assertWritable(_loc[id] ?? _standalone);
    final c = _current;
    if (c != null && c.page.id == id) {
      c.updateMeta(c.page.meta.withTitle(title));
    } else {
      final loc = _loc[id] ?? _standalone;
      final next = await _updateClosedPage(loc, id, (page) => page.withMeta(page.meta.withTitle(title)));
      _touch(loc);
      _metas[id] = next!.meta;
    }
    _rebuildTree();
  }

  /// The background of page [id] (the open page's live one), or null for an
  /// unknown page.
  PageBackground? backgroundOf(String id) =>
      ((id == currentId ? _current?.page.meta : null) ?? _metas[id])?.background;

  /// Chooses the background of page [id]. The open page changes through its
  /// controller (one undo step, autosaved); another page is loaded, changed
  /// in its header only, and saved.
  Future<void> setBackground(String id, PageBackground background) async {
    _assertWritable(_loc[id] ?? _standalone);
    final c = _current;
    if (c != null && c.page.id == id) {
      c.setBackground(background);
      return;
    }
    final loc = _loc[id] ?? _standalone;
    final next = await _updateClosedPage(loc, id, (page) {
      final meta = page.meta.withBackground(background);
      return identical(meta, page.meta) ? null : page.withMeta(meta);
    });
    if (next == null) return;
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  /// Deletes a page and all its subpages, and keeps their full content in
  /// memory so [undoDelete] can bring them back. Only the latest delete can
  /// be undone: the previous one is dropped.
  Future<DeletedPages> delete(String id) async {
    final loc = _loc[id] ?? _standalone;
    _assertWritable(loc);
    final st = _storeOf(loc);
    final ids = [id, ..._treeOf(loc).descendantsOf(id)];
    final openId = ids.contains(currentId) ? currentId : null;
    final DeletedPages result;
    final asked = await _guardKept(ids, loc, 'deleting', "Noted is still trying to save this page, so it can't be deleted yet.");
    try {
      result = await _deleteGuarded(id, loc, st, ids, openId, asked);
    } finally {
      for (final p in ids) {
        _free(p, _busyDeleting);
      }
    }
    return result;
  }

  // Refuses (BusyException) when a page of [ids] is busy, asks about kept
  // changes, then marks the pages busy for [why] (3.7 delete and move). A
  // delete or move of several pages needs recovery, so it is refused while
  // the recovery lock isn't held (build note 2).
  // Returns whether the user was asked about kept changes.
  Future<bool> _guardKept(List<String> ids, String loc, String why, String busyMessage) async {
    var asked = false;
    for (final p in ids) {
      if (_busy.containsKey(p)) throw NotebookException(busyMessage);
    }
    if (ids.length > 1 && _lockProblem() != null) {
      throw const NotebookException("Noted can't keep a backup right now.");
    }
    if (why == 'deleting') {
      final rec = _recovery;
      final kept = rec != null && ids.any((p) => rec.entriesOfPage(p).any((e) => !rec.isLanded(e.gen)));
      final troubled = _trouble.isTrouble && ids.contains(_trouble.pageId);
      if (kept || troubled) {
        final title = _titleOrUntitled(pageTitleOf(ids.first) ?? '');
        asked = true;
        if (!await _ask(UserQuestion.deleteKept, title)) throw const LeaveCancelled();
        if (troubled && _preview == null) {
          // The user chose to delete the changes with the page: the session
          // is dropped without a last save; its entries go once the page is.
          _disposeCurrent();
        }
      }
    }
    for (final p in ids) {
      _busy[p] = why == 'deleting' ? _busyDeleting : _busyMoving;
    }
    return asked;
  }

  Future<DeletedPages> _deleteGuarded(
    String id,
    String loc,
    PageStore st,
    List<String> ids,
    String? openId,
    bool asked,
  ) async {
    // Closing saves the open page, so the copies read below are current.
    if (openId != null) await _closeCurrent();
    // The last save may have put new edits in recovery. They were not what the
    // user was asked about: ask now, so they are not deleted unseen.
    final rec = _recovery;
    if (!asked && rec != null && ids.any((p) => rec.entriesOfPage(p).any((e) => !rec.isLanded(e.gen)))) {
      if (!await _ask(UserQuestion.deleteKept, _titleOrUntitled(pageTitleOf(ids.first) ?? ''))) {
        throw const LeaveCancelled();
      }
    }
    // The text each page was read with: the file is deleted only while it still
    // holds exactly that (a version a sync client landed since is kept).
    final texts = [for (final p in ids) await st.readText(p)];
    final pages = [for (final t in texts) readPage(t)];
    // A file that holds another page than the one being deleted is never
    // deleted under this page's name.
    for (var i = 0; i < ids.length; i++) {
      if (pages[i].id != ids[i]) throw const NotebookException('This page could not be deleted: it holds a different page.');
    }
    final previous = _lastDeleted;
    if (previous != null) discardDeleted(previous);
    // Each page's assets folder is set aside, so undo can bring it back.
    final stash = <String, Directory>{};
    final trash = Directory('${_deletedAssetsDir.path}${Platform.pathSeparator}${newId()}');
    for (final p in ids) {
      final dir = _assetsDir(loc, p);
      if (!await dir.exists()) continue;
      final to = Directory('${trash.path}${Platform.pathSeparator}${assetsFolderName(p)}');
      try {
        _postCopyNotices(await _moveDir(dir, to, fromTrash: false), 'the folder of deleted pages', 'the page');
        stash[p] = to;
      } on FileSystemException catch (e) {
        debugPrint('Setting aside ${dir.path} failed: $e');
        if (e is _IncompleteAttachments) _postIncomplete(e, 'the folder of deleted pages', 'the page');
        // Whatever was moved is what Undo restores; files that stayed in the
        // page folder stay there.
        if (await to.exists()) stash[p] = to;
      }
    }
    final keptIds = <String>{}; // changed since they were read: not deleted
    // Set-aside folders that could not be put back (or handed to recovery) whole:
    // never removed, nor the trash folder that holds them.
    final keepTrash = <String>{};
    final deletedNow = <int>[]; // deleted by this call, for putting back on a failure
    try {
      for (var i = 0; i < ids.length; i++) {
        final p = ids[i];
        final r = await _deleteIfUnchanged(loc, p, texts[i]);
        if (!r.deleted && r.outcome != DeleteOutcome.absent) {
          keptIds.add(p);
          continue;
        }
        if (r.deleted) deletedNow.add(i);
        _landedProblems.remove(p); // the user deleted it
        _metas.remove(p);
        _loc.remove(p);
      }
    } on Object catch (rollbackError) {
      // No undo is offered for a delete that threw, so what it already
      // deleted is put back, never over a file that has appeared since.
      final stuck = <int>[]; // could not be put back: kept in recovery
      // A different file is at the page's path: the deleted version is kept
      // beside it as a copy ([copied], by file name), or held for Undo ([direct]).
      // Not through recovery, whose replay would take the file as the newer page.
      final copied = <int, String>{};
      final direct = <int>[];
      final inFile = <int>{}; // a different file was at the page's path
      // The recovery entries this rollback wrote (a fresh slot each, no base),
      // by page. Removed only by their exact generation, once the page is back
      // as it was or a copy of it stands (see [settle]); else replay takes them.
      final ours = <int, List<String>>{};
      final durable = <int>{}; // recovery holds the page, read back
      final safe = <int>{}; // back in its folder, or copied beside another file
      // Registered first, with what is neither durable nor safe: exit waits for
      // it, is bounded, and asks only about the pages still listed (0141, 0152).
      final rollbackDone = Completer<void>();
      void refreshRisk() {
        if (deletedNow.isEmpty) return;
        _undoRuns[rollbackDone.future] = DeletedPages._(
          [for (final i in deletedNow) if (!durable.contains(i) && !safe.contains(i)) pages[i]],
          null,
          loc,
          {},
        );
      }

      refreshRisk();
      // Deletes the entries of page [i] by exact generation. Never throws.
      Future<void> dropOurs(int i) async {
        final rec = _recovery;
        final gens = ours[i];
        // A notebook that is gone writes nothing more: the next start settles it.
        if (rec == null || gens == null || _disposed) return;
        await _deleteGens(rec, gens, null);
        ours.remove(i);
      }

      // The page is in its folder (restored, or there as it was, or another
      // writer's version is on top of what landed): its entry goes only when
      // the file reads as exactly this version, or, after our own publish, as a
      // readable page of this id (what is on top was already on disk before the
      // delete, so nothing new is exposed, and merging again would bring back
      // what the other writer deleted). A read that fails leaves the entry.
      Future<void> settle(int i, {required bool published}) async {
        if (!ours.containsKey(i) || _disposed) return;
        try {
          final back = await st.readText(ids[i]);
          var onTop = false;
          if (back != texts[i]) {
            final now = published ? _tryRead(back) : null;
            if (now == null || now.id != ids[i]) return;
            onTop = true;
          }
          await dropOurs(i);
          if (onTop) await _checkFile(st.pathFor(ids[i]));
        } on Object catch (e) {
          debugPrint('Settling the kept copy of page ${ids[i]} failed: $e');
        }
      }

      String? plain; // the message when recovery or copies hold everything
      DeletedPages? held;
      var heldCause = '';
      var handedOff = false;
      try {
        // Recorded in recovery before the first restore: the pages exist only
        // in memory until then, and a quit or a kill would lose them.
        for (final i in deletedNow) {
          final k = await _keepRollbackCopy(st, pages[i], null);
          if (k.gen != null) (ours[i] ??= []).add(k.gen!);
          if (k.durable) durable.add(i);
          refreshRisk();
        }
        for (final i in deletedNow) {
          try {
            if (await _restoreText(loc, pages[i], texts[i])) {
              _metas[ids[i]] = pages[i].meta;
              _loc[ids[i]] = loc;
              safe.add(i);
              refreshRisk();
              await settle(i, published: true);
            } else {
              // A file appeared at its path meanwhile. Unless it holds exactly
              // the deleted version, that version is not in the folder: it is
              // published beside the file as a copy, never over it (0053).
              String? there;
              try {
                there = await st.readText(ids[i]);
              } on Object {
                there = null;
              }
              if (there != texts[i]) {
                inFile.add(i);
                final copy = await _publishConflictCopy(st, pages[i]);
                if (copy != null) {
                  copied[i] = _baseName(copy);
                  safe.add(i);
                  refreshRisk();
                  await dropOurs(i); // the copy holds this version
                } else {
                  direct.add(i);
                }
              } else {
                safe.add(i);
                refreshRisk();
                await settle(i, published: false);
              }
              try {
                await _checkFile(st.pathFor(ids[i])); // read as any change
              } on Object catch (e) {
                debugPrint('Reading the file at page ${ids[i]} after a failed delete failed: $e');
              }
            }
          } on Object catch (e) {
            debugPrint('Putting back page ${ids[i]} after a failed delete failed: $e');
            if (!safe.contains(i)) stuck.add(i);
          }
        }
      for (var i = 0; i < ids.length; i++) {
        final dir = stash[ids[i]];
        if (dir == null) continue;
        try {
          _postCopyNotices(
            await _moveDir(dir, _assetsDir(loc, ids[i]), fromTrash: true),
            'the page',
            'the folder of deleted pages',
          );
          stash.remove(ids[i]);
        } on Object catch (e) {
          // Also a NotebookException (a location that was dropped meanwhile).
          debugPrint('Putting back the attachments of page ${ids[i]} failed: $e');
          if (e is FileSystemException) _postKept(e, dir, 'the page', 'the folder of deleted pages');
          // Stays in the stash, and the trash folder is never removed while it
          // holds what could not be put back.
          keepTrash.add(dir.path);
        }
      }
      // Preserve first (0141): what only exists in memory goes to recovery or
      // is held for Undo before any step that can fail, so no later failure
      // (a check, the clean-up, the reopen, the fallback) can lose it.
      // Attachments that could not go back to their folder are handed to
      // recovery's kept files (0098): they land beside the page when it does,
      // and are out of reach of a later delete's clean-up of the trash.
      final rec = _recovery;
      if (rec != null) {
        for (final id in stash.keys.toList()) {
          try {
            _postCopyNotices(
              await _moveDir(
                stash[id]!,
                Directory('${rec.directory.path}${Platform.pathSeparator}${assetsFolderName(id)}'),
                fromTrash: true,
              ),
              'the recovery folder',
              'the folder of deleted pages',
            );
            keepTrash.remove(stash.remove(id)!.path); // emptied: nothing left to protect
            handedOff = true;
          } on Object catch (e) {
            debugPrint('Keeping the attachments of page $id for recovery failed: $e');
            _postKept(e, stash[id]!, 'the recovery folder', 'the folder of deleted pages');
            keepTrash.add(stash[id]!.path);
          }
        }
      }
      if (stuck.isNotEmpty || copied.isNotEmpty || direct.isNotEmpty) {
        // What could not be put back is in recovery already (written before the
        // first restore, see above), which writes a page file that is not there
        // when it replays and merges into one that is. A stuck page without a
        // verified entry tries once more, so a recovery folder that came back is
        // used. What recovery does not take is held in memory and offered as an
        // Undo, which writes it back and never over a file that is there; its
        // set-aside attachments are in [keepTrash], so no clean-up of the trash
        // reaches them.
        final taken = <int>[];
        final untaken = <int>[];
        for (final i in stuck) {
          if (!durable.contains(i)) {
            final k = await _keepRollbackCopy(st, pages[i], ours[i]?.last);
            if (k.gen != null && !(ours[i]?.contains(k.gen) ?? false)) (ours[i] ??= []).add(k.gen!);
            if (k.durable) durable.add(i);
          }
          (durable.contains(i) ? taken : untaken).add(i);
        }
        // A different file is there and the copy failed: recovery holds the
        // version and replay merges it into the file; without an entry the
        // page is held, as before.
        final directTaken = [
          for (final i in direct) if (durable.contains(i)) i,
          for (final i in taken) if (inFile.contains(i)) i,
        ];
        final directHeld = [for (final i in direct) if (!durable.contains(i)) i];
        String titles(Iterable<int> at) => at.map((i) => '"${_titleOrUntitled(pages[i].meta.title)}"').join(', ');
        final total = stuck.length + copied.length + direct.length;
        final head =
            '${total == 1 ? 'A page' : '$total pages'} could not be deleted '
            'completely and ${total == 1 ? 'was' : 'were'} not put back.';
        final heldText = taken.every(inFile.contains)
            ? ''
            : ' Recovery holds the content of ${titles(taken.where((i) => !inFile.contains(i)))} and will write it back.';
        final directTakenText = directTaken.isEmpty
            ? ''
            : ' Recovery holds the content of ${titles(directTaken)} and will add it to the file there.';
        final copyText = copied.isEmpty
            ? ''
            : ' A newer file was already in the place of ${titles(copied.keys)}, so the deleted '
                  '${copied.length == 1 ? 'version was' : 'versions were'} kept beside '
                  '${copied.length == 1 ? 'it' : 'them'} as ${copied.values.map((n) => '"$n"').join(', ')}; '
                  'nothing was written over the file.';
        if (untaken.isEmpty && directHeld.isEmpty) {
          plain = '$head$heldText$directTakenText$copyText';
        } else {
          final only = [...untaken, ...directHeld];
          held = DeletedPages._(
            [for (final i in only) pages[i]],
            null,
            loc,
            {
              for (final i in only)
                if (stash.containsKey(ids[i])) ids[i]: stash[ids[i]]!,
            },
            keepTrash: keepTrash,
          );
          _held.add(held);
          heldCause =
              '$head$heldText$directTakenText$copyText'
              '${untaken.isEmpty ? '' : ' Recovery could not keep ${titles(untaken)}.'}'
              '${directHeld.isEmpty ? '' : ' A newer file is in the place of ${titles(directHeld)} and a copy could not be saved beside it.'}';
        }
      }
      } finally {
        // After the decision: until then the pages are only in memory or in
        // an entry nobody has taken over, and exit must not pass them by.
        _undoRuns.remove(rollbackDone.future);
        rollbackDone.complete();
      }
      // An entry left (a page recovery holds, or one a read could not settle)
      // is replayed once the delete is over.
      if (ours.isNotEmpty) _backoff.schedule();
      // Land kept attachments as soon as the folder takes them, not only at
      // the next start; raised only now, so a stuck page's entry exists
      // before the folder check looks for the page its files go with.
      if (handedOff) _keptRetry = true;
      // Now the side effects, each on its own: none can lose what is kept.
      // Pages kept because a newer version landed: read like any change.
      for (final p in keptIds) {
        try {
          await syncHook?.call('delete-rollback-check', st.pathFor(p));
          await _checkFile(st.pathFor(p));
        } on Object catch (e) {
          debugPrint('Reading the file of kept page $p after a failed delete failed: $e');
        }
      }
      try {
        if (stash.isEmpty && keepTrash.isEmpty) await _removeDir(trash);
      } on Object catch (e) {
        debugPrint('Removing the set-aside folder after a failed delete failed: $e');
      }
      try {
        _touch(loc);
        _rebuildTree();
      } on Object catch (e) {
        debugPrint('Refreshing the tree after a failed delete failed: $e');
      }
      String? noPage; // why no page could be opened
      if (openId != null) {
        _free(openId, _busyDeleting); // reopened for editing, not as a preview
        try {
          if (!_loc.containsKey(openId)) throw StateError('page $openId is not in the folder');
          await open(openId);
        } on Object catch (e) {
          debugPrint('Reopening page $openId after a failed delete failed: $e');
          if (_current == null) {
            try {
              await syncHook?.call('delete-rollback-fallback', loc);
              await _openFallback(loc);
            } on Object catch (e2) {
              debugPrint('Opening a page after a failed delete failed: $e2');
              noPage = describeError(e2);
            }
          }
        }
      }
      final openNote = noPage == null ? '' : ' No page could be opened ($noPage).';
      if (held != null) throw _hold(held, '$heldCause$openNote');
      if (plain != null) throw NotebookException('$plain$openNote', needsAction: true);
      final original = rollbackError;
      if (noPage != null && original is NotebookException) {
        throw NotebookException('${original.message}$openNote', needsAction: original.needsAction);
      }
      rethrow;
    }
    for (final p in keptIds) {
      // Its attachments go back, and the version on disk is read like any
      // external change.
      final dir = stash.remove(p);
      if (dir != null) {
        try {
          _postCopyNotices(
            await _moveDir(dir, _assetsDir(loc, p), fromTrash: true),
            'the page',
            'the folder of deleted pages',
          );
        } on FileSystemException catch (e) {
          debugPrint('Putting back the attachments of page $p failed: $e');
          _postKept(e, dir, 'the page', 'the folder of deleted pages');
          keepTrash.add(dir.path); // what is left there is never cleaned up with the trash
        }
      }
      await _checkFile(st.pathFor(p));
    }
    // What the user chose to delete with the pages goes once they are gone,
    // by exact generation. A page kept because it changed keeps its entries.
    await _dropKeptEntries([for (final p in ids) if (!keptIds.contains(p)) p], st);
    final deleted = DeletedPages._(
      [for (var i = 0; i < ids.length; i++) if (!keptIds.contains(ids[i])) pages[i]],
      openId,
      loc,
      stash,
      keepTrash: keepTrash,
      keptNote: keptIds.isEmpty
          ? null
          : '${keptIds.length == 1 ? 'A page was' : '${keptIds.length} pages were'} changed on '
                'another device after it was read, so ${keptIds.length == 1 ? 'it was' : 'they were'} '
                'not deleted.',
    );
    _lastDeleted = deleted;
    _touch(loc);
    _rebuildTree();
    if (_current == null) await _openFallback(loc);
    return deleted;
  }

  // The first half of a move of kept edits (3.7): each non-landed entry of the
  // moved pages is written again under the target's folder, and read back,
  // while the old one stays. Landed ones are deleted. Throws a
  // NotebookException, with what was written settled back, if a write fails.
  Future<List<_Rekey>> _rekeyBegin(
    List<String> ids,
    PageStore fromStore,
    PageStore toStore,
    String fromLoc,
    String toLoc,
  ) async {
    final rec = _recovery;
    if (rec == null) return const [];
    final fromFolder = _normalizePath(fromStore.directory.path);
    final toFolder = _normalizePath(toStore.directory.path);
    final done = <_Rekey>[];
    final landed = <String>[];
    Never refuse(Object why) => throw NotebookException(
      'Nothing was moved. The changes kept for a page could not be moved with it ($why).',
      needsAction: true,
    );
    for (final p in ids) {
      final preexisting = rec.entriesFor(toFolder, p).isNotEmpty;
      final olds = <RecoveryEntry>[];
      for (final e in rec.entriesFor(fromFolder, p)) {
        if (rec.isLanded(e.gen)) {
          landed.add(e.gen);
        } else {
          olds.add(e);
        }
      }
      final mine = <_Rekey>[];
      try {
        for (final e in olds) {
          if (preexisting) {
            // The target holds an entry already: merged into it, never replaced.
            final NotedPage? eb = e.baseText == null ? null : _tryRead(e.baseText!);
            if (e.baseText != null && eb == null) refuse('its base can not be read');
            final out = await _keepForRecovery(toLoc, toStore, e.page, base: eb, exactBase: true);
            if (!out.safe || out.gen == null) {
              refuse(out.why ?? (out.cause == null ? 'it could not be written' : describeError(out.cause!)));
            }
            mine.add(_Rekey(p, e, out.gen!, true));
          } else {
            // Its own fresh slot, so the pair is the generation and its copy.
            if (_lockProblem() != null) refuse(_recovery == null ? 'no recovery' : recoveryLock!.problem);
            final fresh = await rec.transaction(
              (tx) => tx.write(
                folder: toFolder,
                page: e.page,
                baseText: e.baseText,
                time: DateTime.now(),
                freshSlot: true,
              ),
            );
            mine.add(_Rekey(p, e, fresh.gen, false));
          }
        }
        // Merged ones share the last generation (each write replaced the slot),
        // so that is the one read back, not the obsolete ones.
        if (preexisting && mine.isNotEmpty) {
          final last = mine.last.freshGen;
          for (var i = 0; i < mine.length; i++) {
            mine[i] = _Rekey(p, mine[i].old, last, true);
          }
        }
        // Each copy is read back before anything is deleted.
        for (final k in mine) {
          final fresh = rec.indexEntries.where((x) => x.gen == k.freshGen).firstOrNull;
          if (fresh == null || !await rec.transaction((tx) => tx.verify(fresh))) {
            refuse('the new copy did not read back');
          }
        }
      } on NotebookException {
        done.addAll(mine);
        await _settleRekeys(done, const {});
        rethrow;
      } on Object catch (e) {
        done.addAll(mine);
        await _settleRekeys(done, const {});
        refuse(describeError(e));
      }
      done.addAll(mine);
    }
    if (landed.isNotEmpty) await _deleteGens(rec, landed, null);
    return done;
  }

  // The second half: each page's kept entry is decided where the page ended
  // up. At the target (in [atDest]) the old key goes, once the new one reads
  // back; at the source the new one goes. A delete that fails marks the
  // generation landed. Never throws.
  Future<void> _settleRekeys(List<_Rekey> keys, Set<String> atDest) async {
    final rec = _recovery;
    // A notebook that is gone (the app quit, or died) writes nothing more: both
    // keys stay, and the next start settles them.
    if (rec == null || keys.isEmpty || _disposed) return;
    for (final k in keys) {
      try {
        final RecoveryEntry? victim;
        if (atDest.contains(k.id)) {
          final fresh = rec.indexEntries.where((x) => x.gen == k.freshGen).firstOrNull;
          victim = fresh != null && await rec.transaction((tx) => tx.verify(fresh)) ? k.old : null;
        } else {
          victim = k.preexisting ? null : rec.indexEntries.where((x) => x.gen == k.freshGen).firstOrNull;
        }
        if (victim != null) await _deleteEntry(rec, victim);
      } on Object catch (e) {
        debugPrint('Settling the kept changes of page ${k.id} failed: $e');
      }
    }
    keys.clear();
  }
  // Deletes the recovery entries of [pageIds] in the folder of [st], by exact
  // generation (the pages are deleted).
  Future<void> _dropKeptEntries(List<String> pageIds, PageStore st) async {
    final rec = _recovery;
    if (rec == null) return;
    final folder = _key(_normalizePath(st.directory.path));
    final gens = [
      for (final e in rec.indexEntries)
        if (pageIds.contains(e.pageId) && _key(e.folder) == folder) e.gen,
    ];
    if (gens.isNotEmpty) await _deleteGens(rec, gens, null);
  }

  Future<void> _openFallback(String loc) async {
    final own = _treeOf(loc);
    if (own.roots.isNotEmpty) {
      await open(own.roots.first.id);
    } else if (_tree.roots.isNotEmpty) {
      await open(_tree.roots.first.id);
    } else {
      await _createFallbackPage();
    }
  }

  // Keeps [d] for Undo: in [_held] (once), out of [_lastDeleted] if it is
  // there. Returns the exception that tells the user, naming the pages not yet
  // restored (0141). No I/O; only called with at least one page not restored.
  PagesNotRestoredException _hold(DeletedPages d, String cause) {
    if (!_held.contains(d)) _held.add(d);
    if (identical(_lastDeleted, d)) _lastDeleted = null;
    final left = [for (final p in d.pages) if (!d._restored.contains(p.id)) p];
    final titles = left.map((p) => '"${_titleOrUntitled(p.meta.title)}"').join(', ');
    final one = left.length == 1;
    return PagesNotRestoredException(
      '$cause The content of $titles is held in memory only. Choose '
      'Undo to write ${one ? 'it' : 'them'} back. Closing this message lets '
      '${one ? 'it' : 'them'} go.',
      d,
    );
  }

  bool _allRestored(DeletedPages d) => d.pages.every((p) => d._restored.contains(p.id));

  // [d] is fully back: it is no longer in need of Undo.
  void _settle(DeletedPages d) {
    _held.remove(d);
    if (identical(_lastDeleted, d)) _lastDeleted = null;
  }

  /// Writes the pages of [deleted] back, with their original ids, content,
  /// parents and order, and reopens the page that was open. Does nothing if
  /// a later delete replaced it, or if the binder is gone. An Undo that fails
  /// keeps the pages held, with Undo, until they are back or the user lets
  /// them go (0141).
  Future<void> undoDelete(DeletedPages deleted) => _asUser(() => _undoDelete(deleted));

  Future<void> _undoDelete(DeletedPages deleted) async {
    final running = _undoing[deleted];
    if (running != null) {
      await running; // its outcome is reported once, by the Undo that runs
      return;
    }
    if (!_held.contains(deleted) && !identical(_lastDeleted, deleted)) return;
    // Exit waits for an Undo in flight, so the page it holds is not lost.
    final done = Completer<void>();
    _undoing[deleted] = done.future;
    _undoRuns[done.future] = deleted;
    try {
      await _undoDeleteNow(deleted);
    } on PagesNotRestoredException {
      rethrow; // already held, and the outcome
    } on Object catch (e) {
      if (_allRestored(deleted)) rethrow;
      debugPrint('Undo stopped early: $e');
      throw _hold(deleted, 'Undo could not finish (${describeError(e)}).');
    } finally {
      _undoing.remove(deleted);
      if (_allRestored(deleted)) _settle(deleted);
      _undoRuns.remove(done.future);
      done.complete();
    }
  }

  Future<void> _undoDeleteNow(DeletedPages deleted) async {
    final wasHeld = _held.contains(deleted);
    try {
      _assertWritable(deleted._location);
      _storeOf(deleted._location);
    } on NotebookException catch (e) {
      throw _hold(deleted, e.message); // still only in memory: Undo can be tried again
    }
    final attachmentsLeft = <String>[]; // saved folders that could not be emptied
    var knownCause = true; // every failure was a different file in the way
    final leftIds = <String>[];
    for (final MapEntry(key: id, value: dir) in deleted._assets.entries) {
      try {
        _postCopyNotices(
          await _moveDir(dir, _assetsDir(deleted._location, id), fromTrash: true),
          'the page',
          'the folder of deleted pages',
        );
      } on Object catch (e) {
        if (e is _IncompleteAttachments) _postCopyNotices(e.copy, 'the page', 'the folder of deleted pages');
        debugPrint('Restoring the attachments of page $id failed: $e');
        attachmentsLeft.add(dir.path);
        leftIds.add(id);
        if (e is! _IncompleteAttachments || !e.onlyDiffering) knownCause = false;
      }
    }
    if (wasHeld) {
      // What went back is no longer in need of protection; the set-aside
      // folder that held it goes if nothing else is in it.
      for (final MapEntry(key: id, value: dir) in deleted._assets.entries) {
        if (leftIds.contains(id)) continue;
        deleted._keepTrash.remove(dir.path);
        try {
          if (await dir.parent.exists() && await dir.parent.list().isEmpty) await dir.parent.delete();
        } on FileSystemException catch (e) {
          debugPrint('Removing ${dir.parent.path} failed: $e');
        }
      }
    }
    // What could not be restored stays where the message says it is: a later
    // discard of this delete leaves those folders alone.
    for (final id in leftIds) {
      final d = deleted._assets.remove(id)!;
      deleted._keepTrash.add(d.path);
    }
    // A file that is at a page's path now (a sync client put one there) is not
    // written over. The restored version, which only exists in memory, is put
    // beside it as a conflict copy, which the per-box conflict-copy merge then
    // combines with the file (0053).
    final merged = <String>[]; // titles whose restored version was merged in
    final kept = <String>[]; // titles whose restored version stays beside the file
    final notRestored = <String>[]; // titles that could not be put anywhere
    final failedWrite = <String>[]; // titles whose write threw
    for (final page in deleted.pages) {
      if (deleted._restored.contains(page.id)) continue;
      final title = _titleOrUntitled(page.meta.title);
      var wrote = false;
      try {
        wrote = await _writeNew(deleted._location, page);
      } on Object catch (e) {
        debugPrint('Restoring page ${page.id} failed: $e');
        failedWrite.add(title); // still only in memory
        continue;
      }
      if (wrote) {
        _metas[page.id] = page.meta;
        _loc[page.id] = deleted._location;
        deleted._restored.add(page.id);
        continue;
      }
      PageStore st;
      String? copy;
      try {
        st = _storeOf(deleted._location);
        copy = await _publishConflictCopy(st, page);
      } on Object catch (e) {
        debugPrint('Saving restored page ${page.id} beside its file failed: $e');
        notRestored.add(title);
        continue;
      }
      if (copy == null) {
        notRestored.add(title);
        await _checkQuietly(st.pathFor(page.id));
        continue;
      }
      await _checkQuietly(st.pathFor(page.id)); // the file that is there
      deleted._restored.add(page.id); // a copy beside the file: the page is back
      await _checkQuietly(copy); // merged into it, and the copy removed
      if (File(copy).existsSync()) {
        kept.add(title); // the merge failed: the restored version stays beside it
      } else {
        merged.add(title);
      }
    }
    final reopenFailed = <String>[];
    try {
      _touch(deleted._location);
      _rebuildTree();
      final reopen = deleted.openId;
      if (reopen != null && _loc.containsKey(reopen)) await open(reopen);
    } on Object catch (e) {
      debugPrint('Reopening after Undo failed: $e');
      reopenFailed.add(describeError(e));
    }
    final notes = <String>[
      if (merged.isNotEmpty)
        'A newer file was already in the place of ${merged.map((t) => '"$t"').join(', ')}, so the '
            'restored ${merged.length == 1 ? 'version was' : 'versions were'} merged into it box by box '
            'and nothing was written over.',
      if (kept.isNotEmpty)
        'A newer file was already in the place of ${kept.map((t) => '"$t"').join(', ')}, so the '
            'restored ${kept.length == 1 ? 'version was' : 'versions were'} kept beside it as a copy '
            'that could not be merged yet; nothing was written over.',
      if (notRestored.isNotEmpty)
        'A file was in the place of ${notRestored.map((t) => '"$t"').join(', ')} and the restored '
            '${notRestored.length == 1 ? 'version' : 'versions'} could not be saved beside it.',
      if (failedWrite.isNotEmpty)
        '${failedWrite.map((t) => '"$t"').join(', ')} could not be written back.',
      if (attachmentsLeft.isNotEmpty)
        'The ${deleted.pages.length == 1 ? 'page was' : 'pages were'} brought back, but the '
            'attachments of ${attachmentsLeft.length == 1 ? 'one page' : '${attachmentsLeft.length} pages'} could not be restored completely'
            '${knownCause ? ' (a different file with the same name was already there and was left as it is)' : ''}. '
            'What could not be restored is still saved in ${attachmentsLeft.join(', ')}.',
      if (reopenFailed.isNotEmpty) 'The page could not be opened again (${reopenFailed.first}).',
    ];
    if (!_allRestored(deleted)) throw _hold(deleted, notes.join(' '));
    _settle(deleted);
    if (notes.isNotEmpty) throw NotebookException(notes.join(' '), needsAction: true);
  }

  // A check of a file after Undo wrote or published beside it: what it finds
  // is read like any change; a failure leaves the page as it is.
  Future<void> _checkQuietly(String path) async {
    try {
      await _checkFile(path);
    } on Object catch (e) {
      debugPrint('Reading $path after Undo failed: $e');
    }
  }

  // Publishes [page] beside its file as a conflict copy (never over anything)
  // and returns its path, or null if that failed.
  Future<String?> _publishConflictCopy(PageStore st, NotedPage page) async {
    final sep = Platform.pathSeparator;
    final name = '${page.id}${PageStore.extension}';
    final text = writePage(page);
    for (var attempt = 0; attempt < 8; attempt++) {
      final path = '${st.directory.path}$sep${conflictCopyName(name, label: 'undo')}';
      final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}-$attempt.tmp');
      try {
        await tmp.writeAsString(text, flush: true);
        await syncHook?.call('undo-copy-before-publish', st.directory.path);
        final published = await _underFolderLock(st, () async {
          if (!await publishExclusive(tmp, path)) return false;
          _emitPublished(path, _identityOf(() => text), () => text);
          return true;
        });
        if (published) return path;
      } on FileSystemException catch (e) {
        debugPrint('Saving the restored page beside its file failed: $e');
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } on FileSystemException {
          // A leftover with a unique name of its own.
        }
      }
    }
    return null;
  }

  // Removes the folders [d] set aside, except those Undo could not restore.
  Future<void> _removeSetAside(DeletedPages d) {
    final sep = Platform.pathSeparator;
    String parentOf(String p) => p.substring(0, p.lastIndexOf(sep));
    final keptParents = {for (final k in d._keepTrash) parentOf(k)};
    return Future.wait([
      for (final dir in d._assets.values)
        if (!d._keepTrash.contains(dir.path)) _removeDir(keptParents.contains(dir.parent.path) ? dir : dir.parent),
    ]);
  }

  /// Drops the in-memory copy of [deleted] (its snackbar went away).
  void discardDeleted(DeletedPages deleted) {
    if (identical(_lastDeleted, deleted)) _lastDeleted = null;
    if (_undoing.containsKey(deleted)) return; // its Undo is copying from the set-aside
    _held.remove(deleted);
    unawaited(_removeSetAside(deleted));
  }

  /// Moves [id] under [parentId] (null: top level) at [index] among that
  /// parent's other children (null: last). Returns false, changing nothing,
  /// if that would put a page under itself or one of its descendants.
  ///
  /// Within a location, siblings are renumbered 0..n-1; only pages whose
  /// parent or order changed are written, and only those two header values
  /// change. If [parentId] is in another location (a binder, or another
  /// standalone folder), the page and its subpages move there (see
  /// [moveToLocation]) and a [NotebookException] reports a failure.
  Future<bool> move(String id, {required String? parentId, int? index}) =>
      _asUser(() => _move(id, parentId: parentId, index: index));

  Future<bool> _move(String id, {required String? parentId, int? index}) async {
    final from = _loc[id];
    if (from == null || !_metas.containsKey(id)) return false;
    var to = from;
    if (parentId != null) {
      final parentLoc = _loc[parentId];
      if (parentLoc == null) return false;
      to = parentLoc;
    }
    return _place(id, to, parentId: parentId, index: index);
  }

  // Puts [id] under [parentId] in the location [to], which may be another
  // location than the page's own.
  Future<bool> _place(String id, String to, {required String? parentId, int? index}) async {
    final from = _loc[id];
    if (from == null || !_metas.containsKey(id)) return false;
    _assertWritable(from);
    if (to != from) {
      _assertWritable(to);
      // Standalone folders share one tree.
      if (_isStandaloneLoc(from) && _isStandaloneLoc(to) && _tree.wouldCycle(id, parentId)) {
        return false;
      }
      await _moveAcross(id, to, parentId: parentId, index: index);
      return true;
    }
    final tree = _treeOf(from);
    if (tree.wouldCycle(id, parentId)) return false;
    final siblings = [
      for (final s in parentId == null ? tree.roots : tree.childrenOf(parentId))
        if (s.id != id) s.id,
    ];
    siblings.insert((index ?? siblings.length).clamp(0, siblings.length), id);
    for (var i = 0; i < siblings.length; i++) {
      final sid = siblings[i];
      final m = _metas[sid]!;
      final p = sid == id ? parentId : m.parentId;
      if (m.parentId == p && m.order == i) continue;
      await _setPlacement(sid, p, i);
    }
    _rebuildTree();
    return true;
  }

  /// Moves [id] to the top level of the binder [binderPath] (null:
  /// standalone) at [index] (null: last). Moving to another location moves
  /// the page's file and its subpages' files; throws [NotebookException] if
  /// that fails, leaving everything where it was.
  Future<bool> moveToLocation(String id, {String? binderPath, int? index}) =>
      _asUser(() => _moveToLocation(id, binderPath: binderPath, index: index));

  Future<bool> _moveToLocation(String id, {String? binderPath, int? index}) async {
    final from = _loc[id];
    final to = binderPath ?? _standalone;
    if (from == null) return false;
    if (to != _standalone && _binders[to] == null) return false;
    // "Pages" is one section: dropping a page from another standalone folder
    // there only makes it a top-level page of its own folder.
    if (from == to || (to == _standalone && _isStandaloneLoc(from))) {
      return move(id, parentId: null, index: index);
    }
    await _moveAcross(id, to, parentId: null, index: index);
    return true;
  }

  /// Moves [id] next to [targetId], under the same parent, before it or (with
  /// [after]) after it. The target may be in another location (a binder or
  /// another standalone folder): the page then moves to the target's location.
  Future<bool> moveRelative(String id, String targetId, {required bool after}) async {
    final to = _loc[targetId];
    final from = _loc[id];
    if (id == targetId || to == null || from == null || !_metas.containsKey(id)) return false;
    final tree = _treeOf(to);
    final parent = tree.parentIdOf(targetId);
    final sameTree = to == from || (_isStandaloneLoc(from) && _isStandaloneLoc(to));
    if (sameTree && tree.wouldCycle(id, parent)) return false;
    final others = [for (final s in tree.siblingsOf(targetId)) if (s.id != id) s.id];
    final at = others.indexOf(targetId) + (after ? 1 : 0);
    return _place(id, to, parentId: parent, index: at);
  }

  /// Moves [id] one place up among its siblings.
  Future<bool> moveUp(String id) async {
    final tree = treeOfPage(id);
    final i = tree.siblingsOf(id).indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: tree.parentIdOf(id), index: i - 1);
  }

  /// Moves [id] one place down among its siblings.
  Future<bool> moveDown(String id) async {
    final tree = treeOfPage(id);
    final siblings = tree.siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i < 0 || i >= siblings.length - 1) return false;
    return move(id, parentId: tree.parentIdOf(id), index: i + 1);
  }

  /// Makes [id] the last subpage of the sibling above it.
  Future<bool> indent(String id) async {
    final siblings = treeOfPage(id).siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: siblings[i - 1].id);
  }

  /// Moves [id] out to its parent's level, right after the parent.
  Future<bool> outdent(String id) async {
    final parent = treeOfPage(id).parentIdOf(id);
    if (parent == null) return false;
    return moveRelative(id, parent, after: true);
  }

  Future<void> _setPlacement(String id, String? parentId, int order) async {
    final c = _current;
    if (c != null && c.page.id == id) {
      // The open page changes through its controller, so the in-memory page
      // and the autosave stay consistent.
      c.updateMeta(c.page.meta.withPlacement(parentId: parentId, order: order));
      _metas[id] = c.page.meta;
    } else {
      final loc = _loc[id] ?? _standalone;
      final next = await _updateClosedPage(
        loc,
        id,
        (page) => page.withMeta(page.meta.withPlacement(parentId: parentId, order: order)),
      );
      _touch(loc);
      _metas[id] = next!.meta;
    }
  }

  /// Whether the file of [page] in [store] exists and holds exactly the page
  /// as it was copied (read back). Any failure to read counts as not intact.
  Future<bool> _sourceIntact(PageStore store, NotedPage page, [String? copiedText]) async {
    try {
      final now = await store.readText(page.id);
      return now == writePage(page) || now == copiedText;
    } on Object {
      return false;
    }
  }

  /// Moves [id] and its subpages to another location: each page file is
  /// written to the target folder and read back to check it, and only when
  /// all of them check out are the source files deleted. On any failure the
  /// target files are removed again and the sources stay as they were. If a
  /// source can't be deleted and an already deleted one can't be put back, that
  /// page keeps its copy at the target and the error names the partial result.
  Future<void> _moveAcross(String id, String toLoc, {String? parentId, int? index}) async {
    final fromLoc = _loc[id]!;
    _assertWritable(fromLoc);
    _assertWritable(toLoc);
    final fromStore = _storeOf(fromLoc);
    final toStore = _storeOf(toLoc);
    // The page and the subpages stored with it (standalone folders share a
    // tree, so a subpage kept in another folder stays where it is).
    final tree = _treeOf(fromLoc);
    final ids = <String>[id];
    void collect(String parent) {
      for (final c in tree.childrenOf(parent)) {
        if (_loc[c.id] != fromLoc) continue;
        ids.add(c.id);
        collect(c.id);
      }
    }

    collect(id);
    final reopen = ids.contains(currentId) ? currentId : null;
    // The pages are busy until each has settled (3.7).
    await _guardKept(
      ids,
      fromLoc,
      'moving',
      "Noted is still trying to save this page, so it can't be moved yet.",
    );
    final rekeys = <_Rekey>[];
    final atDest = <String>{}; // pages that ended at the target
    // Closing or flushing writes pending edits, so the copies read below are
    // current.
    try {
      if (reopen != null) {
        await _closeCurrent();
      } else {
        await flush();
      }
    } on Object {
      for (final p in ids) {
        _free(p, _busyMoving);
      }
      rethrow;
    }
    Object? pending; // what the move is failing with, for the reopen below
    NotebookException? notice; // the move worked; there is something to tell
    String? attachmentsNote;
    var movedFully = false; // the pages are at the target; only placing is left
    try {
      // The text of each source as it was copied: the generation that must
      // still be there when the source is deleted.
      final copiedText = <String>[];
      final originals = <NotedPage>[];
      for (final p in ids) {
        final before = await fromStore.readText(p);
        if (readPage(before).id != p) {
          throw const NotebookException('This page could not be moved: it holds a different page.');
        }
        final page = await fromStore.load(p);
        if (await fromStore.readText(p) != before) {
          throw const NotebookException('A page changed while it was being read, so nothing was moved.');
        }
        copiedText.add(before);
        originals.add(page);
      }
      // Only the moved page's parent and order change; its subpages keep
      // theirs.
      final moved = [
        for (var i = 0; i < originals.length; i++)
          i == 0
              ? originals[i].withMeta(
                  originals[i].meta.withPlacement(
                    parentId: parentId,
                    order: _treeOf(toLoc).nextOrder(parentId),
                  ),
                )
              : originals[i],
      ];

      // Only what this move published: a page file it created (never one that
      // was already there) and the attachment files and folders it created.
      final written = <String>[];
      final writtenText = <String, String>{}; // the file text published, by page
      final copies = <String, AttachmentCopy>{}; // the attachments copied, by page
      // Copies a rollback kept because they are no longer what this move
      // published (or could not be checked): never deleted (0124).
      final keptCopies = <String>[];
      // Removes only what this move published, and only while it still holds
      // exactly that: a destination file or attachment that changed since is
      // kept and reported (see keptCopiesNote).
      Future<void> removeCopies() async {
        for (final w in written) {
          try {
            final r = await _deleteIfUnchanged(toLoc, w, writtenText[w]!);
            if (!r.deleted && r.outcome != DeleteOutcome.absent) keptCopies.add('page file of $w');
          } on Object catch (e) {
            debugPrint('Removing copy of page $w failed: $e');
            keptCopies.add('page file of $w');
          }
          if (!await removeCreated(copies[w])) keptCopies.add('attachments of $w');
        }
      }

      // Damaged or incomplete files this move set aside in the target, and files
      // it left alone because they were changing: said however the move ends, so
      // a kept `.damaged-` file is always named.
      String keptFilesNote() {
        final all = AttachmentCopy();
        for (final c in copies.values) {
          all.damagedKept.addAll(c.damagedKept);
          all.stillChanging.addAll(c.stillChanging);
        }
        final lines = _copyNotices(all, _placeName(toLoc), _placeName(fromLoc));
        return lines.isEmpty ? '' : ' ${lines.join(' ')}';
      }

      String keptCopiesNote() =>
          (keptCopies.isEmpty
              ? ''
              : ' Some of the copies made for the move in ${_placeName(toLoc)} were kept, because they '
                    'changed after they were made or could not be checked; you can delete what you do '
                    'not need.') +
          keptFilesNote();
      NotebookException withKept(NotebookException e) {
        final note = keptCopiesNote();
        return note.isEmpty ? e : NotebookException('${e.message}$note', needsAction: true);
      }

      try {
        for (final p in moved) {
          if (!await _writeNew(toLoc, p)) {
            throw NotebookException(
              '${_placeName(toLoc)} already has a file for this page, so it was not moved. The '
              'existing file was left as it is, and the page stays where it was. Move or delete '
              'the file in ${_placeName(toLoc)} if you want to move the page there.',
              needsAction: true,
            );
          }
          written.add(p.id);
          writtenText[p.id] = writePage(p);
          final readBack = await toStore.readText(p.id);
          if (readBack != writePage(p)) {
            throw const NotebookException(
              'A page was not copied correctly, so nothing was moved.',
            );
          }
          // Its images and files go with it.
          await _copyDir(
            _assetsDir(fromLoc, p.id),
            _assetsDir(toLoc, p.id),
            into: copies[p.id] = AttachmentCopy(),
          );
        }
      } on Object catch (e) {
        await removeCopies();
        if (e is NotebookException) throw withKept(e);
        debugPrint('Copying the page to its new place failed: $e');
        throw withKept(NotebookException('Could not move the page.${_osReason(e)}'));
      }

      // Kept changes go with their pages: the new key is written (and read
      // back) before the stale-source check and before any source is deleted;
      // the old key stays until each page has settled (build note 9).
      try {
        rekeys.addAll(await _rekeyBegin(ids, fromStore, toStore, fromLoc, toLoc));
      } on NotebookException catch (e) {
        await removeCopies();
        throw withKept(e);
      }
      await syncHook?.call('move-rekeyed', toStore.directory.path);
      // Every source is checked before any is deleted. One that changed (or
      // can't be read) since it was copied stops the move: nothing is deleted,
      // and this move's own verified copies are dropped. A source that is gone
      // (its folder is still there) is different: its copy is then the only
      // one of the page and is never dropped, so the check does not stop the
      // move; the delete step below handles every page, vanished or not, and
      // reports what really happened.
      final stale = <int>[];
      final unreadable = <int>[];
      final vanished = <int>{};
      for (var i = 0; i < ids.length; i++) {
        try {
          if (await fromStore.readText(ids[i]) != copiedText[i]) stale.add(i);
        } on Object {
          // Gone only if the folder itself is still there; a missing folder or
          // drive can't be told from a missing page, so it stops the move.
          if (fromStore.directory.existsSync() &&
              FileSystemEntity.typeSync(fromStore.pathFor(ids[i]), followLinks: false) ==
                  FileSystemEntityType.notFound) {
            vanished.add(i);
          } else {
            unreadable.add(i);
          }
        }
      }
      if (!fromStore.directory.existsSync() && unreadable.isNotEmpty) {
        // The folder itself is gone (moved away, a drive that left): nothing
        // there can be checked or removed, and the copies are then the only
        // ones. They are kept, and the pages count as being in the target.
        for (final p in moved) {
          // The source files are gone from the app's view, as after a delete.
          final key = _key(fromStore.pathFor(p.id));
          _known.remove(key);
          _pathId.remove(key);
          _conflicts.remove(p.id);
          _metas[p.id] = p.meta;
          _loc[p.id] = toLoc;
        }
        atDest.addAll(ids); // after the new key is read back, in the settlement
        _touch(fromLoc);
        _touch(toLoc);
        _rebuildTree();
        final src = _placeName(fromLoc);
        final withAssets = [for (final p in ids) if (copies[p]?.sourceExisted ?? false) p];
        final stayed = [for (final c in copies.values) ...c.differing];
        throw NotebookException(
          '$src is not available right now, so the old ${ids.length == 1 ? 'file' : 'files'} could not be '
          'checked or removed. The ${ids.length == 1 ? 'page was' : 'pages were'} copied to '
          '${_placeName(toLoc)} and kept there'
          '${withAssets.isEmpty ? '' : ', with ${withAssets.length == 1 ? 'its attachments' : 'the attachments of ${withAssets.length} pages'}'}'
          '${stayed.isEmpty ? '' : ' (${stayed.length == 1 ? 'one attachment file' : '${stayed.length} attachment files'} '
              'could not be copied because ${_placeName(toLoc)} already has different ones)'}. '
          'If $src comes back with the old ${ids.length == 1 ? 'page' : 'pages'}, delete the '
          '${ids.length == 1 ? 'one' : 'ones'} you do not need.'
          '${keptFilesNote()}',
          needsAction: true,
        );
      }
      if (vanished.isEmpty && (stale.isNotEmpty || unreadable.isNotEmpty)) {
        await removeCopies();
        String label(int i) {
          final t = originals[i].meta.title.trim();
          return '"${t.isEmpty ? 'Untitled' : t}"';
        }

        final source = _placeName(fromLoc);
        String list(List<int> l) => l.map(label).join(', ');
        String it(List<int> l) => l.length == 1 ? 'it' : 'them';
        throw NotebookException(
          [
            'Nothing was moved.',
            if (stale.isNotEmpty)
              '${list(stale)} ${stale.length == 1 ? 'has' : 'have'} a newer version in $source, so '
                  '${stale.length == 1 ? 'it was' : 'they were'} left there and the copy made for the move was dropped.',
            if (unreadable.isNotEmpty)
              '${list(unreadable)} could not be read in $source to check ${it(unreadable)}, so '
                  '${unreadable.length == 1 ? 'it stays' : 'they stay'} where '
                  '${unreadable.length == 1 ? 'it was' : 'they were'}.',
            if (!stale.contains(0) && !unreadable.contains(0)) '${label(0)} stayed where it was.',
          ].join(' ') + keptCopiesNote(),
          needsAction: true,
        );
      }

      final removed = <int>[];
      final changedNow = <int>{}; // found changed by the compare-and-delete
      try {
        for (var i = 0; i < ids.length; i++) {
          // Only the generation that was copied is deleted: the file is set
          // aside, compared and only then removed, so a version that arrives
          // after the check above is kept (and the classification below
          // reports it).
          final r = await _deleteIfUnchanged(fromLoc, ids[i], copiedText[i]);
          if (r.outcome == DeleteOutcome.absent) {
            vanished.add(i); // never restored: it was removed by someone else
            continue;
          }
          if (!r.deleted) {
            changedNow.add(i);
            throw const NotebookException('A page changed during the move.');
          }
          removed.add(i);
        }
      } on Object catch (e) {
        // Classify each page by what is at its source now. The source file is
        // never written over: a page we deleted is put back only if nothing
        // exists at its path.
        //  intact: the source holds exactly what was copied; the copy goes.
        //  gone:   no source and none can be put back; the copy is the page.
        //  both:   a source exists but can't be verified or differs (an
        //          external edit, another line ending, a locked file); both
        //          stay and nothing about the page changes.
        // A page's chosen file keeps its own name: the store dropped the path
        // of a file it deleted, so the checks and the restore below would
        // otherwise look at `<id>.canvas`, which may be another file.
        for (final p in ids) {
          final c = _adoptedFiles[p];
          if (c != null && _key(File(c).parent.path) == _key(fromStore.directory.path)) fromStore.adopt(p, c);
        }
        final intact = <int>[];
        final gone = <int>[];
        final both = <int>[];
        // changed: a newer version arrived after the check; it stays, and this
        // move's own copy of the older one is dropped.
        final changed = <int>[];
        final appeared = <int>{}; // a file appeared at the old path during the restore
        Future<bool> absent(int i) async =>
            await FileSystemEntity.type(fromStore.pathFor(ids[i])) == FileSystemEntityType.notFound;
        for (var i = 0; i < ids.length; i++) {
          if (await _sourceIntact(fromStore, originals[i], copiedText[i])) {
            intact.add(i);
            continue;
          }
          if (removed.contains(i) && await absent(i)) {
            // An exclusive save: the page is published only if nothing is at
            // its path at that moment, so a file that appears in the meantime
            // is never written over (the page is then in both places).
            try {
              if (!await _restoreText(fromLoc, originals[i], copiedText[i], beforePublish: restoreBeforePublishHook)) {
                appeared.add(i);
                debugPrint('Restoring page ${ids[i]}: a file appeared at its old path, keeping both');
              }
            } on Object catch (e2) {
              debugPrint('Restoring page ${ids[i]} failed: $e2');
            }
            if (await _sourceIntact(fromStore, originals[i], copiedText[i])) {
              intact.add(i);
              continue;
            }
          }
          if (await absent(i)) {
            gone.add(i);
          } else if (changedNow.contains(i)) {
            changed.add(i);
          } else {
            both.add(i);
          }
        }
        // Remove the copy of an intact page: the page file and its attachments
        // each get their own try, and a failure keeps that page in both places.
        final copyLeft = <int, String>{};
        for (final i in [...intact, ...changed]) {
          try {
            // Only the file this move published, and only while it still holds
            // exactly that: a copy that changed since is kept, and reported.
            final r = await _deleteIfUnchanged(toLoc, ids[i], writtenText[ids[i]]!);
            if (!r.deleted && r.outcome != DeleteOutcome.absent) {
              debugPrint('The copy of page ${ids[i]} changed after the move made it, keeping it');
              copyLeft[i] = 'the page file';
            }
          } on Object catch (e2) {
            debugPrint('Removing copy of page ${ids[i]} failed: $e2');
            copyLeft[i] = 'the page file';
          }
          // Only what this move copied, never an attachments folder (or a file
          // in it) that was at the target before.
          if (!await removeCreated(copies[ids[i]])) {
            debugPrint('Removing the attachments of page ${ids[i]} at the target failed');
            copyLeft[i] = copyLeft.containsKey(i) ? 'the page file and its attachments' : 'its attachments';
          }
        }
        if (gone.isEmpty && both.isEmpty && changed.isEmpty && copyLeft.isEmpty) {
          debugPrint('Removing the old page files failed: $e');
          throw withKept(NotebookException('Could not remove the old files, so nothing was moved.${_osReason(e)}'));
        }
        // Only a page with no source moves. A page whose parent ended up in
        // the other location goes to the top level of its own (0059).
        final movedIdx = gone.toSet();
        atDest.addAll([for (final i in movedIdx) ids[i]]);
        final idIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
        for (final i in movedIdx) {
          _metas[ids[i]] = moved[i].meta;
          _loc[ids[i]] = toLoc;
        }
        // Standalone folders share one tree: a page whose parent is in the
        // other folder keeps it. A page kept in both places is not changed
        // at all, so the tree and its file agree.
        final shareTree = _isStandaloneLoc(fromLoc) && _isStandaloneLoc(toLoc);
        for (var i = 0; i < ids.length && !shareTree; i++) {
          if (both.contains(i) || changed.contains(i)) continue;
          final parent = moved[i].meta.parentId;
          final pi = parent == null ? null : idIndex[parent];
          if (pi == null || movedIdx.contains(i) == movedIdx.contains(pi)) continue;
          final loc = movedIdx.contains(i) ? toLoc : fromLoc;
          final fixed = moved[i].withMeta(
            moved[i].meta.withPlacement(parentId: null, order: _treeOf(loc).nextOrder(null)),
          );
          // Saved too, unless the file is one whose content wasn't verified.
          if (movedIdx.contains(i) || intact.contains(i)) {
            try {
              // Over exactly the text that was verified there, checked at the
              // moment of replacing; a file that changed since stays as it is.
              final known = movedIdx.contains(i)
                  ? {writtenText[ids[i]]}
                  : {copiedText[i], writePage(originals[i])};
              final now = await _storeOf(loc).readText(ids[i]);
              if (known.contains(now) && await _writeIfUnchanged(loc, fixed, now)) {
                _metas[ids[i]] = fixed.meta; // only when it landed
              } else {
                debugPrint('Moving page ${ids[i]} to the top level: its file changed, left as it is');
              }
            } on Object catch (e2) {
              debugPrint('Moving page ${ids[i]} to the top level failed: $e2');
            }
          }
        }
        _touch(fromLoc);
        _touch(toLoc);
        _rebuildTree();
        String titleOf(int i) {
          final t = originals[i].meta.title.trim();
          return t.isEmpty ? 'Untitled' : t;
        }

        String place(String loc) => _binders[loc]?.title ?? (loc == _standalone ? 'Pages' : loc);
        final target = place(toLoc);
        final source = place(fromLoc);
        // Pages with the same title are told apart by their parent or place.
        final titleCount = <String, int>{};
        for (var i = 0; i < ids.length; i++) {
          titleCount.update(titleOf(i), (n) => n + 1, ifAbsent: () => 1);
        }
        String name(int i) {
          final t = titleOf(i);
          if (titleCount[t]! < 2) return '"$t"';
          final parent = originals[i].meta.parentId;
          final pi = parent == null ? null : idIndex[parent];
          return pi != null
              ? '"$t" (subpage of "${titleOf(pi)}")'
              : '"$t" (top level of $source)';
        }

        String names(Iterable<int> l) => l.map(name).join(', ');
        debugPrint('The move was only partly done: $e');
        final parts = <String>[];
        if (gone.isNotEmpty) {
          final goneGone = gone.where(vanished.contains).toList();
          final goneOther = gone.where((i) => !vanished.contains(i)).toList();
          if (goneGone.isNotEmpty) {
            parts.add(
              '${names(goneGone)} ${goneGone.length == 1 ? 'was' : 'were'} no longer in $source, so '
              '${goneGone.length == 1 ? 'it is' : 'they are'} kept in $target.',
            );
          }
          if (goneOther.isNotEmpty) {
            parts.add(
              '${names(goneOther)} ${goneOther.length == 1 ? 'is' : 'are'} now in $target; the old '
              '${goneOther.length == 1 ? 'file' : 'files'} could not be put back.',
            );
          }
        }
        final appearedIdx = both.where(appeared.contains).toList();
        final bothOther = both.where((i) => !appeared.contains(i)).toList();
        if (appearedIdx.isNotEmpty) {
          parts.add(
            'Another file appeared at the old place of ${names(appearedIdx)} in $source, so it was '
            'left alone; the page ${appearedIdx.length == 1 ? 'is' : 'pages are'} in $target. One of the two '
            'will show under "Can\'t open" until you delete the other.',
          );
        }
        if (bothOther.isNotEmpty) {
          parts.add(
            '${names(bothOther)} ${bothOther.length == 1 ? 'is' : 'are'} kept in both places. The old '
            '${bothOther.length == 1 ? 'file' : 'files'} in $source could not be checked or '
            '${bothOther.length == 1 ? 'has' : 'have'} changed, so nothing was deleted; the '
            '${bothOther.length == 1 ? 'copy is' : 'copies are'} in $target. One of the two will show '
            'under "Can\'t open" until you delete the other.',
          );
        }
        if (copyLeft.isNotEmpty) {
          parts.add(
            [
              for (final en in copyLeft.entries)
                if (en.value == 'its attachments')
                  '${name(en.key)} stayed where it was, but a leftover attachments folder remains '
                      'in $target. You can delete it.'
                else
                  'The copy of ${name(en.key)} in $target (${en.value}) could not be removed, so it '
                      'is kept in both places. One of the two will show under "Can\'t open" until '
                      'you delete the other.',
            ].join(' '),
          );
        }
        final changedOk = changed.where((i) => !copyLeft.containsKey(i)).toList();
        if (changedOk.isNotEmpty) {
          parts.add(
            '${names(changedOk)} ${changedOk.length == 1 ? 'was' : 'were'} not moved: a newer version of '
            '${changedOk.length == 1 ? 'it' : 'them'} is in $source, so ${changedOk.length == 1 ? 'it was' : 'they were'} '
            'left there and the copy made for the move was dropped.',
          );
        }
        final stayed = intact.where((i) => !copyLeft.containsKey(i)).toList();
        if (stayed.isNotEmpty) {
          parts.add('${names(stayed)} stayed where ${stayed.length == 1 ? 'it was' : 'they were'}.');
        }
        throw NotebookException(
          '${gone.isEmpty && both.isEmpty && copyLeft.isEmpty ? 'The page was not moved.' : 'The move was only partly done.'} '
          '${parts.join(' ')}${keptFilesNote()}',
          needsAction: both.isNotEmpty || copyLeft.isNotEmpty || changed.isNotEmpty,
        );
      }
      atDest.addAll(ids);
      await syncHook?.call('move-source-deleted', fromStore.directory.path);
      // Only the attachment files that were copied and verified go from the
      // source; a file that arrived there after the copy, or whose target
      // differs, stays.
      for (final id in ids) {
        final copy = copies[id];
        if (copy != null) await removeVerifiedSources(copy, _assetsDir(fromLoc, id));
      }
      // Files that stayed because the target holds something else.
      final differing = [for (final c in copies.values) ...c.differing];
      final keptAside = [for (final c in copies.values) ...c.keptAside];
      final damagedKept = [for (final c in copies.values) ...c.damagedKept];
      final stillChanging = [for (final c in copies.values) ...c.stillChanging];
      attachmentsNote = differing.isEmpty && keptAside.isEmpty && damagedKept.isEmpty && stillChanging.isEmpty
          ? null
          : _attachmentsNote(
              differing,
              keptAside,
              _placeName(toLoc),
              _placeName(fromLoc),
              damagedKept: damagedKept,
              stillChanging: stillChanging,
            );

      for (final p in moved) {
        _metas[p.id] = p.meta;
        _loc[p.id] = toLoc;
      }
      _touch(fromLoc);
      _touch(toLoc);
      _rebuildTree();
      movedFully = true;
      // Said together with a failed placement, so neither hides the other.
      notice = attachmentsNote == null
          ? null
          : NotebookException('The page was moved, but $attachmentsNote', needsAction: true);
      if (index != null) await move(id, parentId: parentId, index: index);
      if (notice != null) throw notice;
    } on Object catch (e) {
      // Only a NotebookException leaves here, so the user always sees a message.
      if (e is! NotebookException) debugPrint('Moving the page failed: $e');
      final out = identical(e, notice)
          ? notice!
          : movedFully
          ? NotebookException(
              'The page was moved, but it could not be put at that position.'
              '${notice == null ? '' : ' Also, $attachmentsNote'}',
              needsAction: notice != null,
            )
          : e is NotebookException
          ? e
          : NotebookException('Could not move the page.${_osReason(e)}');
      pending = out;
      throw out;
    } finally {
      // A page that ended at the target keeps its chosen file there (its file
      // in the source is gone), so the target's file is not listed as a
      // duplicate of a file that no longer exists.
      for (final p in atDest) {
        final c = _adoptedFiles[p];
        if (c == null || _key(File(c).parent.path) != _key(fromStore.directory.path)) continue;
        final dest = toStore.pathFor(p);
        _adoptedFiles[p] = dest;
        _goneChosen.remove(p);
        fromStore.unadopt(p);
        toStore.adopt(p, dest);
      }
      // Every page settles before the reopen; it leaves busy only after.
      await _settleRekeys(rekeys, atDest);
      for (final p in ids) {
        _free(p, _busyMoving);
      }
      if (reopen != null && _current == null && _loc.containsKey(reopen)) {
        try {
          await open(reopen);
        } on Object catch (e) {
          // A failure to reopen never hides what happened to the move, and
          // nothing but a NotebookException leaves here.
          debugPrint('Reopening page $reopen after the move failed: $e');
          final p = pending;
          if (p is NotebookException) {
            // ignore: control_flow_in_finally
            throw NotebookException(
              '${p.message} The page could not be reopened.${_osReason(e)}',
              needsAction: p.needsAction,
            );
          } else if (p == null) {
            // ignore: control_flow_in_finally
            throw NotebookException('The page was moved, but it could not be reopened.${_osReason(e)}');
          }
        }
      }
    }
  }

  // Binders -----------------------------------------------------------------

  // Refuses a change of the binder or folder list while it can't be trusted
  // (see [_settingsHeld]). Called before the change's first await, picker or
  // folder creation. Unless the launch read is still settling, a refusal also
  // starts a retry of the read, which it never waits for.
  void _refuseWhileHeld() {
    final held = _settingsHeld;
    if (held == null) return;
    if (held == _SettingsHold.pending) {
      throw const NotebookException('Noted is still loading its binder list. Try again in a moment.');
    }
    unawaited(retrySettings());
    throw const NotebookException("Noted can't read its binder list right now. Try again in a moment.");
  }

  /// Creates a binder at once in a new subfolder of the default binder
  /// folder ([defaultBinderFolderPath]) named after [name] (see
  /// [binderFolderName]; a number is added if the folder exists), shows its
  /// cover and asks for its title field to take focus.
  ///
  /// The built-in default folder is created if it is missing. A default
  /// folder the user chose is never created: a missing one throws a
  /// [NotebookException].
  Future<BinderSection> createBinder({String name = 'New binder'}) async {
    _refuseWhileHeld();
    final path = await _newBinderFolder(name);
    try {
      return _showNewBinder(await addBinder(path));
    } on FileSystemException catch (e) {
      throw NotebookException('Could not create the binder: ${e.message}');
    }
  }

  /// Creates a binder at once from the binder template [template], like
  /// [createBinder]: in a new subfolder of the default binder folder named
  /// after the template (numbered if taken), with no folder picker. Its
  /// cover opens with the title field focused. If the binder can't be
  /// written, the new folder is removed again.
  Future<BinderSection> createBinderFromTemplateInDefault(NotedTemplate template) async {
    _refuseWhileHeld();
    final path = await _newBinderFolder(template.name);
    try {
      return _showNewBinder(await createBinderFromTemplate(template, path, openCover: false));
    } on Object {
      try {
        final dir = Directory(path);
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } on FileSystemException catch (e) {
        debugPrint('Removing the empty binder folder failed: ${e.message}');
      }
      rethrow;
    }
  }

  /// Shows a binder just created by the user: its cover, with the title field
  /// asked to take focus.
  BinderSection _showNewBinder(BinderSection section) {
    if (section.available) {
      requestTitleFocus('cover:${section.path}');
      showCover(section.path);
    }
    return section;
  }

  /// Creates and returns a new, empty subfolder of the default binder folder
  /// named after [name] (see [binderFolderName]): "Name", or "Name 2",
  /// "Name 3" … if that is taken by a listed binder or anything on disk.
  ///
  /// The built-in default folder is created if it is missing. A default
  /// folder the user chose is never created: a missing one throws a
  /// [NotebookException].
  Future<String> _newBinderFolder(String name) async {
    final root = defaultBinderFolderPath;
    if (_pullOnly(root)) throw const NotebookException(_pullOnlyMessage);
    final builtin = settings?.defaultBinderFolder == null || _key(root) == _key(builtinBinderFolderPath);
    try {
      if (builtin) {
        await Directory(root).create(recursive: true);
      } else if (!await Directory(root).exists()) {
        throw const NotebookException(
          'The default binder folder was not found. Choose another one in Settings.',
        );
      }
      final base = binderFolderName(name);
      for (var n = 1;; n++) {
        final path = _normalizePath(
          '$root${Platform.pathSeparator}${n == 1 ? base : '$base $n'}',
        );
        if (_binders.keys.any((b) => _key(b) == _key(path)) ||
            await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
          continue;
        }
        await Directory(path).create();
        return path;
      }
    } on FileSystemException catch (e) {
      throw NotebookException('Could not create the binder: ${e.message}');
    }
  }

  /// Asks for a folder with [pickFolder] and adds it as a binder (see
  /// [addBinder]), then shows its cover. A folder that has a binder is
  /// opened. Returns null if cancelled.
  Future<BinderSection?> newBinderInFolder() async {
    _refuseWhileHeld();
    final pick = pickFolder;
    if (pick == null) return null;
    final path = await pick();
    if (path == null) return null;
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  /// Asks for a folder with [pickFolder] and opens the binder in it, then
  /// shows its cover. A folder without a binder file is refused. Returns
  /// null if cancelled.
  Future<BinderSection?> openBinder() async {
    _refuseWhileHeld();
    final pick = pickFolder;
    if (pick == null) return null;
    final path = await pick();
    if (path == null) return null;
    if (!await BinderStore(Directory(_normalizePath(path))).file.exists()) {
      throw const NotebookException('That folder has no binder. Use "New binder in another folder…" to make one.');
    }
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  /// Sets the default page folder: the folder must exist and not hold a
  /// binder. It becomes a standalone folder in use (so its pages are listed),
  /// and new top-level pages go there. Pages in the old default stay listed.
  Future<void> setDefaultPageFolder(String path) async {
    final s = settings;
    if (s == null) return;
    final normal = await checkStandaloneFolder(path);
    await addStandaloneFolder(normal);
    s.defaultPageFolder = normal;
    notifyListeners();
  }

  /// Sets the default binder folder, which must exist.
  Future<void> setDefaultBinderFolder(String path) async {
    final s = settings;
    if (s == null) return;
    final normal = _normalizePath(path);
    if (!await Directory(normal).exists()) {
      throw const NotebookException('That folder was not found.');
    }
    s.defaultBinderFolder = normal;
    notifyListeners();
  }

  /// Moves the page [id] and its subpages to the standalone folder [path]
  /// (made a standalone folder in use), as a top-level page there. Uses the
  /// same copy, verify, delete algorithm as other moves; throws a
  /// [NotebookException] on failure with the sources left in place. A binder
  /// folder is refused. Returns false if the page is in that folder already.
  Future<bool> moveToFolder(String id, String path) async {
    final from = _loc[id];
    if (from == null) return false;
    final to = await addStandaloneFolder(path);
    if (to == from) return false;
    await _moveAcross(id, to, parentId: null);
    return true;
  }

  /// Adds the folder [path] to the binders. A folder that already has a
  /// binder file is opened as it is; otherwise a binder file is created in
  /// it and the page files already there become its pages.
  ///
  /// A folder that holds a copy of a binder already listed (the same binder
  /// id) is refused with a [NotebookException].
  Future<BinderSection> addBinder(String path) async => (await addBinderChecked(path)).section;

  /// [addBinder] that also says whether this call listed the binder (`added`)
  /// and whether its id had been removed from the list before (`wasRemoved`,
  /// for a caller that takes the binder out again: see [removeBinder]).
  Future<({BinderSection section, bool added, bool wasRemoved})> addBinderChecked(String path) async {
    path = _normalizePath(path);
    final known = _binders[path];
    if (known != null) return (section: known, added: false, wasRemoved: false);
    _refuseWhileHeld();
    if (path == defaultFolderPath || _folders.containsKey(path)) {
      throw const NotebookException('That folder holds the standalone pages.');
    }
    // A binder file is never made in a pull-only folder (opening one is fine).
    if (_pullOnly(path) && !await BinderStore(Directory(path)).file.exists()) {
      throw const NotebookException(_pullOnlyMessage);
    }
    await flush();
    final r = await _queued(() => _listBinder(path, found: false));
    if (r == null) throw const NotebookException('Noted is closing.');
    final refused = r.refused;
    if (refused != null) throw NotebookException(refused);
    return (section: r.section!, added: r.added, wasRemoved: r.wasRemoved);
  }

  // Runs [body] as one `_checking` job (after the writes in flight), the way
  // the folder checks do. Null if the notebook was disposed first.
  Future<T?> _queued<T>(Future<T> Function() body) {
    final done = Completer<T?>();
    final job = _checking.then((_) async {
      try {
        await _chain.idle;
        if (_disposed) {
          done.complete(null);
        } else {
          done.complete(await body());
        }
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    _checking = job;
    return done.future;
  }

  // Lists the binder in [path]: one step for a hand add (Open binder…, New
  // binder in another folder…) and for a binder discovery found. Runs inside
  // `_checking`. A found binder never creates a file or folder, never sweeps
  // set-aside files and is listed only if it still is the binder [expectId].
  Future<({BinderSection? section, bool added, bool wasRemoved, String? refused})> _listBinder(
    String path, {
    required bool found,
    String? expectId,
  }) async {
    final key = _key(path);
    ({BinderSection? section, bool added, bool wasRemoved, String? refused}) none({String? refused}) =>
        (section: null, added: false, wasRemoved: false, refused: refused);
    // Already there, or a copy of a binder listed from another folder.
    final listedHere = _binders.values.where((b) => _key(b.path) == key).firstOrNull;
    if (listedHere != null) return (section: listedHere, added: false, wasRemoved: false, refused: null);
    final read = await BinderStore(Directory(path)).read();
    if (found && (read is! BinderFound || read.binder.id != expectId)) return none();
    if (read is BinderFound) {
      final id = read.binder.id;
      final holder = _binders.values.where((b) => _binderIds[_key(b.path)] == id).firstOrNull;
      if (holder != null) {
        final text = holder.available
            ? 'This folder holds a copy of binder "${holder.title}", which is listed from ${holder.path}.'
            : '"${holder.title}" is listed but not found at its old folder. '
                  'Remove it from the sidebar first, then open this folder.';
        return none(refused: text);
      }
    }
    await _binderSeam('recheck', path);
    final wasRemoved = _removedBinders.contains(expectId ?? (read is BinderFound ? read.binder.id : ''));
    if (found) {
      _foundAdds[key] = [];
      _sweepOff++;
    }
    try {
      final section = await _openBinder(path, create: !found, createFolder: !found, sweep: !found);
      final id = section.binder?.id;
      if (found && (!section.available || id != expectId)) {
        _undoOpen(path);
        return none();
      }
      await _binderSeam('opened', path);
      _binders[path] = section;
      _recordBinderId(path, section.binder);
      _rebuildTree();
      _syncWatchers();
      await _saveSettings();
      if (!await _reconcileAdded(path, found: found, expectId: expectId)) {
        return none();
      }
      final now = _binders[path];
      if (now != null && now.available && !_isLocked(path)) {
        await _mergePendingCopies(inQueue: true);
        if (!_disposed && _binders[path] == now && now.available) await _recoverPending(onlyLoc: path);
      }
      return (section: _binders[path] ?? section, added: true, wasRemoved: wasRemoved, refused: null);
    } finally {
      if (found) {
        _foundAdds.remove(key);
        _sweepOff--;
      }
    }
  }

  // Takes back what [_openBinder] noted in memory for a folder that was not
  // listed after all.
  void _undoOpen(String path) {
    final key = _key(path);
    for (final id in [for (final e in _loc.entries) if (e.value == path) e.key]) {
      _forgetPage(id);
    }
    _binderText.remove(key);
    _pendingCopies.removeWhere((p) => _key(File(p).parent.path) == key);
  }

  // The page files and the binder file may have changed between the scan of
  // [path] and the start of its watcher, which saw nothing: looks again, as a
  // watcher event would. False if a found binder turned out to be another one
  // and was taken out again.
  Future<bool> _reconcileAdded(
    String path, {
    required bool found,
    String? expectId,
  }) async {
    final section = _binders[path];
    if (section == null) return true;
    try {
      // The binder file first, before any page is reconciled or written.
      await _checkBinderFile(BinderStore(Directory(path)).file.path);
      final now = _binders[path];
      if (_disposed) return true;
      // Another binder at the folder, or no binder file any more: the found add
      // is undone (nothing was listed for good). Only the removed ids this add
      // took out are put back; anything recorded meanwhile stays.
      if (found &&
          now != null &&
          ((now.binder != null && now.binder!.id != expectId) || now.status == BinderStatus.unavailable)) {
        _binders.remove(path);
        _binderIds.remove(_key(path));
        for (final id in _foundAdds[_key(path)] ?? const <String>[]) {
          if (!_removedBinders.contains(id)) _removedBinders.add(id);
        }
        _undoOpen(path);
        if (_coverPath == path) _coverPath = null;
        _rebuildTree();
        _syncWatchers();
        await _saveSettings();
        return false;
      }
      if (now == null || !identical(now, _binders[path])) return true;
      // Then the pages: what is listed there now, what the notebook knows of it
      // and what its "Can't open" list holds.
      final seen = <String>{};
      final paths = <String>[];
      void add(String p) {
        if (seen.add(_key(p))) paths.add(p);
      }

      try {
        await for (final f in Directory(path).list(followLinks: false)) {
          if (f is File && f.path.endsWith(PageStore.extension)) add(f.path);
        }
      } on FileSystemException catch (e) {
        debugPrint('Listing $path failed: $e');
      }
      final st = now.store;
      if (st != null) {
        for (final e in _loc.entries.toList()) {
          if (e.value == path) add(st.pathFor(e.key));
        }
      }
      for (final u in now.unreadable.toList()) {
        add(u.path);
      }
      for (final p in paths) {
        if (_disposed || !identical(_binders[path], now)) break;
        try {
          if (p.endsWith(PageStore.extension)) {
            await _checkFile(p);
          } else if (await FileSystemEntity.type(p, followLinks: false) == FileSystemEntityType.notFound) {
            // A set-aside file that has gone (put back, or deleted by its writer).
            _dropUnreadable(path, p);
          }
        } on Object catch (e) {
          debugPrint('Checking $p failed: $e');
        }
      }
      return true;
    } finally {
      // (sweeping stays off for the whole found add: see _listBinder)
    }
  }

  // Standalone folders ---------------------------------------------------------

  /// Checks that [path] can hold standalone pages and returns it in its
  /// normal form. Throws [NotebookException] for a folder that is a binder
  /// (listed, or with a binder file).
  Future<String> checkStandaloneFolder(String path) async {
    path = _normalizePath(path);
    final isBinder =
        _binders.keys.any((b) => _key(b) == _key(path)) ||
        await BinderStore(Directory(path)).file.exists();
    if (isBinder) {
      throw const NotebookException(
        'That folder holds a binder. Choose another folder for standalone pages.',
      );
    }
    if (!await Directory(path).exists()) {
      throw const NotebookException('That folder was not found.');
    }
    return path;
  }

  /// Makes [path] a folder of standalone pages and remembers it. Returns the
  /// location key: '' for the default folder. Does nothing if the folder is
  /// known already. Throws [NotebookException] if the folder can't be used
  /// (see [checkStandaloneFolder]).
  Future<String> addStandaloneFolder(String path) async {
    path = _normalizePath(path);
    if (_key(path) == _key(defaultFolderPath)) return _standalone;
    final known = _folders.keys.where((f) => _key(f) == _key(path)).firstOrNull;
    if (known != null) {
      if (_folders[known]!.available) return known;
      throw NotebookException(_pullOnly(known) ? _pullOnlyMessage : 'That folder is not available.');
    }
    _refuseWhileHeld();
    await checkStandaloneFolder(path);
    await flush();
    final folder = await _openFolder(path);
    if (!folder.available) throw NotebookException(folder.reason ?? 'That folder is not available.');
    _folders[path] = folder;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    await _mergePendingCopies();
    return path;
  }

  /// Takes the folder out of the list. Its files stay where they are.
  // A notice of a page in the folder [loc] that the user removed from the app.
  void _dropLandedIn(String loc) {
    final k = _key(_normalizePath(loc));
    _landedProblems.removeWhere((_, p) => _key(_normalizePath(File(p.path).parent.path)) == k);
  }

  // Forgets the files chosen (or seen missing) in the folder [dir], which is
  // being removed; returns their page ids, for [_promoteDuplicate].
  List<String> _dropAdoptionsIn(String dir) {
    final k = _key(dir);
    final ids = [
      for (final e in _adoptedFiles.entries)
        if (_key(File(e.value).parent.path) == k) e.key,
    ];
    for (final id in ids) {
      _adoptedFiles.remove(id);
      _goneChosen.remove(id);
    }
    return ids;
  }

  Future<void> removeStandaloneFolder(String path) async {
    _refuseWhileHeld();
    final folder = _folders[path];
    _dropLandedIn(path);
    if (folder == null) return;
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId) || _orphanLoc == path;
    if (openHere) await _closeCurrent();
    final released = _dropAdoptionsIn(path);
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    for (final e in _pathId.entries.toList()) {
      if (ids.contains(e.value)) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
    _folders.remove(path);
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    for (final id in released) {
      await _promoteDuplicate(id);
    }
    if (openHere) await _openFallback(_standalone);
  }

  Future<StandaloneFolder> _openFolder(String path) async {
    StandaloneFolder unavailable(String why, {bool missing = false}) =>
        StandaloneFolder._(path, available: false, reason: why, missing: missing);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return unavailable('Folder not found. It may be on another device.', missing: true);
      }
      if (await BinderStore(dir).file.exists()) return unavailable('This folder holds a binder.');
      final pages = storeFactory(dir);
      final entries = await _scan(pages);
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      _takeCopies(path, entries, bad, merge: true);
      for (final e in entries.whereType<ReadablePage>()) {
        if (_metas.containsKey(e.meta.id) || _otherThanChosen(e.meta.id, e.path)) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        _pathId[_key(e.path)] = e.meta.id;
        if (e.conflicted) _conflicts.add(e.meta.id);
      }
      return StandaloneFolder._(path, available: true, store: pages, unreadable: bad);
    } on FileSystemException catch (e) {
      return unavailable('${e.message}${e.path == null ? '' : ': ${e.path}'}');
    }
  }

  // Templates ------------------------------------------------------------------

  /// The folder of app-wide templates, or null if there is no place for it.
  Directory? get appTemplatesDirectory {
    final d = templatesDirectory;
    if (d != null) return d;
    final f = bindersFile;
    return f == null ? null : Directory('${f.parent.path}${Platform.pathSeparator}templates');
  }

  Directory _templatesDirFor(String? binderPath) {
    if (binderPath != null) {
      return Directory('$binderPath${Platform.pathSeparator}templates');
    }
    final d = appTemplatesDirectory;
    if (d == null) throw const NotebookException('There is no folder for app-wide templates.');
    return d;
  }

  /// The templates of [kind] that can be used in the binder [binderPath]
  /// (null: not in a binder): the binder's own and the app-wide ones. Files
  /// that can't be read are listed apart and never touched.
  Future<TemplateListing> listTemplates(TemplateKind kind, {String? binderPath}) async {
    final items = <TemplateItem>[];
    final bad = <UnreadableTemplateItem>[];
    final scopes = <String?>[
      if (binderPath != null && kind == TemplateKind.page) binderPath,
      if (appTemplatesDirectory != null) null,
    ];
    for (final scope in scopes) {
      final entries = await TemplateStore(_templatesDirFor(scope)).scan();
      for (final e in entries) {
        switch (e) {
          case ReadableTemplate():
            if (e.template.kind == kind) items.add(TemplateItem(e.template, e.path, scope));
          case UnreadableTemplate():
            bad.add(UnreadableTemplateItem(e.path, e.reason, scope));
        }
      }
    }
    return TemplateListing(items, bad);
  }

  /// Saves the page [pageId], as it is now, as a template named [name]:
  /// in its binder's templates if [inBinder], otherwise app-wide. Subpages
  /// are not included.
  Future<NotedTemplate> savePageAsTemplate(
    String pageId, {
    required String name,
    bool inBinder = false,
  }) async {
    final loc = _loc[pageId];
    if (loc == null) throw const NotebookException('That page is not available.');
    final binder = binderOfPage(pageId);
    if (inBinder && binder == null) {
      throw const NotebookException('Only a page in a binder can be saved to the binder.');
    }
    if (inBinder) _assertWritable(binder!); // the binder's folder is not written when damaged
    final dir = _templatesDirFor(inBinder ? binder : null);
    await flush();
    final page = await _loadPage(_storeOf(loc), pageId);
    final title = page.meta.title.trim();
    final template = NotedTemplate.forPage(
      name: name.trim().isNotEmpty ? name.trim() : (title.isEmpty ? 'Untitled page' : title),
      page: page,
    );
    await _saveTemplate(dir, template);
    await _copyDirNotify(
      _assetsDir(loc, pageId),
      _templateAssets(dir, template.id, pageId),
      'the template',
      'the page',
    );
    return template;
  }

  /// Where template [templateId] in [dir] keeps the images and files of its
  /// page [pageId]: `<templateId>.assets/<pageId>/` beside the template file.
  static Directory _templateAssets(Directory dir, String templateId, String pageId) => Directory(
    '${dir.path}${Platform.pathSeparator}$templateId.assets${Platform.pathSeparator}$pageId',
  );

  /// Copies the images and files of template page [fromId] into the assets
  /// folder of the new page [toId] in [loc]. The template is looked for in
  /// the binder's templates (if [loc] is a binder) and the app-wide ones.
  Future<void> _copyTemplateAssets(NotedTemplate template, String fromId, String loc, String toId) async {
    final dirs = [
      if (_binders.containsKey(loc)) _templatesDirFor(loc),
      ?appTemplatesDirectory,
    ];
    for (final d in dirs) {
      final src = _templateAssets(d, template.id, fromId);
      if (await src.exists()) {
        await _copyDirNotify(src, _assetsDir(loc, toId), 'the new page', 'the template');
        return;
      }
    }
  }

  /// Saves the settings and whole page tree of the binder [path] as an
  /// app-wide binder template.
  Future<NotedTemplate> saveBinderAsTemplate(String path, {required String name}) async {
    final section = _binders[path];
    final binder = section?.binder;
    final st = section?.store;
    if (section == null || !section.available || binder == null || st == null) {
      throw const NotebookException('That binder is not available.');
    }
    final dir = _templatesDirFor(null);
    await flush();
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    // Parents before children, in tree order.
    final ordered = <String>[];
    void walk(PageMeta p) {
      ordered.add(p.id);
      section.tree.childrenOf(p.id).forEach(walk);
    }

    section.tree.roots.forEach(walk);
    for (final id in ids) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    final pages = [for (final id in ordered) await _loadPage(st, id)];
    final template = NotedTemplate.forBinder(
      name: name.trim().isNotEmpty ? name.trim() : section.title,
      binder: binder,
      pages: pages,
    );
    await _saveTemplate(dir, template);
    for (final id in ordered) {
      await _copyDirNotify(_assetsDir(path, id), _templateAssets(dir, template.id, id), 'the template', 'the binder');
    }
    return template;
  }

  Future<void> _saveTemplate(Directory dir, NotedTemplate template) async {
    try {
      await TemplateStore(dir).save(template);
    } on FileSystemException catch (e) {
      throw NotebookException('Could not save the template: ${e.message}');
    }
  }

  /// Deletes a template file found by [listTemplates].
  Future<void> deleteTemplate(TemplateItem item) async {
    final inBinder = item.binderPath;
    if (inBinder != null && _binders.containsKey(inBinder) && _isLocked(inBinder)) throw NotebookException(_lockedMessage(inBinder));
    if (_pullOnly(File(item.path).parent.path)) throw const NotebookException(_pullOnlyMessage);
    try {
      await TemplateStore(_templatesDirFor(item.binderPath)).delete(item.path);
      final stem = item.path.endsWith(templateExtension)
          ? item.path.substring(0, item.path.length - templateExtension.length)
          : item.path;
      await _removeDir(Directory('$stem.assets'));
    } on FileSystemException catch (e) {
      throw NotebookException('Could not delete the template: ${e.message}');
    }
  }

  /// Creates a page from the page template [template] and opens it, placed
  /// as [createPage] would place it.
  Future<String> createPageFromTemplate(
    NotedTemplate template, {
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) async {
    if (template.kind != TemplateKind.page) {
      throw const NotebookException('That is not a page template.');
    }
    final loc = await _placeFor(parentId, binderPath, folderPath);
    final page = template.instantiatePage(
      parentId: parentId,
      order: _treeOf(loc).nextOrder(parentId),
    );
    // Its images and files first, so the page never shows without them.
    await _copyTemplateAssets(template, template.page.id, loc, page.id);
    await _writeNewPage(loc, page);
    _touch(loc);
    _metas[page.id] = page.meta;
    _loc[page.id] = loc;
    if (focusTitle) requestTitleFocus(page.id);
    await open(page.id);
    return page.id;
  }

  /// Creates a binder in the folder [path] from the binder template
  /// [template]: its settings (with a new binder id) and page tree (with new
  /// ids), then adds it like [addBinder] and shows its cover (unless
  /// [openCover] is false). A folder that has a binder is refused.
  Future<BinderSection> createBinderFromTemplate(
    NotedTemplate template,
    String path, {
    bool openCover = true,
  }) async {
    _refuseWhileHeld();
    if (template.kind != TemplateKind.binder) {
      throw const NotebookException('That is not a binder template.');
    }
    path = _normalizePath(path);
    if (path == defaultFolderPath || _folders.containsKey(path)) {
      throw const NotebookException('That folder holds the standalone pages.');
    }
    if (_pullOnly(path)) throw const NotebookException(_pullOnlyMessage);
    final dir = Directory(path);
    final binders = BinderStore(dir);
    if (_binders.containsKey(path) || await binders.file.exists()) {
      throw const NotebookException(
        'That folder already has a binder. Choose an empty folder for the new binder.',
      );
    }
    await flush();
    // The folder is claimed from before the binder file exists until the binder
    // is listed (or the creation is undone): discovery leaves it alone.
    final claim = _key(path);
    _claims.add(claim);
    try {
      return await _instantiateBinder(template, path, openCover: openCover);
    } finally {
      _claims.remove(claim);
    }
  }

  Future<BinderSection> _instantiateBinder(
    NotedTemplate template,
    String path, {
    required bool openCover,
  }) async {
    final dir = Directory(path);
    final binders = BinderStore(dir);
    final made = template.instantiateBinder();
    final pages = storeFactory(dir);
    final written = <NotedPage>[];
    var binderWritten = false;
    try {
      final binderIdentity = _identityOf(() => made.binder.write());
      await binders.create(made.binder);
      binderWritten = true;
      _emitPublished(binders.file.path, binderIdentity, () => made.binder.write());
      await _binderSeam('claimed', path);
      for (final p in made.pages) {
        // New ids in a new binder folder: a file already there is not ours.
        final pageIdentity = _identityOf(() => writePage(p));
        // One job per page: the publish and its report, under the folder's lock.
        final published = await folderLocks.run(pages.directory, () async {
          if (!await pages.saveNew(p)) return false;
          _emitPublished(pages.pathFor(p.id), pageIdentity, () => writePage(p));
          return true;
        });
        if (!published) {
          throw const NotebookException(
            'A file for one of the new pages already exists, so the binder was not created. '
            'The existing file was left as it is.',
          );
        }
        written.add(p);
      }
      // Binder templates are app-wide; their pages' images and files follow
      // the new page ids.
      final templates = appTemplatesDirectory;
      for (var i = 0; templates != null && i < made.pages.length; i++) {
        await _copyDirNotify(
          _templateAssets(templates, template.id, template.pages[i].id),
          Directory('${dir.path}${Platform.pathSeparator}${assetsFolderName(made.pages[i].id)}'),
          'the new binder',
          'the template',
        );
      }
    } on Object catch (e) {
      // Only what was published here goes, and only while it still holds what
      // was written; anything that changed since is kept.
      for (final p in written) {
        try {
          final r = await folderLocks.run(pages.directory, () async {
            final r = await pages.deleteIfUnchanged(p.id, writePage(p));
            if (r.deleted) _emitDeleted(pages.pathFor(p.id));
            return r;
          });
          if (!r.deleted && r.outcome != DeleteOutcome.absent) debugPrint('Keeping page ${p.id}: it changed');
        } on Object catch (e2) {
          debugPrint('Removing page ${p.id} failed: $e2');
        }
      }
      if (binderWritten) {
        try {
          final r = await deleteFileIfUnchanged(binders.file.path, utf8.encode(made.binder.write()));
          if (r.deleted) _emitDeleted(binders.file.path);
          if (!r.deleted && r.outcome != DeleteOutcome.absent) {
            debugPrint('Keeping the binder file: it changed');
            // It stays in the folder, so discovery must not list it as new.
            _markRemoved(made.binder.id);
            await _saveSettings();
          }
        } on Object catch (e2) {
          debugPrint('Removing binder file failed: $e2');
        }
      }
      if (e is NotebookException) rethrow;
      debugPrint('Creating the binder failed: $e');
      throw NotebookException('Could not create the binder.${_osReason(e)}');
    }
    final section = await addBinder(path);
    if (openCover && section.available) showCover(section.path);
    return section;
  }

  // Binders -----------------------------------------------------------------

  /// Takes the binder out of the sidebar. Its folder and files stay.
  ///
  /// Its binder id is remembered as removed, so discovery does not list it
  /// again, unless [recordRemoved] is false (an open that is refused takes the
  /// binder out again).
  Future<void> removeBinder(String path, {bool recordRemoved = true}) async {
    _refuseWhileHeld();
    final section = _binders[path];
    _dropLandedIn(path);
    if (section == null) return;
    // Before the first await, so a pass that runs meanwhile sees it. A binder
    // with no known id records nothing.
    final binderId = _binderIds.remove(_key(path));
    final addedRemoved = binderId != null && recordRemoved && !_removedBinders.contains(binderId);
    if (binderId != null && recordRemoved) _markRemoved(binderId);
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId);
    if (openHere) {
      try {
        await _closeCurrent();
      } on Object {
        // The binder stays listed (the user declined to leave the page, or the
        // close failed): put back exactly what this call changed.
        if (identical(_binders[path], section)) {
          if (binderId != null) _binderIds[_key(path)] = binderId;
          if (addedRemoved) _removedBinders.remove(binderId);
        }
        rethrow;
      }
    }
    final released = _dropAdoptionsIn(path);
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    for (final e in _pathId.entries.toList()) {
      if (ids.contains(e.value)) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
    _binders.remove(path);
    // Another remove of this binder may have put its id back after a declined
    // leave: the binder is gone now, so its id is a removed one again.
    _binderIds.remove(_key(path));
    final goneId = binderId ?? section.binder?.id;
    if (goneId != null && recordRemoved && !_binderIds.containsValue(goneId)) _markRemoved(goneId);
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    for (final id in released) {
      await _promoteDuplicate(id);
    }
    if (openHere) await _openFallback(_standalone);
  }

  /// Shows the cover of the available binder [path] instead of a page.
  void showCover(String path) {
    final s = _binders[path];
    if (s == null || !s.available) return;
    _coverPath = path;
    notifyListeners();
  }

  /// Changes cover fields of the binder and writes `noted-binder.json`.
  Future<void> updateBinder(
    String path, {
    String? title,
    String? description,
    String? owner,
    String? color,
  }) async {
    final s = _binders[path];
    var b = s?.binder;
    if (s == null || b == null || !s.available || _isLocked(path)) return;
    final before = b;
    if (title != null && title != b.title) b = b.withTitle(title);
    if (description != null && description != b.description) b = b.withDescription(description);
    if (owner != null && owner != b.owner) b = b.withOwner(owner);
    if (color != null && color != b.color) b = b.withColor(color);
    if (identical(b, before)) return;
    s.binder = b;
    s.lastEdited = DateTime.now();
    notifyListeners();
    await _afterSaves(() async {
      final latest = s.binder;
      if (latest != null) {
        await _saveBinderFile(path, latest);
        _binderText[_key(path)] = latest.write();
      }
    }, what: 'binder cover edit of $path').catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
  }

  // The one way a binder file is read: the bytes, decoded as UTF-8. Bad bytes
  // are a damaged file ([damaged]); an I/O failure or a lock is [failure] (try
  // again later, never "missing"); a file that isn't there is [missing].
  Future<({String? text, bool missing, String? damaged, String? failure})> _readBinderText(File f) async {
    final List<int> bytes;
    try {
      bytes = await f.readAsBytes();
    } on FileSystemException catch (e) {
      if (await FileSystemEntity.type(f.path) == FileSystemEntityType.notFound) {
        return (text: null, missing: true, damaged: null, failure: null);
      }
      return (text: null, missing: false, damaged: null, failure: e.message);
    }
    try {
      return (text: utf8.decode(bytes), missing: false, damaged: null, failure: null);
    } on FormatException {
      return (text: null, missing: false, damaged: 'not valid UTF-8 text', failure: null);
    }
  }

  // Reads the binder file once: what it parsed to and the text that was parsed.
  Future<({BinderRead read, String? text})> _readBinderFile(BinderStore store) async {
    final r = await _readBinderText(store.file);
    if (r.missing) return (read: const BinderMissing(), text: null);
    final failure = r.failure ?? r.damaged;
    if (failure != null) return (read: BinderUnreadable(failure), text: null);
    final text = r.text!;
    try {
      return (read: BinderFound(Binder.parse(text)), text: text);
    } on BinderFormatException catch (e) {
      return (read: BinderUnreadable(e.message), text: text);
    }
  }

  Future<BinderSection> _openBinder(
    String path, {
    bool create = false,
    bool createFolder = true,
    bool sweep = true,
  }) async {
    BinderSection unavailable(String why, {bool missing = false}) =>
        BinderSection._(path, BinderStatus.unavailable, reason: why, missing: missing);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return unavailable('Folder not found. It may be on another device.', missing: true);
      }
      final binders = BinderStore(dir);
      // One read of the binder file: what is parsed is exactly what is cached
      // for the later "did it change" check.
      final once = await _readBinderFile(binders);
      var read = once.read;
      String? text = once.text;
      if (read is BinderMissing) {
        if (!create || _pullOnly(path)) return unavailable('No $binderFileName in this folder.');
        final made = await binders.create(
          Binder.create(
            title: _folderName(path),
            color: binderPalette[_binders.length % binderPalette.length],
          ),
        );
        read = BinderFound(made);
        text = made.write(); // what `create` wrote
        _emitPublished(binders.file.path, null, () => text!);
      }
      // A binder whose file can't be read still lists its pages, read-only.
      final binder = read is BinderFound ? read.binder : null;
      await _binderSeam('parsed', path);
      if (text != null) {
        _binderText[_key(path)] = text;
      } else {
        _binderText.remove(_key(path));
      }
      final pages = storeFactory(dir);
      final entries = await _scan(pages, createFolder: createFolder, sweep: sweep && _sweepOff == 0);
      var latest = (await binders.file.lastModified());
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      // Conflict copies are merged by writing, which a damaged binder forbids.
      _takeCopies(path, entries, bad, merge: binder != null);
      final section = BinderSection._(
        path,
        binder != null ? BinderStatus.available : BinderStatus.unreadable,
        binder: binder,
        store: pages,
        reason: read is BinderUnreadable ? read.reason : null,
        unreadable: bad,
      );
      for (final e in entries.whereType<ReadablePage>()) {
        if ((_metas.containsKey(e.meta.id) && _loc[e.meta.id] != path) ||
            _otherThanChosen(e.meta.id, e.path)) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        _pathId[_key(e.path)] = e.meta.id;
        if (e.conflicted) _conflicts.add(e.meta.id);
        final m = await File(e.path).lastModified();
        if (m.isAfter(latest)) latest = m;
      }
      section.lastEdited = latest;
      return section;
    } on FileSystemException catch (e) {
      return unavailable('${e.message}${e.path == null ? '' : ': ${e.path}'}');
    }
  }

  void _touch(String loc) {
    if (loc == _standalone) return;
    final s = _binders[loc];
    if (s == null) return;
    s.lastEdited = DateTime.now();
    if (!_disposed) notifyListeners();
  }

  // `binders.json`, the app settings file:
  //   {"format":1,"binders":["<folder>", ...],"standaloneFolders":["<folder>", ...]}
  // `standaloneFolders` is absent until a second standalone folder is used.
  // Fields this build doesn't know are kept.
  List<String> _readFolderPaths() {
    final list = _settings['standaloneFolders']?.decode();
    return [
      for (final p in list is List ? list : const [])
        if (p is String && p.isNotEmpty) resolveStoredPath(p),
    ];
  }

  // The binder ids recorded in `binders.json`, by the folder as listed.
  Map<String, String> _readRecordedIds() {
    final map = _settings['binderIds']?.decode();
    return {
      for (final e in (map is Map ? map : const {}).entries)
        if (e.key is String && e.value is String && (e.value as String).isNotEmpty) resolveStoredPath(e.key as String): e.value as String,
    };
  }

  // The most removed ids kept; the oldest go first.
  int _removedCap = 1000;

  // Records [id] as a binder this device took out of its list.
  void _markRemoved(String id) {
    _removedBinders.remove(id);
    _removedBinders.add(id);
    while (_removedBinders.length > _removedCap) {
      _removedBinders.removeAt(0);
    }
  }

  // Notes that the listed folder [path] holds [binder] (null: unreadable, the
  // recorded id stays). A recorded id that differs is replaced (today's
  // adoption of whatever binder file is at a listed path), and an id a listed
  // binder has is no longer a removed one. True if anything changed.
  bool _recordBinderId(String path, Binder? binder) {
    if (binder == null) return false;
    final key = _key(path);
    final changed = _binderIds[key] != binder.id;
    _binderIds[key] = binder.id;
    final cleared = _removedBinders.remove(binder.id);
    // A found add being made at [path] remembers what it took out of the
    // removed ids, so that undoing it puts back only those.
    if (cleared) _foundAdds[key]?.add(binder.id);
    return cleared || changed;
  }

  Future<void> _saveSettings() async {
    final f = bindersFile;
    if (f == null) return;
    if (_settingsHeld != null) {
      debugPrint('Not saving ${f.path}: the binder list is not settled');
      return;
    }
    final paths = _binders.keys.toList();
    // Stored in the codec's form (relative to the documents folder on mobile).
    final storedPaths = [for (final p in paths) storedPath(p)];
    final folders = [for (final p in _folders.keys) storedPath(p)];
    // `binderIds` is never written while an upgrade is open (the next launch
    // must still be one) and always once it is closed, even as `{}`.
    final ids = (_settingsKind == _SettingsKind.fresh || _settingsKind == _SettingsKind.current)
        ? {
            for (final p in paths)
              storedPath(p): ?_binderIds[_key(p)],
          }
        : null;
    final removed = List<String>.of(_removedBinders);
    await _afterSaves(() async {
      await f.parent.create(recursive: true);
      _settings = _settings
          .set('format', RawJson.encode(1))
          .set('binders', RawJson.encode(storedPaths));
      if (folders.isNotEmpty || _settings.containsKey('standaloneFolders')) {
        _settings = _settings.set('standaloneFolders', RawJson.encode(folders));
      }
      if (ids != null) _settings = _settings.set('binderIds', RawJson.encode(ids));
      if (removed.isNotEmpty || _settings.containsKey('removedBinders')) {
        _settings = _settings.set('removedBinders', RawJson.encode(removed));
      }
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString('${_settings.toRaw().text}\n', flush: true);
      await tmp.rename(f.path);
    }, what: 'settings file write').catchError((Object e) {
      debugPrint('Saving ${f.path} failed: $e');
    });
  }

  // AI requests (invariant 4) --------------------------------------------------

  /// Decides a request from the MCP server (see [AiLinkAuthority]) and, for a
  /// write, applies it. Null [aiAccess]: no code is accepted.
  Future<AiLinkResponse> handleAiLink(AiLinkRequest request, [bool Function()? clientOpen]) {
    final service = aiAccess;
    if (service == null) return Future.value(AiLinkResponse.error(AiLinkCode.badCode));
    return _aiAuthority(service).handle(request, clientOpen: clientOpen);
  }

  AiLinkAuthority _aiAuthority(AiAccessService service) {
    final authority = _authority ??= AiLinkAuthority(
      service: service,
      host: this,
      timings: aiTimings,
      merges: _mergeService(service),
    );
    authority.approver = aiApprover;
    return authority;
  }

  /// Asks the user about the AI codes that were used while Noted was closed
  /// and are not approved yet (from the MCP server's log), once each. Call it
  /// after [load], when the window can show the question.
  Future<void> askPendingAiApprovals() async {
    final service = aiAccess;
    if (service == null) return;
    await _loaded.future;
    if (_disposed) return;
    await _aiAuthority(service).askPendingApprovals();
  }

  AiLinkAuthority? _authority;

  Future<void> _aiQueue = Future.value();

  // Saves that didn't land, counted for each page, so a write can tell that
  // its own page's save failed.
  final Map<String, int> _saveFailures = {};

  void _countSaveFailure(String pageId) => _saveFailures[pageId] = (_saveFailures[pageId] ?? 0) + 1;

  static const String _keptMessage = "Noted kept the change on screen but couldn't save it; don't retry an append.";

  @override
  Future<bool> aiWaitLoaded(Duration timeout) async {
    try {
      await _loaded.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<String?> aiPageOfBox(String boxId, {String? hint}) async => (await _findBox(boxId, hint))?.pageId;

  // The page that holds box [boxId] and the box as that one read saw it (the
  // open page's, or the page loaded once from its store).
  Future<({String pageId, BoxRecord box})?> _findBox(String boxId, String? hint) async {
    final c = _current;
    final open = c?.page.node(boxId);
    if (hint != null && _loc.containsKey(hint)) {
      if (c != null && c.page.id == hint) {
        if (open is BoxRecord) return (pageId: hint, box: open);
      } else if (await _pageBox(hint, boxId) case final b?) {
        return (pageId: hint, box: b);
      }
    }
    final now = c?.page.node(boxId);
    if (c != null && now is BoxRecord) return (pageId: c.page.id, box: now);
    for (final e in _loc.entries.toList()) {
      if (e.key == currentId || e.key == hint) continue;
      if (await _pageBox(e.key, boxId) case final b?) return (pageId: e.key, box: b);
    }
    return null;
  }

  Future<BoxRecord?> _pageBox(String pageId, String boxId) async {
    final loc = _loc[pageId];
    if (loc == null) return null;
    try {
      final n = (await _loadPage(_storeOf(loc), pageId)).node(boxId);
      return n is BoxRecord ? n : null;
    } on Object {
      return null; // not readable: not found
    }
  }

  @override
  Future<String?> aiTargetName(AiCodeTarget target) async {
    switch (target.kind) {
      case AiCodeTargetKind.page:
        return pageTitleOf(target.id);
      case AiCodeTargetKind.binder:
        return _binders.values.where((b) => b.binder?.id == target.id).firstOrNull?.title;
      case AiCodeTargetKind.box:
        // One read: the lookup hands back the box it found.
        final found = await _findBox(target.id, target.page);
        if (found == null) return null;
        // The box's saved plain-text snapshot: what a reader of the page sees.
        for (final line in found.box.snapshotText.split(RegExp(r'\r?\n'))) {
          if (line.trim().isNotEmpty) return line;
        }
        return '';
      case null:
        return null;
    }
  }

  @override
  List<String> aiReadablePages(AiCodeTarget target) {
    final Iterable<String> covered;
    switch (target.kind) {
      case AiCodeTargetKind.page:
        final loc = _loc[target.id];
        if (loc == null) return const [];
        covered = [target.id, ..._treeOf(loc).descendantsOf(target.id)];
      case AiCodeTargetKind.binder:
        final section = _binders.values.where((b) => b.binder?.id == target.id).firstOrNull;
        if (section == null) return const [];
        covered = [
          for (final e in _loc.entries)
            if (e.value == section.path) e.key,
        ];
      case AiCodeTargetKind.box:
      case null:
        return const [];
    }
    return [
      for (final id in covered)
        if (_loc[id] case final loc? when !_isLocked(loc) && aiAccessFor(id).value != AiAccess.guarded) id,
    ];
  }

  // Asking the page AI to merge a conflict (run 2026-11-01-04) ---------------

  AiMergeService? _aiMerge;

  AiMergeService? _mergeService(AiAccessService service) => _aiMerge ??= AiMergeService(access: service, host: this);

  /// The page AI's help with a conflict, for the canvas; null when there are
  /// no AI codes at all ([aiAccess] is null).
  PageAiMerge? get aiMerge {
    final service = aiAccess;
    return service == null ? null : _mergeService(service);
  }

  @override
  Future<NotedPage?> aiSavedPage(String pageId) async {
    final loc = _loc[pageId];
    if (loc == null) return null;
    try {
      // What the file holds now: let the pending save land, then read it.
      await flush();
      return await _afterSaves(() => _loadPage(_storeOf(loc), pageId));
    } on Object {
      return null;
    }
  }

  @override
  BoxRecord? aiOpenBox(String pageId, String boxId) {
    final c = _current;
    if (c == null || c.page.id != pageId) return null;
    final box = c.page.node(boxId);
    return box is BoxRecord ? box : null;
  }

  @override
  bool aiMergeTypeAllowed(String pageId, String typeId) => boxTypeAvailabilityFor(pageId, typeId).allowed;

  @override
  BoxCodec<Object?>? aiMergeCodec(String typeId) => modules.codecs.codecFor(typeId);

  @override
  Future<AiLinkResponse> aiWriteBox(
    AiLinkWriteBox request,
    AiCode code, {
    required DateTime deadline,
    required AiLinkCode? Function() recheck,
    Future<AiLinkCode?> Function()? confirm,
  }) async {
    final left = deadline.difference(DateTime.now());
    if (!await aiWaitLoaded(left.isNegative ? Duration.zero : left)) return AiLinkResponse.error(AiLinkCode.busy);
    final refusal = recheck();
    if (refusal != null) return AiLinkResponse.error(refusal);
    final pageId = await aiPageOfBox(request.box, hint: code.target.page);
    if (pageId == null) return AiLinkResponse.error(AiLinkCode.noBox);
    if (confirm != null) {
      // Ask only about a write that would go through, outside the queue so a
      // question that waits doesn't hold up other requests.
      final no = await _aiPrecheck(pageId, request, code, recheck);
      if (no != null) return no;
      final refused = await confirm();
      if (refused != null) return AiLinkResponse.error(refused);
    }
    final run = _aiQueue.then((_) => _aiApply(pageId, request, code, recheck));
    _aiQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  // The answer a write would get now, or null if it would go through.
  Future<AiLinkResponse?> _aiPrecheck(
    String pageId,
    AiLinkWriteBox req,
    AiCode code,
    AiLinkCode? Function() recheck,
  ) async {
    final loc = _loc[pageId];
    if (loc == null) return AiLinkResponse.error(AiLinkCode.noBox);
    final c = _current;
    final NotedPage page;
    var readOnly = false;
    if (c != null && c.page.id == pageId) {
      if (_trouble.isTrouble && _trouble.pageId == pageId) return _aiTroubled();
      page = c.page;
      readOnly = c.readOnly;
    } else {
      try {
        page = await _loadPage(_storeOf(loc), pageId);
      } on Object {
        return AiLinkResponse.error(AiLinkCode.noBox);
      }
    }
    return _aiPrepare(page, loc, readOnly, code, req, recheck).error;
  }

  Future<AiLinkResponse> _aiApply(
    String pageId,
    AiLinkWriteBox req,
    AiCode code,
    AiLinkCode? Function() recheck,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final c = _current;
      if (c != null && c.page.id == pageId) return _aiWriteOpen(c, code, req, recheck);
      final queuedOn = _chain.generation;
      final r = await _afterSaves(
        () => _aiWriteClosed(pageId, code, req, recheck, queuedOn),
        what: 'AI write to page $pageId',
        pages: {pageId},
      );
      if (r != null) return r;
      // The page was opened while this waited its turn: apply it there.
    }
    return AiLinkResponse.error(AiLinkCode.saveFailed);
  }

  // The rules that decide whether the box may be written at all, in order, on
  // [page] as it is now. Null: allowed. Also run on a merged page, so the
  // rules hold for what is about to be saved.
  AiLinkCode? _aiGate(
    NotedPage page,
    String loc,
    bool readOnly,
    AiCode code,
    AiLinkWriteBox req,
    AiLinkCode? Function() recheck,
  ) {
    // Revoked while this waited: refuse. Nothing awaits between here and the
    // change itself.
    final gone = recheck();
    if (gone != null) return gone;
    // The Writer permission may have changed while this waited.
    final permission = aiAccess?.writerPermission(req.box) ?? AiWriterPermission.append;
    if (!permission.allows(req.mode)) return AiLinkCode.notPermitted;
    final box = page.node(req.box);
    if (box is! BoxRecord) return AiLinkCode.noBox;
    final r = modules.codecs.resolve(box);
    if (r is! LiveBox) return AiLinkCode.notWritable;
    // A type this page doesn't allow behaves as switched off here.
    final chain = [page.meta, ..._metaChain(page.id).skip(1)];
    if (!effectiveBoxTypeAllowed(box.typeId, chain, binder: _binderOf(page.id)).allowed) {
      return AiLinkCode.notWritable;
    }
    if (box.isConflicted) return AiLinkCode.conflict;
    if (readOnly || _isLocked(loc)) return AiLinkCode.locked;
    return null;
  }

  // Every rule after the lookup, in order, on the box as it is now. Returns
  // an answer to refuse with, or the codec and the data to write.
  ({AiLinkResponse? error, BoxCodec<Object?>? codec, Object? data}) _aiPrepare(
    NotedPage page,
    String loc,
    bool readOnly,
    AiCode code,
    AiLinkWriteBox req,
    AiLinkCode? Function() recheck,
  ) {
    ({AiLinkResponse? error, BoxCodec<Object?>? codec, Object? data}) no(AiLinkCode c) =>
        (error: AiLinkResponse.error(c), codec: null, data: null);
    final refused = _aiGate(page, loc, readOnly, code, req, recheck);
    if (refused != null) return no(refused);
    final r = modules.codecs.resolve(page.node(req.box)! as BoxRecord) as LiveBox;
    final next = r.codec.aiWrite(
      r.data,
      AiWrite(
        connectionId: code.id,
        content: req.content,
        mode: switch (req.mode) {
          AiLinkMode.append => AiWriteMode.append,
          AiLinkMode.replaceAi => AiWriteMode.replaceAiText,
          AiLinkMode.replace => AiWriteMode.replace,
        },
      ),
    );
    if (next == null) return no(AiLinkCode.notWritable);
    return (error: null, codec: r.codec, data: next);
  }

  // The open page has changes that couldn't be saved: nothing is written to it.
  AiLinkResponse _aiTroubled() => AiLinkResponse.error(
    AiLinkCode.saveFailed,
    "The page has changes that couldn't be saved, so nothing was written.",
  );

  // The page is open: change it through its controller, as one undo step the
  // user sees at once, and let the normal save write it.
  Future<AiLinkResponse> _aiWriteOpen(
    CanvasController c,
    AiCode code,
    AiLinkWriteBox req,
    AiLinkCode? Function() recheck,
  ) async {
    final pageId = c.page.id;
    final loc = _loc[pageId];
    if (loc == null) return AiLinkResponse.error(AiLinkCode.noBox);
    if (_trouble.isTrouble && _trouble.pageId == pageId) return _aiTroubled();
    final p = _aiPrepare(c.page, loc, c.readOnly, code, req, recheck);
    if (p.error != null) return p.error!;
    if (c.replaceBoxData({req.box: p.data}) == 0) {
      return AiLinkResponse.error(AiLinkCode.notWritable);
    }
    final failures = _saveFailures[pageId] ?? 0;
    await flush();
    if ((_saveFailures[pageId] ?? 0) != failures) {
      return AiLinkResponse.error(AiLinkCode.saveFailed, _keptMessage);
    }
    return AiLinkResponse.written(box: req.box);
  }

  // The page is closed: load it, commit the box as an edit does, and save it
  // through the page's store. Null: the page is open now.
  Future<AiLinkResponse?> _aiWriteClosed(
    String pageId,
    AiCode code,
    AiLinkWriteBox req,
    AiLinkCode? Function() recheck,
    int queuedOn,
  ) async {
    if (_current?.page.id == pageId) return null;
    final loc = _loc[pageId];
    if (loc == null) return AiLinkResponse.error(AiLinkCode.noBox);
    // A write queued before the chain was cut waits on the save it was queued
    // behind, so the page being held for that save is not a reason to refuse it.
    final heldByItsOwnQueue = queuedOn != _chain.generation && _busy[pageId] == _busyDetached;
    if (_busy.containsKey(pageId) && !heldByItsOwnQueue) {
      return AiLinkResponse.error(AiLinkCode.busy, 'Noted is still trying to save this page. Try again in a moment.');
    }
    final PageStore st;
    final NotedPage page;
    try {
      st = _storeOf(loc);
      page = await _loadPage(st, pageId);
    } on Object {
      return AiLinkResponse.error(AiLinkCode.noBox);
    }
    final p = _aiPrepare(page, loc, false, code, req, recheck);
    if (p.error != null) return p.error!;
    final box = page.node(req.box)! as BoxRecord;
    final next = page.replaceNode(
      commitBox(
        box,
        p.codec!,
        p.data,
        device: deviceName,
        at: deviceName == null ? null : DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final NotedPage saved;
    try {
      saved = await _saveClosedPage(
        loc,
        st,
        page,
        next,
        (merged) => _aiGate(merged, loc, false, code, req, recheck),
      );
    } on _SaveRefused catch (e) {
      return e.response;
    }
    final metaChanged = saved.meta != page.meta;
    _metas[pageId] = saved.meta;
    _touch(loc);
    if (metaChanged) _rebuildTree();
    return AiLinkResponse.written(box: req.box);
  }

  // The answer to an AI write whose page could not be saved: "kept" only if
  // recovery now holds the change.
  Future<AiLinkResponse> _keptAnswer(String loc, PageStore st, NotedPage toSave, NotedPage base) async {
    final out = await _keepForRecovery(loc, st, toSave, base: base);
    return out.safe
        ? AiLinkResponse.error(AiLinkCode.saveFailed, _keptMessage)
        : AiLinkResponse.error(AiLinkCode.saveFailed, 'The change could not be saved or kept, so nothing was written.');
  }

  // Reads the file of a closed page: null text if it is not there. Throws
  // _SaveRefused if it is there but can't be read as this page: it is never
  // written over (0051).
  Future<({String? text, NotedPage? page, int time})> _readClosedPage(String id, String path) async {
    AiLinkResponse unreadable(String why) => AiLinkResponse.error(
      AiLinkCode.saveFailed,
      "This page's file can't be read ($why), so nothing was written to it.",
    );
    final String text;
    final int time;
    try {
      text = await File(path).readAsString();
      time = (await File(path).lastModified()).millisecondsSinceEpoch;
    } on FileSystemException catch (e) {
      if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
        return (text: null, page: null, time: 0);
      }
      throw _SaveRefused(unreadable(e.message));
    } on FormatException {
      throw _SaveRefused(unreadable('not valid UTF-8 text'));
    }
    try {
      final page = readPage(text);
      if (page.id != id) throw _SaveRefused(unreadable('it holds a different page'));
      return (text: text, page: page, time: time);
    } on PageFormatException catch (e) {
      throw _SaveRefused(unreadable(e.message));
    }
  }

  // Saves [mine], an edit of [base], to a page that isn't open, with the same
  // guard the open page has: the file is read again, what others wrote since
  // [base] is merged in (three-way, as for the open page), [check] is run on
  // the merged page (non-null: refuse with that code), and the file is read
  // once more just before the write. If it changed in between, the merge is
  // done again; after a few rounds the save is refused. A file this app can't
  // read is refused and left as it is. Returns the page written.
  Future<NotedPage> _saveClosedPage(
    String loc,
    PageStore st,
    NotedPage base,
    NotedPage mine,
    AiLinkCode? Function(NotedPage merged) check,
  ) async {
    final id = base.id;
    final path = st.pathFor(id);
    final baseText = writePage(base);
    // The file is gone but its folder is there, or the page isn't in this
    // place any more: it was deleted or moved meanwhile, and is not recreated.
    // (A vanished folder is different: the save goes to recovery.)
    //
    // The folder is looked at first: when it is gone, the page may have been
    // forgotten with it (_folderGone), which is not a delete or a move, so the
    // save must still reach _write and recovery.
    var folderGone = false;
    Future<void> assertStillHere(String? text) async {
      folderGone = !await st.directory.exists();
      if (folderGone) return;
      if (_loc[id] != loc) throw _SaveRefused(AiLinkResponse.error(AiLinkCode.noBox));
      if (text == null) throw _SaveRefused(AiLinkResponse.error(AiLinkCode.noBox));
    }

    for (var attempt = 0; attempt < 5; attempt++) {
      await syncHook?.call('closed-reread', path);
      final seen = await _readClosedPage(id, path);
      await assertStillHere(seen.text);
      var toSave = mine;
      var recoveryBase = base;
      final theirs = seen.page;
      if (theirs != null && writePage(theirs) != baseText) {
        toSave = mergePage(base, mine, theirs, modules.codecs, theirsTime: seen.time).page;
        recoveryBase = theirs;
      }
      await syncHook?.call('closed-before-write', path);
      final again = await _readClosedPage(id, path);
      if (again.text != seen.text) continue;
      await assertStillHere(again.text);
      // The rules are run on what is about to be written, every round, with
      // nothing awaited between this and the write.
      final refused = check(toSave);
      if (refused != null) throw _SaveRefused(AiLinkResponse.error(refused));
      if (_loc[id] != loc && !folderGone) throw _SaveRefused(AiLinkResponse.error(AiLinkCode.noBox));
      try {
        // Over exactly the file that was read and merged, checked at the
        // moment of replacing (0128); a file that changed since is merged again.
        if (!await _writeIfUnchanged(loc, toSave, again.text)) continue;
      } on FolderUnavailableException {
        throw _SaveRefused(await _keptAnswer(loc, st, toSave, recoveryBase));
      } on NotebookException {
        throw _SaveRefused(AiLinkResponse.error(AiLinkCode.locked));
      } on FileSystemException {
        if (await st.directory.exists()) {
          throw _SaveRefused(AiLinkResponse.error(AiLinkCode.saveFailed));
        }
        throw _SaveRefused(await _keptAnswer(loc, st, toSave, recoveryBase));
      }
      return toSave;
    }
    throw _SaveRefused(
      AiLinkResponse.error(
        AiLinkCode.busy,
        'The page file keeps changing, so nothing was written to it.',
      ),
    );
  }

  // Lists [job], a write queued on the save chain, as unfinished until it
  // completes.
  Future<T> _track<T>(String what, Future<T> job) {
    _unfinished.add(what);
    return job.whenComplete(() => _unfinished.remove(what));
  }

  // Runs [job] after the jobs queued so far (L1) and before any later one.
  // [pages] are the pages it works on: if the chain is detached while it
  // hangs, they are busy until it ends.
  Future<T> _afterSaves<T>(
    Future<T> Function() job, {
    String what = 'queued job',
    Set<String> pages = const {},
  }) => _track(what, _chain.run(job, pages: pages));

  // Autosave ------------------------------------------------------------------

  /// What is still waiting to be saved, or null when nothing is: a change on
  /// the autosave timer, or a save that has started and not finished.
  @visibleForTesting
  String? get unsavedDescription {
    final parts = <String>[
      if (_pendingSave != null) 'page ${_pendingSave!.id} waiting for the autosave timer',
      if (_saveTimer?.isActive ?? false) 'autosave timer running',
      for (final w in _unfinished) '$w started and not finished',
    ];
    return parts.isEmpty ? null : parts.join('; ');
  }

  /// Writes any unsaved change now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final p = _pendingSave;
    _pendingSave = null;
    if (p != null) unawaited(_enqueueSave(p, _pendingSeq));
    await _chain.idle;
  }

  void _pageChanged(NotedPage page) {
    final loc = _loc[page.id];
    if (loc != null && _isLocked(loc)) return; // a read-only page is never saved
    if (_preview != null) return; // a preview is never saved
    final s = _session;
    if (s != null && s.pageId == page.id) s.seq++;
    _pendingSave = page;
    _pendingSeq = s?.seq ?? 0;
    if (_metas[page.id] != page.meta) {
      _metas[page.id] = page.meta;
      _rebuildTree();
    }
    _setConflict(page.id, hasConflicts(page));
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  // Saves run one after another, so an older version never lands last. The
  // job never throws: how it ended is the result. [seq] is the snapshot of the
  // page's session the save is for.
  Future<SaveResult> _enqueueSave(NotedPage page, int seq, {bool wantIdentity = false}) {
    final s = _session;
    final session = s != null && s.pageId == page.id && !s.ended ? s : null;
    return _afterSaves(
      () => _saveNow(page, seq, session, wantIdentity: wantIdentity),
      what: 'save of page ${page.id}',
      pages: {page.id},
    );
  }

  // [wantIdentity]: the result carries the identity of what landed, hashed from
  // the text in hand before the lock (mergeRemote asks).
  Future<SaveResult> _saveNow(NotedPage page, int seq, SaveSession? session, {bool wantIdentity = false}) async {
    // A snapshot a Discard threw away is never published.
    if (session != null && seq < session.floor) return const SaveResult(SaveEnd.skipped);
    // The open page's place may be gone or locked: nothing can be written, so
    // its edits are not saved. They go through the recovery rules like any
    // failed save (a skipped save would let the page be disposed unasked).
    final loc = _loc[page.id] ?? (session != null ? _orphanLoc : null);
    // A pull-only page has no edits: nothing to save, and nothing to keep.
    if (loc != null && _pullOnly(loc)) return const SaveResult(SaveEnd.skipped);
    if (loc == null) {
      return session == null
          ? const SaveResult(SaveEnd.skipped)
          : await _saveFailed(_standalone, store, page, seq, session, reason: 'its folder is not available', folderGone: true);
    }
    final st = _storeOrFolder(loc);
    if (_loc[page.id] == null || _isLocked(loc)) {
      return session == null
          ? const SaveResult(SaveEnd.skipped)
          : await _saveFailed(loc, st, page, seq, session, reason: 'its folder is not available', folderGone: true);
    }
    var toSave = page;
    var savedSeq = seq;
    try {
      final path = st.pathFor(page.id);
      final key = _key(path);
      var landed = false;
      ContentIdentity? identity;
      for (var attempt = 0; !landed; attempt++) {
        if (attempt >= _maxWriteTries) {
          // The file changed under every attempt: the edits are kept.
          final r = await _saveFailed(loc, st, toSave, savedSeq, session, reason: 'the page file keeps changing');
          return SaveResult(r.end, r.keep, null, true);
        }
        final isOpen = session != null && identical(session, _session) && _current?.page.id == page.id;
        if (isOpen) {
          // Merge what someone else wrote since the last look first, so this
          // save doesn't overwrite it. A replacement this app can't read is
          // never overwritten: the edits are in recovery and the page is
          // read-only until a readable version lands (0051). This looks even
          // if nothing is known about the file (it was deleted and a new one
          // may have been put in its place); only a file that is really
          // absent is written.
          if (await _checkFile(path)) {
            _countSaveFailure(page.id); // it did not land, so a caller that needs it must know
            return SaveResult(SaveEnd.blocked, _blockKeep);
          }
          final c = _current;
          if (c != null && c.page.id == page.id && identical(session, _session)) {
            toSave = c.page;
            savedSeq = session.seq;
          }
        }
        // A Discard that came since this save began: nothing more is published.
        if (session != null && savedSeq < session.floor) return const SaveResult(SaveEnd.skipped);
        final known = _known[key];
        try {
          // Over exactly the file last seen, checked at the moment of replacing
          // (0128): a version that landed since is not overwritten.
          final w = await _writeIfUnchangedFull(loc, toSave, known, wantIdentity: wantIdentity);
          landed = w.landed;
          identity = w.identity;
        } on FolderUnavailableException {
          return await _saveFailed(loc, st, toSave, savedSeq, session, folderGone: true);
        } on FileSystemException catch (e) {
          // The folder may have vanished during the write.
          final folderGone = !await st.directory.exists();
          return await _saveFailed(loc, st, toSave, savedSeq, session, error: e, folderGone: folderGone);
        }
        if (landed) break;
        // The file is not what was last seen. The open page takes it in at the
        // top of the next round (_checkFile merges it). A page that is not open
        // has nothing to merge against here: it is never written over; its
        // edits are kept in recovery, which merges them three-way later.
        if (isOpen && identical(session, _session) && _current?.page.id == page.id) continue;
        final r = await _saveFailed(loc, st, toSave, savedSeq, session, reason: 'the page file changed');
        await _checkFile(path);
        // Not merged here: the edits are in recovery, and the existing triggers
        // (load, a folder coming back) replay them three-way.
        return r;
      }
      if (session != null && savedSeq < session.floor) session.landedPastFloor = true;
      if (_current?.page.id == toSave.id && (session == null || identical(session, _session))) _base = toSave;
      _touch(loc);
      if (session != null) await _retireOwn(session, st, toSave, savedSeq);
      return SaveResult(SaveEnd.landed, null, identity);
    } on NotebookException {
      // The location can't be written now (checked inside the write).
      return session == null
          ? const SaveResult(SaveEnd.skipped)
          : await _saveFailed(loc, st, toSave, savedSeq, session, reason: 'its folder is not available', folderGone: true);
    } on Object catch (e, s) {
      // Not an I/O error: also state 2, "an unexpected error" (build note 6).
      debugPrint('Saving page ${page.id} failed: $e\n$s');
      return await _saveFailed(loc, st, toSave, savedSeq, session, error: e is IOException ? e : null);
    }
  }

  // A save did not land: the edits go to recovery (3.4), and the bar says so.
  Future<SaveResult> _saveFailed(
    String loc,
    PageStore st,
    NotedPage toSave,
    int seq,
    SaveSession? session, {
    Object? error,
    String? reason,
    bool folderGone = false,
  }) async {
    _countSaveFailure(toSave.id);
    final KeepOutcome keep;
    try {
      keep = await _keepForRecovery(loc, st, toSave, session: session, seq: seq);
    } on Object catch (e) {
      debugPrint('Keeping page ${toSave.id} for recovery failed: $e');
      return SaveResult(SaveEnd.failed, KeepOutcome(KeepKind.failed, cause: e));
    }
    if (session != null && identical(session, _session) && !session.ended) {
      _troubleFrom(
        session,
        toSave,
        keep,
        reason: reason ?? (error == null ? 'an unexpected error' : describeError(error)),
        folderGone: folderGone,
        error: error,
      );
    }
    return SaveResult(SaveEnd.failed, keep);
  }

  // The store of [loc], or a bare one for its folder when the location is gone
  // (only its directory and file names are used, to key a recovery entry).
  PageStore _storeOrFolder(String loc) {
    try {
      return _storeOf(loc);
    } on NotebookException {
      return PageStore(loc == _standalone ? store.directory : Directory(loc));
    }
  }

  // Throws unless the pages of [loc] may be written. A folder that has gone
  // is never created again by a save.
  Future<void> _assertCanWrite(String loc) async {
    _assertWritable(loc);
    final st = _storeOf(loc);
    if (!await st.directory.exists()) {
      throw const FolderUnavailableException();
    }
  }

  // The bar -------------------------------------------------------------------

  /// How the open page's saves are going (the bar above the page).
  TroubleState get trouble => _trouble;

  void _setTrouble(TroubleState s) {
    if (s == _trouble) return;
    _trouble = s;
    if (!_disposed) notifyListeners();
  }

  // Sets the bar after a failed save, by what became of the edits.
  void _troubleFrom(
    SaveSession session,
    NotedPage page,
    KeepOutcome keep, {
    required String reason,
    required bool folderGone,
    Object? error,
  }) {
    final title = _titleOrUntitled(page.meta.title);
    if (keep.safe) {
      // A folder that went away is dealt with by the folder check (the page
      // turns read-only); the bar is for a folder that is there.
      if (folderGone) {
        if (_trouble.pageId == page.id && _trouble.kind == TroubleKind.recoveryFailing) {
          _setTrouble(TroubleState.saved);
        }
      } else {
        _setTrouble(
          TroubleState(
            TroubleKind.failing,
            pageId: page.id,
            title: title,
            reason: reason,
            canSaveCopy: pickFolder != null,
          ),
        );
      }
      _backoff.schedule();
      return;
    }
    final why = keep.why ?? (keep.cause == null ? reason : describeError(keep.cause!));
    final base = TroubleState(
      TroubleKind.recoveryFailing,
      pageId: page.id,
      title: title,
      reason: why,
      advice: saveCopyAdvice,
      canSaveCopy: pickFolder != null,
    );
    _setTrouble(base);
    _backoff.schedule();
    final rec = _recovery;
    if (rec != null) {
      unawaited(
        checkStorage(
          error ?? keep.cause ?? reason,
          recoveryDirectory: rec.directory,
          needed: writePage(page).length,
          recoveryFailure: keep.cause,
        ).then((c) {
          if (_disposed || _trouble != base) return;
          _setTrouble(
            TroubleState(
              TroubleKind.recoveryFailing,
              pageId: page.id,
              title: title,
              reason: c.summary,
              advice: c.advice,
              canSaveCopy: pickFolder != null,
            ),
          );
        }, onError: (Object _) {}),
      );
    }
  }

  // Asks the user; no window to ask means no.
  Future<bool> _ask(UserQuestion q, String title) async {
    final ask = questioner;
    if (ask == null) return false;
    try {
      return await ask(q, title);
    } on Object catch (e) {
      debugPrint('Asking the user failed: $e');
      return false;
    }
  }

  // Recovery ------------------------------------------------------------------

  // Why recovery can't be used now (the lock isn't held), or null. A lock that
  // is taken late means another process may have written entries meanwhile,
  // so the index is rebuilt before the next transaction.
  String? _lockProblem() {
    final l = recoveryLock;
    if (l == null || l.check()) return null;
    if (l.ensure()) {
      _relist = true;
      return null;
    }
    return l.problem;
  }

  /// Why Noted can't use its recovery folder now, or null. For the window.
  String? get recoveryLockProblem {
    final l = recoveryLock;
    return l == null || l.held ? null : l.problem;
  }

  // The codecs for page [id]: those of its disallowed box types are off, so a
  // merge treats such a box opaquely, as a switched-off module would (0111).
  CodecRegistry _pageCodecs(String id) {
    final off = disallowedBoxTypesFor(id);
    final r = CodecRegistry();
    for (final c in modules.codecs.codecs) {
      r.register(c, enabled: modules.codecs.isEnabled(c.typeId) && !off.contains(c.typeId));
    }
    return r;
  }

  // Whether the edits of [ep] (made against [eb]) are already in [nb]: every
  // box it added or changed is in [nb] exactly as it is there (a box with
  // more conflict versions is not the same: it is merged), every box it deleted is absent, and the page header
  // is its own (whole). Only ever used to skip; a false "no" just merges.
  static bool _editsIn(NotedPage eb, NotedPage ep, NotedPage nb) {
    final baseById = {for (final n in eb.nodes) n.id: n};
    final epIds = {for (final n in ep.nodes) n.id};
    for (final m in ep.nodes) {
      final b = baseById[m.id];
      if (b != null && b.toRaw() == m.toRaw()) continue;
      final x = nb.node(m.id);
      if (x == null) return false;
      if (x.toRaw() == m.toRaw()) continue;
      return false;
    }
    for (final b in eb.nodes) {
      if (!epIds.contains(b.id) && nb.node(b.id) != null) return false;
    }
    // The stacking order: a reorder of the boxes both have is an edit too.
    List<String> common(NotedPage p, Set<String> ids) => [for (final x in p.nodes) if (ids.contains(x.id)) x.id];
    final both = baseById.keys.toSet().intersection(epIds);
    final eo = common(eb, both), po = common(ep, both);
    if (!listEquals(eo, po) && !listEquals(common(nb, both), po)) return false;
    // The whole header (every field, so a new one cannot be missed), by its text.
    final eh = eb.meta.fields.toRaw().text, ph = ep.meta.fields.toRaw().text;
    return ph == eh || nb.meta.fields.toRaw().text == ph;
  }

  // A save couldn't land: keep exactly what the save would have written, so
  // the edit survives quitting (0066). The only caller of RecoveryStore.write.
  // [session]: the open page's own writer (3.4.1), else a closed writer that
  // merges into the entries already there (3.4.2). [base] is the page as last
  // read or written, if not the one the notebook remembers.
  Future<KeepOutcome> _keepForRecovery(
    String loc,
    PageStore st,
    NotedPage page, {
    NotedPage? base,
    bool exactBase = false,
    SaveSession? session,
    int seq = 0,
  }) async {
    final rec = _recovery;
    if (rec == null) {
      return const KeepOutcome(KeepKind.refused, why: 'Noted has no recovery folder');
    }
    if (session != null && seq < session.floor) return KeepOutcome.discarded;
    if (session != null && seq <= session.newestWritten) return KeepOutcome.dropped;
    final problem = _lockProblem();
    if (problem != null) return KeepOutcome(KeepKind.refused, why: problem);
    var baseText = base == null ? (exactBase ? null : _known[_key(st.pathFor(page.id))]) : writePage(base);
    final b = _base;
    if (baseText == null && !exactBase && b != null && session != null) baseText = writePage(b);
    final folder = _normalizePath(st.directory.path);
    try {
      return await rec.transaction((tx) async {
        if (_relist) {
          _relist = false;
          await tx.list();
        }
        final entries = rec.entriesFor(folder, page.id);
        if (session != null) return _keepAsSession(rec, tx, folder, page, baseText, session, seq, entries);
        return _keepAsClosed(rec, tx, folder, page, baseText, base, entries);
      });
    } on RecoveryRefused catch (e) {
      return KeepOutcome(KeepKind.refused, why: e.why);
    } on Object catch (e) {
      debugPrint('Keeping page ${page.id} for recovery failed: $e');
      return KeepOutcome(KeepKind.failed, cause: e, why: e is RecoveryTimeout ? e.toString() : null);
    }
  }

  // The first step of a delete rollback (0141): [page], already deleted, is
  // written to recovery as its own fresh slot with no base, holding exactly the
  // deleted version, and read back. Nothing is read or merged, so an entry of
  // the page that is already there (or that another instance wrote) is never
  // touched. [gen] is set as soon as the write returns, whatever the read-back
  // shows (the entry is then ours to remove); [durable] only when it read back.
  // [known]: an entry written earlier that was not read back; it is read again,
  // not written twice. Never throws; no recovery, a refusal or a failure is
  // logged and not durable.
  Future<({String? gen, bool durable})> _keepRollbackCopy(PageStore st, NotedPage page, String? known) async {
    var gen = known;
    try {
      await syncHook?.call('delete-rollback-keep', st.pathFor(page.id));
      final rec = _recovery;
      if (rec == null || _lockProblem() != null) return (gen: gen, durable: false);
      if (gen == null) {
        final folder = _normalizePath(st.directory.path);
        final written = await rec.transaction(
          (tx) => tx.write(folder: folder, page: page, baseText: null, time: DateTime.now(), freshSlot: true),
        );
        gen = written.gen;
      }
      final entry = rec.indexEntries.where((x) => x.gen == gen).firstOrNull;
      final ok = entry != null && await rec.transaction((tx) => tx.verify(entry));
      return (gen: gen, durable: ok);
    } on Object catch (e) {
      debugPrint('Keeping page ${page.id} in recovery before putting it back failed: $e');
      return (gen: gen, durable: false);
    }
  }

  // 3.4.1: the open page replaces only its own generations (and landed ones).
  Future<KeepOutcome> _keepAsSession(
    RecoveryStore rec,
    RecoveryTx tx,
    String folder,
    NotedPage page,
    String? baseText,
    SaveSession session,
    int seq,
    List<RecoveryEntry> entries,
  ) async {
    if (seq < session.floor) return KeepOutcome.discarded;
    if (seq <= session.newestWritten) return KeepOutcome.dropped;
    final foreign = entries.where((e) => !session.own.containsKey(e.gen) && !rec.isLanded(e.gen));
    if (foreign.isNotEmpty) {
      // Only reachable after the lock was taken late: never replaced.
      return const KeepOutcome(
        KeepKind.refused,
        why: 'the recovery folder holds changes for this page that this window did not write',
      );
    }
    final time = DateTime.now().toUtc();
    final gen = rec.generationFor(folder, time, baseText, writePage(page));
    // Recorded before writing: a tmp file that gets promoted is recognised.
    session.own[gen] = seq;
    final replaceable = {...session.own.keys, for (final e in entries) e.gen};
    final written = await tx.write(
      folder: folder,
      page: page,
      baseText: baseText,
      time: time,
      replaceable: replaceable,
    );
    session.newestWritten = seq;
    // Older generations in other slots go; one that can't be deleted is marked
    // landed (deleted, never merged, later).
    for (final e in rec.entriesFor(folder, page.id)) {
      if (e.gen == written.gen) continue;
      if (!session.own.containsKey(e.gen) && !rec.isLanded(e.gen)) continue;
      try {
        await tx.delete(e);
      } on Object catch (ex) {
        debugPrint('Deleting an older kept generation failed: $ex');
        rec.markLanded(e.gen);
      }
      session.own.remove(e.gen);
    }
    // A generation the write replaced is gone from the disk (a tmp left by an
    // earlier failed rename is older than this one and is deleted at the next
    // listing), so only the new one is still ours.
    session.own.removeWhere((g, _) => g != gen && !rec.indexEntries.any((e) => e.gen == g));
    return KeepOutcome(KeepKind.kept, gen: gen);
  }

  // 3.4.2: a closed writer merges into the entries of the page, never
  // replaces one it didn't merge.
  Future<KeepOutcome> _keepAsClosed(
    RecoveryStore rec,
    RecoveryTx tx,
    String folder,
    NotedPage page,
    String? baseText,
    NotedPage? basePage,
    List<RecoveryEntry> entries,
  ) async {
    final codecs = _pageCodecs(page.id);
    final nb = basePage ?? (baseText == null ? null : _tryRead(baseText));
    var np = page;
    final sorted = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    for (final e in sorted) {
      if (rec.isLanded(e.gen)) continue; // deleted, never merged
      final NotedPage eb;
      if (e.baseText == null) {
        eb = NotedPage.create(e.page.meta);
      } else {
        final r = _tryRead(e.baseText!);
        if (r == null) {
          return const KeepOutcome(
            KeepKind.refused,
            why: 'the base of the changes kept for this page can not be read',
          );
        }
        eb = r;
      }
      // Already in the writer's base: nothing to merge.
      if (nb != null && _editsIn(eb, e.page, nb)) continue;
      final result = mergePage(
        eb,
        e.page,
        np,
        codecs,
        theirsTime: DateTime.now().millisecondsSinceEpoch,
        markLanded: false,
      ).page;
      final lost = _ownEditsMissing(eb, e.page, result);
      final lostMine = _ownEditsMissing(nb ?? NotedPage.create(page.meta), page, result);
      if (lost != null || lostMine != null) {
        return KeepOutcome(
          KeepKind.refused,
          why: 'the kept changes could not be combined safely (${lost ?? lostMine})',
        );
      }
      np = result;
    }
    final time = DateTime.now().toUtc();
    final written = await tx.write(
      folder: folder,
      page: np,
      baseText: baseText,
      time: time,
      replaceable: {for (final e in entries) e.gen},
    );
    for (final e in entries) {
      if (e.gen == written.gen || e.file.path == written.file.path) continue;
      try {
        await tx.delete(e);
      } on Object catch (ex) {
        debugPrint('Deleting a merged kept generation failed: $ex');
        rec.markLanded(e.gen);
      }
    }
    return KeepOutcome(KeepKind.kept, gen: written.gen);
  }

  static NotedPage? _tryRead(String text) {
    try {
      return readPage(text);
    } on PageFormatException {
      return null;
    }
  }

  // T: after a landed save of snapshot [upTo], the session's own generations
  // up to it are deleted, but only when the file reads back as published
  // (another writer on top is merged in by _checkFile, and T runs after the
  // next landed save). A delete that fails marks the generation landed.
  Future<void> _retireOwn(SaveSession session, PageStore st, NotedPage saved, int upTo) async {
    final rec = _recovery;
    if (rec != null && session.own.values.any((s) => s <= upTo)) {
      try {
        final back = await st.readText(saved.id);
        if (back == writePage(saved)) {
          final gens = [
            for (final en in session.own.entries)
              if (en.value <= upTo) en.key,
          ];
          await _deleteGens(rec, gens, session);
          await _landKeptAssets(rec);
        }
      } on Object catch (e) {
        debugPrint('Retiring the kept changes of page ${saved.id} failed: $e');
      }
    }
    if (identical(session, _session) && _trouble.pageId == saved.id && _trouble.kind != TroubleKind.preview) {
      _setTrouble(TroubleState.saved);
    }
    _told.remove(saved.id);
    _backoff.reset();
    if (rec != null && rec.indexEntries.isNotEmpty) _backoff.schedule();
  }

  // Deletes the entries holding generations [gens] (of [session], if given),
  // by exact generation. Ones that can't be deleted are marked landed.
  Future<void> _deleteGens(RecoveryStore rec, Iterable<String> gens, SaveSession? session) async {
    final entries = [
      for (final g in gens)
        for (final e in rec.indexEntries)
          if (e.gen == g) e,
    ];
    if (entries.isNotEmpty && _lockProblem() != null) {
      // Without the lock nothing is deleted (a handle that is lost is taken
      // again first, build note 4); the generations wait, marked landed.
      for (final e in entries) {
        rec.markLanded(e.gen);
      }
      for (final g in gens) {
        session?.own.remove(g);
      }
      return;
    }
    try {
      await rec.transaction((tx) async {
        for (final e in entries) {
          try {
            await tx.delete(e);
          } on Object catch (ex) {
            debugPrint('Deleting a kept generation failed: $ex');
            rec.markLanded(e.gen);
          }
          session?.own.remove(e.gen);
        }
      });
    } on Object catch (ex) {
      debugPrint('Deleting kept generations failed: $ex');
      for (final e in entries) {
        rec.markLanded(e.gen);
        session?.own.remove(e.gen);
      }
    }
    for (final g in gens) {
      session?.own.remove(g);
    }
  }

  String? _locOfFolder(String folder) {
    final k = _key(folder);
    if (k == _key(store.directory.path)) return _standalone;
    for (final f in _folders.values) {
      if (_key(f.path) == k) return f.path;
    }
    for (final b in _binders.values) {
      if (_key(b.path) == k) return b.path;
    }
    return null;
  }

  // Merges the recovery entries whose folder is available (only those of
  // [onlyLoc] if given) into the saved pages and deletes each entry once the
  // result has been read back and checked. An entry that can't be applied
  // stays. A busy page, and a page being edited, are skipped (R-1 v5): its
  // own session holds its edits.
  Future<void> _recoverPending({String? onlyLoc}) async {
    final rec = _recovery;
    if (rec == null) return;
    final problem = _lockProblem();
    if (problem != null) {
      // Writes, deletes and replay are refused; the index is still built, by
      // reading only, so opening a page knows what is kept for it.
      debugPrint('Replay refused: $problem');
      if (!rec.indexed) {
        try {
          await rec.indexReadOnly();
        } on Object catch (e) {
          debugPrint('Reading the recovery folder failed: $e');
        }
      }
      return;
    }
    final RecoveryListing listing;
    try {
      listing = await rec.transaction((tx) async {
        if (_relist) _relist = false;
        return tx.list();
      });
    } on Object catch (e) {
      // The index keeps what it knew; the next tick lists again.
      debugPrint('Listing recovery failed: $e');
      return;
    }
    _recoveryProblems = listing.problems;
    _recoveryDamaged = listing.damaged;
    // A failure stays listed only while its entry does.
    final live = {for (final e in listing.entries) _entryKey(e)};
    _replayProblems.removeWhere((k, _) => !live.contains(k));
    // Landed leftovers are deleted, never merged (0130).
    if (rec.landedEntries.isNotEmpty) {
      await _deleteGens(rec, [for (final e in rec.landedEntries) e.gen], null);
    }
    // Entries under a key other than the one their page is listed in go
    // first (3.7: the duplicate is dropped while the other key still exists, or
    // re-keyed), then the rest; a second round takes what re-keying wrote.
    bool stale(RecoveryEntry e) {
      final listed = _loc[e.pageId];
      return listed != null && _locOfFolder(e.folder) != listed;
    }

    final tried = <String>{};
    for (var round = 0; round < 2; round++) {
      final todo = [
        for (final e in round == 0 ? listing.entries : rec.indexEntries)
          if (!tried.contains(e.gen)) e,
      ]..sort((a, b) => (stale(a) ? 0 : 1).compareTo(stale(b) ? 0 : 1));
      if (todo.isEmpty) break;
      for (final e in todo) {
        if (_disposed) return;
        tried.add(e.gen);
        if (rec.isLanded(e.gen)) continue;
        if (!rec.indexEntries.any((x) => x.gen == e.gen)) continue; // retired since the listing
        final id = e.pageId;
        if (_busy.containsKey(id) || _isEditableOpen(id)) continue;
        final loc = _locOfFolder(e.folder);
        if (loc == null || _isLocked(loc) || (onlyLoc != null && loc != onlyLoc)) continue;
        _busy[id] = _busyReplaying;
        try {
          await _replayEntry(rec, e, loc);
        } finally {
          _free(id, _busyReplaying);
        }
      }
    }
    // The kept files go on their own: an entry is retired as soon as its page
    // has landed, so they must not wait for it (or for an entry at all).
    await _landKeptAssets(rec, onlyLoc: onlyLoc);
    if (!_disposed) notifyListeners();
    await _refreshPreview();
  }

  // Replays the kept changes of page [id], which the caller has marked busy.
  // True if nothing is left to replay for it; null never.
  Future<bool?> _replayPage(String id) async {
    final rec = _recovery;
    if (rec == null) return true;
    if (_lockProblem() != null) return false;
    var all = true;
    for (final e in [...rec.entriesOfPage(id)]) {
      if (rec.isLanded(e.gen)) continue;
      final loc = _locOfFolder(e.folder);
      if (loc == null || _isLocked(loc)) {
        all = false;
        continue;
      }
      if (!await _replayEntry(rec, e, loc)) all = false;
    }
    return all;
  }

  // One entry through _recoverEntry, with its failure noted. True once it is
  // replayed and retired.
  Future<bool> _replayEntry(RecoveryStore rec, RecoveryEntry e, String loc) async {
    final key = _entryKey(e);
    final path = _entryPath(e);
    try {
      if (await _recoverEntry(rec, e, loc)) {
        _replayProblems.remove(key);
        _replayHardFailure.remove(e.pageId);
        _told.remove(e.pageId);
        return true;
      }
    } on _ReplayFailure catch (ex) {
      debugPrint('Recovered page ${e.pageId} not accepted: ${ex.detail ?? ex.why}');
      _replayProblems[key] = (path: path, why: ex.why);
      _replayHardFailure.add(e.pageId);
    } on Object catch (ex) {
      // A write failure; the reading failures are _ReplayFailures above.
      debugPrint('Recovering page ${e.pageId} failed: $ex');
      _replayProblems[key] = (
        path: path,
        why:
            'the edits kept for "${_titleOrUntitled(e.page.meta.title)}" could not be saved into '
            'the page file${_osReason(ex)}',
      );
    }
    return false;
  }

  // Deletes the entry of a replay that landed, by its exact generation; one
  // that can't be deleted is marked landed (deleted later, never merged).
  Future<void> _deleteEntry(RecoveryStore rec, RecoveryEntry e) async {
    if (_lockProblem() != null) {
      rec.markLanded(e.gen);
      return;
    }
    try {
      await rec.transaction((tx) => tx.delete(e));
    } on Object catch (ex) {
      debugPrint('Deleting a replayed recovery entry failed: $ex');
      rec.markLanded(e.gen);
    }
  }

  // The two-key rule (3.7): a page that is listed in a place other than its
  // entry's is not recreated; the entry is re-keyed to where the page is
  // listed, or dropped when an identical entry is already there. A page
  // listed nowhere waits while another key for it exists. Returns whether the
  // entry is dealt with (true); false: wait; null: the page is where the entry
  // is, so replay goes on.
  Future<bool?> _twoKeys(RecoveryStore rec, RecoveryEntry e, String loc) async {
    final id = e.pageId;
    final listed = _loc[id];
    if (listed == loc) return null;
    if (listed == null) {
      final other = rec.entriesOfPage(id).any((o) => o.gen != e.gen && _key(o.folder) != _key(e.folder));
      return other ? false : null;
    }
    final PageStore toSt;
    try {
      if (_isLocked(listed)) return false;
      toSt = _storeOf(listed);
    } on NotebookException {
      return false;
    }
    final toFolder = _normalizePath(toSt.directory.path);
    // Recheck the current index right before acting (build note 9).
    final same = rec.entriesFor(toFolder, id).any((o) => o.pageText == e.pageText && o.baseText == e.baseText);
    if (same) {
      await _deleteEntry(rec, e);
      return true;
    }
    final NotedPage? basePage = e.baseText == null ? null : _tryRead(e.baseText!);
    if (e.baseText != null && basePage == null) return false;
    final out = await _keepForRecovery(
      listed,
      toSt,
      e.page,
      base: basePage,
      exactBase: true,
    );
    if (!out.safe) return false;
    await _deleteEntry(rec, e);
    return true;
  }

  // The operating system's own reason, in brackets, when [e] has one (for
  // example " (Access is denied.)"); empty otherwise.
  static String _osReason(Object e) {
    final m = e is FileSystemException ? e.osError?.message : null;
    if (m == null || m.trim().isEmpty) return '';
    final plain = m.trim().replaceAll(RegExp(r'[.\s]+$'), '');
    return ' ($plain)';
  }

  static String _titleOrUntitled(String title) => title.trim().isEmpty ? 'Untitled' : title.trim();

  static String _entryPath(RecoveryEntry e) {
    final p = e.file.path;
    return p.substring(0, p.length - '.entry'.length);
  }

  // The entry's file and time: a newer generation in the same file is another
  // key, so it doesn't inherit the reason of the old one.
  static String _entryKey(RecoveryEntry e) => '${_entryPath(e)}@${e.time.microsecondsSinceEpoch}';

  // Applies one entry. Returns true once it is replayed and retired, false if
  // it isn't due yet; throws a _ReplayFailure (or anything else) if it can't be
  // applied, and then it stays. The entry is retired as soon as its page has
  // landed (the publish went through over exactly what was merged against):
  // merging it again later, against a page the user has changed since, would
  // bring back what they deleted. So once it has landed it is retired whatever
  // the read-back shows; if the read-back is not what landed, the entry's own
  // edits are looked for in it, and if one is gone (or it can't be read) the
  // user is told (_landedProblems). Only a page that landed and reads back as
  // written, but fails the check, stays as an entry. Its kept files are landed
  // apart (_landKeptAssets, 0098); a re-replay after an interruption before
  // the retire is harmless, since the merge of a page with itself changes
  // nothing.
  Future<bool> _recoverEntry(
    RecoveryStore rec,
    RecoveryEntry e,
    String loc,
  ) async {    final mine = e.page;
    // The target is the entry's verified identity. The store refuses entries
    // where it disagrees with the page, so this guards against a regression.
    final id = e.pageId;
    final label = '"${_titleOrUntitled(mine.meta.title)}"';
    if (mine.id != id) {
      throw _ReplayFailure(
        'the edits kept for $label belong to a different page',
        detail: 'the page is "${mine.id}" but the entry says "$id"',
      );
    }
    final st = _storeOf(loc);
    if (!await st.directory.exists()) return false;
    final base = e.baseText == null
        ? NotedPage.create(mine.meta)
        : _readForReplay(e.baseText!, 'the copy kept with the edits for $label');
    // The page is where the entry says, or the entry is re-keyed (3.7).
    final moved = await _twoKeys(rec, e, loc);
    if (moved != null) return moved;    final path = st.pathFor(id);
    final file = File(path);
    // Read, merge, publish only over exactly what was merged against (or only
    // if still absent), and read back: the same loop as _saveClosedPage. If the
    // file changed in between (a newer generation landed), merge again; the
    // entry is retired only once the bytes on disk are the ones merged.
    for (var attempt = 0; attempt < 5; attempt++) {
      await syncHook?.call('recover-reread', path);
      NotedPage? theirs;
      String? theirsText;
      var time = DateTime.now().millisecondsSinceEpoch;
      if (await file.exists()) {
        try {
          theirsText = utf8.decode(await file.readAsBytes());
          time = (await file.lastModified()).millisecondsSinceEpoch;
        } on FormatException catch (ex) {
          throw _ReplayFailure("the saved file of $label isn't a valid page file", detail: '$ex');
        } on FileSystemException catch (ex) {
          // Locked or gone since exists(): look again.
          if (attempt < 4) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
          throw _ReplayFailure(
            "the saved file of $label can't be read just now",
            detail: ex.message,
          );
        }
        theirs = _readForReplay(theirsText, 'the saved file of $label');
        if (theirs.id != id) {
          throw _ReplayFailure(
            'the saved file for $label holds a different page',
            detail: 'the saved file holds page "${theirs.id}", not "$id"',
          );
        }
      }
      // An entry with no base (a deleted page kept by a rollback, or a new
      // page) has no common base with a file that stands at its path: that is
      // a conflict copy (0053), merged as one, in its recovery form (0120).
      final noBase = e.baseText == null;
      final merged = theirs == null
          ? mine
          : noBase
          ? mergeConflictCopy(
              theirs,
              mine,
              _pageCodecs(id),
              copyTime: e.time.millisecondsSinceEpoch,
              forRecovery: true,
            ).page
          : mergePage(base, mine, theirs, _pageCodecs(id), theirsTime: time, markLanded: false).page;
      final out = writePage(merged);
      if (out != theirsText) {
        await syncHook?.call('recover-before-publish', path);
        final published = theirsText == null
            ? await _writeNew(loc, merged)
            : await _writeIfUnchanged(loc, merged, theirsText);
        if (!published) continue; // the file changed since it was read
      }
      final wrote = out != theirsText;
      if (wrote) await syncHook?.call('recover-published', path);
      // From here on, if [wrote], the page has landed (the publish only
      // succeeds over exactly what was merged against): the entry is retired
      // as soon as that is so (0124), whatever the read-back shows. Merging it
      // again later, against a page someone has changed since, would bring
      // back what they deleted.
      String? back;
      for (var read = 0; back == null; read++) {
        try {
          back = await st.readText(id);
        } on FileSystemException {
          if (read < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue; // a lock may pass; a few tries
          }
          if (!wrote) rethrow;
          // Landed but can't be read back to check: retired, and listed.
          debugPrint('Recovered page $id landed but could not be read back to check');
          await _applyClosed(merged, loc, _key(path), path);
          await _deleteEntry(rec, e);
          _landedProblems[id] = (path: path, why: _landedThenChanged(label));
          return true;
        }
      }
      if (back != out) {
        // Nothing of ours was written: the file changed since it was read.
        if (!wrote && attempt < 4) continue;
        if (!wrote) {
          throw _ReplayFailure(
            'the saved file of $label keeps changing',
            detail: 'the page file changed on every attempt to merge into it',
          );
        }
        // Another writer is on top of what landed: not merged again (that
        // could bring back what they deleted), and the external-change check
        // picks their file up as it does any other. The entry's own edits are
        // looked for in what is there; if any is gone, or it can't be read,
        // the user is told.
        final key = _key(path);
        NotedPage? now;
        String? unreadable;
        try {
          now = readPage(back);
          if (now.id != id) unreadable = 'it holds a different page';
        } on PageFormatException catch (ex) {
          unreadable = ex.message;
        }
        await _deleteEntry(rec, e);
        if (now == null || unreadable != null) {
          // Listed as a page that can't be opened, like any file that turns
          // unreadable. A file that holds another page keeps no last known
          // text, so a later check looks at it again (and lets go of a choice).
          if (now != null) {
            _known.remove(key);
          } else {
            _known[key] = back;
          }
          final notice = 'The edits kept for $label were saved, but the page was then changed '
              'and can no longer be read ($unreadable)';
          _landedProblems[id] = (path: path, why: notice);
          _knownUnreadable(
            loc,
            key,
            path,
            notice,
          );
          return true;
        }
        await _applyClosed(now, loc, key, path);
        final lost = _ownEditsMissing(base, mine, now);
        if (lost != null) {
          debugPrint('Recovered page $id landed, then changed: $lost');
          _landedProblems[id] = (path: path, why: _landedThenChanged(label));
        }
        return true;
      }
      final result = _readForReplay(back, 'the saved file of $label');
      final why = theirs != null && noBase
          ? verifyConflictCopyMerge(result, theirs, mine, forRecovery: true)
          : verifyRecoveredPage(base: base, mine: mine, theirs: theirs, result: result);
      if (why != null) throw _ReplayFailure(_notAllKept(label), detail: why);
      await _applyClosed(readPage(back), loc, _key(path), path);
      await _deleteEntry(rec, e);
      return true;
    }
    throw _ReplayFailure(
      'the saved file of $label keeps changing',
      detail: 'the page file changed on every attempt to merge into it',
    );
  }

  static String _landedThenChanged(String label) =>
      'The edits kept for $label were saved, but the page changed right after; check it';

  // Why an edit of [mine] (relative to [base]) is not in [result], or null if
  // each one is: a box it added or changed is there (with its content, or
  // conflicted, or changed again since: all fine) and not back as in [base];
  // a box it deleted is not back exactly as in [base]; a title it changed is
  // not [base]'s again. What [mine] didn't touch isn't looked at, so what
  // another writer deleted of those doesn't count.
  static String? _ownEditsMissing(NotedPage base, NotedPage mine, NotedPage result) {
    final baseById = {for (final n in base.nodes) n.id: n};
    final mineIds = {for (final n in mine.nodes) n.id};
    for (final m in mine.nodes) {
      final b = baseById[m.id];
      if (b != null && b.toRaw() == m.toRaw()) continue;
      final x = result.node(m.id);
      if (x == null) return 'box ${m.id} is missing';
      if (b != null && x.toRaw() == b.toRaw()) return 'the edit of box ${m.id} was undone';
    }
    for (final b in base.nodes) {
      if (mineIds.contains(b.id)) continue;
      final x = result.node(b.id);
      if (x != null && x.toRaw() == b.toRaw()) return 'box ${b.id}, deleted, is back';
    }
    if (mine.meta.title != base.meta.title && result.meta.title == base.meta.title) {
      return 'the title is the old one again';
    }
    return null;
  }

  // Reads page text during a replay; a format problem becomes a plain
  // _ReplayFailure naming what was read ([what], e.g. 'the saved file of "T"').
  static NotedPage _readForReplay(String text, String what) {
    try {
      return readPage(text);
    } on UnsupportedPageFormatException catch (ex) {
      throw _ReplayFailure('$what is from a newer version of Noted', detail: ex.message);
    } on PageFormatException catch (ex) {
      throw _ReplayFailure("$what isn't a valid page file", detail: ex.message);
    }
  }

  static String _notAllKept(String label) => 'some of the edits kept for $label did not make it into the saved page';

  // Files added while the page's folder was away were kept in the recovery
  // folder, in `<page id>.assets`. That folder is its own marker: every one
  // whose page is in an available location (of [onlyLoc] if given) is landed,
  // whether or not an entry exists, and goes only when each file is verified
  // at its target. A failure lists the folder and is retried by the folder
  // check. A folder whose page isn't found stays; it is listed only when
  // every location is available and no entry waits for that page, so it
  // doesn't nag while its folder is merely away.
  Future<void> _landKeptAssets(RecoveryStore rec, {String? onlyLoc}) {
    final run = _landChain.then((_) => _landKeptAssetsNow(rec, onlyLoc));
    _landChain = run.catchError((Object _) {});
    return run;
  }

  Future<void> _landKeptAssetsNow(RecoveryStore rec, String? onlyLoc) async {
    if (_disposed || !await rec.directory.exists()) return;
    final suffix = '.assets';
    final folders = <Directory>[];
    await for (final d in rec.directory.list(followLinks: false)) {
      if (d is Directory && d.path.endsWith(suffix)) folders.add(d);
    }
    final unmatched = <Directory, String>{};
    var retry = false;
    final present = <String>{};
    for (final kept in folders) {
      if (_disposed) return;
      present.add(kept.path);
      final name = kept.path.split(RegExp(r'[\\/]')).last;
      final id = name.substring(0, name.length - suffix.length);
      final loc = _loc[id];
      if (loc == null) {
        unmatched[kept] = id;
        continue;
      }
      if (_isLocked(loc) || (onlyLoc != null && loc != onlyLoc)) continue;
      try {
        final to = _assetsDir(loc, id);
        final done = <_LandedFile>[];
        await _landFiles(kept, to, done);
        for (final f in done) {
          if (!await _holdsContent(f.source, f.name, f.target)) {
            throw FileSystemException('The kept file ${f.name} did not land with its content');
          }
        }
        await keptLandedHook?.call(kept.path);
        // Only what was verified is deleted, one file at a time; whatever else
        // is in the folder (an incomplete temp file, a file that arrived
        // meanwhile) keeps the folder.
        for (final f in done) {
          await f.source.delete();
        }
        await _removeEmptyDirs(kept, top: true);
        _keptProblems.remove(kept.path);
        _attachments?.filesChanged();
      } on _KeptFolderNotEmpty catch (e) {
        debugPrint('Kept folder of page $id is not empty: ${e.left}');
        _keptProblems[kept.path] =
            'The files kept for "${_titleOrUntitled(_metas[id]?.title ?? '')}" were moved into place, '
            'but other files stay in the kept folder (${e.left.join(', ')}).';
        retry = true;
      } on FileSystemException catch (e) {
        debugPrint('Moving the kept files of page $id failed: $e');
        // The app's own messages are plain; an OS error gets its reason in brackets.
        final detail = e.osError == null ? ': ${e.message}' : _osReason(e);
        _keptProblems[kept.path] =
            'The files kept for "${_titleOrUntitled(_metas[id]?.title ?? '')}" could not be moved into place$detail.';
        retry = true;
      }
    }
    if (unmatched.isNotEmpty) {
      final waiting = {for (final e in (await rec.list()).entries) e.pageId};
      final settled = _settingsHeld == null &&
          !_defaultGone &&
          _folders.values.every((f) => f.available) &&
          _binders.values.every((b) => b.available);
      for (final MapEntry(key: kept, value: id) in unmatched.entries) {
        if (settled && !waiting.contains(id)) {
          _keptProblems[kept.path] = 'These kept files have no page to go with.';
        } else {
          _keptProblems.remove(kept.path);
        }
      }
    }
    _keptProblems.removeWhere((k, _) => !present.contains(k) && !Directory(k).existsSync());
    // A run limited to one location says nothing about the others.
    _keptRetry = retry || (onlyLoc != null && _keptRetry);
  }

  static final RegExp _hashName = RegExp(r'^([0-9a-f]{64})(\.[a-z0-9]+)?$');

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Runs after the kept files of a folder are landed and verified, before
  /// they are deleted. For tests.
  @visibleForTesting
  Future<void> Function(String keptFolder)? keptLandedHook;

  /// Runs just before a non-hash kept file is published at its target. For
  /// tests.
  @visibleForTesting
  static void Function()? landBeforePublishHook;

  /// Runs just before a hash-named kept file is renamed into place; it may
  /// throw to stand in for a failed rename. For tests.
  @visibleForTesting
  static void Function()? landHashRenameHook;

  /// Runs just before a page put back at its old place during a failed move
  /// is published. For tests.
  @visibleForTesting
  Future<void> Function()? restoreBeforePublishHook;

  // Whether [target] holds what the kept [source] holds under [name]: a file
  // named by its content hash is checked against the hash, any other by its
  // bytes. (The hash function is noted_core's; it takes whole bytes, and the
  // app has no hashing dependency of its own to stream with.)
  static Future<bool> _holdsContent(File source, String name, File target) async {
    if (!await target.exists()) return false;
    final bytes = await target.readAsBytes();
    final m = _hashName.firstMatch(name);
    if (m != null) return contentHash(bytes) == m.group(1);
    final kept = await source.readAsBytes();
    if (kept.length != bytes.length) return false;
    for (var i = 0; i < kept.length; i++) {
      if (kept[i] != bytes[i]) return false;
    }
    return true;
  }

  // Copies the files of the kept folder [from] into [to]. Each goes to a temp
  // name in [to], is checked there and renamed into place, so a partly copied
  // file is never taken for the real one. A target named by its hash that
  // doesn't hold it is replaced (it is a partial copy); any other name that
  // differs is someone's file that only shares the name, and is never
  // replaced. Which names land is [attachmentNameToTake]'s rule (a `<hash>.tmp`
  // attachment keeps its name; a complete `<hash>.<ext>.tmp` lands without
  // `.tmp`). Leftover unique temp names of a stopped write
  // (`<name>.<micros>-<n>.tmp`) are first put back, when complete, under their
  // own name in [from] and land with the rest; the others stay and keep the
  // folder. Every file that is in place with verified content is added to
  // [done].
  static Future<void> _landFiles(Directory from, Directory to, List<_LandedFile> done) async {
    await to.create(recursive: true);
    await sweepAttachmentLeftovers(from, AttachmentCopy());
    await for (final e in from.list()) {
      final raw = _baseName(e.path);
      final sep = Platform.pathSeparator;
      if (e is Directory) {
        await _landFiles(e, Directory('${to.path}$sep$raw'), done);
        continue;
      }
      if (e is! File) continue;
      final name = await attachmentNameToTake(e, raw);
      if (name == null) continue;
      final target = File('${to.path}$sep$name');
      final tmp = File('${target.path}.landing.tmp');
      if (await _holdsContent(e, name, target)) {
        if (await tmp.exists()) await tmp.delete(); // left by an earlier try
        done.add(_LandedFile(e, name, target));
        continue;
      }
      final isHash = _hashName.firstMatch(name) != null;
      final collision = FileSystemException('a different $name is already there; both are kept', target.path);
      if (!isHash && await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw collision;
      }
      if (await tmp.exists()) await tmp.delete();
      try {
        await e.copy(tmp.path);
        if (!await _holdsContent(e, name, tmp)) {
          throw FileSystemException('The copy of $name differs from the kept file', e.path);
        }
        if (!isHash) {
          // Never replaces: a different file that arrived since the check
          // above stays as it is, and the kept source stays too.
          if (!await publishExclusive(tmp, target.path, beforeOsCall: landBeforePublishHook)) throw collision;
        } else {
          try {
            landHashRenameHook?.call();
            await tmp.rename(target.path);
          } on FileSystemException {
            // A target that holds its hash is already the file; any other
            // is a partial copy and goes.
            if (await _holdsContent(e, name, target)) {
              await tmp.delete();
            } else {
              if (await target.exists()) await target.delete();
              await tmp.rename(target.path);
            }
          }
        }
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } on Object {
          // Only a cleanup; the original error is what counts.
        }
        rethrow;
      }
      done.add(_LandedFile(e, name, target));
    }
  }

  // Removes the emptied folders under [d] and then [d] itself, none of them
  // recursively: a folder that still holds something stays, and that is
  // reported.
  static Future<void> _removeEmptyDirs(Directory d, {bool top = false}) async {
    await for (final e in d.list()) {
      if (e is Directory) await _removeEmptyDirs(e);
    }
    try {
      await d.delete();
    } on FileSystemException {
      if (!top) return;
      final left = [await for (final e in d.list(recursive: true)) _baseName(e.path)];
      throw _KeptFolderNotEmpty(left);
    }
  }

  // Like [_delete], but only if the file still holds exactly [expectedText]
  // (see PageStore.deleteIfUnchanged); a changed file is kept.
  Future<DeleteResult> _deleteIfUnchanged(String loc, String id, String expectedText) async {
    _assertWritable(loc);
    final st = _storeOf(loc);
    final key = _key(st.pathFor(id));
    // One at a time with a scan of the folder, which would put the set-aside
    // file back (see _underFolderLock). The job is the single store call.
    final r = await _underFolderLock(st, () async {
      final path = st.pathFor(id);
      final r = await st.deleteIfUnchanged(id, expectedText);
      if (r.deleted) _emitDeleted(path);
      return r;
    });
    if (r.deleted || r.outcome == DeleteOutcome.absent) {
      _known.remove(key);
      _pathId.remove(key);
      _conflicts.remove(id);
    }
    return r;
  }

  // Puts back the source file with exactly [text] (what it held when it was
  // copied), only if nothing is at its path when it is published. [page] is the
  // parsed [text], for the bookkeeping.
  Future<bool> _restoreText(
    String loc,
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
  }) async {
    await _assertCanWrite(loc);
    final st = _storeOf(loc);
    final identity = _identityOf(() => text);
    final path = st.pathFor(page.id);
    final key = _key(path);
    // Outside the lock, so a test can pause a publish without holding the folder.
    await syncHook?.call('new-before-publish', st.directory.path);
    // The publish and its report are one job, so the feed keeps the lock's order.
    final published = await _underFolderLock(st, () async {
      // Checked again inside the lock: the location may have gone while this waited.
      await _assertCanWrite(loc);
      if (!await st.saveNewText(page, text, beforePublish: beforePublish)) return false;
      _emitPublished(path, identity, () => text);
      return true;
    });
    if (!published) return false;
    _known[key] = text;
    _pathId[key] = page.id;
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
    onPageContent?.call(loc, page);
    return true;
  }

  String _placeName(String loc) => _binders[loc]?.title ?? (loc == _standalone ? 'Pages' : loc);

  // How many times a write that finds its file changed rereads, merges and
  // tries again before it gives up.
  static const int _maxWriteTries = 5;

  // Reads page [id] through the store, which refuses a file that holds another
  // page (so that page's content is never served under this id). A refusal
  // queues a check of the file, which settles what page the file is.
  Future<NotedPage> _loadPage(PageStore st, String id) async {
    try {
      return await st.load(id);
    } on PageFormatException catch (e) {
      if (e.message == _holdsOtherPage && !_disposed) unawaited(checkFile(st.pathFor(id)));
      rethrow;
    }
  }

  // Writes a page that is new (a fresh id): nothing may be at its path, and a
  // file that is there is never written over.
  Future<void> _writeNewPage(String loc, NotedPage page) async {
    if (await _writeNew(loc, page)) return;
    throw const NotebookException(
      'A file for the new page already exists, so it was not created. The existing file was left as it is.',
    );
  }

  // Changes page [id], which is not open, and saves it over exactly the file
  // that was read (compare-and-swap, 0128). If the file changed in between, it
  // is read again and [change] is applied to what is there now, which is the
  // merge for a header-only change. [change] returns null for no change (then
  // nothing is written and null is returned). Gives up after [_maxWriteTries].
  Future<NotedPage?> _updateClosedPage(String loc, String id, NotedPage? Function(NotedPage page) change) =>
      _track('change of page $id', _updateClosedPageNow(loc, id, change));

  Future<NotedPage?> _updateClosedPageNow(
    String loc,
    String id,
    NotedPage? Function(NotedPage page) change,
  ) async {
    final st = _storeOf(loc);
    for (var attempt = 0; attempt < _maxWriteTries; attempt++) {
      final text = await st.readText(id);
      await syncHook?.call('closed-update-read', st.pathFor(id));
      final read = readPage(text);
      if (read.id != id) {
        // The file holds another page: its header is never changed under this
        // page's name. A check settles which page the file is.
        unawaited(checkFile(st.pathFor(id)));
        throw const NotebookException("This page's file holds a different page, so the change was not saved.");
      }
      final next = change(read);
      if (next == null) return null;
      if (!await _writeIfUnchanged(loc, next, text)) continue;
      // The page may have been opened meanwhile, from the file as it was before
      // this write: its editor takes the change too, or its next autosave would
      // put the old header back.
      final c = _current;
      if (c != null && c.page.id == id && c.page.meta != next.meta) c.updateMeta(next.meta);
      return next;
    }
    throw const NotebookException(
      'The page file keeps changing, so the change was not saved. Try again in a moment.',
    );
  }

  // Like [_write], for a page that must be NEW at its path: false, with
  // nothing written, when a file is there at the moment of publishing.
  Future<bool> _writeNew(String loc, NotedPage page, {Future<void> Function()? beforePublish}) async {
    await _assertCanWrite(loc);
    final st = _storeOf(loc);
    final identity = _identityOf(() => writePage(page));
    final path = st.pathFor(page.id);
    final key = _key(path);
    await syncHook?.call('new-before-publish', st.directory.path);
    // The publish and its report are one job, so the feed keeps the lock's order.
    final published = await _underFolderLock(st, () async {
      // Checked again inside the lock: the location may have gone while this waited.
      await _assertCanWrite(loc);
      if (!await st.saveNew(page, beforePublish: beforePublish)) return false;
      _emitPublished(path, identity, () => writePage(page));
      return true;
    });
    if (!published) return false;
    _known[key] = writePage(page);
    _pathId[key] = page.id;
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
    onPageContent?.call(loc, page);
    return true;
  }

  // PageStore.scan puts back what an interrupted compare-and-swap replace
  // left aside, so it must not run while one is in flight on the same folder
  // (0128). Both go through _underFolderLock: one at a time per folder. The job
  // is a single store call, never another locked call, so they can't wait on
  // each other.
  Future<T> _underFolderLock<T>(PageStore st, Future<T> Function() job) =>
      _lockRun(st.directory, job);

  // How long a read of a page file waits for its folder's other jobs.
  static const Duration _readLockWait = Duration(milliseconds: 500);

  // A single read of a page file, taking its turn with the writes and scans of
  // [folder] (they are short, so the turn comes at once). A job that has the
  // folder for longer than [_readLockWait] is hung (a stalled write holds its
  // lock until it ends, and the reads of that folder must not wait for it), and
  // the read goes ahead without the lock, as it did before reads took turns.
  // Not queued at all when the caller already runs inside a job on the folder,
  // which would wait on itself.
  Future<T> _readUnderFolderLock<T>(Directory folder, Future<T> Function() read) async {
    if (FolderLocks.isHeld(folder)) return read();
    final started = Completer<void>();
    var abandoned = false;
    final job = folderLocks.run<T?>(folder, () async {
      if (abandoned) return null;
      started.complete();
      return read();
    });
    final timer = Timer(_readLockWait, () {
      if (started.isCompleted) return;
      abandoned = true;
      started.complete();
    });
    await started.future;
    timer.cancel();
    if (!abandoned) return (await job) as T;
    // Its turn, when it comes, does nothing.
    unawaited(job.then<void>((_) {}, onError: (_) {}));
    return read();
  }

  // The conflict copies a scan of [loc] found: merged later when the place can
  // be written ([merge]); in a pull-only place they are never merged, and are
  // listed as duplicates of their page (G3).
  void _takeCopies(String loc, List<PageEntry> entries, List<UnreadablePage> bad, {required bool merge}) {
    final copies = entries.whereType<ConflictCopyPage>();
    if (_pullOnly(loc)) {
      bad.addAll(copies.map((c) => UnreadablePage(c.path, 'duplicate page id ${c.meta.id}')));
    } else if (merge) {
      _pendingCopies.addAll(copies.map((c) => c.path));
    }
  }

  Future<List<PageEntry>> _scan(PageStore st, {bool createFolder = true, bool sweep = true}) {
    // A store made again (a binder opened again) is told which files were chosen.
    final dir = _key(st.directory.path);
    for (final e in _adoptedFiles.entries) {
      if (_key(File(e.value).parent.path) == dir) st.adopt(e.key, e.value);
    }
    return _underFolderLock(st, () async {
      // No scan sweeps while a found add runs: set-aside files may belong to a
      // write another device has under way.
      // A pull-only folder is never created by a read (G2).
      final entries = await st.scan(
        createFolder: createFolder && !_pullOnly(st.directory.path),
        sweep: sweep && _sweepOff == 0,
      );
      // A chosen file that now holds another page: the open or a busy page
      // keeps it (its next save meets that page and is blocked); any other
      // page lets go of the choice, and a duplicate is promoted by the caller.
      for (final e in st.releasedAdoptions.entries.toList()) {
        if (_adoptedFiles[e.key] case final a? when _key(a) == _key(e.value)) {
          if (e.key == currentId || _busy.containsKey(e.key)) {
            st.adopt(e.key, e.value);
          } else {
            _releaseChoice(e.key, e.value, store: st);
          }
        }
      }
      final listedBad = {
        for (final u in entries.whereType<UnreadablePage>()) _key(u.path),
      };
      for (final e in _adoptedFiles.entries.toList()) {
        final path = e.value;
        if (_key(File(path).parent.path) != dir) continue;
        if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound &&
            Directory(File(path).parent.path).existsSync()) {
          // Absent while its folder is there: held until a check confirms it
          // gone (the next checkFolders), or the file is back by then.
          _goneChosen[e.key] = path;
          st.adopt(e.key, path);
        } else if (_choiceHeld(e.key) || listedBad.contains(_key(path))) {
          st.adopt(e.key, path);
        }
      }
      return entries;
    });
  }

  /// Whether the notebook still tracks the file at [path] (its last known
  /// text or its page id).
  @visibleForTesting
  void setKnownTextForTest(String path, String text) => _known[_key(path)] = text;

  @visibleForTesting
  bool knowsFileForTest(String path) => _known.containsKey(_key(path)) || _pathId.containsKey(_key(path));

  /// Scans the folder of location [loc] through the folder lock, as the
  /// notebook's own scans do.
  @visibleForTesting
  Future<List<PageEntry>> scanLocationForTest(String loc) async {
    final entries = await _scan(_storeOf(loc));
    await _promoteReleased();
    return entries;
  }

  // Writes [page] only if its file still holds exactly [expectedText] (null: no
  // file) at the moment of replacing, the only way a page file that may have
  // changed is written: false, with nothing written, when it does not (see
  // PageStore.saveIfUnchanged; the caller rereads, merges and tries again).
  Future<bool> _writeIfUnchanged(String loc, NotedPage page, String? expectedText) async =>
      (await _writeIfUnchangedFull(loc, page, expectedText)).landed;

  // As [_writeIfUnchanged], and reports the identity of what was published
  // (computed from the text in hand before the lock, when the feed is live or
  // [wantIdentity]). With [onlyAtPath], nothing is written when the page's file
  // is at another path inside the lock job ([_WriteOutcome.pathMoved]). The
  // feed event is added inside the job, after the store call succeeded, so
  // events are in the lock's order; no listener code runs there.
  Future<_WriteOutcome> _writeIfUnchangedFull(
    String loc,
    NotedPage page,
    String? expectedText, {
    bool wantIdentity = false,
    String? onlyAtPath,
  }) async {
    _assertWritable(loc);
    final st = _storeOf(loc);
    final published = wantIdentity || _feedLive ? identityOfForTest(utf8.encode(writePage(page))) : null;
    var pathMoved = false;
    String? publishedAt;
    // The check is made inside the lock, right before the replace.
    final result = await _underFolderLock(st, () async {
      await _assertCanWrite(loc);
      final path = st.pathFor(page.id);
      if (onlyAtPath != null && _key(path) != _key(onlyAtPath)) {
        pathMoved = true;
        return null;
      }
      final r = await st.saveIfUnchanged(page, expectedText);
      if (r.replaced) {
        publishedAt = path;
        // A listener that subscribed after the check above: hashed inside the
        // emit's guard, so nothing can throw after the landed write.
        _emitPublished(path, published, () => writePage(page));
      }
      return r;
    });
    if (pathMoved) return const _WriteOutcome(landed: false, pathMoved: true);
    if (!result!.replaced) return const _WriteOutcome(landed: false);
    final key = _key(publishedAt ?? st.pathFor(page.id));
    _known[key] = writePage(page);
    _pathId[key] = page.id;
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
    onPageContent?.call(loc, page);
    return _WriteOutcome(landed: true, identity: published);
  }

  // Merging a remote version (sync stage 1) ----------------------------------

  /// Three-way merges [remote], a version of the page file at [path] that
  /// [base] was the common ancestor of, into the notebook's page and saves the
  /// result over exactly the file that was read (compare-and-swap, 0128). The
  /// bytes are page files; nothing here parses anything else. [remoteTime] is
  /// the remote file's time for the merge (default: now).
  ///
  /// [RemoteMergeOutcome.changed]: the file kept changing, the save was
  /// skipped, or the page is busy. [RemoteMergeOutcome.refused]: any other
  /// failure, with a reason. Neither writes anything through this call, and it
  /// never writes blind. A closed page is merged in one save-chain job; the open
  /// page takes the merge in the editor (not an undo step) and saves through its
  /// normal save.
  ///
  /// Never call it inside a [FolderLocks] job on the page's folder (it awaits a
  /// write on that folder: a deadlock; asserted in debug builds), nor inside a
  /// save-chain job.
  Future<RemoteMergeResult> mergeRemote(
    String path,
    List<int> base,
    List<int> remote, {
    int? remoteTime,
  }) async {
    assert(
      !FolderLocks.isHeld(File(path).parent),
      'mergeRemote runs inside a FolderLocks job on its own folder',
    );
    assert(!_chain.insideJob, 'mergeRemote runs inside a save-chain job: it would wait on itself');
    if (_disposed) return const RemoteMergeResult.refused('the notebook is closed');
    try {
      await flush();
      final loc = _locationOf(path);
      if (loc == null) return const RemoteMergeResult.refused('the file is not in a joined location');
      final NotedPage basePage;
      final NotedPage remotePage;
      try {
        basePage = readPage(utf8.decode(base));
      } on Object {
        return const RemoteMergeResult.refused('the base version can not be read');
      }
      try {
        remotePage = readPage(utf8.decode(remote));
      } on Object {
        return const RemoteMergeResult.refused('the remote version can not be read');
      }
      final id = remotePage.id;
      if (basePage.id != id) return const RemoteMergeResult.refused('the base holds another page');
      final time = remoteTime ?? DateTime.now().millisecondsSinceEpoch;
      for (var round = 0; round < _maxWriteTries; round++) {
        final c = _current;
        final RemoteMergeResult? r;
        if (c != null && c.page.id == id) {
          r = await _mergeRemoteOpen(loc, path, id, basePage, remotePage, time);
        } else {
          final queuedOn = _chain.generation;
          // A test seam: the page may be opened here, before the job is queued.
          await syncHook?.call('merge-remote-closed', path);
          r = await _afterSaves(
            () => _mergeRemoteClosed(loc, path, id, basePage, remotePage, time, queuedOn),
            what: 'merge of remote page $id',
            pages: {id},
          );
        }
        // Null: the page was opened (or closed) while this waited; try the other path.
        if (r != null) return r;
      }
      return const RemoteMergeResult.changed();
    } on NotebookException catch (e) {
      return RemoteMergeResult.refused(e.message);
    } on Object catch (e) {
      return RemoteMergeResult.refused(describeError(e));
    }
  }

  // The path rule: the page is tracked at [path] in [loc], and that is the file
  // its store writes. A same-id duplicate or an unchosen file is never merged.
  String? _remotePathProblem(String loc, String path, String id, PageStore st) {
    final key = _key(path);
    if (_pathId[key] != id || _loc[id] != loc || _key(st.pathFor(id)) != key) {
      return 'the file is not the one this page is saved in';
    }
    return null;
  }

  // The page is closed: one chain job from the read to the compare-and-swap, so
  // an open of the page can't interleave. Null: the page is open now.
  Future<RemoteMergeResult?> _mergeRemoteClosed(
    String loc,
    String path,
    String id,
    NotedPage basePage,
    NotedPage remotePage,
    int time,
    int queuedOn,
  ) async {
    for (var attempt = 0; attempt < _maxWriteTries; attempt++) {
      if (_current?.page.id == id) return null;
      // A page held by a save or a move isn't merged under it, except one that
      // waited on the very save that holds it (as the AI's closed write).
      final heldByItsOwnQueue = queuedOn != _chain.generation && _busy[id] == _busyDetached;
      if (_busy.containsKey(id) && !heldByItsOwnQueue) return const RemoteMergeResult.changed();
      final st = _storeOf(loc);
      if (_isLocked(loc)) return const RemoteMergeResult.refused('the location is read-only');
      final problem = _remotePathProblem(loc, path, id, st);
      if (problem != null) return RemoteMergeResult.refused(problem);
      final String text;
      final NotedPage mine;
      try {
        text = await st.readText(id);
        mine = readPage(text);
      } on Object {
        return const RemoteMergeResult.refused('the page file can not be read');
      }
      if (mine.id != id) return const RemoteMergeResult.refused('the page file holds another page');
      final merged = mergePage(basePage, mine, remotePage, _pageCodecs(id), theirsTime: time).page;
      if (writePage(merged) == text) {
        // Nothing to write, but the file may have been replaced since the
        // watcher last looked: the live state takes it in as after a landing.
        // A file the notebook already holds as it is changes nothing, and must
        // not count as an edit of the binder.
        final key = _key(path);
        if (_known[key] != text) {
          _known[key] = text;
          _pathId[key] = id;
          _setConflict(id, hasConflicts(merged));
          onPageContent?.call(loc, merged);
          _metas[id] = merged.meta;
          _touch(loc);
          _rebuildTree();
        }
        return RemoteMergeResult.merged(identityOfForTest(utf8.encode(text)), wrote: false);
      }
      final w = await _writeIfUnchangedFull(loc, merged, text, wantIdentity: true, onlyAtPath: path);
      if (w.pathMoved) return const RemoteMergeResult.refused('the file is not the one this page is saved in');
      if (!w.landed) continue; // the file changed: read and merge again
      _metas[id] = merged.meta;
      _touch(loc);
      _rebuildTree();
      return RemoteMergeResult.merged(w.identity, wrote: true);
    }
    return const RemoteMergeResult.changed();
  }

  // The page is open: merge into the editor with the unsaved edits, then save
  // through the normal save, which rereads the file and merges what arrived.
  Future<RemoteMergeResult?> _mergeRemoteOpen(
    String loc,
    String path,
    String id,
    NotedPage basePage,
    NotedPage remotePage,
    int time,
  ) async {
    // No await from here to the apply.
    final c = _current;
    if (c == null || c.page.id != id) return null;
    final key = _key(path);
    if (!_isOpenFile(loc, key)) return const RemoteMergeResult.refused('the file is not the one this page is saved in');
    if (_isLocked(loc)) return const RemoteMergeResult.refused('the location is read-only');
    final st = _storeOf(loc);
    final problem = _remotePathProblem(loc, path, id, st);
    if (problem != null) return RemoteMergeResult.refused(problem);
    if (c.readOnly || _diskBlockId == id || _preview != null || (_trouble.isTrouble && _trouble.pageId == id)) {
      return const RemoteMergeResult.refused('the open page can not be saved now');
    }
    if (_busy.containsKey(id)) return const RemoteMergeResult.changed();
    final knownBefore = _known[key]; // the file as last seen, before the merge
    final merged = mergePage(basePage, c.page, remotePage, _pageCodecs(id), theirsTime: time).page;
    final changed = writePage(merged) != writePage(c.page);
    if (changed) c.applyExternal(merged); // not an undo step
    // The save of the merged page (or of the page as it is when nothing
    // changed), which reports how it ended.
    _saveTimer?.cancel();
    _saveTimer = null;
    final pending = _pendingSave;
    final NotedPage toSave;
    final int seq;
    if (pending != null && pending.id == id) {
      _pendingSave = null;
      toSave = pending;
      seq = _pendingSeq;
    } else {
      toSave = c.page;
      seq = _session?.seq ?? 0;
    }
    final res = await _enqueueSave(toSave, seq, wantIdentity: true);
    if (res.end == SaveEnd.landed) {
      // "Wrote": the file now differs from what the notebook last saw there.
      final before = knownBefore == null ? null : identityOfForTest(utf8.encode(knownBefore));
      return RemoteMergeResult.merged(res.identity, wrote: res.identity != before);
    }
    if (res.end == SaveEnd.skipped || res.keepsChanging) return const RemoteMergeResult.changed();
    return const RemoteMergeResult.refused('the page could not be saved; the edits are kept');
  }

  // External changes (0020) ---------------------------------------------------

  /// Whether the page [id] has a conflicted box, on screen or in its file.
  bool hasConflict(String id) => _conflicts.contains(id);

  /// Records whether page [id] has a conflicted box. Tells the listeners if
  /// that changed.
  void _setConflict(String id, bool value) {
    final changed = value ? _conflicts.add(id) : _conflicts.remove(id);
    if (changed && !_disposed) notifyListeners();
  }

  /// A comparable form of a file path: absolute, with forward slashes and,
  /// on Windows, lower case.
  static String _key(String path) {
    final p = File(path).absolute.path.replaceAll(r'\', '/');
    return Platform.isWindows ? p.toLowerCase() : p;
  }

  String? _locationOf(String path) {
    final dir = _key(File(path).parent.path);
    if (dir == _key(store.directory.path)) return _defaultGone ? null : _standalone;
    for (final f in _folders.values) {
      if (f.available && _key(f.path) == dir) return f.path;
    }
    for (final b in _binders.values) {
      // A binder with a damaged file still has its pages looked after.
      if ((b.available || b.readOnly) && _key(b.path) == dir) return b.path;
    }
    return null;
  }

  /// Starts and stops the folder watchers to match the available folders.
  void _syncWatchers() {
    if (!watchFiles || _disposed) return;
    final wanted = <String, String>{
      if (!_defaultGone) _standalone: store.directory.path,
      for (final f in _folders.values)
        if (f.available) f.path: f.path,
      // A binder that can't be used is watched too, as long as its folder
      // exists, so a repaired or restored binder file brings it back.
      for (final b in _binders.values)
        if (!b.missing && (b.available || Directory(b.path).existsSync())) b.path: b.path,
    };
    for (final loc in _watchers.keys.toList()) {
      if (!wanted.containsKey(loc)) unawaited(_watchers.remove(loc)!.cancel());
    }
    wanted.forEach((loc, dir) {
      if (_watchers.containsKey(loc)) return;
      try {
        // A watcher that fails or ends usually means its folder went away:
        // look at the folders now instead of waiting for the timer.
        _watchers[loc] = Directory(dir).watch().listen(
          _onFileEvent,
          onError: (Object e) {
            debugPrint('Watching $dir failed: $e');
            unawaited(checkFolders());
          },
          onDone: () {
            _watchers.remove(loc);
            unawaited(checkFolders());
          },
        );
      } on FileSystemException catch (e) {
        debugPrint('Watching $dir failed: $e');
      }
    });
    _syncRootWatchers({for (final d in wanted.values) _key(d)});
  }

  void _onFileEvent(FileSystemEvent e) {
    // A folder that appeared in a folder discovery looks in (standalone folders
    // are watched here): a binder may have arrived.
    if (e.isDirectory) _onRootEvent(e);
    // Something in or about an assets folder: the open page's boxes may be
    // waiting for a file.
    if (e.path.contains('.assets') || (e is FileSystemMoveEvent && (e.destination ?? '').contains('.assets'))) {
      _attachments?.filesChanged();
    }
    _schedule(e.path);
    if (e is FileSystemMoveEvent && e.destination != null) _schedule(e.destination!);
  }

  // Only `.canvas` files and binder files matter; the temporary files of our
  // own atomic writes end in `.tmp` and are ignored here.
  void _schedule(String path) {
    final binderFile = _isBinderFile(path);
    if (!binderFile && !path.endsWith(PageStore.extension)) return;
    final key = _key(path);
    _debounce[key]?.cancel();
    _debounce[key] = Timer(watchDebounce, () {
      _debounce.remove(key);
      unawaited(binderFile ? checkBinderFile(path) : checkFile(path));
    });
  }

  bool _isBinderFile(String path) =>
      path.split(RegExp(r'[\\/]')).last == binderFileName;

  /// Looks at the page file [path] after it may have been changed by someone
  /// else, and brings the tree and the open page up to date (0020).
  ///
  /// Does nothing if the file still holds exactly what this app last wrote or
  /// read. A page that isn't open has its header re-read (a new file adds a
  /// page, a deleted one removes it, an unreadable one is listed). The open
  /// page is merged per box with the file, keeping unsaved local edits; if its
  /// file was deleted the page stays as it is and the next save writes it
  /// again.
  Future<void> checkFile(String path) {
    final job = _checking.then((_) async {
      await _chain.idle; // let writes in flight land first
      if (!_disposed) await _checkFile(path);
    }).catchError((Object e) {
      debugPrint('Checking $path failed: $e');
    });
    _checking = job;
    return job;
  }

  /// Tells the notebook that the files at [paths] arrived, changed or were
  /// removed by something other than a watcher (the OneDrive pull on a device
  /// that has no folder watching). It runs what a watcher event runs for each
  /// path, one after another and without the debounce, whether or not
  /// [watchFiles] is on, and completes when all are looked at. It also tells
  /// the open page's attachments that files arrived.
  ///
  /// A page file in a pull-only location that is a conflict copy of a file
  /// with the same page id is listed as a duplicate and never merged, also for
  /// the open page. After a file is found removed, the files listed as
  /// duplicates of its page are looked at again, so the page moves to the file
  /// that survives.
  Future<void> filesChanged(Iterable<String> paths) async {
    final list = paths.toList();
    for (final path in list) {
      if (_disposed) return;
      try {
        await _fileChanged(path);
      } on Object catch (e) {
        debugPrint('Looking at $path failed: $e');
      }
    }
    // As the watcher does: only a path in or about an assets folder.
    if (!_disposed && list.any((p) => p.contains('.assets'))) _attachments?.filesChanged();
  }

  Future<void> _fileChanged(String path) async {
    if (_isBinderFile(path)) {
      await checkBinderFile(path);
      return;
    }
    if (!path.endsWith(PageStore.extension)) return;
    final key = _key(path);
    final id = _pathId[key];
    await checkFile(path);
    if (_disposed || id == null) return;
    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) return;
    // The file is gone: the files listed as duplicates of its page are looked
    // at again (their last known text is forgotten, so each is read afresh).
    final dupes = [
      ..._unreadable,
      for (final f in _folders.values) ...f.unreadable,
      for (final b in _binders.values) ...b.unreadable,
    ].where((u) => u.reason == 'duplicate page id $id' && _key(u.path) != key).map((u) => u.path).toList();
    for (final d in dupes) {
      if (_disposed) return;
      _known.remove(_key(d));
      await checkFile(d);
    }
  }

  /// Runs [job] as a save-chain job.
  @visibleForTesting
  Future<T> runOnChainForTest<T>(Future<T> Function() job) => _afterSaves(job, what: 'test job');

  /// Runs the check of [path] as a save-chain job, as a save's own check runs
  /// it (inside a job, where queuing on the chain would wait on itself).
  @visibleForTesting
  Future<bool> checkFileInChainForTest(String path) => _afterSaves(() => _checkFile(path), what: 'check of $path');

  /// Looks at a binder's `noted-binder.json` ([path]) after it may have been
  /// changed by someone else.
  ///
  /// Does nothing if the file still holds exactly what this app last wrote or
  /// read. A changed cover is taken over (the sidebar and the cover update). A
  /// file that is damaged or from a newer app marks the binder unreadable, and
  /// a deleted one marks it unavailable, as at startup; the file is never
  /// written in either case. A binder that was unusable and has a good file
  /// again is opened afresh.
  Future<void> checkBinderFile(String path) {
    final job = _checking.then((_) async {
      await _chain.idle;
      if (!_disposed) await _checkBinderFile(path);
    }).catchError((Object e) {
      debugPrint('Checking $path failed: $e');
    });
    _checking = job;
    return job;
  }

  Future<void> _checkBinderFile(String path) async {
    if (!_isBinderFile(path)) return;
    final dirKey = _key(File(path).parent.path);
    final section = _binders.values.where((b) => _key(b.path) == dirKey).firstOrNull;
    if (section == null) return;
    if (section.missing) return; // checkFolders brings a returned folder back
    final got = await _readBinderText(File(path));
    final text = got.text;
    String? unreadable = got.damaged;
    if (got.failure != null) {
      // Locked or offline for now: not missing and not damaged. Look again later;
      // only a folder that is gone is dealt with.
      if (!_disposed && !await Directory(section.path).exists()) await _binderGone(section);
      return;
    }
    if (_disposed) return;
    if (text == null && unreadable == null && !await Directory(section.path).exists()) {
      // The folder is gone, not just the file.
      if (_disposed) return;
      await _binderGone(section);
      return;
    }
    if (text != null && _binderText[dirKey] == text) return;
    Binder? binder;
    if (text != null) {
      _binderText[dirKey] = text;
      try {
        binder = Binder.parse(text);
      } on BinderFormatException catch (e) {
        unreadable = e.message;
      }
    } else {
      _binderText.remove(dirKey);
    }

    if (binder != null) {
      if (section.available) {
        section.binder = binder;
        section.lastEdited = DateTime.now();
        notifyListeners();
        // Whatever binder file is at a listed path is adopted: its id is the
        // one recorded now.
        // A found add of this folder saves (or undoes) it itself: a save here could
        // list the folder with another id before the add looks at it.
        if (_recordBinderId(section.path, binder) && !_foundAdds.containsKey(_key(section.path))) {
          await _saveSettings();
        }
        await _binderSeam('adopted', section.path);
      } else {
        await _reopenBinder(section.path);
      }
      return;
    }
    if (text == null && unreadable == null) {
      if (section.status == BinderStatus.unavailable) return;
      if (_pullOnly(section.path)) {
        // Its pages stay listed and its open page stays open (G6); an aside of
        // the binder file means a replace is under way, so nothing is decided.
        if (!await _holdsBinderFile(section.path)) await _binderGone(section);
        return;
      }
      await _disableBinder(
        section,
        BinderStatus.unavailable,
        'No $binderFileName in this folder.',
      );
    } else if (section.available) {
      await _damageBinder(section, unreadable ?? 'unreadable');
    } else if (section.status == BinderStatus.unavailable) {
      // The folder was unusable and now holds a damaged file: list its pages.
      await _reopenBinder(section.path);
    } else if (section.reason != unreadable) {
      section.reason = unreadable;
      notifyListeners();
    }
  }

  /// The binder file of an available binder can't be read any more. The binder
  /// stays in the sidebar with its pages, which turn read-only: an open page
  /// is saved first, then switched to a read-only view. Neither the binder file
  /// nor any page of the binder is written until the file is readable again.
  Future<void> _damageBinder(BinderSection section, String reason) async {
    final path = section.path;
    await flush(); // pending edits of the open page land while writing is allowed
    if (_disposed || _binders[path] != section) return;
    section
      ..status = BinderStatus.unreadable
      ..reason = reason
      ..binder = null;
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    notifyListeners();
  }

  /// Takes the pages of the binder out of the notebook and marks it unusable.
  /// Its files, binder file included, are not touched.
  Future<void> _disableBinder(BinderSection section, BinderStatus status, String reason) async {
    section.missing = false;
    final path = section.path;
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId);
    // Saves while the store still works. A page whose edits are safe nowhere
    // stays open, read-only, under the warning (3.5).
    var left = true;
    if (openHere) left = await _leaveOpenPage(stayIfUnsafe: true);
    if (openHere && left) _disposeCurrent();
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    for (final e in _pathId.entries.toList()) {
      if (ids.contains(e.value)) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    section
      ..status = status
      ..reason = reason
      ..binder = null
      ..store = null
      ..unreadable = const []
      ..tree = PageTree.build(const []);
    if (_coverPath == path) _coverPath = null;
    _rebuildTree();
    _syncWatchers();
    if (openHere && left) {
      await _openFallback(_standalone);
    } else if (openHere) {
      _orphanLoc = path;
      _syncReadOnly();
    }
  }

  /// A binder whose file is readable again: reads the folder afresh.
  Future<void> _reopenBinder(String path) async {
    // Pages left over from a binder that was listed read-only are read again;
    // the open one stays, so its view isn't torn down.
    for (final e in _loc.entries.where((e) => e.value == path && e.key != currentId).toList()) {
      _forgetPage(e.key);
    }
    final fresh = await _openBinder(path);
    if (_disposed) return;
    _binders[path] = fresh;
    final changed = _recordBinderId(path, fresh.binder);
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    if (changed) await _saveSettings();
    await _promoteReleased();
    await _mergePendingCopies(inQueue: true);
  }

  // Drops what the notebook knows of page [id] (not its file).
  void _forgetPage(String id) {
    _metas.remove(id);
    _loc.remove(id);
    _conflicts.remove(id);
    for (final e in _pathId.entries.toList()) {
      if (e.value == id) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
  }

  /// Returns true if [path] is the open page's file and it can't be read as a
  /// page (damaged, a newer format, or a read error that isn't "missing"): the
  /// open page is then read-only and must not be saved over it.
  Future<bool> _checkFile(String path) async {
    if (!path.endsWith(PageStore.extension)) return false;
    final loc = _locationOf(path);
    if (loc == null) return false;
    await syncHook?.call('check-start', path);
    final key = _key(path);
    final file = File(path);
    final openId = _current?.page.id;
    // Decided by path, not by _pathId: that entry is dropped when the file is
    // deleted, and a sync client often deletes first and renames the new file in.
    final isOpen = openId != null && _preview == null && _isOpenFile(loc, key);
    String? text;
    var time = DateTime.now().millisecondsSinceEpoch;
    try {
      // A file held by another program (a sync client downloading it) is busy,
      // not unreadable: the open page's file is reread quietly for a while
      // before the page is blocked.
      //
      // Each read is one job under the folder's lock, as a save's replace is:
      // on Windows a file open for reading can't be renamed, so a read that
      // overlapped this notebook's own save of the file made the save fail with
      // a sharing violation.
      Future<({String text, int time})> read() => _readUnderFolderLock(file.parent, () async {
        final s = await file.readAsString();
        return (text: s, time: (await file.lastModified()).millisecondsSinceEpoch);
      });

      final got = isOpen ? await _whileBusy(read) : await read();
      text = got.text;
      time = got.time;
    } on FileSystemException catch (e) {
      if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
        text = null;
      } else {
        // It is there but can't be read now: not the same as missing.
        if (_disposed) return false;
        debugPrint('Reading $path failed: $e');
        return isOpen && await _blockOpen(loc, key, "it couldn't be read", openId);
      }
    } on FormatException {
      if (_disposed) return false;
      if (isOpen) return _blockOpen(loc, key, "it isn't a valid page file", openId);
      _knownUnreadable(loc, key, path, 'not valid UTF-8 text');
      return false;
    }
    if (_disposed) return false;
    // The folder may have been removed while the file was read: nothing of it
    // is applied then.
    if (_locationOf(path) != loc) return false;
    final wasBlocked = isOpen && _diskBlockId == openId;
    if (text == null) {
      // The whole folder going away is not the page file being deleted:
      // checkFolders deals with that.
      if (_binders.containsKey(loc) && !await Directory(File(path).parent.path).exists()) {
        return false;
      }
      if (wasBlocked) {
        // Nothing left to protect: the next save writes the page again.
        _clearDiskBlock();
        final cp = _current;
        if (cp != null && cp.page.id == openId) _pageChanged(cp.page);
      }
      _fileGone(loc, key, path);
      return false;
    }
    if (conflictCopyOriginalNames(path.split(RegExp(r'[\\/]')).last).isNotEmpty) {
      if (_pullOnly(loc)) {
        // Never merged here: a copy with a same-id original is listed as a
        // duplicate, also for the open page; any other file is handled as usual.
        if (await _listPullOnlyCopy(loc, key, path, text)) return false;
      } else if (!_isLocked(loc) && await _tryConflictCopy(loc, key, path, text, time)) {
        return false;
      }
    }
    if (_known[key] == text && !wasBlocked) return false;
    final previous = _known[key];
    _known[key] = text;
    final NotedPage page;
    var saveAfterMerge = false;
    try {
      page = readPage(text);
    } on PageFormatException catch (e) {
      if (isOpen) {
        // Keep the last readable text as the merge base for recovery.
        if (previous == null) {
          _known.remove(key);
        } else {
          _known[key] = previous;
        }
        debugPrint('Page file $path is not readable: ${e.message}');
        return _blockOpen(
          loc,
          key,
          e is UnsupportedPageFormatException
              ? 'it is from a newer version of Noted'
              : "it isn't a valid page file",
          openId,
        );
      }
      _knownUnreadable(loc, key, path, e.message);
      return false;
    }
    if (isOpen && page.id != openId) {
      // A valid page, but not this one: saving over it would destroy it.
      if (previous == null) {
        _known.remove(key);
      } else {
        _known[key] = previous;
      }
      return _blockOpen(loc, key, 'it holds a different page', openId);
    }
    // A chosen file seen missing before and back now is taken back.
    if (_goneChosen[page.id] case final g? when _key(g) == key) _goneChosen.remove(page.id);
    // The file holds this page: another page's choice of it is let go first,
    // whatever this page's own duplicate classification below says.
    await _releaseOthersAt(key, page.id);
    final chosen = _adoptedFiles[page.id];
    if (chosen != null && _key(chosen) != key && _choiceHeld(page.id)) {
      // Another file was chosen for this id (see [adoptUnlistedPageFile]):
      // this one is a duplicate, never merged into the page.
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'duplicate page id ${page.id}');
      return false;
    }
    if (wasBlocked) {
      _clearDiskBlock(); // readable again: merge it as usual
      // The merged page is saved even if it equals the file, so the recovery
      // entry kept for the block can be dropped once that save has landed.
      saveAfterMerge = _session?.own.isNotEmpty ?? false;
    }
    if (_current?.page.id == page.id && _loc[page.id] == loc && _preview == null) {
      if (_pullOnly(loc) && !isOpen) {
        // Another file holding the open page's id. While the page's own file
        // is there it is a duplicate, as a scan lists it (never merged in);
        // once that file is gone the page moves to this one.
        final own = _storeOf(loc).pathFor(page.id);
        final ownKey = _key(own);
        if (_folderName(path) == '${page.id}${PageStore.extension}') {
          // The page's own name is back while it is shown from another file:
          // it goes to the file with its name, as a reload lists it, and the
          // file it was shown from is a duplicate.
          _dropUnreadable(loc, path, rebuild: false);
          _pathId.removeWhere((k, v) => v == page.id);
          _known.remove(ownKey);
          _pathId[key] = page.id;
          _storeOf(loc).adopt(page.id, path);
          if (File(own).existsSync()) {
            _knownUnreadable(loc, ownKey, own, 'duplicate page id ${page.id}');
          }
          _disposeCurrent();
          try {
            await _openFresh(page.id);
          } on Object catch (e) {
            debugPrint('Opening page ${page.id} at its own file failed: $e');
          }
          if (_current == null && !_disposed) await _fallbackAfterFailedOpen(loc);
          onPageContent?.call(loc, page);
          _rebuildTree();
          return false;
        }
        if (ownKey != key && File(own).existsSync()) {
          _known.remove(key);
          _knownUnreadable(loc, key, path, 'duplicate page id ${page.id}');
          return false;
        }
        _dropUnreadable(loc, path, rebuild: false);
        _known.remove(ownKey);
        _pathId.removeWhere((k, v) => v == page.id);
        _pathId[key] = page.id;
        // The store follows, so the page can be opened again from this file.
        _storeOf(loc).adopt(page.id, path);
      }
      _mergeOpen(page, text, time);
      final cp = _current;
      if (saveAfterMerge && cp != null && cp.page.id == page.id) _pageChanged(cp.page);
    } else if (await _openPageSurvivesElsewhere(page, loc, key, path)) {
      // handled: listed as a duplicate, or the page was opened afresh there
    } else {
      await _applyClosed(page, loc, key, path);
    }
    return false;
  }

  // Runs [read], again after a growing wait (50 ms, doubling to 1 s) while it
  // fails because the file is busy, for up to [busyReadWindow]. Any other
  // failure, and a file still busy after that, is thrown.
  Future<T> _whileBusy<T>(Future<T> Function() read) async {
    final end = DateTime.now().add(busyReadWindow);
    var wait = const Duration(milliseconds: 50);
    while (true) {
      try {
        return await read();
      } on FileSystemException catch (e) {
        if (!isBusyError(e) || _disposed || DateTime.now().add(wait).isAfter(end)) rethrow;
        await Future<void>.delayed(wait);
        wait = wait * 2 > const Duration(seconds: 1) ? const Duration(seconds: 1) : wait * 2;
      }
    }
  }

  // The open page's file can't be read: keep what is on disk, put the edits
  // in recovery, and make the page read-only with the reason shown.
  // [openId] is the page the file belongs to; the page on screen may have
  // changed while this waited, and then nothing is blocked (the file is left
  // alone either way, so this still returns true).
  Future<bool> _blockOpen(String loc, String key, String why, String openId) async {
    if (_disposed) return false;
    final c = _current;
    if (c == null || c.page.id != openId) return true;
    final text = writePage(c.page);
    // Already blocked: the page is read-only, so its entry is still current.
    // (A pull-only page has no edits to keep.)
    if (_diskBlockId != openId && text != _known[key] && !_pullOnly(loc)) {
      final st = _storeOf(loc);
      final s = _session;
      final keep = _blockKeep = await _keepForRecovery(loc, st, c.page, session: s, seq: s?.seq ?? 0);
      // A recovery write that failed is the loud state, so leaving asks.
      if (s != null && identical(s, _session) && !keep.safe) {
        _troubleFrom(s, c.page, keep, reason: "its file couldn't be read", folderGone: false);
      }
    }
    if (_disposed) return true;
    if (_current?.page.id != openId) return true;
    _diskBlockId = openId;
    _diskBlockWhy = why;
    final kept = _blockKeep?.safe ?? true;
    _diskBlockReason = kept
        ? 'This page is read-only: its file was replaced and $why. '
              'Your edits are kept in recovery. Put back a readable version, or open another page.'
        : 'This page is read-only: its file was replaced and $why. '
              'Your edits could not be kept in recovery either, so they exist only on screen. '
              'Use Save a copy elsewhere or Copy page text.';
    _syncReadOnly();
    return true;
  }

  // Whether [key] is the file of the page on screen.
  bool _isOpenFile(String loc, String key) {
    final id = _current?.page.id;
    // A page still waiting for its folder (_orphanLoc) owns that folder's file
    // of its id as well, so an unreadable or foreign file that lands there
    // blocks the page instead of being listed. (A readable one is still taken
    // as closed first; _resumeOpenPage then merges it into the page.)
    if (id == null || (_loc[id] != loc && _orphanLoc != loc)) return false;
    try {
      return _key(_storeOf(loc).pathFor(id)) == key;
    } on Object {
      return false;
    }
  }

  // While the open page is blocked its file is looked at again, so a read
  // error that was only passing (a sync client holding the file) clears.
  Future<void> _recheckBlocked() async {
    final id = _diskBlockId;
    final c = _current;
    if (id == null || c == null || c.page.id != id) return;
    final loc = _loc[id];
    // A pull-only page is looked at too: its file is rewritten by the pull.
    if (loc == null || (_isLocked(loc) && !_pullOnly(loc))) return;
    await _checkFile(_storeOf(loc).pathFor(id));
  }

  void _clearDiskBlock() {
    _diskBlockId = null;
    _diskBlockReason = null;
    _diskBlockWhy = null;
    _syncReadOnly();
  }

  /// Merges the conflict copies a scan found, and forgets them.
  Future<void> _mergePendingCopies({bool inQueue = false}) async {
    final paths = List<String>.of(_pendingCopies);
    _pendingCopies.clear();
    for (final p in paths) {
      await (inQueue ? _checkFile(p) : checkFile(p));
    }
  }

  // The open page of a pull-only place has its id in a file of another place
  // [loc]. While its own file is there, or when [loc] can be written, that file
  // is a duplicate, never a new home for the page. Once its own file is gone
  // the page moves: it is closed without a save (it has no edits) and opened
  // afresh from the survivor, so its content, base and attachments are rebuilt.
  // False if this does not apply.
  Future<bool> _openPageSurvivesElsewhere(NotedPage page, String loc, String key, String path) async {
    final id = page.id;
    final cur = _current;
    final at = _loc[id];
    if (cur == null || cur.page.id != id || _preview != null || at == null || at == loc || !_pullOnly(at)) {
      return false;
    }
    String? own;
    try {
      own = _storeOf(at).pathFor(id);
    } on NotebookException {
      own = null;
    }
    if (!_pullOnly(loc) || (own != null && File(own).existsSync())) {
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'duplicate page id $id');
      return true;
    }
    final old = _binders[at];
    _dropUnreadable(loc, path, rebuild: false);
    _loc[id] = loc;
    for (final e in _pathId.entries.where((e) => e.value == id).toList()) {
      _pathId.remove(e.key);
      _known.remove(e.key);
    }
    _pathId[key] = id;
    _metas[id] = page.meta;
    final st = _storeOf(loc);
    st.adopt(id, path);
    _disposeCurrent();
    try {
      await _openFresh(id);
    } on Object catch (e) {
      debugPrint('Opening page $id at its new place failed: $e');
    }
    if (_current == null && !_disposed) await _fallbackAfterFailedOpen(loc);
    if (old != null) _touch(at);
    onPageContent?.call(loc, page);
    _rebuildTree();
    return true;
  }

  // No page is open after a page failed to open at its new place: another one
  // is, as after a binder moved.
  Future<void> _fallbackAfterFailedOpen(String loc) async {
    try {
      await _openFallback(loc);
    } on Object catch (e) {
      debugPrint('Opening a page after the move failed: $e');
    }
  }

  // [path] in a pull-only place holds [text]: if it is a conflict copy of a
  // file with the same page id, it is listed as a duplicate of that page and
  // nothing is merged or written. True if it was one.
  Future<bool> _listPullOnlyCopy(String loc, String key, String path, String text) async {
    final NotedPage copy;
    try {
      copy = readPage(text);
    } on PageFormatException {
      return false;
    }
    final original = await PageStore.findConflictOriginal(path, copy);
    if (original == null) return false;
    if (_disposed) return true;
    if (_pathId[key] == copy.id && copy.id != currentId) {
      // This copy is the file listed for the page (it was alone, or reported
      // before its original): the page is handed to the original, not evicted.
      NotedPage? op;
      try {
        op = readPage(await File(original).readAsString());
      } on Object {
        op = null;
      }
      if (_disposed) return true;
      if (op != null && op.id == copy.id) {
        _pathId.remove(key);
        _known.remove(key);
        if (_loc[copy.id] == loc) {
          _metas.remove(copy.id);
          _loc.remove(copy.id);
          _conflicts.remove(copy.id);
        }
        await _applyClosed(op, loc, _key(original), original);
      }
    }
    _known.remove(key);
    _knownUnreadable(loc, key, path, 'duplicate page id ${copy.id}');
    return true;
  }

  /// Handles [path] if it is a sync client's conflict copy of another page
  /// file (same page id, see [conflictCopyOriginalNames]): merges it into the
  /// original, checks the saved result and only then deletes the copy. Returns
  /// false if the file is not a conflict copy. If anything fails the copy is
  /// left where it is and listed as a file that can't be opened.
  Future<bool> _tryConflictCopy(
    String loc,
    String key,
    String path,
    String text,
    int time,
  ) async {
    NotedPage copy;
    try {
      copy = readPage(text);
    } on PageFormatException {
      return false;
    }
    var originalPath = await PageStore.findConflictOriginal(path, copy);
    if (originalPath == null) return false;
    // The file it copies is listed as a duplicate (another file with its id
    // was chosen): merging would land in a file the copy is not of. It is left
    // for later.
    final ok = _key(originalPath);
    final dupes = [
      ..._unreadable,
      for (final f in _folders.values) ...f.unreadable,
      for (final b in _binders.values) ...b.unreadable,
    ];
    if (dupes.any((u) => _key(u.path) == ok && u.reason.startsWith('duplicate page id'))) {
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'conflict copy of a duplicate file; not merged');
      return true;
    }
    try {
      // The sync client may change the copy or the original while this runs.
      // The copy is deleted only if it still holds what was merged, and the
      // original is replaced only if it still holds what was read; otherwise
      // the merge is done again from what is there now.
      for (var attempt = 0; ; attempt++) {
        try {
          await _mergeConflictCopy(loc, path, originalPath!, copy, time, text);
          break;
        } on _SourceChanged {
          if (attempt >= 4) throw const FormatException('the page files keep changing');
          try {
            text = await File(path).readAsString();
            time = (await File(path).lastModified()).millisecondsSinceEpoch;
          } on FileSystemException {
            if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) rethrow;
            break; // the copy is gone: nothing left to merge or delete
          }
          copy = readPage(text);
          originalPath = await PageStore.findConflictOriginal(path, copy);
          if (originalPath == null) throw const FormatException('its page file is gone');
        }
      }
      _known.remove(key);
      _dropUnreadable(loc, path);
    } on Object catch (e) {
      debugPrint('Merging conflict copy $path failed, keeping it: $e');
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'Could not be merged into its page: $e');
    }
    return true;
  }

  // [consumed] is the text of the copy that [copy] was read from.
  Future<void> _mergeConflictCopy(
    String loc,
    String copyPath,
    String originalPath,
    NotedPage copy,
    int time,
    String consumed,
  ) async {
    final id = copy.id;
    final st = _storeOf(loc);
    bool openHere() {
      final c = _current;
      return c != null && c.page.id == id && _loc[id] == loc;
    }

    // The page on screen: merge into it, keeping unsaved edits, and save it.
    Future<String?> openBranch(CanvasController c) async {
      final original = c.page;
      final merged = mergeConflictCopy(original, copy, modules.codecs, copyTime: time).page;
      if (writePage(merged) != writePage(original)) c.applyExternal(merged);
      await flush();
      return verifyConflictCopyMerge(readPage(await st.readText(id)), original, copy);
    }

    // The page is closed: one chain job from the read of the original to
    // `_applyClosed`, so an open of the page can't run between the read and the
    // write and install the page as it was before. [open] is set when the page
    // turned out to be open after all (checked first, inside the job).
    Future<({bool open, String? failure})> closedBranch() async {
      if (openHere()) return (open: true, failure: null);
      final text = await File(originalPath).readAsString();
      final original = readPage(text);
      final merged = mergeConflictCopy(original, copy, modules.codecs, copyTime: time).page;
      final out = writePage(merged);
      if (out == text) return (open: false, failure: verifyConflictCopyMerge(readPage(text), original, copy));
      // Make the store write to the file the original was read from.
      if (_key(st.pathFor(id)) != _key(originalPath)) {
        await _scan(st);
        await _promoteReleased();
      }
      // Replace the original only if it still holds exactly what the merge
      // read, checked at the moment of replacing (0128); if not, merge again.
      await syncHook?.call('original-read', originalPath);
      if (!await _writeIfUnchanged(loc, merged, text)) throw const _SourceChanged();
      final back = await st.readText(id);
      if (back != out) throw const FormatException('the saved page differs from what was written');
      final failure = verifyConflictCopyMerge(readPage(back), original, copy);
      if (_loc[id] != loc) {
        await _applyClosed(merged, loc, _key(originalPath), originalPath);
      }
      return (open: false, failure: failure);
    }

    String? failure;
    var settled = false;
    for (var round = 0; round < 3 && !settled; round++) {
      final c = _current;
      if (c != null && openHere()) {
        failure = await openBranch(c);
        settled = true;
        continue;
      }
      // Inside a chain job already (a save's own check) the job can't queue on
      // the chain and wait: it runs inline, as it always did.
      final ({bool open, String? failure}) r;
      if (_chain.insideJob) {
        r = await closedBranch();
      } else {
        // A test seam: the page may be opened here, before the job is queued.
        await syncHook?.call('conflict-copy-closed', copyPath);
        r = await _afterSaves(closedBranch, what: 'conflict-copy merge of page $id', pages: {id});
      }
      if (!r.open) {
        failure = r.failure;
        settled = true;
      }
    }
    // Opened and closed again every round: leave the copy for the next check.
    if (!settled) throw const _SourceChanged();
    if (failure != null) throw FormatException(failure);
    // Delete the copy only if it is still exactly what was merged.
    await syncHook?.call('copy-merged', copyPath);
    final String now;
    try {
      now = await File(copyPath).readAsString();
    } on FileSystemException {
      if (await FileSystemEntity.type(copyPath) == FileSystemEntityType.notFound) return;
      rethrow;
    } on FormatException {
      throw const _SourceChanged();
    }
    if (now != consumed) throw const _SourceChanged();
    // Deleted only if it still holds exactly the text that was merged, checked
    // at the moment of deleting (0128); a copy that changed since is merged again.
    final deleted = await _underFolderLock(st, () async {
      final r = await deleteFileIfUnchanged(copyPath, utf8.encode(consumed));
      if (r.deleted) _emitDeleted(copyPath);
      return r;
    });
    if (!deleted.deleted && deleted.outcome != DeleteOutcome.absent) throw const _SourceChanged();
  }

  /// The file is gone. Returns the page id whose adopted file this was (it is
  /// confirmed by [_confirmGoneChosen] at a later check); an open page keeps
  /// its choice.
  String? _fileGone(String loc, String key, String path) {
    _known.remove(key);
    final id = _pathId.remove(key);
    if (id == null) {
      _dropUnreadable(loc, path);
      // A chosen file already dropped from the index (damaged, then gone) is
      // still its page's: seen missing once, settled by a later check.
      for (final e in _adoptedFiles.entries) {
        if (_key(e.value) == key && e.key != currentId) {
          _goneChosen[e.key] = e.value;
          return e.key;
        }
      }
      return null;
    }
    String? forgotten;
    final chosen = _adoptedFiles[id];
    if (chosen != null && _key(chosen) == key && id != currentId) {
      // Seen missing once: a sync client may be about to rename a new file in.
      _goneChosen[id] = chosen;
      forgotten = id;
    }
    if (_loc[id] != loc || id == currentId) return forgotten; // moved, or open: keep it
    _metas.remove(id);
    _loc.remove(id);
    _conflicts.remove(id);
    _touch(loc);
    _rebuildTree();
    return forgotten;
  }

  /// Settles the chosen files seen missing at an earlier check: one that is
  /// back holding its page is taken back; one still gone (its folder being
  /// there) is forgotten, and a duplicate of its page is promoted.
  Future<void> _confirmGoneChosen() async {
    for (final e in _goneChosen.entries.toList()) {
      final id = e.key;
      final path = e.value;
      if (id == currentId || _busy.containsKey(id)) continue;
      final loc = _locationOf(path);
      NotedPage? back;
      // Only a file that is not there confirms the choice is gone: one that
      // refuses reads or holds unreadable text may be back, held by sync.
      var present = false;
      try {
        back = readPage(await File(path).readAsString());
        if (back.id != id) back = null;
      } on PathNotFoundException {
        back = null;
      } on Object {
        // Refuses reads, holds invalid text or half-synced JSON: while the file
        // exists it may still be the chosen page, so the choice stays.
        back = null;
        present = File(path).existsSync();
      }
      await syncHook?.call('confirm-gone-read', path);
      // The page may have been opened or made busy while the file was read.
      if (id == currentId || _busy.containsKey(id)) continue;
      if (_goneChosen[id] != path) continue;
      final chosen = _adoptedFiles[id];
      if (chosen == null || _key(chosen) != _key(path)) {
        _goneChosen.remove(id); // another file was chosen since
        continue;
      }
      if (back != null && loc != null) {
        _goneChosen.remove(id);
        if (!_pathId.containsValue(id)) await _applyClosed(back, loc, _key(path), path);
        continue;
      }
      if (present) continue; // not readable now: the choice stays, checked again later
      if (!Directory(File(path).parent.path).existsSync()) continue; // folder away
      _releaseChoice(id, path);
      if (!_pathId.containsValue(id) && _loc.containsKey(id)) {
        final at = _loc[id]!;
        _metas.remove(id);
        _loc.remove(id);
        _conflicts.remove(id);
        _touch(at);
        _rebuildTree();
      }
      await _promoteReleased();
    }
  }

  /// A file with page [id] that was listed only as a duplicate becomes the
  /// page's file now that the chosen one is gone (and is chosen, so a later
  /// scan can't swap it back for the file that reappears).
  Future<void> _promoteDuplicate(String id) async {
    if (_pathId.containsValue(id)) return;
    final lists = <(String, List<UnreadablePage>)>[
      (_standalone, _unreadable),
      for (final e in _folders.entries) (e.key, e.value.unreadable),
      for (final e in _binders.entries) (e.key, e.value.unreadable),
    ];
    final candidates = <(String, UnreadablePage)>[];
    for (final (loc, list) in lists) {
      for (final u in list) {
        if (u.reason != 'duplicate page id $id') continue;
        final name = u.path.split(RegExp(r'[\\/]')).last;
        // A name shaped like a sync client's conflict copy is merged, not chosen.
        if (conflictCopyOriginalNames(name).isNotEmpty) continue;
        candidates.add((loc, u));
      }
    }
    candidates.sort((a, b) {
      int rank((String, UnreadablePage) c) =>
          c.$2.path.split(RegExp(r'[\\/]')).last == '$id.canvas' ? 0 : 1;
      return rank(a).compareTo(rank(b));
    });
    for (final (loc, u) in candidates) {
      {
        final NotedPage page;
        try {
          page = readPage(await File(u.path).readAsString());
        } on Object {
          continue;
        }
        if (page.id != id || _pathId.containsValue(id)) continue;
        try {
          _storeOf(loc).adopt(id, u.path);
        } on NotebookException {
          continue;
        }
        _adoptedFiles[id] = u.path;
        await _applyClosed(page, loc, _key(u.path), u.path);
        return;
      }
    }
  }

  // The file at [key] holds page [id]: it can't stay the chosen file of another
  // page (unless that page is open or busy), whose duplicate is promoted.
  Future<void> _releaseOthersAt(String key, String id) async {
    var released = false;
    for (final e in _adoptedFiles.entries.toList()) {
      if (e.key == id || _key(e.value) != key || e.key == currentId || _busy.containsKey(e.key)) continue;
      _releaseChoice(e.key, e.value);
      released = true;
    }
    if (released) await _promoteReleased();
  }

  /// The file can't be read as a page. An open page stays as it is; any
  /// other page is taken out of the tree and listed as one that can't be
  /// opened.
  void _knownUnreadable(String loc, String key, String path, String reason) {
    final id = _pathId[key];
    if (id != null && id == currentId) return;
    // Already listed for this reason and not in the index: nothing changes, so
    // no touch and no rebuild (a damaged chosen file is looked at every tick).
    if (id == null) {
      final listed = loc == _standalone
          ? _unreadable
          : (_folders[loc]?.unreadable ?? _binders[loc]?.unreadable ?? const <UnreadablePage>[]);
      if (listed.any((u) => _key(u.path) == key && u.reason == reason)) return;
    }
    if (id != null && _loc[id] == loc) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    _pathId.remove(key);
    _dropUnreadable(loc, path, rebuild: false);
    final entry = UnreadablePage(path, reason);
    if (loc == _standalone) {
      _unreadable = [..._unreadable, entry];
    } else if (_folders[loc] case final f?) {
      f.unreadable = [...f.unreadable, entry];
    } else {
      final s = _binders[loc];
      if (s != null) s.unreadable = [...s.unreadable, entry];
    }
    _touch(loc);
    _rebuildTree();
  }

  void _dropUnreadable(String loc, String path, {bool rebuild = true}) {
    final key = _key(path);
    bool other(UnreadablePage u) => _key(u.path) != key;
    var removed = false;
    if (loc == _standalone) {
      final next = _unreadable.where(other).toList();
      removed = next.length != _unreadable.length;
      _unreadable = next;
    } else if (_folders[loc] case final f?) {
      final next = f.unreadable.where(other).toList();
      removed = next.length != f.unreadable.length;
      f.unreadable = next;
    } else {
      final s = _binders[loc];
      if (s != null) {
        final next = s.unreadable.where(other).toList();
        removed = next.length != s.unreadable.length;
        s.unreadable = next;
      }
    }
    if (removed && rebuild) _rebuildTree();
  }

  /// A page that isn't open: take its header (and conflict state) from the
  /// file.
  Future<void> _applyClosed(NotedPage page, String loc, String key, String path) async {
    final id = page.id;
    // This file holds page [id] now: it can't stay the chosen file of another
    // page (unless that page is open or busy), whose duplicate is promoted.
    await _releaseOthersAt(key, id);
    final elsewhere = _pathId.entries.where((e) => e.value == id && e.key != key);
    if (elsewhere.isNotEmpty) {
      // Two files claim the page id; keep the first and list this one.
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'duplicate page id $id');
      return;
    }
    final previous = _pathId[key];
    if (previous != null && previous != id && _loc[previous] == loc) {
      _metas.remove(previous);
      _loc.remove(previous);
      _conflicts.remove(previous);
    }
    _dropUnreadable(loc, path, rebuild: false);
    _pathId[key] = id;
    _metas[id] = page.meta;
    _loc[id] = loc;
    if (_isStandaloneLoc(loc) || _binders[loc]?.store != null) {
      final st = _storeOf(loc);
      // Make the store find files whose names aren't the page id.
      // (Never when the folder is gone: a scan would create it.)
      if (_key(st.pathFor(id)) != key && await st.directory.exists()) await _scan(st, sweep: _sweepOff == 0);
    }
    _setConflict(id, hasConflicts(page));
    _touch(loc);
    onPageContent?.call(loc, page);
    _rebuildTree();
    await _promoteReleased();
  }

  /// The open page's file changed: merge it into the page on screen.
  void _mergeOpen(NotedPage theirs, String text, int time) {
    final c = _current!;
    final base = _base;
    _base = theirs;
    if (base == null) return;
    final result = mergePage(base, c.page, theirs, modules.codecs, theirsTime: time);
    final merged = result.page;
    final save = writePage(merged) != text || _pendingSave?.id == merged.id;
    _metas[merged.id] = merged.meta;
    c.applyExternal(merged, save: save);
    final loc = _loc[merged.id];
    if (loc != null) onPageContent?.call(loc, merged);
    _setConflict(merged.id, hasConflicts(merged));
    _rebuildTree();
  }

  // Binder discovery (0050) ----------------------------------------------------

  /// Binders another device made that sit in a folder this device looks in,
  /// but that this device doesn't list: a full pass over every root (the
  /// default binder folder, the default page folder, the standalone folders and
  /// the parent of each listed binder), one level down. Reads only: it never
  /// creates or writes a file or folder in shared storage. A binder it finds
  /// once is listed in its own job; a binder this device removed is never
  /// listed again, and on the first launch of a build with discovery (a
  /// `binders.json` with no `binderIds`) every binder this device doesn't list
  /// is recorded as removed instead, so none appears unasked.
  ///
  /// A call while a pass runs asks for one more pass after it. The result
  /// completes when the pass (and the adds of the binders it found) is over.
  Future<void> discoverBinders() {
    if (_disposed || _settingsHeld != null) return discoveryIdle;
    final running = _discovering;
    if (running != null) {
      _discoverAgain = true;
      return discoveryIdle;
    }
    final done = Completer<void>();
    _discovering = done.future;
    unawaited(
      _discoverLoop().whenComplete(() {
        _discovering = null;
        done.complete();
      }),
    );
    return discoveryIdle;
  }

  Future<void> _discoverLoop() async {
    try {
      do {
        _discoverAgain = false;
        await _discoverOnce();
      } while (_discoverAgain && !_disposed);
    } on Object catch (e) {
      debugPrint('Looking for binders failed: $e');
    }
  }

  /// Completes when no discovery pass is running and no binder found by one is
  /// still being added.
  Future<void> get discoveryIdle async {
    while (!_disposed) {
      final running = _discovering;
      if (running != null) {
        await running;
        continue;
      }
      if (_discoveryJobs.isEmpty) return;
      await Future.wait(_discoveryJobs.toList());
    }
  }

  /// The folders discovery looks in, at most 20, in this order. A listed
  /// binder's folder is never one; a folder that doesn't exist is dropped by
  /// the caller.
  List<String> _discoveryRoots({int? cap}) {
    final limit = cap ?? _rootCap;
    _rootsTruncated = false;
    final listed = {for (final p in _binders.keys) _key(p)};
    final out = <String>[];
    final seen = <String>{};
    void add(String? raw) {
      if (raw == null) return;
      final p = _normalizePath(raw);
      final k = _key(p);
      if (listed.contains(k) || !seen.add(k)) return;
      if (out.length >= limit) {
        _rootsTruncated = true; // a root left out: nothing can be said of what it holds
        return;
      }
      out.add(p);
    }

    add(defaultBinderFolderPath);
    add(defaultFolderPath);
    add(settings?.defaultPageFolder);
    for (final p in _folders.keys) {
      add(p);
    }
    for (final b in _binders.values) {
      add(File(b.path).parent.path);
    }
    return out;
  }

  bool _refusedForPermission(FileSystemException e) {
    final c = e.osError?.errorCode;
    return Platform.isWindows ? c == 5 : (c == 13 || c == 1);
  }

  Future<void> _discoverOnce() async {
    final started = DateTime.now();
    final listed = {for (final p in _binders.keys) _key(p)};
    final standalone = {
      _key(defaultFolderPath),
      if (settings?.defaultPageFolder case final chosen?) _key(_normalizePath(chosen)),
      for (final p in _folders.keys) _key(p),
    };
    var rootsOk = true;
    var readsOk = true;
    final found = <String, List<({String path, String title})>>{};
    final seenFolders = <String>{};
    final sep = Platform.pathSeparator;
    // The pass that could close an upgrade lists without the caps (once), so it
    // can record what it saw; any other pass keeps them and says what it cut.
    final uncapped = _settingsKind == _SettingsKind.upgrade;
    final folderCap = uncapped ? 1 << 30 : _folderCap;
    final capNotes = <UnreadablePage>[];
    final roots = _discoveryRoots(cap: uncapped ? 1 << 30 : null);
    if (_rootsTruncated) {
      capNotes.add(
        UnreadablePage(
          defaultBinderFolderPath,
          'Noted looks in only the first $_rootCap places for binders; open binders elsewhere with Open binder…',
        ),
      );
    }
    await _noteEventFolders();
    for (final root in roots) {
      if (_disposed) return;
      final List<FileSystemEntity> entries;
      try {
        final dir = Directory(root);
        if (!await dir.exists()) continue;
        await _binderSeam('root-list', root);
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException catch (e) {
        if (_refusedForPermission(e)) {
          if (_rootsRefused.add(_key(root))) debugPrint('Looking for binders in $root: not allowed ($e)');
        } else {
          rootsOk = false;
          debugPrint('Looking for binders in $root failed: $e');
        }
        continue;
      }
      // Links are never followed, and what isn't a binder folder by its name is
      // skipped before the cap counts.
      final folders = [
        for (final e in entries)
          if (e is Directory && !_notABinderFolderName(_folderName(e.path))) e.path,
      ]..sort((a, b) => _folderName(a).compareTo(_folderName(b)));
      if (folders.length > folderCap) {
        if (_rootsCut.add(_key(root))) debugPrint('Looking for binders in $root: only the first 1000 folders');
        capNotes.add(
          UnreadablePage(
            root,
            'Noted looks at only the first $folderCap folders in $root; open binders beyond them with Open binder…',
          ),
        );
        folders.removeRange(folderCap, folders.length);
      }
      for (final path in folders) {
        if (_disposed) return;
        final k = _key(path);
        if (listed.contains(k) || standalone.contains(k) || _claims.contains(k)) continue;
        if (!seenFolders.add(k)) continue;
        final file = '$path$sep$binderFileName';
        if (await FileSystemEntity.type(file, followLinks: false) != FileSystemEntityType.file) continue;
        final read = await _readCandidate(file);
        if (read.failed) {
          readsOk = false;
        } else if (read.id case final id?) {
          found.putIfAbsent(id, () => []).add((path: _normalizePath(path), title: read.title ?? ''));
        }
      }
    }
    if (_disposed) return;

    // Classified on the complete, current map.
    final listedIds = <String, String>{};
    for (final b in _binders.values) {
      final id = _binderIds[_key(b.path)];
      if (id != null) listedIds[id] = b.path;
    }
    // A pull-only binder whose folder is gone, or holds no binder file, and
    // whose id is in exactly one new place under the same read-only root: the
    // OneDrive folder was renamed or moved. Decided only by a pass that saw
    // every root and read every file, and before the `movedTo` branch below.
    final rehomes = <({String id, String from, String to})>[];
    // (A pass cut short by the root or folder cap did not see every root.)
    if (_readOnlyRoots.isNotEmpty && readsOk && rootsOk && capNotes.isEmpty) {
      for (final e in found.entries.toList()) {
        final from = listedIds[e.key];
        if (from == null || !_pullOnly(from) || e.value.length != 1) continue;
        final to = e.value.single.path;
        if (_readOnlyRootOf(from) != _readOnlyRootOf(to)) continue;
        if (await _holdsBinderFile(from)) continue;
        if (_disposed) return;
        rehomes.add((id: e.key, from: from, to: to));
        found.remove(e.key);
      }
    }
    final alsoIn = <String, List<String>>{};
    final movedTo = <String, List<String>>{};
    final duplicates = <String, ({String title, List<String> folders})>{};
    final adds = <({String id, String path})>[];
    var recorded = false;
    var overflow = false;
    found.forEach((id, folders) {
      final paths = [for (final f in folders) f.path];
      final title = folders.first.title.trim().isEmpty ? _folderName(paths.first) : folders.first.title.trim();
      final at = listedIds[id];
      if (at != null) {
        final others = paths.where((p) => _key(p) != _key(at)).toList();
        if (others.isEmpty) return;
        ((_binders[at]?.available ?? false) ? alsoIn : movedTo)[_key(at)] = others;
        return;
      }
      if (_settingsKind == _SettingsKind.upgrade) {
        if (!_removedBinders.contains(id)) {
          // Recording would evict an id this pass needs: leave it unrecorded and
          // keep the upgrade open, so no pass ever adds it.
          if (_removedBinders.length >= _removedCap) {
            overflow = true;
            return;
          }
          _markRemoved(id);
          recorded = true;
        }
        _upgradeNotes[id] = (title: title, folder: paths.first);
        return;
      }
      if (_removedBinders.contains(id)) return;
      // An unreadable file, or a root that could not be listed (or was cut), might
      // hold this id too: nothing new is admitted from such a pass.
      if (!readsOk || !rootsOk) return;
      if (paths.length > 1) {
        duplicates[id] = (title: title, folders: paths);
      } else {
        adds.add((id: id, path: paths.single));
      }
    });
    _upgradeNotes.removeWhere((id, _) => !_removedBinders.contains(id) || listedIds.containsKey(id));
    if (overflow) {
      capNotes.add(
        UnreadablePage(
          defaultBinderFolderPath,
          "Noted found too many binders it didn't list to remember them all; it adds none of them by itself. Open them with Open binder…",
        ),
      );
    }
    final changed =
        _alsoIn.toString() != alsoIn.toString() ||
        _movedTo.toString() != movedTo.toString() ||
        _duplicateIds.toString() != duplicates.toString() ||
        _capNotes.map((n) => n.reason).join() != capNotes.map((n) => n.reason).join();
    _alsoIn = alsoIn;
    _capNotes = capNotes;
    _movedTo = movedTo;
    _duplicateIds = duplicates;
    // The upgrade closes when every root that exists was listed and every
    // candidate was read; only then does `binderIds` get written.
    var closed = false;
    if (_settingsKind == _SettingsKind.upgrade && rootsOk && readsOk && !overflow) {
      _settingsKind = _SettingsKind.current;
      closed = true;
    }
    if (recorded || closed) await _saveSettings();
    if (_disposed) return;
    if (changed || recorded) notifyListeners();

    if (rehomes.isNotEmpty) {
      final chain = _rehomeInTurn(rehomes);
      _discoveryJobs.add(chain);
      unawaited(chain.whenComplete(() => _discoveryJobs.remove(chain)));
    }
    // The found adds go one after another: the next is queued on `_checking`
    // only when the previous one has ended, so a hand add waits for at most one.
    if (adds.isNotEmpty) {
      final chain = _addFoundInTurn(adds);
      _discoveryJobs.add(chain);
      unawaited(chain.whenComplete(() => _discoveryJobs.remove(chain)));
    }
    final took = DateTime.now().difference(started);
    if (took > _slowPass) {
      debugPrint('Looking for binders took ${took.inSeconds} s');
      // The backstop is stretched while passes are slow (to 5 minutes at most).
      final most = folderCheckInterval > Duration.zero
          ? (const Duration(minutes: 5).inMilliseconds / folderCheckInterval.inMilliseconds).ceil()
          : 10;
      _backstopTicks = (_backstopTicks * 2).clamp(10, most < 10 ? 10 : most);
    } else {
      _backstopTicks = 10;
    }
  }

  Future<void> _addFoundInTurn(List<({String id, String path})> adds) async {
    for (final a in adds) {
      if (_disposed) return;
      try {
        await _queued(() async {
          await _binderSeam('job', a.path);
          await _addFound(a.id, a.path);
        });
      } on Object catch (e) {
        debugPrint('Adding the binder in ${a.path} failed: $e');
      }
    }
  }

  // Notes about open pages a re-homed binder left behind, by old folder (G6).
  final Map<String, ({UnreadablePage note, String id})> _rehomeNotes = {};

  Future<void> _rehomeInTurn(List<({String id, String from, String to})> list) async {
    for (final r in list) {
      if (_disposed) return;
      try {
        await _queued(() => _rehome(r.id, r.from, r.to));
      } on Object catch (e) {
        debugPrint('Moving the binder from ${r.from} to ${r.to} failed: $e');
      }
    }
  }

  // A pull-only binder was renamed or moved under its read-only root (G6): its
  // folder [from] holds no binder file and the binder with the same id is in
  // [to]. The old location's pages and id are dropped (not recorded as
  // removed), [to] is opened as a binder, and the open page, if it was in the
  // binder, is opened afresh at its new place without a save: a pull-only page
  // has no edits, so its content, base and attachments are all rebuilt.
  Future<void> _rehome(String id, String from, String to) async {
    final old = _binders[from];
    if (old == null || !identical(_binders[from], old) || !_pullOnly(from)) return;
    if (_binderIds[_key(from)] != id) return;
    if (_binders.keys.any((p) => _key(p) == _key(to)) || _claims.contains(_key(to))) return;
    if (_readOnlyRootOf(from) != _readOnlyRootOf(to)) return;
    // Checked again now, on disk (an aside of the binder file counts).
    if (await _holdsBinderFile(from)) return;
    final read = await BinderStore(Directory(to)).read();
    if (read is! BinderFound || read.binder.id != id || _disposed) return;
    if (!identical(_binders[from], old)) return;
    final ids = [for (final e in _loc.entries) if (e.value == from) e.key];
    final openId = currentId;
    final openHere = openId != null && ids.contains(openId);
    // What is dropped is kept, to put back if [to] turns out not to be usable.
    final keptMetas = {for (final i in ids) i: _metas[i]};
    final keptConflicts = {for (final i in ids) if (_conflicts.contains(i)) i};
    final keptPaths = {
      for (final e in _pathId.entries)
        if (ids.contains(e.value)) e.key: e.value,
    };
    final keptKnown = {
      for (final k in keptPaths.keys) k: ?_known[k],
    };
    void putBack() {
      for (final i in ids) {
        final m = keptMetas[i];
        if (m != null) _metas[i] = m;
        _loc[i] = from;
        if (keptConflicts.contains(i)) _conflicts.add(i);
      }
      _pathId.addAll(keptPaths);
      _known.addAll(keptKnown);
    }
    final fromDir = _key(from);
    final keptAdopted = {
      for (final e in _adoptedFiles.entries)
        if (_key(File(e.value).parent.path) == fromDir) e.key: e.value,
    };
    final keptGone = {for (final i in keptAdopted.keys) i: ?_goneChosen[i]};
    _dropAdoptionsIn(from);
    for (final i in ids) {
      _forgetPage(i);
    }
    final BinderSection fresh;
    try {
      fresh = await _openBinder(to, createFolder: false, sweep: false);
    } on Object {
      putBack();
      _adoptedFiles.addAll(keptAdopted);
      _goneChosen.addAll(keptGone);
      rethrow;
    }
    if (_disposed) return;
    if (!identical(_binders[from], old) || !fresh.available || fresh.binder?.id != id) {
      _undoOpen(to);
      if (identical(_binders[from], old)) {
        putBack();
        _adoptedFiles.addAll(keptAdopted);
        _goneChosen.addAll(keptGone);
      }
      return;
    }
    // The destination is registered in the place of the old one, in the same
    // position in the list.
    final entries = _binders.entries.toList();
    _binders.clear();
    for (final e in entries) {
      if (identical(e.value, old)) {
        _binders[to] = fresh;
      } else {
        _binders[e.key] = e.value;
      }
    }
    _binderIds.remove(_key(from));
    _binderText.remove(_key(from));
    _alsoIn = {..._alsoIn}..remove(_key(from));
    _movedTo = {..._movedTo}..remove(_key(from));
    _recordBinderId(to, fresh.binder);
    if (_coverPath == from) _coverPath = to;
    final last = _lastDeleted;
    if (last != null && last._location == from) _lastDeleted = null;
    _dropLandedIn(from);
    final fromKey = _key(from);
    _pendingCopies.removeWhere((p) => _key(File(p).parent.path) == fromKey);
    if (openHere && currentId == openId) {
      if (_loc[openId] == to) {
        _disposeCurrent();
        try {
          await _openFresh(openId);
        } on Object catch (e) {
          debugPrint('Opening page $openId at its new place failed: $e');
        }
      } else {
        // Its file stayed in the old folder: the page closes, with a note.
        final title = _titleOrUntitled(keptMetas[openId]?.title ?? '');
        _disposeCurrent();
        _rehomeNotes[fromKey] = (
          note: UnreadablePage(
            from,
            'The page "$title" stayed in the old folder of binder "${fresh.title}" when it moved, '
            'so it was closed.',
          ),
          id: openId,
        );
      }
    }
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    await _promoteReleased();
    if (openHere && _current == null && !_disposed) {
      try {
        await _openFallback(to);
      } on Object catch (e) {
        debugPrint('Opening a page after the binder moved failed: $e');
      }
    }
    if (!_disposed) notifyListeners();
  }

  bool _notABinderFolderName(String name) =>
      name.startsWith('.') || name.endsWith('.assets') || name == 'templates';

  // Reads the binder file at [path]. A read that fails (a lock, an offline
  // placeholder) is `failed`; a file that was read but isn't a binder file with
  // an id of this form is a settled "not one". The read is reused while the
  // file's size and time are unchanged.
  Future<_Candidate> _readCandidate(String path) async {
    try {
      final stat = await File(path).stat();
      final size = stat.size;
      final time = stat.modified.millisecondsSinceEpoch;
      final cached = _candidateReads[path];
      if (cached != null && cached.size == size && cached.time == time) return cached.read;
      await _binderSeam('candidate-read', path);
      final bytes = await File(path).readAsBytes();
      _Candidate result;
      try {
        final binder = Binder.parse(utf8.decode(bytes));
        result = RegExp(r'^[0-9a-f]{16}$').hasMatch(binder.id)
            ? _Candidate.found(binder.id, binder.title)
            : const _Candidate.notOne();
      } on BinderFormatException {
        result = const _Candidate.notOne();
      } on FormatException {
        result = const _Candidate.notOne();
      }
      _candidateReads[path] = (size: size, time: time, read: result);
      return result;
    } on FileSystemException catch (e) {
      debugPrint('Reading $path failed: $e');
      return const _Candidate.failed();
    }
  }

  // The job that lists a found binder, after rechecking at the moment it runs.
  Future<void> _addFound(String id, String path) async {
    final k = _key(path);
    if (_binders.keys.any((p) => _key(p) == k) || _claims.contains(k)) return;
    if (_binderIds.containsValue(id) || _removedBinders.contains(id) || _duplicateIds.containsKey(id)) return;
    final r = await _listBinder(path, found: true, expectId: id);
    if (r.refused != null) debugPrint('Found binder in $path not added: ${r.refused}');
  }

  /// Notes for the "Can't open" list about binders discovery saw and didn't
  /// add: one id in more than one folder, and binders recorded as removed by
  /// the first pass of an upgrade.
  List<UnreadablePage> get discoveryNotes => [
    ..._heldNotes,
    ..._capNotes,
    // A note goes once the old folder is gone or the page is listed again.
    for (final r in _rehomeNotes.values)
      if (!_loc.containsKey(r.id) && Directory(r.note.path).existsSync()) r.note,
    for (final d in _duplicateIds.values)
      UnreadablePage(
        d.folders.first,
        'Binder "${d.title}" is in more than one folder: ${d.folders.join(', ')}. '
        'Open the one you want with Open binder…',
      ),
    for (final n in _upgradeNotes.values)
      UnreadablePage(
        n.folder,
        'Found binder "${n.title}" in ${n.folder}; it wasn\'t added. Open it with Open binder… to use it',
      ),
  ];

  /// Other folders that hold a copy of the available binder at [path] (same
  /// binder id). They are not used.
  List<String> binderAlsoIn(String path) => _alsoIn[_key(path)] ?? const [];

  /// Folders where the binder listed (and missing) at [path] was found again:
  /// it may have been moved. Nothing is changed.
  List<String> binderMovedTo(String path) => _movedTo[_key(path)] ?? const [];

  // A directory event in a folder discovery looks in: a binder folder may have
  // arrived there. Only remembered here; the debounced pass looks at it, so the
  // UI isolate does no file work per event.
  void _onRootEvent(FileSystemEvent e) {
    if (_disposed || !e.isDirectory) return;
    final roots = {for (final r in _discoveryRoots()) _key(r)};
    var relevant = false;
    void seen(String p) {
      if (!roots.contains(_key(File(p).parent.path))) return;
      if (_notABinderFolderName(_folderName(p))) return;
      relevant = true;
      if (_eventFolders.length < 200) _eventFolders.add(p);
    }

    seen(e.path);
    if (e is FileSystemMoveEvent && e.destination != null) seen(e.destination!);
    if (!relevant) return;
    _rootDebounce?.cancel();
    _rootDebounce = Timer(discoveryDebounce, () => unawaited(discoverBinders()));
  }

  // Folders the events named that hold no binder file yet become fresh folders
  // (checked on the folder ticks); a pass lists the rest anyway.
  Future<void> _noteEventFolders() async {
    final paths = _eventFolders.toList();
    _eventFolders.clear();
    for (final p in paths) {
      if (_disposed) return;
      if (await FileSystemEntity.type(p, followLinks: false) != FileSystemEntityType.directory) continue;
      final file = '$p${Platform.pathSeparator}$binderFileName';
      if (await FileSystemEntity.type(file, followLinks: false) == FileSystemEntityType.file) continue;
      if (_freshFolders.length < 50) _freshFolders.putIfAbsent(_key(p), () => (path: p, since: DateTime.now()));
    }
  }

  // On every folder tick: the fresh folders (seen without a binder file) are
  // statted for 10 minutes; every [_backstopTicks]th tick is a backstop pass.
  void _discoveryTick() {
    if (_disposed || _settingsHeld != null) return;
    _folderTicks++;
    final backstop = _folderTicks >= _backstopTicks;
    if (backstop) _folderTicks = 0;
    unawaited(_checkFresh(backstop));
  }

  Future<void> _checkFresh(bool backstop) async {
    var arrived = false;
    final now = DateTime.now();
    for (final e in _freshFolders.entries.toList()) {
      if (_disposed) return;
      if (now.difference(e.value.since) > const Duration(minutes: 10)) {
        _freshFolders.remove(e.key);
        continue;
      }
      final file = '${e.value.path}${Platform.pathSeparator}$binderFileName';
      if (await FileSystemEntity.type(file, followLinks: false) == FileSystemEntityType.file) {
        _freshFolders.remove(e.key);
        arrived = true;
      }
    }
    if (arrived || backstop) unawaited(discoverBinders());
  }

  // One non-recursive watcher for each root that no folder watcher covers.
  void _syncRootWatchers(Set<String> watchedDirs) {
    final wanted = <String, String>{
      for (final r in _discoveryRoots())
        if (!watchedDirs.contains(_key(r)) && Directory(r).existsSync()) _key(r): r,
    };
    for (final k in _rootWatchers.keys.toList()) {
      if (!wanted.containsKey(k)) unawaited(_rootWatchers.remove(k)!.cancel());
    }
    wanted.forEach((k, dir) {
      if (_rootWatchers.containsKey(k)) return;
      try {
        _rootWatchers[k] = Directory(dir).watch().listen(
          _onRootEvent,
          onError: (Object e) => debugPrint('Watching $dir failed: $e'),
          onDone: () => _rootWatchers.remove(k),
        );
      } on FileSystemException catch (e) {
        debugPrint('Watching $dir failed: $e');
      }
    });
  }

  // Folders that come and go -------------------------------------------------

  void _startFolderTimer() {
    _folderTimer?.cancel();
    _folderTimer = null;
    if (!watchFiles || _disposed || folderCheckInterval <= Duration.zero) return;
    _folderTimer = Timer.periodic(folderCheckInterval, (_) {
      _discoveryTick();
      unawaited(checkFolders());
    });
  }

  /// Looks for standalone folders (the default one and the extra ones) that
  /// have disappeared or come back since the last look; with [watchFiles] on
  /// this also runs every [folderCheckInterval] and when a watcher fails.
  ///
  /// A folder that is gone loses its pages from the tree and is listed as
  /// "on another device". Its open page is saved if possible, then stays open
  /// read-only. When the folder comes back it is read again, its watcher is
  /// restarted and the open page is merged with its file. The folder itself is
  /// never created or deleted here.
  Future<void> checkFolders() {
    final job = _checking.then((_) async {
      await _chain.idle;
      if (!_disposed) await _checkFolders();
    }).catchError((Object e) {
      debugPrint('Checking the folders failed: $e');
    });
    _checking = job;
    return job;
  }

  Future<void> _checkFolders() async {
    await _recheckBlocked();
    if (_disposed) return;
    await _confirmGoneChosen();
    if (_disposed) return;
    await _recheckChosenFiles();
    if (_disposed) return;
    final defaultExists = await store.directory.exists();
    if (_disposed) return;
    if (!_defaultGone && !defaultExists) {
      await _folderGone(_standalone);
    } else if (_defaultGone && defaultExists) {
      await _folderBack(_standalone);
    }
    for (final b in _binders.values.toList()) {
      if (_disposed) return;
      if (!identical(_binders[b.path], b)) continue;
      final exists = await Directory(b.path).exists();
      if (_disposed) return;
      if (_pullOnly(b.path)) {
        // A pull-only binder whose binder file is gone is "gone" even when its
        // folder still holds pages: the open page stays open, and nothing is
        // opened again until the binder file is on disk (G6).
        final onDisk = exists && await File('${b.path}${Platform.pathSeparator}$binderFileName').exists();
        if (_disposed) return;
        if (b.missing) {
          if (onDisk) await _binderBack(b.path);
        } else if (!exists || !(onDisk || await _holdsBinderFile(b.path))) {
          await _binderGone(b);
        }
        continue;
      }
      if (b.missing) {
        if (exists) await _binderBack(b.path);
      } else if (!exists) {
        await _binderGone(b);
      }
    }
    for (final f in _folders.values.toList()) {
      if (_disposed) return;
      if (!identical(_folders[f.path], f)) continue;
      final exists = await Directory(f.path).exists();
      if (_disposed) return;
      if (f.available && !exists) {
        await _folderGone(f.path);
      } else if (!f.available && f.missing && exists) {
        await _folderBack(f.path);
      }
    }
    _syncWatchers(); // restarts a watcher that ended
    // Kept files that failed to land are tried again, also for the open page.
    final rec = _recovery;
    if (_keptRetry && rec != null && !_disposed) {
      await _landKeptAssets(rec);
      if (!_disposed) notifyListeners();
    }
  }

  // Whether the folder [dir] holds a binder file, or an aside of one that a
  // killed replace left (which counts as holding it, as for the engine).
  Future<bool> _holdsBinderFile(String dir) async {
    try {
      if (!await Directory(dir).exists()) return false;
      if (await File('$dir${Platform.pathSeparator}$binderFileName').exists()) return true;
      await for (final f in Directory(dir).list(followLinks: false)) {
        if (f is! File) continue;
        final name = f.path.split(RegExp(r'[\\/]')).last;
        if (name.startsWith('$binderFileName.') &&
            (name.endsWith(asideSuffix) || name.endsWith(verifiedSuffix))) {
          return true;
        }
      }
    } on FileSystemException {
      return true; // can't tell: not gone
    }
    return false;
  }

  Future<void> _folderGone(String loc) async {
    // Pending edits of the open page are written first if that is still
    // possible; if not, they stay in the page on screen.
    await flush();
    if (_disposed) return;
    final ids = [for (final e in _loc.entries) if (e.value == loc) e.key];
    if (ids.contains(currentId)) _orphanLoc = loc;
    for (final id in ids) {
      _forgetPage(id);
    }
    if (loc == _standalone) {
      _defaultGone = true;
      _unreadable = const [];
    } else {
      final f = _folders[loc];
      if (f != null) {
        f
          ..available = false
          ..missing = true
          ..store = null
          ..reason = 'Folder not found. It may be on another device.'
          ..unreadable = const [];
      }
    }
    final last = _lastDeleted;
    if (last != null && last._location == loc) _lastDeleted = null;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
  }

  /// A binder's folder disappeared. Pending edits are written first if that
  /// is still possible. The binder stays in the sidebar as "on another
  /// device" with its pages listed, read-only; an open page stays open. Its
  /// watcher stops and nothing is written until the folder is back.
  Future<void> _binderGone(BinderSection section) async {
    await flush();
    final path = section.path;
    if (_disposed || _binders[path] != section || section.missing) return;
    // A pull-only binder is also "gone" when only its binder file is (G6).
    final fileOnly = _pullOnly(path) && await Directory(path).exists();
    if (_disposed || _binders[path] != section || section.missing) return;
    section
      ..missing = true
      ..status = BinderStatus.unavailable
      ..reason = fileOnly ? 'No $binderFileName in this folder.' : 'Folder not found. It may be on another device.';
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
  }

  /// A binder's folder is back: reads the binder file and the pages again,
  /// restarts the watcher, merges conflict copies and merges the open page.
  Future<void> _binderBack(String path) async {
    final old = _binders[path];
    if (old == null) return;
    // A pull-only binder is read before anything is dropped: with no binder
    // file it stays "gone", listed, with its rows (G6).
    if (_pullOnly(path) && !File('$path${Platform.pathSeparator}$binderFileName').existsSync()) return;
    for (final e in _loc.entries.where((e) => e.value == path && e.key != currentId).toList()) {
      _forgetPage(e.key);
    }
    final fresh = await _openBinder(path);
    if (_disposed || !identical(_binders[path], old)) return;
    if (fresh.missing) return; // gone again
    if (fresh.status == BinderStatus.unavailable) {
      // A pull-only binder stays "gone", listed, with its open page: it is
      // never taken apart (G6).
      if (_pullOnly(path)) return;
      // No binder file (or unusable): as at startup.
      await _disableBinder(old, BinderStatus.unavailable, fresh.reason ?? '');
      return;
    }
    _binders[path] = fresh;
    final changed = _recordBinderId(path, fresh.binder);
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    if (changed) await _saveSettings();
    await _promoteReleased();
    await _mergePendingCopies(inQueue: true);
    await _afterResume(await _resumeOpenPage(path, force: true));
    await _recoverPending(onlyLoc: path);
  }

  Future<void> _folderBack(String loc) async {
    if (loc == _standalone) {
      final entries = await _scan(store);
      _defaultGone = false;
      _adoptDefault(entries);
    } else {
      final fresh = await _openFolder(loc);
      if (_disposed) return;
      if (!fresh.available) {
        // Still can't be used (for example it now holds a binder).
        final f = _folders[loc];
        if (f != null) {
          f
            ..missing = fresh.missing
            ..reason = fresh.reason;
        }
        return;
      }
      _folders[loc] = fresh;
    }
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    await _promoteReleased();
    await _mergePendingCopies(inQueue: true);
    await _afterResume(await _resumeOpenPage(loc));
    await _recoverPending(onlyLoc: loc);
  }

  // The open page came back with no file: what it kept in recovery is saved
  // again (its own save lands it and retires the entry).
  Future<void> _afterResume(({bool ran, NotedPage? theirs}) resumed) async {
    final c = _current;
    final s = _session;
    if (resumed.ran && c != null && s != null && s.own.isNotEmpty) {
      if (resumed.theirs == null) _pageChanged(c.page);
      await flush(); // lands the page and retires its kept changes
    }
  }

  // The plain reason the file at [path] can't be used as page [id], chosen
  // like _checkFile does.
  Future<String> _whyUnreadable(String path, String id) async {
    try {
      final page = readPage(utf8.decode(await File(path).readAsBytes()));
      return page.id != id ? 'it holds a different page' : "it isn't a page this version of Noted can read";
    } on UnsupportedPageFormatException {
      return 'it is from a newer version of Noted';
    } on PageFormatException {
      return "it isn't a valid page file";
    } on FormatException {
      return "it isn't a valid page file";
    } on Object {
      return "it couldn't be read";
    }
  }

  // The open page was kept read-only while its folder was away: it is
  // writable again and merged with whatever its file holds now.
  //
  // Returns whether it ran, and the page read from the file (null: the file
  // is gone).
  Future<({bool ran, NotedPage? theirs})> _resumeOpenPage(String loc, {bool force = false}) async {
    final c = _current;
    if (c == null || (!force && _orphanLoc != loc)) return (ran: false, theirs: null);
    final id = c.page.id;
    if (_loc[id] != loc) {
      // Not listed in the folder. A file at its path that the scan couldn't
      // list as a page (a newer format, damaged, another id) is never written
      // over: the page is put back in its place but blocked, read-only until a
      // readable version arrives, which is merged into it (_mergeOpen).
      if (_orphanLoc == loc && _loc[id] == null) {
        try {
          final path = _storeOf(loc).pathFor(id);
          if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
            debugPrint('Open page $id: its file is there but cannot be read as a page.');
            _loc[id] = loc;
            _metas[id] = c.page.meta;
            _orphanLoc = null;
            _rebuildTree();
            await _blockOpen(loc, _key(path), await _whyUnreadable(path, id), id);
            return (ran: false, theirs: null);
          } else {
            // Its file is gone (the page was saved before the folder went and
            // came back without it). The page stays and is editable; its next
            // save writes the file, and a file that lands before that is
            // merged into it like any other change to the open page.
            _loc[id] = loc;
            _metas[id] = c.page.meta;
            _orphanLoc = null;
            _syncReadOnly();
            _rebuildTree();
            return (ran: true, theirs: null);
          }
        } on Object catch (e) {
          debugPrint('Checking the open page after its folder came back failed: $e');
        }
      }
      return (ran: false, theirs: null); // not in the folder any more
    }
    _orphanLoc = null;
    _syncReadOnly();
    try {
      final path = _storeOf(loc).pathFor(id);
      final file = File(path);
      final String text;
      try {
        text = await file.readAsString();
      } on PathNotFoundException {
        return (ran: true, theirs: null);
      }
      final time = (await file.lastModified()).millisecondsSinceEpoch;
      final page = readPage(text);
      if (page.id != id) {
        // A valid page, but not this one: nothing is merged, and the file is
        // not taken as this page's last known text.
        if (_current == c) await _blockOpen(loc, _key(path), 'it holds a different page', id);
        return (ran: false, theirs: null);
      }
      _known[_key(path)] = text;
      if (_current == c) _mergeOpen(page, text, time);
      return (ran: true, theirs: page);
    } on Object catch (e) {
      debugPrint('Reading the open page after its folder came back failed: $e');
      return (ran: false, theirs: null);
    }
  }

  // Saving trouble: leaving, the preview, retry, discard (R-1 v5) -------------

  // The page on screen is `id` and it can be edited (not a preview).
  bool _isEditableOpen(String id) => _current?.page.id == id && _preview == null;

  // Page [id] stops being busy, but only if it is busy for [why] (it may be
  // held by something else meanwhile).
  /// Marks page [id] busy (or free) as a move or a detached save would.
  @visibleForTesting
  void setBusyForTest(String id, bool busy) {
    if (busy) {
      _busy[id] = _busyMoving;
    } else {
      _busy.remove(id);
    }
  }

  void _free(String id, String why) {
    if (_busy[id] != why) return;
    _busy.remove(id);
    _recheckChosen(id);
  }

  // Page [id] ended being busy for [why]: whatever waited for it can go on.
  void _unbusy(String id, [String? why]) {
    if (why != null && _busy[id] != why) return;
    if (_busy.remove(id) == null) return;
    _recheckChosen(id);
    if (!_disposed) unawaited(_afterBusyCleared());
  }

  // Looks again at the file chosen for page [id], which the page's being open
  // or busy kept from being looked at: queued (a check is a job of its own).
  // A file that already holds another page releases the choice at once.
  void _recheckChosen(String id) {
    final b = _adoptedFiles[id];
    if (b == null || _disposed || id == currentId || _busy.containsKey(id)) return;
    if (_pathId[_key(b)] case final other? when other != id) {
      _releaseChoice(id, b);
      unawaited(_promoteReleased());
      return;
    }
    unawaited(checkFile(b));
  }

  // At checkFolders: the chosen files of closed pages that nothing lists for
  // their page (a lock or damage that cleared without a watcher event).
  Future<void> _recheckChosenFiles() async {
    for (final e in _adoptedFiles.entries.toList()) {
      final id = e.key;
      final path = e.value;
      if (_adoptedFiles[id] != path || id == currentId || _busy.containsKey(id)) continue;
      if (_goneChosen.containsKey(id) || _pathId[_key(path)] == id) continue;
      if (!Directory(File(path).parent.path).existsSync()) continue;
      if (_pathId[_key(path)] case final other? when other != id) {
        _releaseChoice(id, path);
        await _promoteReleased();
        continue;
      }
      // Looked at afresh: a last known text that equals what is there (kept
      // from a read that listed the file unreadable) must not end the check.
      _known.remove(_key(path));
      try {
        await _checkFile(path);
      } on Object catch (e) {
        debugPrint('Checking the chosen file $path failed: $e');
      }
      if (_disposed) return;
    }
  }

  Future<void> _afterBusyCleared() async {
    try {
      await _refreshPreview();
    } on Object catch (e) {
      debugPrint('Refreshing the preview failed: $e');
    }
  }

  // A job left on a detached chain ended: its pages are free again.
  void _oldJobEnded(Set<String> pages) {
    for (final p in pages) {
      final n = (_detached[p] ?? 1) - 1;
      if (n > 0) {
        _detached[p] = n;
      } else {
        _detached.remove(p);
        _unbusy(p, _busyDetached);
      }
    }
    if (!_disposed && !_backoff.scheduled) _backoff.schedule();
  }

  static const String _busyDetached = 'a save is still running';
  static const String _busyReplaying = 'replaying';
  static const String _busyDeleting = 'deleting';
  static const String _busyMoving = 'moving';
  static const String _busyDiscarding = 'discarding';

  // Leaves the open page (R-1 v5, 3.5): its last save is tried for up to
  // [leaveSaveLimit]; if it lands, T has run and the page may go. Otherwise
  // the edits are in recovery ("kept"), or the user is asked. Returns true if
  // the page may be closed. With [stayIfUnsafe] it returns false instead of
  // asking when the edits are not safe anywhere.
  Future<bool> _leaveOpenPage({bool stayIfUnsafe = false}) async {
    var mayGo = false;
    final freeze = _Freeze();
    try {
      return mayGo = await _leaveOpenPageFrozen(stayIfUnsafe: stayIfUnsafe, freeze: freeze);
    } finally {
      final c = freeze.controller;
      if (c != null) {
        _leaving--; // only this leave's own freeze ends here
        if (!mayGo) {
          // The page stays: editable again, and what a sync merge changed
          // while it was frozen (suppressed, since read-only) is saved.
          _syncReadOnly();
          if (!_disposed && identical(_current, c) && _preview == null && !identical(c.page, freeze.page)) _pageChanged(c.page);
        }
      }
    }
  }

  Future<bool> _leaveOpenPageFrozen({required bool stayIfUnsafe, required _Freeze freeze}) async {
    final c = _current;
    final session = _session;
    if (c == null || session == null || _preview != null) return true;
    final editing = c.editingId;
    if (editing != null) c.setEditing(editing, false);
    _saveTimer?.cancel();
    _saveTimer = null;
    final hadPending = _pendingSave != null;
    _pendingSave = null;
    final page = c.page;
    final seq = session.seq;
    final troubled = _trouble.isTrouble && _trouble.pageId == page.id;
    if (!hadPending && !troubled && _chain.isIdle) return true;
    _leaving++;
    freeze
      ..controller = c
      ..page = page;
    _syncReadOnly();
    // A place that is gone or locked is not a reason to go unasked: the edits
    // still have to be in recovery (the save runs the same rules).
    final loc = _loc[page.id] ?? _orphanLoc ?? _standalone;
    final st = _storeOrFolder(loc);
    final SaveResult? res = await _enqueueSave(page, seq).then<SaveResult?>((r) => r).timeout(
      leaveSaveLimit,
      onTimeout: () => null,
    );
    if (res != null && (res.end == SaveEnd.landed || res.end == SaveEnd.skipped)) return true;
    final KeepOutcome keep;
    if (res == null) {
      // Timed out: the save is left behind. Every page with a job still on the
      // old chain is busy until it ends; the next open waits on a new chain.
      _chain.detach().forEach((p, n) {
        _busy[p] = _busyDetached;
        _detached[p] = (_detached[p] ?? 0) + n;
      });
      // A pull-only page has no edits: there is nothing to keep (G1).
      if (_pullOnly(loc)) return true;
      keep = await _keepForRecovery(loc, st, page, session: session, seq: seq);
      _troubleFrom(session, page, keep, reason: "the drive isn't responding", folderGone: false);
    } else {
      keep = res.keep ?? KeepOutcome.dropped;
    }
    if (keep.safe) {
      _announceKept(page);
      return true;
    }
    if (stayIfUnsafe) return false;
    final lose = await _ask(UserQuestion.leaveAndLose, _titleOrUntitled(page.meta.title));
    if (!lose) throw const LeaveCancelled();
    return true;
  }

  // Tells the user, once per failure streak, that [page]'s edits are in
  // recovery.
  void _announceKept(NotedPage page) {
    if (_disposed || !_told.add(page.id)) return;
    final reason = _trouble.pageId == page.id && _trouble.reason.isNotEmpty ? _trouble.reason : 'it could not be saved';
    _keptNotices.add(KeptNotice(pageId: page.id, title: _titleOrUntitled(page.meta.title), reason: reason));
  }

  Future<void> _closeCurrent() async {
    await _leaveOpenPage();
    _disposeCurrent();
  }

  // A pull-only page that stayed open while its file was removed has no file
  // (nor an aside of one, which counts as present) and no other tracked file
  // with its id: once it is left its row goes, as a reload has it, and a file
  // listed as a duplicate of the page takes its place. Nothing is done for any
  // other page.
  void _dropGhostRow(String id) {
    final loc = _loc[id];
    if (loc == null || !_pullOnly(loc) || _pathId.containsValue(id)) return;
    try {
      final file = _storeOf(loc).pathFor(id);
      if (File(file).existsSync() || _hasAside(file)) return;
    } on NotebookException {
      return;
    }
    _forgetPage(id);
    _touch(loc);
    _rebuildTree();
    // A page with a chosen file keeps its choice until a folder check settles it.
    if (_disposed || _adoptedFiles.containsKey(id)) return;
    unawaited(
      _promoteDuplicate(id).catchError((Object e) {
        debugPrint('Promoting a duplicate of page $id failed: $e');
      }),
    );
  }

  // Whether [file] has an aside beside it that a killed replace left.
  bool _hasAside(String file) {
    final name = _folderName(file);
    try {
      for (final f in File(file).parent.listSync(followLinks: false)) {
        if (f is! File) continue;
        final n = _folderName(f.path);
        if (n.startsWith('$name.') && (n.endsWith(asideSuffix) || n.endsWith(verifiedSuffix))) return true;
      }
    } on FileSystemException {
      return true; // can't tell: present
    }
    return false;
  }

  // Closes the page on screen without saving it.
  void _disposeCurrent() {
    _session?.ended = true;
    _session = null;
    _preview = null;
    _blockKeep = null;
    _setTrouble(TroubleState.saved);
    final closing = _current?.page.id;
    _current?.dispose();
    _current = null;
    if (closing != null) _dropGhostRow(closing);
    _attachments?.dispose();
    _attachments = null;
    _base = null;
    _orphanLoc = null;
    _readOnlyReason = null;
    // The page's chosen file went while it was open: from now on it is a
    // closed page's, settled at a later check like any other.
    final chosen = closing == null ? null : _adoptedFiles[closing];
    if (closing != null && chosen != null && !File(chosen).existsSync()) {
      _goneChosen[closing] = chosen;
    }
    // The closing page's chosen file is looked at again: it may have been
    // damaged, locked or replaced while the page was open and kept it.
    if (closing != null) _recheckChosen(closing);
  }

  // Opening (R-1 v5, 3.6) -----------------------------------------------------

  // Opens [id] with no page open. The file is read and the page looked up in
  // the index in one save-chain job, so no write falls between them; a page
  // with kept edits is replayed outside the chain (bounded), and one that
  // can't be made current is shown as a preview.
  Future<void> _openFresh(String id) async {
    var otherPage = false;
    try {
      await _openFreshRead(id, () => otherPage = true);
    } finally {
      // The chosen file holds another page: it is no longer this page's. The
      // choice is let go whether or not the open worked, unless the page ended
      // up on screen (a kept-edits preview): closing it rechecks the file.
      if (otherPage && !_disposed) {
        final b = _adoptedFiles[id];
        final loc = _loc[id];
        if (b != null && loc != null && id != currentId && !_busy.containsKey(id)) {
          String? at;
          try {
            at = _storeOf(loc).pathFor(id);
          } on NotebookException {
            at = null;
          }
          if (at != null && _key(at) == _key(b)) {
            _releaseChoice(id, b);
            await _promoteReleased();
          }
        }
      }
    }
  }

  Future<void> _openFreshRead(String id, void Function() sawOtherPage) async {
    final loc = _loc[id] ?? _standalone;
    final st = _storeOf(loc);
    final rec = _recovery;
    final folder = _normalizePath(st.directory.path);
    final first = await _afterSaves<({bool done, List<RecoveryEntry> landed, bool ownsBusy})>(() async {
      final (:text, :readError, page: parsed) = await _readForOpen(st, id);
      if (readError?.why == _holdsOtherPage) sawOtherPage();
      await syncHook?.call('open-read', st.pathFor(id));
      final entries = rec == null ? const <RecoveryEntry>[] : rec.entriesFor(folder, id);
      final landed = [for (final e in entries) if (rec != null && rec.isLanded(e.gen)) e];
      final pending = entries.length - landed.length;
      final NotedPage page;
      try {
        if (text == null) throw readError!;
        page = parsed ?? readPage(text);
      } on _FileUnreadable catch (e) {
        if (pending == 0) throw e.cause;
        _installPreview(
          id,
          loc,
          st,
          null,
          null,
          [for (final x in entries) if (!rec!.isLanded(x.gen)) x],
          unreadable: e.why,
        );
        return (done: true, landed: landed, ownsBusy: false);
      } on PageFormatException catch (e) {
        // A file this version can't read, with changes kept for the page: they
        // are shown from the entry (a preview that can't land), never lost.
        if (pending == 0) rethrow;
        _installPreview(
          id,
          loc,
          st,
          null,
          null,
          [for (final x in entries) if (!rec!.isLanded(x.gen)) x],
          unreadable: e is UnsupportedPageFormatException
              ? 'the page file is from a newer version of Noted'
              : "the page file isn't a valid page file",
        );
        return (done: true, landed: landed, ownsBusy: false);
      }
      final already = _busy.containsKey(id);
      if (pending == 0 && !already) {
        _installEditable(id, loc, st, text, page);
        return (done: true, landed: landed, ownsBusy: false);
      }
      if (!already) _busy[id] = _busyReplaying;
      return (done: false, landed: landed, ownsBusy: !already);
    }, what: 'open of page $id', pages: {id});
    if (first.landed.isNotEmpty && rec != null) {
      // Landed already: deleted, never merged (0130).
      await _deleteGens(rec, [for (final e in first.landed) e.gen], null);
    }
    if (first.done) return;
    if (first.ownsBusy) {
      final replay = _replayPage(id);
      final r = await replay.timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (r == null) {
        unawaited(replay.whenComplete(() => _unbusy(id, _busyReplaying)));
      } else {
        _free(id, _busyReplaying);
      }
    }
    await _afterSaves(() async {
      final (:text, :readError, page: parsed) = await _readForOpen(st, id);
      if (readError?.why == _holdsOtherPage) sawOtherPage();
      final pending = rec == null
          ? const <RecoveryEntry>[]
          : [for (final e in rec.entriesFor(folder, id)) if (!rec.isLanded(e.gen)) e];
      final NotedPage page;
      try {
        if (text == null) throw readError!;
        page = parsed ?? readPage(text);
      } on _FileUnreadable catch (e) {
        if (pending.isEmpty) throw e.cause;
        _installPreview(id, loc, st, null, null, pending, unreadable: e.why);
        return;
      } on PageFormatException catch (e) {
        if (pending.isEmpty) rethrow;
        _installPreview(
          id,
          loc,
          st,
          null,
          null,
          pending,
          unreadable: e is UnsupportedPageFormatException
              ? 'the page file is from a newer version of Noted'
              : "the page file isn't a valid page file",
        );
        return;
      }
      if (pending.isEmpty && !_busy.containsKey(id)) {
        _installEditable(id, loc, st, text, page);
      } else {
        _installPreview(id, loc, st, text, page, pending);
      }
    }, what: 'open of page $id', pages: {id});
  }

  // Reads the file of [id] for opening. A file that refuses reads or holds
  // invalid UTF-8 is returned as an error, so that kept edits can still be
  // shown from recovery (0137) before the error is given up on.
  //
  // A file that parses as another page is returned as an error too, with no
  // text: the other page is never installed under [id].
  static const String _holdsOtherPage = 'the page file holds a different page';

  Future<({String? text, _FileUnreadable? readError, NotedPage? page})> _readForOpen(PageStore st, String id) async {
    try {
      final text = await st.readText(id);
      NotedPage? page;
      try {
        page = readPage(text);
      } on PageFormatException {
        // Damaged or newer: the callers tell which, as before.
      }
      if (page != null && page.id != id) {
        return (text: null, readError: _FileUnreadable(const PageFormatException(_holdsOtherPage), _holdsOtherPage), page: null);
      }
      return (text: text, readError: null, page: page);
    } on PathNotFoundException catch (e) {
      return (text: null, readError: _FileUnreadable(e, "the page file isn't there"), page: null);
    } on FileSystemException catch (e) {
      return (text: null, readError: _FileUnreadable(e, "the page file can't be read"), page: null);
    } on FormatException catch (e) {
      return (text: null, readError: _FileUnreadable(e, "the page file isn't a valid page file"), page: null);
    }
  }

  // Sets up the page [id] (read as [text]) for editing.
  void _installEditable(String id, String loc, PageStore st, String text, NotedPage page) {
    _known[_key(st.pathFor(id))] = text;
    _base = page;
    _metas[id] = page.meta;
    _setConflict(id, hasConflicts(page));
    _preview = null;
    final session = _session = SaveSession(id);
    // A change reported by a controller that is no longer the open one (a
    // late callback after it was closed) is ignored: it would queue an
    // unchecked save of a closed page.
    late final CanvasController controller;
    controller = CanvasController(
      page,
      modules,
      onChanged: (p) {
        if (identical(_current, controller) && identical(_session, session)) _pageChanged(p);
      },
      deviceName: deviceName,
    );
    _current = controller;
    _attachments = _makeAttachments(id, loc);
    _setTrouble(TroubleState.saved);
    _syncReadOnly();
    _rebuildTree();
  }

  // Shows [id] read-only: the file with the kept [entries] merged in memory,
  // never written (3.6).
  void _installPreview(
    String id,
    String loc,
    PageStore st,
    String? text,
    NotedPage? page,
    List<RecoveryEntry> entries, {
    String? unreadable,
  }) {
    final sortedEntries = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    // With no readable file, the newest entry's page stands in for it.
    final shown = page ?? sortedEntries.last.page;
    if (text != null) _known[_key(st.pathFor(id))] = text;
    _base = page;
    _metas[id] = shown.meta;
    var merged = shown;
    String? unlandable = unreadable;
    final codecs = _pageCodecs(id);
    final sorted = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    for (final e in sorted) {
      final NotedPage eb;
      if (e.baseText == null) {
        // With a file there, replay merges an entry with no base as a conflict
        // copy (0053); the preview shows what replay would land.
        if (page != null) {
          merged = mergeConflictCopy(
            merged,
            e.page,
            codecs,
            copyTime: e.time.millisecondsSinceEpoch,
            forRecovery: true,
          ).page;
          continue;
        }
        eb = NotedPage.create(e.page.meta);
      } else {
        final r = _tryRead(e.baseText!);
        if (r == null) {
          unlandable = 'the copy kept with the changes can no longer be read';
          continue;
        }
        eb = r;
      }
      merged = mergePage(
        eb,
        e.page,
        merged,
        codecs,
        theirsTime: DateTime.now().millisecondsSinceEpoch,
        markLanded: false,
      ).page;
    }
    final problem = _replayProblems.entries
        .where((p) => entries.any((e) => p.key == _entryKey(e)))
        .map((p) => p.value.why)
        .firstOrNull;
    final reason = unlandable ?? problem ?? (_busy.containsKey(id) ? 'Noted is still trying to save this page' : 'the page file is not available');
    final preview = _preview = _Preview(id, loc, entries, reason, unlandable: unlandable != null || problem != null && _replayHardFailure.contains(id));
    _session = null;
    late final CanvasController controller;
    controller = CanvasController(merged, modules, onChanged: (_) {}, deviceName: deviceName);
    _current = controller;
    _attachments = _makeAttachments(id, loc);
    _setTrouble(_previewTrouble(preview, merged));
    _syncReadOnly();
    _rebuildTree();
  }

  // Replays that failed for a reason that retrying won't change (the check
  // failed, a file can't be read), by page.
  final Set<String> _replayHardFailure = {};

  TroubleState _previewTrouble(_Preview p, NotedPage page) => TroubleState(
    TroubleKind.preview,
    pageId: p.id,
    title: _titleOrUntitled(page.meta.title),
    reason: p.reason,
    canDiscardKept: p.unlandable,
    canSaveCopy: pickFolder != null,
  );

  // The preview becomes an editable page once nothing is kept for it and
  // nothing holds it.
  bool _reopening = false;
  Future<void> _refreshPreview() async {
    final p = _preview;
    final rec = _recovery;
    if (p == null || rec == null || _reopening || _disposed) return;
    if (_busy.containsKey(p.id)) return;
    final pending = [
      for (final e in rec.indexEntries)
        if (e.pageId == p.id && !rec.isLanded(e.gen)) e,
    ];
    if (pending.isEmpty) {
      _reopening = true;
      try {
        _disposeCurrent();
        try {
          await _openFresh(p.id);
        } on PageFormatException catch (e) {
          // Nothing is kept for the page any more and its file can't be read:
          // it is listed as a page that can't be opened; another page is shown.
          debugPrint('Page ${p.id} can not be opened: ${e.message}');
          if (_current == null) {
            final others = [..._treeOf(p.loc).roots, ..._tree.roots].where((r) => r.id != p.id);
            if (others.isNotEmpty) {
              await _open(others.first.id);
            } else {
              await _createFallbackPage();
            }
          }
        }
      } finally {
        _reopening = false;
      }
      return;
    }
    final c = _current;
    if (c != null) {
      final reason = _replayProblems.entries
          .where((x) => pending.any((e) => x.key == _entryKey(e)))
          .map((x) => x.value.why)
          .firstOrNull;
      if (reason != null && reason != p.reason) {
        p.reason = reason;
        _setTrouble(_previewTrouble(p, c.page));
      }
    }
  }

  /// Retry on a preview: replays the kept changes now.
  Future<void> retryPreview() async {
    final p = _preview;
    if (p == null || _busy.containsKey(p.id)) return;
    _busy[p.id] = _busyReplaying;
    try {
      await _replayPage(p.id);
    } finally {
      _free(p.id, _busyReplaying);
    }
    await _refreshPreview();
    _backoff.schedule();
  }

  /// "Discard kept changes" on a preview that can't land: asks first, then
  /// deletes exactly the generations the preview shows.
  Future<void> discardKept() async {
    final p = _preview;
    final rec = _recovery;
    if (p == null || rec == null || !p.unlandable) return;
    if (_busy.containsKey(p.id)) {
      throw const NotebookException('Noted is still trying to save this page. Try again in a moment.');
    }
    final title = _trouble.title;
    if (!await _ask(UserQuestion.discardKept, title)) return;
    _busy[p.id] = _busyDiscarding;
    try {
      final problem = _lockProblem(); // without the recovery lock nothing is deleted
      if (problem != null) throw StateError(problem);
      await rec.transaction((tx) async {
        for (final e in p.entries) {
          await tx.delete(e);
        }
      });
    } on Object catch (e) {
      throw NotebookException("Couldn't remove the changes kept for this page: ${e is StateError ? e.message : describeError(e)}", needsAction: true);
    } finally {
      _free(p.id, _busyDiscarding);
    }
    for (final e in p.entries) {
      _replayProblems.remove(_entryKey(e));
    }
    await _refreshPreview();
  }

  // Backoff: tries everything that is waiting again --------------------------

  Future<void> _backoffTick() async {
    if (_disposed) return;
    final rec = _recovery;
    var again = false;
    try {
      final lockOk = _lockProblem() == null;
      final c = _current;
      final s = _session;
      if (c != null && s != null && _preview == null && _trouble.isTrouble && _trouble.pageId == c.page.id) {
        final r = await _enqueueSave(c.page, s.seq);
        if (r.end != SaveEnd.landed && r.end != SaveEnd.skipped) again = true;
      }
      if (rec != null && lockOk) {
        await _recoverPending();
        await _deleteGens(rec, [for (final e in rec.landedEntries) e.gen], null);
        if (rec.indexEntries.isNotEmpty) again = true;
      } else if (rec != null && !lockOk) {
        again = true;
        if (_trouble.kind == TroubleKind.saved && rec.indexEntries.isNotEmpty) notifyListeners();
      }
      final p = _preview;
      if (p != null && !p.unlandable && _backoff.delay == backoffMax && rec != null) {
        // A write that keeps failing past the longest wait: the changes can't land.
        p.unlandable = true;
        final cur = _current;
        if (cur != null) _setTrouble(_previewTrouble(p, cur.page));
      }
    } on Object catch (e) {
      debugPrint('Trying the kept changes again failed: $e');
      again = true;
    }
    if (again && !_disposed) _backoff.schedule();
  }

  // The open page's own buttons -------------------------------------------------

  /// Retry (bar button): the save is tried again now, and recovery too if it
  /// was failing; on a preview, the kept changes are replayed.
  Future<void> retrySave() async {
    if (_preview != null) return retryPreview();
    final c = _current;
    final s = _session;
    if (c == null || s == null || !_trouble.isTrouble) return;
    _backoff.cancelWait();
    final r = await _enqueueSave(c.page, s.seq);
    if (r.end != SaveEnd.landed) _backoff.schedule();
  }

  /// Discard changes (bar button): throws away what the page holds that was
  /// not saved, and reopens it as it is on disk plus what has landed.
  Future<void> discardChanges() async {
    final c = _current;
    final s = _session;
    final rec = _recovery;
    if (c == null || s == null || _preview != null || !_trouble.isTrouble) return;
    final id = c.page.id;
    if (_busy[id] == _busyDiscarding) return; // a second click while the first waits
    final oldFloor = s.floor;
    s.floor = s.seq + 1;
    _saveTimer?.cancel();
    _saveTimer = null;
    _pendingSave = null;
    _busy[id] = _busyDiscarding;
    _syncReadOnly(); // typing while Discard waits would be dropped: the page is read-only
    try {
      // A save already running (a retry in file I/O) finishes first. It never
      // publishes anything newer than the floor; one that was already writing
      // lands, and what landed is part of the page as it reopens.
      await _chain.idle;
      if (rec != null && s.own.isNotEmpty) {
        final problem = _lockProblem();
        if (problem != null) throw StateError(problem);
        final gens = {...s.own.keys};
        await rec.transaction((tx) async {
          for (final e in rec.indexEntries.where((e) => gens.contains(e.gen)).toList()) {
            await tx.delete(e);
          }
        });
        s.own.clear();
      }
    } on Object catch (e) {
      _free(id, _busyDiscarding);
      _syncReadOnly();
      s.floor = oldFloor; // nothing was discarded: later snapshots are kept again
      if (identical(_current, c)) _pageChanged(c.page); // and saved again
      throw NotebookException(
        "Couldn't remove the changes kept for this page: ${e is StateError ? e.message : describeError(e)}",
        needsAction: true,
      );
    }
    _free(id, _busyDiscarding);
    // The user went elsewhere while Discard waited: the own generations are
    // gone, and nothing is reopened over the page now on screen.
    if (!identical(_current, c) || !identical(_session, s)) return;
    if (s.landedPastFloor) {
      _notices.add('A save that was already running finished before Discard, so those changes were kept.');
    }
    _disposeCurrent();
    await _openFresh(id);
  }

  /// The title and the text of the boxes of the page on screen, in reading
  /// order. For unsupported boxes it is their saved snapshot; nothing is
  /// decoded.
  String pageText() {
    final c = _current;
    if (c == null) return '';
    final boxes = [for (final n in c.page.nodes) if (n is BoxRecord) n];
    boxes.sort((a, b) {
      final dy = a.bounds.y.compareTo(b.bounds.y);
      return dy != 0 ? dy : a.bounds.x.compareTo(b.bounds.x);
    });
    final out = StringBuffer(c.page.meta.title);
    for (final b in boxes) {
      final t = b.snapshotText;
      if (t.isNotEmpty) out..writeln()..write(t);
    }
    return out.toString();
  }

  /// Copy page text (bar button).
  Future<void> copyPageText() => Clipboard.setData(ClipboardData(text: pageText()));

  /// "Save a copy elsewhere…": asks for a folder and writes the page on screen
  /// there as a new page, with its attachments. Nothing is replaced or deleted.
  /// Returns what to tell the user (empty: cancelled).
  Future<String> saveCopyElsewhere() async {
    final pick = pickFolder;
    if (pick == null) throw const NotebookException('Saving a copy elsewhere is not available on this device.');
    final c = _current;
    if (c == null) return '';
    final page = c.page;
    final oldId = page.id;
    final loc = _loc[oldId] ?? _preview?.loc ?? _orphanLoc;
    final chosen = await pick();
    if (chosen == null) return '';
    final dir = Directory(_normalizePath(chosen));
    // Nothing is made in a pull-only folder.
    if (_pullOnly(dir.path)) throw const NotebookException(_pullOnlyMessage);
    final newPageId = newId();
    final copy = page.withMeta(page.meta.withId(newPageId).withPlacement(parentId: null, order: 0));
    final left = <String>[];
    final sources = <Directory>[
      ?(loc == null ? null : Directory('${_storeOrFolder(loc).directory.path}${Platform.pathSeparator}${assetsFolderName(oldId)}')),
      if (_recovery != null)
        Directory('${_recovery!.directory.path}${Platform.pathSeparator}${assetsFolderName(oldId)}'),
    ];
    final result = AttachmentCopy();
    final targetAssets = Directory('${dir.path}${Platform.pathSeparator}${assetsFolderName(newPageId)}');
    try {
      await dir.create(recursive: true);
      for (final src in sources) {
        try {
          // A missing folder copies nothing; a pull-only source is not swept.
          await _copyDir(src, targetAssets, into: result, sweepSource: !_pullOnly(src.path));
        } on Object catch (e) {
          debugPrint('Copying ${src.path} failed: $e');
          left.add(src.path);
        }
      }
      final target = PageStore(dir);
      final copyIdentity = _identityOf(() => writePage(copy));
      final copied = await _lockRun(target.directory, () async {
        if (!await target.saveNew(copy)) return false;
        // Reported only if the picked folder is a joined location.
        if (_locationOf(target.pathFor(newPageId)) != null) {
          _emitPublished(target.pathFor(newPageId), copyIdentity, () => writePage(copy));
        }
        return true;
      });
      if (!copied) {
        throw const NotebookException('A file for the copy already exists, so nothing was written.');
      }
      if (await target.readText(newPageId) != writePage(copy)) {
        throw const NotebookException('The copy was not written correctly.');
      }
    } on FileSystemException catch (e) {
      throw NotebookException("Couldn't save the copy: ${describeError(e)}", needsAction: true);
    }
    // Whatever the page refers to in its folder that did not arrive is named:
    // the source folder missing or unreadable, a different file already at the
    // target, or a leftover kept aside (never a plain "Saved a copy").
    final refs = _folderAttachmentFiles(page);
    // The original's own folder is not there (or unknown): files kept in it can't be checked.
    final sourceUnavailable = loc == null || !Directory(_storeOrFolder(loc).directory.path).existsSync();
    final differing = {for (final p in result.differing) _baseName(p)};
    final notCopied = <String>[
      for (final f in refs.files)
        if (differing.contains(f) ||
            FileSystemEntity.typeSync(
                  '${targetAssets.path}${Platform.pathSeparator}$f',
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound)
          f,
    ];
    // What was kept aside as damaged, or left alone because it was still
    // changing, in the wording the moves use.
    final keptLines = [
      // The good copy is in the original's folder or, when that one was the
      // damaged one, in the recovery folder: say both when both were read.
      for (final n in _copyNotices(
        result,
        'the copy',
        _recovery == null ? "the original's folder" : "the original's folder or the recovery folder",
      ))
        '${n.substring(0, 1).toLowerCase()}${n.substring(1, n.length - 1)}',
    ];
    final problems = <String>[
      if (notCopied.isNotEmpty)
        "${notCopied.length == 1 ? 'this attachment file was' : 'these attachment files were'} not copied "
            '(the original is missing or unreadable, or a different file is already under that name): '
            '${_namesShown(notCopied)}',
      if (refs.unchecked.isNotEmpty)
        '${refs.unchecked.length == 1 ? 'an attachment name was' : '${refs.unchecked.length} attachment names were'} '
            'not checked because ${refs.unchecked.length == 1 ? "it isn't" : "they aren't"} a file name Noted writes: '
            '${_namesShown(refs.unchecked)}',
      if (refs.unasked > 0 && sourceUnavailable)
        "the original's attachments folder wasn't available, and ${refs.unasked} "
            '${refs.unasked == 1 ? 'box is' : 'boxes are'} of a type that is switched off, not allowed on this page '
            "or from a newer version, so any files ${refs.unasked == 1 ? 'it keeps' : 'they keep'} couldn't be checked",
      ...keptLines,
      if (result.keptAside.isNotEmpty)
        'leftover temporary files in the attachments folder were left where they are: ${_namesShown(result.keptAside)}',
      if (left.isNotEmpty) "these attachment folders couldn't be copied: ${left.join(', ')}",
    ];
    if (problems.isEmpty) return 'Saved a copy to ${dir.path}.';
    return 'Saved a copy to ${dir.path}, but ${problems.join('. Also, ')}. '
        'Nothing in the original was changed.';
  }

  // The attachment files [page] keeps in its folder, as its boxes' modules
  // say (Box API 0.14): [files] are names Noted writes (joined onto the assets
  // folder), [unchecked] are names it does not (never joined), and [unasked]
  // counts boxes whose module could not be asked: switched off, not allowed
  // on the page, unknown, newer or unreadable data.
  ({List<String> files, List<String> unchecked, int unasked}) _folderAttachmentFiles(NotedPage page) {
    final off = disallowedBoxTypesFor(page.id);
    final files = <String>{};
    final unchecked = <String>{};
    var unasked = 0;
    for (final n in page.nodes) {
      if (n is! BoxRecord) continue;
      final r = off.contains(n.typeId) ? null : modules.codecs.resolve(n);
      if (r is! LiveBox) {
        unasked++;
        continue;
      }
      for (final name in r.codec.folderFiles(r.data)) {
        (isAttachmentFileName(name) ? files : unchecked).add(name);
      }
    }
    return (files: files.toList(), unchecked: unchecked.toList(), unasked: unasked);
  }

  static String _namesShown(List<String> paths) {
    final names = paths.map(_baseName).toList();
    return names.length <= 3
        ? names.map((n) => '"$n"').join(', ')
        : '${names.take(3).map((n) => '"$n"').join(', ')} and ${names.length - 3} more';
  }

  // Leaving the app --------------------------------------------------------------

  /// Saves what can be saved before the window closes, within a time limit,
  /// and puts the rest in recovery as leaving a page does. Returns false if
  /// the user chose to stay (the question "Your changes will be lost").
  Future<bool> prepareToExit({Duration? limit}) async {
    final bound = limit ?? leaveSaveLimit;
    try {
      await _leaveOpenPage();
    } on LeaveCancelled {
      return false;
    }
    // The held pages get a deadline of the same length, started now; the queue
    // below keeps its full limit.
    final clock = Stopwatch()..start();
    Duration left() => clock.elapsed >= bound ? Duration.zero : bound - clock.elapsed;
    if (!await _saveHeldAtExit(left)) return false;
    // Other queued writes get the same time; what hangs is left behind.
    var stuck = false;
    await _chain.idle.timeout(bound, onTimeout: () => stuck = true);
    if (stuck) _chain.detach();
    final rec = _recovery;
    if (rec != null && rec.landedEntries.isNotEmpty) {
      await _deleteGens(rec, [for (final e in rec.landedEntries) e.gen], null).timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      _exitLandedLeft = rec.landedEntries.isNotEmpty;
    }
    return true;
  }

  // At exit, pages a failed delete left only in memory ([_held]) are written
  // beside their place as exclusive copies, never over a file (the naming Undo
  // uses). Where that fails, the user is asked before they are lost. False:
  // the user chose to stay.
  Future<bool> _saveHeldAtExit(Duration Function() left) async {
    // An Undo that is still running owns its pages; past the time limit they
    // count as not preserved.
    if (_undoRuns.isNotEmpty) {
      var stalled = false;
      await Future.wait([..._undoRuns.keys]).timeout(
        left(),
        onTimeout: () {
          stalled = true;
          return const <void>[];
        },
      );
      if (stalled) {
        // Read now, not at the start: a delete rollback shrinks its list as
        // pages become safe (recovery holds them, or they are back). It asks
        // only when a page is still at risk.
        final title = [
          for (final d in _undoRuns.values)
            for (final p in d.pages) _titleOrUntitled(p.meta.title),
        ].join(', ');
        if (title.isNotEmpty && !await _ask(UserQuestion.leaveAndLose, title)) return false;
      }
    }
    for (final d in [..._held]) {
      if (_undoing.containsKey(d)) continue; // its Undo owns the pages; the question names them
      final failed = <NotedPage>[];
      for (final page in d.pages) {
        if (d._copied.contains(page.id) || d._restored.contains(page.id)) continue;
        String? copy;
        try {
          _assertWritable(d._location); // a read-only place gets no file
          final st = _storeOf(d._location);
          // A copy that lands after the time limit still counts as made.
          final write = d._copying[page.id] ??= () async {
            try {
              final c = await _publishConflictCopy(st, page);
              if (c != null) d._copied.add(page.id);
              return c;
            } finally {
              d._copying.remove(page.id);
            }
          }();
          copy = await write.timeout(left());
        } on Object catch (e) {
          debugPrint('Saving ${page.id} beside its place at exit failed: $e');
        }
        if (copy == null) {
          failed.add(page);
        } else {
          d._copied.add(page.id);
        }
      }
      if (failed.isNotEmpty) {
        final title = failed.map((p) => _titleOrUntitled(p.meta.title)).join(', ');
        if (!await _ask(UserQuestion.leaveAndLose, title)) return false;
      }
      _held.remove(d);
    }
    return true;
  }

  bool _exitLandedLeft = false;

  /// Whether a recovered page may show boxes deleted since: its entry landed
  /// but could not be deleted, even at quit (the quit notice says so).
  bool get landedEntryLeft => _exitLandedLeft;

  void _rebuildTree() {
    final groups = <String, List<PageMeta>>{};
    for (final e in _metas.entries) {
      (groups[_loc[e.key] ?? _standalone] ??= []).add(e.value);
    }
    _tree = PageTree.build([
      for (final e in groups.entries)
        if (_isStandaloneLoc(e.key)) ...e.value,
    ]);
    for (final b in _binders.values) {
      b.tree = PageTree.build(groups[b.path] ?? const []);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _aiMerge?.dispose();
    _saveTimer?.cancel();
    _backoff.dispose();
    unawaited(_keptNotices.close());
    _folderTimer?.cancel();
    _settingsTimer?.cancel();
    for (final t in _debounce.values) {
      t.cancel();
    }
    _debounce.clear();
    for (final w in _watchers.values) {
      unawaited(w.cancel());
    }
    _watchers.clear();
    _rootDebounce?.cancel();
    for (final w in _rootWatchers.values) {
      unawaited(w.cancel());
    }
    _rootWatchers.clear();
    _current?.dispose();
    _attachments?.dispose();
    unawaited(_notices.close());
    unawaited(_changes.close());
    tools.dispose();
    super.dispose();
  }
}

/// A page file that could not be read as text, and what to say about it.
class _FileUnreadable implements Exception {
  _FileUnreadable(this.cause, this.why);
  final Object cause;
  final String why;
}

// One leave's freeze of the page on screen: the controller it froze and the
// page as it was then (see Notebook._leaveOpenPage).
class _Freeze {
  CanvasController? controller;
  NotedPage? page;
}

// What `binders.json` looked like at load: no file (a new install), a file
// that already records binder ids, or one that doesn't (written by an older
// build: an upgrade, see Notebook.discoverBinders).
enum _SettingsKind { fresh, current, upgrade }

// Why binder list changes are refused (see Notebook.settingsHeld): the launch
// read isn't settled yet, the file is locked or can't be read now, or it is
// damaged. Only a successful read clears the last two.
enum _SettingsHold { pending, locked, damaged }

// What reading one candidate folder's binder file gave.
class _Candidate {
  const _Candidate.found(this.id, this.title) : failed = false;
  const _Candidate.notOne() : id = null, title = null, failed = false;
  const _Candidate.failed() : id = null, title = null, failed = true;

  final String? id;
  final String? title;

  /// An I/O failure (a lock, an offline placeholder): says nothing about the file.
  final bool failed;
}

// What load or a retry adopts from `binders.json`: the listed binder folders
// and the ids the file records for them.
typedef _Adopted = ({List<String> listed, Map<String, String> recorded});

// One read of `binders.json`: the parsed file, a missing file, or why it
// can't be read.
class _SettingsRead {
  _SettingsRead.read(RawObject this.file) : notFound = false, hold = null, error = null;
  _SettingsRead.notFound(this.error) : file = null, notFound = true, hold = null;
  _SettingsRead.failed(_SettingsHold this.hold, this.error) : file = null, notFound = false;

  final RawObject? file;
  final bool notFound;
  final _SettingsHold? hold;
  final Object? error;
}
