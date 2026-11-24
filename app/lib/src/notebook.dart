// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:collection' show MapBase;
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
import 'icloud_folders.dart';
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
  _ReplayFailure(this.why, {this.detail, this.transient = false});

  // The plain reason shown to the user, and the technical detail for the log.
  final String why;
  final String? detail;

  // Not a refusal of the entry: the landed page is waiting to be settled, so the
  // entry is listed but not offered for discarding as unlandable.
  final bool transient;

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

/// A map that tells its owner which key changed, so [Notebook._fileStamps] can drop
/// the stamp of any file whose `_known` or `_pathId` entry changed.
class _TrackedMap extends MapBase<String, String> {
  _TrackedMap(this._changed);
  final void Function(String key) _changed;
  final Map<String, String> _m = {};

  @override
  String? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, String value) {
    // The same text again is no change: the stamp of the file it describes stays.
    if (_m[key] != value) _changed(key);
    _m[key] = value;
  }

  @override
  void clear() {
    _m.keys.toList().forEach(_changed);
    _m.clear();
  }

  @override
  Iterable<String> get keys => _m.keys;
  @override
  String? remove(Object? key) {
    if (key is String) _changed(key);
    return _m.remove(key);
  }
}

// A kept entry written under a move's target folder, paired with the old one
// until the page has settled.
/// A lock of a move's pair that wasn't got in time (see [Notebook._underPair]).
class _LockTimeout implements Exception {
  const _LockTimeout(this.path);
  final String path;
}

/// The in-turn gate (0184) refused a move: nothing moved, and a restore keeps
/// its record to try again.
class _GateRefused extends FileSystemException {
  const _GateRefused(super.message, String super.path);
}

/// A folder move that waited for a lock and gave up: nothing was moved.
class _FolderBusy extends FileSystemException {
  const _FolderBusy(String path) : super('The folder is busy; try again', path);
}

/// How one page's rename ended (see [Notebook._renameOnePage]).
enum _RenameOne { renamed, taken, busy, cannot }

/// How one run of a set-aside's expiry ended (see [Notebook._expireRecord]):
/// [busy] is a run that didn't look at the folder (the page is being moved or
/// deleted), which isn't counted as a kept run.
enum _Expiry { done, restored, kept, busy, stopped }

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

/// A page tree that a move copied instead of renaming (another drive or
/// cloud), with the originals it kept. [Notebook.deleteOriginals] deletes
/// them, each only while it is unchanged and its copy still holds what the
/// move put there. Held in memory only.
class CopiedMove {
  CopiedMove._(this.fromLoc, this.toLoc);

  final String fromLoc;
  final String toLoc;
  final List<_CopiedPage> _pages = [];
  String _message = '';
  bool _running = false;

  /// How many pages still have an original to delete.
  int get pending => _pages.where((p) => !p.finished).length;

  // What each copy should still hold: the text the placement wrote to D's root
  // (the only page that is placed), as the notebook knows it; never a re-read,
  // which could take a sync client's later write for the copy's own. With none
  // known the text the copy was published with stays.
  void _recordCopyText(String? written) {
    final root = _pages.firstOrNull;
    if (root != null && written != null) root.copyText = written;
  }
}

class _CopiedPage {
  _CopiedPage(this.id, this.title, this.sourcePath, this.sourceText, this.copyText, this.files);

  final String id;
  final String title;
  final String sourcePath;

  // The text of the original as it was copied.
  final String sourceText;

  // What the copy should still hold.
  String copyText;
  final List<_CopiedFile> files;
  bool pageGone = false;

  bool get finished => pageGone && files.every((f) => f.gone);
}

class _CopiedFile {
  _CopiedFile(this.source, this.target, this.identity);

  final String source;
  final String target;
  final ContentIdentity identity;
  bool gone = false;
}

/// A move that copied: the pages are at the target, their originals are kept
/// until [Notebook.deleteOriginals] runs for [move].
class OriginalsKeptException extends NotebookException {
  const OriginalsKeptException(super.message, this.move) : super(needsAction: true);

  final CopiedMove move;
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

/// A set-aside folder of a deleted page: in `deleted-attachments`, or in place
/// beside the page (`<id>.deleted-<12 hex>.assets`). The expiry removes its
/// files one by one against [identities], never the folder as a whole.
class _AsideRecord {
  _AsideRecord({
    required this.pageId,
    required this.title,
    required this.loc,
    required this.dir,
    required this.inPlace,
    required this.identities,
  });

  final String pageId;
  final String title;

  /// The page's location (its folder's lock is the expiry's).
  final String loc;
  final Directory dir;
  final bool inPlace;

  /// Each file's identity when the folder was set aside, by path relative to
  /// [dir] with `/`; null for a file that has none (a placeholder, a name that
  /// is not a hash).
  final Map<String, ContentIdentity?> identities;

  /// Runs of the expiry that kept the folder because the page may be back.
  int keptRuns = 0;
  bool reported = false;
  bool running = false;

  /// What a kept run waits for, so unrelated checks don't use up the runs: any
  /// check of the location, or (when false) only a check of [blockedKey]'s file
  /// or of a path that may be the page.
  bool retryOnAnyCheck = true;
  String? blockedKey;

  /// `<id>.deleted-<12 hex>` for an in-place folder (N10).
  String? get stem {
    if (!inPlace) return null;
    final n = dir.path.split(RegExp(r'[\\/]')).last;
    return n.substring(0, n.length - '.assets'.length);
  }
}

/// The folder can't be renamed to where it was asked to go (another drive or a
/// cloud file system that refuses it).
class _CannotRename extends FileSystemException {
  const _CannotRename(String path) : super('The folder can not be renamed there', path);
}

/// Pages removed by one delete, held in full so the delete can be undone.
class DeletedPages {
  DeletedPages._(
    this.pages,
    this.openId,
    this._location,
    this._assets, {
    this.keptNote,
    Set<String>? keepTrash,
    Map<String, _AsideRecord>? records,
    Map<String, String>? locations,
  }) : _keepTrash = {...?keepTrash},
       _records = records ?? {},
       _locations = {...?locations};

  /// What to tell the user when pages were not deleted because their files
  /// changed after they were read (they stay as they are), or null.
  final String? keptNote;

  /// The deleted page and its subpages, parents before children.
  final List<NotedPage> pages;

  /// The deleted page that was open, if any.
  final String? openId;

  final String _location;

  // The folder each page was deleted from, by page id (in memory only): a
  // standalone tree can span folders, and Undo puts each page back in its own.
  // A page not listed was in [_location].
  final Map<String, String> _locations;

  String _locationOfPage(String id) => _locations[id] ?? _location;

  // Each deleted page's assets folder, set aside until the delete is undone
  // (moved back) or forgotten (removed).
  final Map<String, Directory> _assets;

  // What the expiry needs of each set-aside folder, by page id: where it is,
  // whether it is in place, and each file's identity at delete time.
  final Map<String, _AsideRecord> _records;

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

/// A change to a binder's settings that is queued to be written (AI access, a
/// box type or attachment storage). Until it lands the screen shows it; the
/// AI-facing view never loosens because of it.
final class BinderSetting {
  BinderSetting(this.delta, this.what);

  /// Replaced only to rebase [BinderField.base] when an earlier change was
  /// refused.
  BinderDelta delta;

  /// What it changes, for a notice.
  final String what;
}

/// The three text fields of a binder cover.
typedef CoverText = ({String title, String description, String owner});

/// What an open cover has typed and not sent, with the values its fields were
/// last brought in line with (`applied`) and the id of the binder it showed.
typedef CoverTyping = ({CoverText text, CoverText applied, String? shownId});

/// A cover change that is not in the binder file yet (D1, D3). It lives in the
/// notebook, outside the binder section, so it survives damage, unavailability,
/// another binder's file and reopening.
final class CoverChange {
  CoverChange(this.delta, this.fields, this.shownId);

  final BinderDelta delta;

  /// The text of each field it sets: `title`, `description`, `owner`, `color`.
  final Map<String, String> fields;

  /// The id of the binder the cover showed when this was typed.
  final String? shownId;

  /// A try at writing it was refused or couldn't be made: the cover says "Not
  /// saved yet" and offers Discard.
  bool stuck = false;

  /// The binder it is for: the recorded id, else the one the cover showed.
  String? get forId => delta.binderId ?? shownId;

  /// Names the fields, for a question.
  String get what => fields.keys.join(', ');
}

/// A file beside a binder's file that holds a copy of it or part of it (P).
final class BinderCopyRow {
  const BinderCopyRow({
    required this.path,
    required this.name,
    required this.label,
    required this.canPutBack,
    required this.canReadAsBinder,
    this.canDelete = true,
    this.forOtherBinder = false,
    this.bytes,
  });

  final String path;
  final String name;

  /// What it is: same as saved, an interrupted change, an older copy, or a file
  /// this version can't read.
  final String label;

  /// The binder file is missing and this is a complete copy of it.
  final bool canPutBack;

  /// It is a copy of another binder's file.
  final bool forOtherBinder;

  /// Delete is offered (not in a pull-only folder).
  final bool canDelete;

  /// It reads as a binder file.
  final bool canReadAsBinder;

  /// What it held when it was listed.
  final List<int>? bytes;
}

/// Why a binder folder is held: seen to hold something other than this
/// binder's file. While held nothing in the folder is written or deleted, and
/// the open page's unsaved edits are kept in recovery (held edits).
enum BinderHold {
  /// Another binder's file, with another id than the one recorded.
  otherBinder,

  /// A binder file that can't be read.
  damaged,

  /// No binder file (and no aside of one being replaced).
  missing,
}

/// A write or delete in a binder folder refused at its turn because the folder
/// now holds another binder's file.
class BinderHeldException extends NotebookException {
  const BinderHeldException(super.message);
}

/// What a job refused at its turn says when the binder file isn't there or
/// can't be read just now (no hold; the watcher looks again).
const String binderUnreadableNowMessage = "The binder's file can't be read just now.";

// A job refused at its turn because the binder file isn't there or can't be
// read just now (no hold; the watcher looks again). A save tries again later.
class _BinderUnreadableNow extends NotebookException {
  const _BinderUnreadableNow() : super(binderUnreadableNowMessage);
}

/// What a turn at a binder folder found its binder file to be.
enum BinderVerdict {
  /// The binder's own file (the recorded id).
  own,

  /// Another binder's file: the folder is held.
  other,

  /// Not there, or not readable now: no hold, the watcher looks again.
  unreadable,

  /// Nothing to check: no recorded id, or a pull-only or away folder.
  none,
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
    this.other,
    this.copies = const [],
    this.fileMissing = false,
  }) : saved = binder,
       tree = PageTree.build(const []);

  /// The binder's folder.
  final String path;
  BinderStatus status;

  /// The binder as the screen shows it: [saved] with the queued settings and
  /// this binder's cover changes that aren't written yet.
  Binder? binder;

  /// What the binder file held when it was last read or written here.
  Binder? saved;

  /// Settings changes queued to be written, oldest first.
  final List<BinderSetting> pending = [];

  /// The file in this folder belongs to another binder (a different id from
  /// the one this device recorded for the folder). The pages are listed
  /// read-only; nothing is written until the user chooses to use that binder.
  Binder? other;

  /// Set when the folder is seen to hold another binder's file, a damaged
  /// binder file or none, before anything else happens; cleared by a read of
  /// this binder's own file, Use this binder or Remove binder. Nothing in the
  /// folder is written or deleted while it is set. In memory only.
  BinderHold? get hold => _hold;
  BinderHold? _hold;

  /// The other binder read with an [BinderHold.otherBinder] hold, before
  /// [other] is set (Use this binder works from it).
  Binder? get heldOther => _heldOther;
  Binder? _heldOther;

  // Why a [BinderHold.damaged] hold was set: the file's problem.
  String? _holdReason;

  // A hold was cleared and what it kept is still to land (L).
  bool _landDue = false;

  /// The page that was open in this binder when its file went missing, to open
  /// again when the same binder's file is read again.
  String? returnTo;

  /// The page [returnTo] was replaced with when the binder was disabled.
  String? fallbackId;

  /// Files beside the binder file whose name starts with `noted-binder`, as the
  /// last look found them.
  List<BinderCopy> copies;

  /// The binder file was not there when the folder was last read. Its copies
  /// may be put back.
  bool fileMissing;

  /// When a binder-file aside was first seen with no binder file.
  DateTime? asideSince;
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
  const TemplateItem(this.template, this.path, this.binderPath, this.identity, {this.binderId});

  final NotedTemplate template;

  /// The identity of the bytes that were listed; a delete only removes the
  /// file while it still holds them.
  final ContentIdentity identity;

  /// The template file.
  final String path;

  /// The binder the template belongs to; null for an app-wide template.
  final String? binderPath;

  /// The id recorded for the binder when the template was listed: a delete is
  /// refused when the folder holds another binder by then.
  final String? binderId;
}

// What a binder's template work started with (see Notebook._templateSnap).
typedef _TemplateSnap = ({BinderSection? section, String? id});

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
    this.binderStoreFactory = BinderStore.new,
    this.binderRecheckDelay = const Duration(seconds: 2),
    this.asideRestoreAfter = const Duration(seconds: 30),
    this.copyRetireAfter = const Duration(seconds: 30),
    this.coverRetryFirst = const Duration(seconds: 2),
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
    Map<String, String> readOnlyRootNames = const {},
    this.icloud,
  }) : folderLocks = folderLocks ?? FolderLocks(),
       _readOnlyRoots = [for (final r in readOnlyRoots) _normalizePath(r)],
       _readOnlyRootNamesIn = readOnlyRootNames {
    _chain.onDetachedJobEnded = _oldJobEnded;
    icloud?.onRootWritable = _rootWritable;
    // A file that is not downloaded is asked for through the platform (R5.5).
    if (icloud != null && icloud!.active) requestDownload = icloud!.startDownloading;
    icloud?.addListener(_notifyLoad);
  }

  /// Access to iCloud folders and bookmarked folders (R5.3, R5.9): resolved
  /// before the first load, its roots self-tested before they are written.
  final IcloudFolders? icloud;

  // iCloud roots (real paths, as keys) that are registered but not yet
  // self-tested, or whose self-test failed or timed out: `_isLocked` and every
  // sweep refuse them (R5.9). Set before the first load and at each pick.
  final Set<String> _untestedRoots = {};

  // The real-path key of each location asked about, resolved once (cleared when a root changes).
  final Map<String, String> _realKeys = {};

  void _rootWritable(String root, bool writable) {
    _realKeys.clear();
    final k = _key(_normalizePath(root));
    if (writable) {
      _untestedRoots.remove(k);
    } else {
      _untestedRoots.add(k);
    }
    _notifyLoad();
  }

  // Refuses a write into an iCloud root that is not tested or whose access is lost.
  void _assertTested(String path) {
    if (!_mayTouch(path)) throw NotebookException(_untestedMessage(path));
  }

  String _untestedMessage(String path) => icloud?.statusOf(path) ?? 'That folder is not available.';

  // Whether [loc] may be written or swept: not in an iCloud root that is untested, and its access not lost (R5.9).
  bool _mayTouch(String loc) => !_untested(loc) && (loc == _standalone || !(icloud?.accessLost(loc) ?? false));

  // Whether [loc] is at or under an iCloud root that isn't tested yet.
  bool _untested(String loc) {
    if (_untestedRoots.isEmpty || loc == _standalone) return false;
    var k = _realKeys[loc];
    if (k == null) {
      k = _key(_realKey(loc));
      // Not kept for a folder that is not there yet: it may resolve differently once made.
      if (Directory(loc).existsSync()) _realKeys[loc] = k;
    }
    for (final r in _untestedRoots) {
      if (k == r || k.startsWith(r.endsWith('/') ? r : '$r/')) return true;
    }
    return false;
  }

  // [loc] with links resolved (the roots are real paths).
  String _realKey(String loc) {
    try {
      return Directory(loc).existsSync() ? Directory(loc).resolveSymbolicLinksSync() : loc;
    } on FileSystemException {
      return loc;
    }
  }

  /// The folder rows' words for a location whose access needs the user or is
  /// being checked (R5.3, R5.9), or null.
  String? cloudStatusOf(String loc) => icloud?.statusOf(loc);

  /// The text under the load's progress while an iCloud folder is checked.
  bool get checkingICloud => icloud?.checking.value ?? false;

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

  // The provider's name by read-only root (the path as given); a root that
  // isn't named here is OneDrive's.
  final Map<String, String> _readOnlyRootNamesIn;
  late final Map<String, String> _readOnlyRootNames = {
    for (final e in _readOnlyRootNamesIn.entries) _key(_normalizePath(e.key)): e.value,
  };

  /// What a refused change to an OneDrive pull-only location says.
  static const String pullOnlyMessage = 'This OneDrive folder is read-only on this device for now.';

  /// What every place that refuses a change to the pull-only location [loc]
  /// says: [pullOnlyMessage] with the provider that owns its root.
  String pullOnlyMessageFor(String loc) {
    final rk = _readOnlyRootOf(loc);
    final name = rk == null ? null : _readOnlyRootNames[rk];
    return name == null ? pullOnlyMessage : 'This $name folder is read-only on this device for now.';
  }

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

  /// How many user-action waits [waitingForFolder] counts now (for tests).
  @visibleForTesting
  int get folderWaitersForTest => _folderWaiters;

  // Runs [action] as a user action: its waits for a folder lock count toward
  // [waitingForFolder] (see _lockRun).
  // The marker is live only until the action's future completes: a watcher or
  // timer made inside it inherits the zone, but not a live marker.
  Future<T> _asUser<T>(Future<T> Function() action) {
    final mark = _UserAction();
    return runZoned(action, zoneValues: {_userActionKey: mark}).whenComplete(() {
      mark.active = false;
      // Work started inside the action may still be queued: its counts go.
      _folderWaiters -= mark.counted;
      mark.counted = 0;
      if (_folderWaiters <= 0 && !_disposed) {
        _folderWaiters = 0;
        _waitingForFolder.value = false;
      }
    });
  }

  final Set<Timer> _waitTimers = {};

  // The one wait point: every folder job goes through here. A user action's
  // wait for its turn longer than [folderWaitNote] shows the note.
  //
  // [gate]: in a listed binder folder with a recorded id, the binder file is
  // read first, inside the job's turn (G2): another binder's file holds the
  // folder and refuses the job; an unreadable or missing one refuses only this
  // job; this binder's own file clears a hold (G3). What a hold has to do next
  // starts after the job, outside the lock.
  Future<T> _lockRun<T>(Directory folder, Future<T> Function() job, {bool gate = true}) {
    final run = _lockRunRaw(folder, gate ? () => _gated(folder, job) : job);
    _afterLockJob(run);
    return run;
  }

  // A job that passes no gate: a binder-file job (guarded by its own checks),
  // a read, or a folder not listed yet.
  Future<T> _lockRunUngated<T>(Directory folder, Future<T> Function() job) => _lockRun(folder, job, gate: false);

  // Starts what a hold requested once [run] has completed, in a side branch
  // with its own error handler (the caller still gets [run] as it is).
  void _afterLockJob(Future<Object?> run) {
    unawaited(run.then<void>((_) {}, onError: (Object _) {}).then((_) => _startRequested()).catchError(_logHoldError));
  }

  void _logHoldError(Object e) => debugPrint('Starting the work of a binder hold failed: $e');

  Future<T> _lockRunRaw<T>(Directory folder, Future<T> Function() job) {
    final mark = Zone.current[_userActionKey];
    if (mark is! _UserAction || !mark.active || _disposed) return folderLocks.run(folder, job);
    var counted = false;
    var started = false;
    Timer? timer;
    // The job starts in a later turn, so the timer exists by then. If run
    // throws, no timer was made.
    final result = folderLocks.run(folder, () {
      started = true;
      if (timer != null) {
        _waitTimers.remove(timer);
        timer.cancel();
      }
      if (counted && mark.counted > 0) {
        mark.counted--;
        if (--_folderWaiters == 0 && !_disposed) _waitingForFolder.value = false;
      }
      return job();
    });
    timer = Timer(folderWaitNote, () {
      _waitTimers.remove(timer);
      if (started || _disposed || !mark.active) return;
      counted = true;
      mark.counted++;
      if (++_folderWaiters == 1) _waitingForFolder.value = true;
    });
    _waitTimers.add(timer);
    return result;
  }

  // Held edits --------------------------------------------------------------

  // The listed binder whose folder is [dir], or null.
  BinderSection? _sectionAt(String dir) =>
      dir == _standalone || _binders.isEmpty ? null : _sectionByKey(_key(_normalizePath(dir)));

  BinderSection? _sectionByKey(String key) {
    for (final b in _binders.values) {
      if (_key(_normalizePath(b.path)) == key) return b;
    }
    return null;
  }

  // [job] in its own turn at [folder], after the binder-file check (G2).
  Future<T> _gated<T>(Directory folder, Future<T> Function() job) async {
    final s = _disposed ? null : _sectionAt(folder.path);
    if (s != null) await _gateLocked(s);
    return job();
  }

  // G2, inside a turn at [s]'s folder: reads and parses its binder file. Throws
  // for another binder (and holds the folder) and, without holding it, for a
  // file that isn't there or can't be read now (the watcher decides). This
  // binder's own file clears a hold (G3).
  Future<void> _gateLocked(BinderSection s) async {
    final verdict = await _classifyLocked(s);
    switch (verdict) {
      case BinderVerdict.own:
        return;
      case BinderVerdict.other:
        throw BinderHeldException(_lockedMessage(s.path));
      case BinderVerdict.unreadable:
        throw const _BinderUnreadableNow();
      case BinderVerdict.none:
        return;
    }
  }

  // The binder-file check of a turn at [s]'s folder (G2, and the scan's): own
  // id (a hold is cleared), another id (the folder is held), or unreadable or
  // missing (no hold; the watcher looks soon). [BinderVerdict.none]: nothing
  // to check (no recorded id, a pull-only or away folder).
  Future<BinderVerdict> _classifyLocked(BinderSection s) async {
    final want = _binderIds[_key(s.path)];
    if (want == null || s.missing || _pullOnly(s.path)) return BinderVerdict.none;
    final file = _binderStore(Directory(s.path)).file;
    await syncHook?.call('binder-gate', file.path);
    final r = await _readBinderText(file);
    Binder? b;
    final text = r.text;
    if (text != null) {
      try {
        b = Binder.parse(text);
      } on BinderFormatException {
        b = null;
      }
    }
    if (_disposed) return BinderVerdict.none;
    if (b == null) {
      _recheckLater(s.path);
      return BinderVerdict.unreadable;
    }
    if (b.id != want) {
      _setHold(s, BinderHold.otherBinder, other: b);
      return BinderVerdict.other;
    }
    if (s._hold != null) _clearHold(s);
    return BinderVerdict.own;
  }

  // An empty gated turn at binder folder [loc], for work that writes outside
  // the lock: false when the gate refused it. The caller also checks
  // [_isLocked] right after, with no await between.
  Future<bool> _binderGate(String loc) async {
    if (_sectionAt(loc) == null) return true;
    try {
      await _lockRun(Directory(loc), () async {});
      return true;
    } on NotebookException {
      return false;
    }
  }

  // Whether files may be removed from [loc] now: not a binder folder, or one
  // that passes [_binderGate] and is not held.
  Future<bool> _mayRemoveIn(String loc) async =>
      _sectionAt(loc) == null || (await _binderGate(loc) && !_isLocked(loc));

  // [_binderGate] before moving attachments in or out of binder folder [loc]:
  // a refusal is a [FileSystemException], as the moves' own failures are.
  Future<void> _gateMove(String loc) async {
    if (_sectionAt(loc) == null) return;
    if (!await _binderGate(loc) || _isLocked(loc)) {
      throw FileSystemException(_isLocked(loc) ? _lockedMessage(loc) : binderUnreadableNowMessage, loc);
    }
  }

  // Steps 1 and 2, synchronous (inside a lock or save-chain job): the folder
  // is held, the open cover's typing and the editing box are taken, and the
  // open page turns read-only. Steps 3 and 4 run in [_afterHold].
  void _setHold(BinderSection s, BinderHold h, {Binder? other, String? reason}) {
    s
      .._hold = h
      .._heldOther = h == BinderHold.otherBinder ? other : null
      .._holdReason = reason
      .._landDue = false;
    if (_coverTypingPath == s.path) _takeCoverTyping();
    final c = _current;
    if (c != null && (_loc[c.page.id] ?? _orphanLoc) == s.path) {
      final editing = c.editingId;
      if (editing != null) c.setEditing(editing, false);
    }
    _syncReadOnly();
    if (!_disposed) notifyListeners();
    _requestAfterHold(s.path);
    unawaited(syncHook?.call('binder-hold-set', s.path));
  }

  // G3: this binder's own file was read with a hold set. [_afterHold] lands.
  void _clearHold(BinderSection s) {
    s
      .._hold = null
      .._heldOther = null
      .._holdReason = null
      .._landDue = true;
    _syncReadOnly();
    if (!_disposed) notifyListeners();
    _requestAfterHold(s.path);
  }

  // Folders whose [_afterHold] is to start once the current job ends.
  final Set<String> _holdRequests = {};
  final Map<String, Future<void>> _holdRuns = {};
  final Map<String, Future<void>> _holdLast = {};
  final Set<String> _holdRerun = {};
  static const Object _holdRunKey = #notedAfterHold;

  void _requestAfterHold(String path) {
    if (_disposed) return;
    final key = _key(_normalizePath(path));
    // From [_afterHold]'s own jobs: the run compares the hold at its end.
    final inside = Zone.current[_holdRunKey];
    if (inside is _HoldRun && inside.active && inside.key == key) return;
    _holdRequests.add(key);
  }

  void _startRequested() {
    if (_holdRequests.isEmpty || _disposed) return;
    final keys = [..._holdRequests];
    _holdRequests.clear();
    for (final key in keys) {
      // Outside any user action: its folder-wait note never counts these jobs.
      runZoned(() => _afterHoldStart(key), zoneValues: {_userActionKey: null});
    }
  }

  void _afterHoldStart(String key) {
    if (_disposed) return;
    if (_holdRuns.containsKey(key)) {
      _holdRerun.add(key);
      return;
    }
    final mark = _HoldRun(key);
    final insideChain = _chain.insideJob;
    final run = runZoned(() => _afterHold(key, insideChain), zoneValues: {_holdRunKey: mark});
    _holdRuns[key] = run;
    _holdLast[key] = run;
    unawaited(
      run.whenComplete(() {
        mark.active = false;
        if (identical(_holdRuns[key], run)) _holdRuns.remove(key);
      }),
    );
  }

  /// The running (or last) [_afterHold] of binder folder [path]; completes at
  /// once when none ran.
  @visibleForTesting
  Future<void> afterHoldForTest(String path) async {
    final key = _key(_normalizePath(path));
    while (true) {
      final run = _holdRuns[key] ?? _holdLast[key];
      if (run == null) return;
      await run;
      if (_holdRuns[key] == null) return;
    }
  }

  /// How many times [_reopenBinder] ran (a test seam).
  @visibleForTesting
  int reopenCountForTest = 0;

  // Steps 3 and 4 for a held folder, or L for one whose hold was cleared,
  // outside every lock and save-chain job. One run per folder at a time; a
  // request while it runs gives one rerun, and so does a hold that differs at
  // its end. Never throws: an error is logged and the hold stays as it is.
  //
  // `checkBinderFile` waits for this run from inside a `_checking` job, so no
  // path under it may await a `_checking` job (checkFile, checkFolders,
  // checkBinderFile, a `_queued` add): that would wait on itself.
  Future<void> _afterHold(String key, bool insideChain) async {
    // A request from a save-chain job: that job ends first.
    if (insideChain) await _chain.idle;
    var changeRerun = false;
    while (!_disposed) {
      _holdRerun.remove(key);
      final s = _sectionByKey(key);
      if (s == null) return;
      final start = _holdSig(s);
      try {
        if (s._hold != null) {
          await _heldSteps(s);
        } else if (s._landDue) {
          s._landDue = false;
          await _land(s);
        }
      } on Object catch (e, st) {
        debugPrint('The binder hold of ${s.path} failed: $e\n$st');
      }
      if (_disposed) return;
      final end = _sectionByKey(key);
      if (end == null) return;
      if (_holdRerun.remove(key)) {
        changeRerun = false;
        continue;
      }
      if (_holdSig(end) != start && !changeRerun) {
        changeRerun = true;
        continue;
      }
      return;
    }
  }

  static String _holdSig(BinderSection s) => '${s._hold?.name}/${s._heldOther?.id}/${s._landDue}';

  // Steps 3 and 4: the open page's pending save meets the hold (and goes to
  // recovery), what is still unsaved of it is kept, and the binder's state
  // changes.
  Future<void> _heldSteps(BinderSection first) async {
    final path = first.path;
    await flush();
    var s = _binders[path];
    if (_disposed || s == null || s._hold == null) return; // cleared meanwhile: L takes over
    await _captureHeld(s);
    s = _binders[path];
    if (_disposed || s == null || s._hold == null) return;
    await syncHook?.call('binder-hold-captured', path);
    s = _binders[path];
    if (_disposed || s == null) return;
    switch (s._hold) {
      case BinderHold.otherBinder:
        final other = s._heldOther;
        if (other != null && s.available) await _otherBinder(s, other);
      case BinderHold.damaged:
        if (s.available) await _damageBinder(s, s._holdReason ?? 'unreadable');
      case BinderHold.missing:
        if (s.status != BinderStatus.unavailable) {
          await _disableBinder(s, BinderStatus.unavailable, 'No $binderFileName in this folder.', fileMissing: true);
        }
      case null:
        return;
    }
  }

  // Step 4: the open page of held folder [s], if it has edits not saved, is
  // kept in recovery as its own generation (0137).
  Future<void> _captureHeld(BinderSection s) async {
    final c = _current;
    final session = _session;
    if (c == null || session == null || session.ended || _preview != null) return;
    final loc = _loc[c.page.id] ?? _orphanLoc;
    if (loc == null || loc != s.path) return;
    final pending = _pendingSave != null;
    final b = _base;
    if (!pending && b != null && (identical(b, c.page) || writePage(b) == writePage(c.page))) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    _pendingSave = null;
    await _saveFailed(loc, _storeOrFolder(loc), c.page, session.seq, session);
  }

  // L: the folder holds this binder's file again. The open page is merged and
  // saved, then the closed entries replay (0156), then the page that was open
  // when the file went away opens again.
  Future<void> _land(BinderSection s) async {
    final path = s.path;
    if (!s.available) {
      await _reopenBinder(path);
      return;
    }
    await _afterResume(await _resumeOpenPage(path, force: true));
    await _recoverPending(onlyLoc: path);
    final now = _binders[path];
    if (now != null && now.available) await _returnToPage(now);
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

  // A moved page whose text was never read: published, with no identity.
  void _emitPublishedUnread(String path) {
    if (!_feedLive) return;
    try {
      _changes.add(LocalChange(LocalChangeKind.published, path));
    } on Object {
      // The feed is advisory.
    }
  }

  // Tells the read observer of a page file about to be read; returns [path].
  static String _obs(String path) {
    PageStore.fileReadObserver?.call(path);
    return path;
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
  final Map<String, ({String path, String why, String? line})> _replayProblems = {};

  // Pages whose recovered edits landed and were retired, but whose file was
  // then changed so that it can no longer be read as the page (the edits are
  // in a conflict copy), or brought back a foreign node the entry deleted, by
  // page id. One-off: the entry is gone, so the next pass must not prune it;
  // cleared when the user opens the page. Changes to boxes, positions and the
  // header are put right or become a version conflict instead (0130).
  final Map<String, ({String path, String why})> _landedProblems = {};

  // Entries whose merged page has landed but isn't settled yet (a read that
  // keeps failing, a write that threw), by generation: the text published and
  // the file it was merged against. A retry settles these without merging
  // again. Memory only; cleared with the entry.
  final Map<String, ({String out, NotedPage? theirs})> _landedText = {};

  // Conflict copies a merge consumed, kept as recovery entries until a later
  // read of the page file holds them (_recheckConsumedCopy), by generation.
  // Memory only: after a restart the entry is an ordinary one with no base.
  final Map<String, _ConsumedCopy> _consumedCopies = {};

  // Whether [e] is an edit waiting to land: not landed, and not a consumed
  // copy kept only until its merge is seen to hold.
  bool _waitingEntry(RecoveryStore rec, RecoveryEntry e) =>
      !rec.isLanded(e.gen) && !_consumedCopies.containsKey(e.gen);

  /// Test seam: the generations kept as consumed conflict copies, and whether
  /// each is parked (sync kept putting an older file back).
  @visibleForTesting
  Map<String, bool> get consumedCopiesForTest => {for (final m in _consumedCopies.values) m.gen: m.parked};

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
      UnreadablePage(p.path, p.line ?? "Recovery can't finish: ${p.why}${p.why.endsWith(')') ? '' : '.'}"),
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

  /// Test seam: how many generations hold landed text.
  @visibleForTesting
  int get landedTextCount => _landedText.length;

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
      [for (final e in rec.indexEntries) if (_waitingEntry(rec, e)) e],
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

  /// Makes the store of a binder's file (a seam for tests).
  final BinderStore Function(Directory) binderStoreFactory;

  /// How long after a missing binder file is seen under a set-aside copy (a
  /// replace in progress) it is looked at again.
  final Duration binderRecheckDelay;

  /// How long a set-aside copy of the binder file may stand with no binder file
  /// before it is put back.
  final Duration asideRestoreAfter;

  /// How long after a conflict copy was merged and deleted its kept version
  /// waits in recovery before a read of the page file decides whether it is
  /// held (then the entry goes) or a sync client put an older file back (then
  /// the merge is done again). Timed by [now].
  final Duration copyRetireAfter;

  /// The first wait before a cover change that was refused is tried again; each
  /// failure doubles it, up to a minute.
  final Duration coverRetryFirst;

  BinderStore _binderStore(Directory d) => binderStoreFactory(d);

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
  late final Map<String, String> _known = _TrackedMap((k) {
    _fileStamps.remove(k);
    _baseText.remove(k);
  });
  // The text a moved page's file held when it was moved, for a page whose stamp
  // didn't match (2b): `_known` is dropped so the file is read, and this is
  // what that read is compared with, so the move's own file is no foreign
  // change. Dropped with any change of `_known` at the key.
  final Map<String, String> _baseText = {};
  // Moved files (by path key) whose arrival the change feed hasn't been told of
  // for want of their text: the next read of the file tells it.
  final Map<String, String> _movePublish = {}; // key to path
  // Page id of each page file (by path key).
  late final Map<String, String> _pathId = _TrackedMap(_fileStamps.remove);
  // The file stamp of each page file Noted last classified (by path key): what a
  // check skips by when the file is unchanged (0157, rule P). Any change of the
  // file's `_known` or `_pathId` entry drops it (see [_TrackedMap]); it is set
  // after those, where a scan, a read or Noted's own publish says so.
  final Map<String, FileStamp> _fileStamps = {};
  // The place of a moved root that wasn't downloaded, written when it is next
  // opened (N8). Lost at quit.
  final Map<String, ({String? parentId, int order})> _heldPlacement = {};
  // Pages with a conflicted box (0020).
  final Set<String> _conflicts = {};
  // The exact text last written or read for each binder file (by the key of
  // the binder's folder).
  final Map<String, String> _binderText = {};
  // Cover changes that are not in a binder file yet, by the key of the binder's
  // folder (D3). Outside the section, so they survive damage, unavailability,
  // another binder's file and reopening.
  final Map<String, List<CoverChange>> _coverPending = {};
  // Temporary files of this device's binder updates that stay for the user
  // (the change was refused or its temp couldn't be removed), by folder key.
  final Map<String, List<BinderTemp>> _ownKeptTemps = {};
  // What the open cover has typed and not sent, read synchronously (D2).
  CoverTyping? Function()? _coverTyping;
  String? _coverTypingPath;
  // The wait before a refused cover change is tried again, and its timer.
  final Map<String, Duration> _coverDelay = {};
  final Map<String, Timer> _coverTimers = {};
  // Folders whose cover changes stopped being tried by themselves (keeps changing).
  final Set<String> _coverHalted = {};
  // Rechecks of a missing binder file that stands under an aside.
  final Map<String, Timer> _asideTimers = {};
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
  /// `settings-loaded` once the load has succeeded and settled the hold, before
  /// binders are looked for;
  /// `load-recover` before load replays the recovery store and `load-first-page`
  /// before it opens (or makes) the first page; `settings-adopt` before each open when a retry adopts the list;
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
  // What the running load settles the hold to once it succeeds, and whether it
  // has read the list and opened what it lists. Writes and refusals go by
  // [_settingsHeld]; what only reads the state goes by [_readHold].
  _SettingsHold? _launchHold;
  bool _listSettled = false;
  // A settings save was skipped while the hold was pending (a binder id changed
  // on disk, say); the load makes it when it settles the hold to null.
  bool _saveAfterLoad = false;
  // Note: while the hold is pending, the locked or damaged notice already shows
  // (it reads [_readHold]) but [retrySettings] does nothing. The load ends by
  // arming the retry timer; a failed or stalled load has its own Retry.
  _SettingsHold? get _readHold => _settingsHeld == _SettingsHold.pending && _listSettled ? _launchHold : _settingsHeld;
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

  final StreamController<String> _keptCleared = StreamController<String>.broadcast();

  /// A page whose kept-edits notice no longer holds (its edits landed): the
  /// window takes the notice down.
  Stream<String> get keptNoticesCleared => _keptCleared.stream;

  void _clearKeptNotice(String pageId) {
    if (_told.remove(pageId) && !_keptCleared.isClosed) _keptCleared.add(pageId);
  }

  /// Whether page [id] is held by something (replaying, a save left behind, a
  /// delete, a move, a discard): it is not replayed, deleted or moved now, and
  /// opening it gives the preview.
  bool isBusy(String id) => _busy.containsKey(id);

  /// Asks the platform to download the file at the path (the page file a save
  /// found not downloaded). A no-op until the Apple channel exists (cloud
  /// parity step 5); the save is kept in recovery and tried again meanwhile.
  void Function(String path)? requestDownload;

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
    // An iCloud root that isn't self-tested yet, or whose access is lost (R5.9).
    if (!_mayTouch(loc)) return true;
    if (loc == _standalone) return _defaultGone;
    final f = _folders[loc];
    if (f != null) return !f.available;
    final s = _binders[loc];
    return s == null || !s.available || s._hold != null;
  }

  // Whether binder folder [loc] is held (held edits).
  bool _heldAt(String loc) => _binders[loc]?._hold != null;

  // Whether the recovery entries of binder folder [loc] stay keyed to it: it
  // is held, or its binder file is missing.
  bool _keyedOnlyHere(String loc) {
    final s = _binders[loc];
    return s != null && (s._hold != null || s.fileMissing);
  }

  // Why a page's edits in a folder held for [h] are kept.
  static String _heldReason(BinderHold h) => switch (h) {
    BinderHold.otherBinder => 'its folder now holds another binder',
    BinderHold.damaged => "its binder's file can't be read",
    BinderHold.missing => 'its binder file is missing',
  };

  // What is promised for edits kept in a folder held for [h], in the banner's
  // words; null where there is no such promise.
  static String? _heldPromise(BinderHold h) => switch (h) {
    BinderHold.otherBinder => 'Your changes are kept and are saved in this folder if you choose Use this binder.',
    BinderHold.damaged => 'Your changes are kept until it can be read.',
    BinderHold.missing => null,
  };

  /// The hold of the binder whose folder is [folder] (a recovery entry's
  /// folder), or null.
  BinderHold? holdOfFolder(String folder) => _sectionAt(folder)?._hold;

  /// Whether [e] counts as kept edits: not the entry of a merged conflict copy
  /// kept until its re-check (copy retire).
  bool isKeptEdit(RecoveryEntry e) => !_consumedCopies.containsKey(e.gen);

  /// How many pages have changes kept in recovery for the folder [path].
  int heldPagesFor(String path) {
    final rec = _recovery;
    if (rec == null) return 0;
    final key = _key(path);
    return {
      for (final e in rec.indexEntries)
        if (_key(e.folder) == key && isKeptEdit(e)) e.pageId,
    }.length;
  }

  // The open page's banner in held folder [s].
  String _heldBanner(BinderSection s, String pageId, BinderHold h) {
    final kept = _recovery?.entriesFor(_normalizePath(s.path), pageId).any(isKeptEdit) ?? false;
    if (h == BinderHold.damaged) {
      return kept
          ? "This binder's file can't be read, so this page is read-only. Your unsaved changes are kept until it can be read."
          : "This binder's file can't be read, so this page is read-only.";
    }
    return kept
        ? 'This folder now holds another binder, so this page is read-only. Your unsaved changes are kept and are saved in this folder if you choose Use this binder.'
        : 'This folder now holds another binder, so this page is read-only.';
  }

  String _lockedMessage(String loc) {
    if (_pullOnly(loc)) return pullOnlyMessageFor(loc);
    if (!_mayTouch(loc)) return _untestedMessage(loc);
    final s = _binders[loc];
    // A hold is set before the binder's status changes.
    if (s != null && s._hold == BinderHold.damaged) return "This binder's file can't be read, so its pages are read-only.";
    if (s != null && s._hold != null && (s.other ?? s._heldOther) != null) {
      return 'This folder now holds another binder, so its pages are read-only.';
    }
    if (s != null && s.readOnly) {
      if (s.other != null) return 'This folder now holds another binder, so its pages are read-only.';
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
    await _expireDeleted(last, deadline: now().add(expiryQuitLimit));
    await _retireConsumedOfDeleted(last);
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
        throw NotebookException(_pullOnly(loc) ? pullOnlyMessageFor(loc) : 'That folder is not available.');
      }
      return st;
    }
    // A binder whose file can't be read keeps its store, for reading.
    final st = _binders[loc]?.store;
    if (st == null) {
      throw NotebookException(_pullOnly(loc) ? pullOnlyMessageFor(loc) : 'That binder is not available.');
    }
    return st;
  }

  /// Reads the folders and opens the first standalone page, creating one if
  /// there is none.
  Future<void> load() async {
    try {
      await _load();
      await _strayCheck(); // O: a folder left behind by a move that stopped
    } finally {
      // A load that stopped before the list was read leaves it locked; one
      // that stopped after leaves it pending, until a load succeeds.
      if (_settingsHeld == _SettingsHold.pending && !_listSettled) _settingsHeld = _SettingsHold.locked;
      _listSettled = false;
      if (!_loaded.isCompleted) _loaded.complete();
      _armSettingsTimer();
    }
  }

  /// How long the start-up load may run before the app shows [loadError]. A
  /// phone reads a notebook's page list in well under this; a slower load
  /// is still running behind the message and clears it when it ends.
  static const Duration loadTimeout = Duration(seconds: 30);

  Object? _loadError;
  Future<void>? _loadRun;

  /// Why the start-up load failed or is taking too long; null while it runs
  /// normally or after it succeeded.
  Object? get loadError => _loadError;

  /// Whether a [loadChecked] run is under way (a timed-out one still is).
  bool get loadRunning => _loadRun != null;

  final Completer<void> _loadSucceeded = Completer<void>();

  /// Completes when a [loadChecked] run succeeds, however late (after a
  /// timeout, or a Retry). Never completes with an error.
  Future<void> get loadSucceeded => _loadSucceeded.future;

  bool _firstLoadSucceeded = false;

  /// Whether a [loadChecked] run has succeeded, however late (after a timeout
  /// or a Retry). Set in the same callback that completes [loadSucceeded], then
  /// listeners are told. Not derived from [loaded] or [loadError]: a Retry
  /// clears the error before its load runs, so a hanging Retry has neither.
  bool get firstLoadSucceeded => _firstLoadSucceeded;

  /// [load] for the app's start and its Retry: a failure, or a load still
  /// running after [timeout], sets [loadError] (and notifies) instead of
  /// throwing. A load still running is never started twice: a call then waits
  /// for it again and leaves [loadError] as it is.
  ///
  /// While [loadError] is set or a run is under way, the retry of a held
  /// binder list does nothing (see [retrySettings]): it would run beside the
  /// load, or open a page behind the error screen. A new run first stops that
  /// retry and starts from a list not yet read, as the first load did.
  Future<void> loadChecked({Duration timeout = loadTimeout}) async {
    var run = _loadRun;
    if (run == null) {
      if (_loadError != null) {
        _loadError = null;
        _notifyLoad();
      }
      run = _loadRun = _startLoad().whenComplete(() => _loadRun = null);
      run.then<void>(
        (_) {
          if (!_loadSucceeded.isCompleted) _loadSucceeded.complete();
          final first = !_firstLoadSucceeded;
          _firstLoadSucceeded = true;
          if (_loadError == null) {
            if (first) _notifyLoad();
            return;
          }
          _loadError = null;
          _notifyLoad();

        },
        onError: (Object e) {
          _loadError = e;
          _settingsHeld ??= _SettingsHold.pending; // no settings write until a load succeeds
          _notifyLoad();
        },
      );
    }
    try {
      await run.timeout(timeout);
    } on TimeoutException {
      _loadError ??= NotebookException('Loading took more than ${timeout.inSeconds} seconds.');
      _notifyLoad();
    } on Object {
      // Recorded by the handler above.
    }
  }

  Future<void> _startLoad() async {
    _settingsTimer?.cancel();
    _settingsTimer = null;
    final running = _retrying;
    if (running != null) await running;
    // Unconditionally: a load that failed after the list was settled leaves no
    // hold, and the lists are cleared again below; nothing may be written from
    // them until a load succeeds.
    _settingsHeld = _SettingsHold.pending;
    _settingsDelay = null;
    // Folder access first (R5.3, R5.9): bookmarks resolved, iCloud roots
    // registered and self-tested before anything is read from or written to
    // them. A failure there never stops the load.
    try {
      await icloud?.start();
    } on Object catch (e) {
      debugPrint('Starting the folder access failed: $e');
    }
    // Held, so no new found-add pass starts; one under way ends before the lists
    // are cleared.
    await discoveryIdle;
    await load();
  }

  void _notifyLoad() {
    if (!_disposed) notifyListeners();
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
    _realKeys.clear();
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
    // The list is read, but nothing may be written from it until the whole
    // load has succeeded (the merges, recovery and the first page included):
    // the hold stays pending, and what the load will settle it to is kept for
    // what only reads it (see [_readHold]).
    _launchHold = launchHold;
    _listSettled = true;
    _rebuildTree();
    _syncWatchers();
    _startFolderTimer();
    await _mergePendingCopies();
    await _binderSeam('load-recover', settingsFile?.path ?? '');
    await _recoverPending();
    await _binderSeam('load-first-page', settingsFile?.path ?? '');
    if (_tree.roots.isEmpty) {
      await _createFallbackPage();
    } else {
      // The first page shown at start is not the user looking at a notice.
      final notices = {..._landedProblems};
      await open(_tree.roots.first.id);
      _landedProblems.addAll(notices);
    }
    // The load has succeeded: the list is trusted (or refused) only now.
    _settingsHeld = _launchHold;
    final redo = _saveAfterLoad && _launchHold == null;
    _saveAfterLoad = false;
    if (redo) await _saveSettings();
    _listSettled = false;
    await _binderSeam('settings-loaded', settingsFile?.path ?? '');
    // The hold lifted and both files read: unused folder access is pruned (R5.3).
    if (icloud != null && _settingsHeld == null) _cloudWork = _cloudWork.then((_) => _pruneCloudAccess());
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
      // The id this device recorded for the folder is the one expected there (I).
      final id = a.recorded.entries.where((e) => _key(e.key) == _key(path)).firstOrNull?.value;
      final section = await _openBinder(path, expectId: id);
      if (_disposed) return;
      _binders[path] = section;
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
      if (_disposed || _settingsHeld == null || _loadError != null || _loadRun != null) return false;
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
    } on StorageBusy {
      // The folder is busy: no new list is written another way (C2).
      await dropTemp();
      _absentSince = null;
      _settingsHeld = _SettingsHold.locked;
      _heldDetail = 'Starting a new list failed: the folder is busy. Try again.';
      notifyListeners();
      return null;
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
    final held = _readHold;
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
        _heldPlacement.remove(id);
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

  // Sets or drops the stamp of the file at [key] (see [_fileStamps]); after the
  // `_known` and `_pathId` entries it describes are set.
  void _recordStamp(String key, FileStamp? stamp) {
    if (stamp == null) {
      _fileStamps.remove(key);
    } else {
      _fileStamps[key] = stamp;
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
      _recordStamp(_key(e.path), e.stamp);
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
      PageStore.fileReadObserver?.call(path);
      text = await File(path).readAsString();
      page = readPage(text);
    } on Object {
      return; // the usual checks report it
    }
    if (page.id != id) return;
    // A sync client's conflict copy of a listed page is merged the usual way.
    if (await PageStore.findConflictOriginal(path, page, preferred: _adoptedFiles[page.id]) != null) return;
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
          File(_obs(path)).readAsStringSync() == text;
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
    await _applyHeldPlacement(id);
    try {
      await _open(id);
    } on LeaveCancelled {
      return; // the user chose to stay on this page
    }
    // Only once the page is open: a failed open leaves the notice for the next
    // look.
    if (_landedProblems.remove(id) != null) notifyListeners();
  }

  // N8: the place a moved root was given while it wasn't downloaded, written
  // now that it is opened. A failure only logs; the page opens where it is.
  Future<void> _applyHeldPlacement(String id) async {
    final held = _heldPlacement.remove(id);
    final loc = _loc[id];
    if (held == null || loc == null || id == currentId) return;
    try {
      final next = await _updateClosedPage(
        loc,
        id,
        (page) => page.withMeta(page.meta.withPlacement(parentId: held.parentId, order: held.order)),
      );
      if (next != null) {
        _metas[id] = next.meta;
        _rebuildTree();
      }
    } on Object catch (e) {
      debugPrint('Placing page $id when it was opened failed: $e');
    }
  }

  Future<void> _open(String id) async {
    if (_coverPath != null) {
      _coverPath = null;
      notifyListeners();
    }
    if (id == currentId) return;
    // A page of a binder whose folder is away can't be read.
    if (_binders[_loc[id]]?.missing ?? false) {
      throw NotebookException(isPullOnlyPage(id) ? pullOnlyMessageFor(_loc[id]!) : 'That binder is not available.');
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
    // Read at each use: a binder folder can be held after the store is made.
    readOnlyNow: () => _isLocked(loc),
    mutate: _sectionAt(loc) == null ? null : <T>(Future<T> Function() job) => _lockRun(Directory(loc), job),
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
  ///
  /// This is what AI may do: while a binder setting is queued and not written,
  /// the stricter of the saved and the shown value counts (N4).
  EffectiveAiAccess aiAccessFor(String id) => effectiveAiAccess(_metaChain(id), binder: _aiBinderOf(id));

  /// As [aiAccessFor], but for the screen: a queued binder setting counts as
  /// if it were saved.
  EffectiveAiAccess shownAiAccessFor(String id) => effectiveAiAccess(_metaChain(id), binder: _binderOf(id));

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
      _readHold == null &&
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
    NotedPage? read;
    final next = await _updateClosedPage(loc, id, (page) {
      final meta = page.meta.withAiAccess(value);
      if (identical(meta, page.meta)) return null;
      read = page;
      return page.withMeta(meta);
    });
    if (next == null) return;
    // The user's choice, once written: a redo of a consumed copy keeps it.
    _noteOwnEdits(id, read, next);
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  // Binder writes (R-2) -----------------------------------------------------------
  //
  // A change to a binder file is a delta, reapplied to the file as it is on disk
  // (BinderStore.update) under the folder's lock, on the save chain (L1). The
  // screen shows the file's last known content with the queued changes on top;
  // what AI may do never loosens because of a change that isn't written.

  // Recomputes what the screen shows for [s]: what the file held when it was
  // last read or written, with the queued settings, then the cover changes of
  // the binder shown here. Another binder's cover changes are never folded in.
  void _recompute(BinderSection s) {
    final saved = s.saved;
    if (saved == null) return;
    var b = saved;
    for (final c in s.pending) {
      b = c.delta.apply(b);
    }
    for (final c in _coverPending[_key(s.path)] ?? const <CoverChange>[]) {
      if (c.forId == saved.id) b = c.delta.apply(b);
    }
    s.binder = b;
  }

  // The binder AI works from: the screen's, but while settings are queued each
  // value is the stricter of what is saved and what the screen shows.
  Binder? _aiBinderFor(BinderSection s) {
    var b = s.binder;
    final saved = s.saved;
    if (b == null || saved == null || s.pending.isEmpty) return b;
    if ((saved.aiAccess ?? defaultAiAccess).strictness > (b.aiAccess ?? defaultAiAccess).strictness) {
      b = b.withAiAccess(saved.aiAccess);
    }
    for (final e in saved.boxTypeChoices.entries) {
      if (e.value == false && b!.boxTypeChoice(e.key) != false) b = b.withBoxType(e.key, false);
    }
    return b;
  }

  Binder? _aiBinderOf(String id) {
    final s = _binders[_loc[id] ?? _standalone];
    return s == null ? null : _aiBinderFor(s);
  }

  Future<void> _queueSetting(
    BinderSection s,
    String what,
    Binder Function(Binder) apply, {
    BinderField? field,
  }) async {
    final delta = BinderDelta(
      binderId: _binderIds[_key(s.path)] ?? s.saved?.id,
      apply: apply,
      kind: BinderDeltaKind.setting,
      field: field,
    );
    final change = BinderSetting(delta, what);
    s.pending.add(change);
    _recompute(s);
    notifyListeners();
    await _afterSaves(() => _landSetting(s, change), what: 'binder $what of ${s.path}').catchError((Object e) {
      debugPrint('Saving binder ${s.path} failed: $e');
    });
  }

  // Reports a binder file this notebook wrote (its text is what the watcher
  // compares with). Inside the folder's lock, right after the write.
  void _written(BinderStore store, BinderUpdated r) {
    _binderText[_key(store.directory.path)] = r.written;
    if (r.wrote) _emitPublished(store.file.path, null, () => r.written);
  }

  // Removes the temps of [d] (T), keeping those that must stay in the list.
  // Returns the paths a delete kept a copy under (a newer file took the temp's
  // path); the caller lists the folder's copies again when there are any.
  Future<List<String>> _removeTemps(BinderStore store, String key, BinderDelta d) async {
    final before = [for (final t in d.temps) t.path];
    final keptPaths = <String>[];
    final stayed = await store.removeTemps(d, currentId: () => _binderIds[key], kept: keptPaths);
    final left = {for (final t in stayed) t.path};
    final kept = _ownKeptTemps[key];
    if (kept != null) {
      // A temp that was published as the binder file, or removed, is no longer kept.
      kept.removeWhere((t) => (before.contains(t.path) && !left.contains(t.path)) || !File(t.path).existsSync());
      if (kept.isEmpty) _ownKeptTemps.remove(key);
    }
    _keepTemps(key, stayed);
    return keptPaths;
  }

  // Lists [temps] as kept copies of the binder file (P).
  void _keepTemps(String key, Iterable<BinderTemp> temps) {
    final list = _ownKeptTemps.putIfAbsent(key, () => []);
    for (final t in temps) {
      if (!list.any((k) => k.path == t.path)) list.add(t);
    }
    if (list.isEmpty) _ownKeptTemps.remove(key);
  }

  // Writes one queued setting (N2, N3). Runs on the save chain.
  Future<void> _landSetting(BinderSection s, BinderSetting c) async {
    final path = s.path;
    final dir = Directory(path);
    final key = _key(path);
    final store = _binderStore(dir);
    var reconcile = false;
    await _lockRunUngated(dir, () async {
      String? why;
      BinderUpdated? done;
      var kept = const <String>[];
      // U0: nothing in here awaits the save chain, a flush, or a state change.
      if (_disposed || !identical(_binders[path], s) || !s.available || _isLocked(path) || !s.pending.contains(c)) {
        why = 'The binder changed before it could be written.';
      } else {
        final r = await store.update(c.delta);
        kept = r.kept;
        switch (r) {
          case BinderUpdated():
            done = r;
          case BinderRefused(:final reason):
            why = reason.endsWith('.') ? reason : '$reason.';
            reconcile = true;
        }
      }
      if (_disposed) return;
      if (done != null) {
        _written(store, done);
        if (identical(_binders[path], s) && s.available) {
          // One synchronous step: the change leaves the queue as the saved copy
          // takes its result.
          s.saved = done.binder;
          s.pending.remove(c);
          if (done.wrote) s.lastEdited = now();
          _recompute(s);
          notifyListeners();
          _noteStricter(s, c.delta, done.binder);
        } else {
          reconcile = true;
        }
      } else {
        _dropSetting(s, c);
        _notices.add("Binder ${s.title}: the change wasn't saved. $why");
        reconcile = true;
      }
      kept = [...kept, ...await _removeTemps(store, key, c.delta)];
      if (kept.isNotEmpty || s.copies.isNotEmpty) await _listCopiesLocked(s, store);
    });
    if (reconcile && !_disposed) unawaited(checkBinderFile(store.file.path, force: true));
  }

  // A queued setting leaves without being written (refused or skipped): the
  // screen goes back to what is saved at once, and the next queued change on
  // the same field is rebased (U3).
  void _dropSetting(BinderSection s, BinderSetting c) {
    final i = s.pending.indexOf(c);
    if (i < 0) return;
    s.pending.removeAt(i);
    final field = c.delta.field;
    for (var j = i; j < s.pending.length; j++) {
      final next = s.pending[j];
      final nf = next.delta.field;
      BinderField? rebased;
      if (field is BinderAiField && nf is BinderAiField && nf.base == field.request) {
        rebased = BinderAiField(base: field.base, request: nf.request);
      } else if (field is BinderBoxTypeField &&
          nf is BinderBoxTypeField &&
          nf.typeId == field.typeId &&
          nf.base == field.request) {
        rebased = BinderBoxTypeField(nf.typeId, base: field.base, request: nf.request);
      }
      if (rebased != null) {
        next.delta = BinderDelta(
          binderId: next.delta.binderId,
          apply: next.delta.apply,
          kind: next.delta.kind,
          field: rebased,
          temps: next.delta.temps,
        );
        break;
      }
    }
    _recompute(s);
    notifyListeners();
  }

  // A landed AI change whose value is not the one asked for: a stricter value
  // was found on disk and kept.
  void _noteStricter(BinderSection s, BinderDelta d, Binder result) {
    switch (d.field) {
      case BinderAiField(:final request):
        if (result.aiAccess != request) {
          _notices.add(
            'Binder ${s.title}: AI access stays ${(result.aiAccess ?? defaultAiAccess).label}; '
            'it was made stricter on another device or outside Noted.',
          );
        }
      case BinderBoxTypeField(:final typeId, :final request):
        if (result.boxTypeChoice(typeId) != request) {
          _notices.add(
            'Binder ${s.title}: the "$typeId" box type stays not allowed; '
            'it was made stricter on another device or outside Noted.',
          );
        }
      case null:
        break;
    }
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
    await _queueSetting(
      s,
      'AI access',
      (x) => x.withAiAccess(value),
      field: BinderAiField(base: b.aiAccess, request: value),
    );
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
    await _queueSetting(
      s,
      'allowed box types',
      (x) => x.withBoxType(typeId, allowed),
      field: BinderBoxTypeField(typeId, base: b.boxTypeChoice(typeId), request: allowed),
    );
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
    await _queueSetting(s, 'images and files', (x) => x.withAttachmentStorage(value));
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
  Future<void> _copyDirNotify(
    Directory from,
    Directory to,
    String targetPlace,
    String sourcePlace, {
    bool sweepSource = true,
    String? sourceLoc,
  }) async {
    final copy = AttachmentCopy();
    try {
      // A pull-only source is only read: its leftovers are not swept (G15).
      // Nor is a page folder [sourceLoc] that can't be written now (a held
      // binder folder).
      final sweep = sweepSource && !_pullOnly(from.path) && (sourceLoc == null || !_isLocked(sourceLoc));
      await _copyDir(from, to, into: copy, sweepSource: sweep);
    } finally {
      _postCopyNotices(copy, targetPlace, sourcePlace);
    }
  }

  /// Moves [from] to [to] by rename (2c's rule, H), never copying and deleting.
  ///
  /// It fails ([_IncompleteAttachments], carrying what was done) on every
  /// incomplete move: a destination file that differs or is still changing, or,
  /// with [fromTrash] (a set-aside folder being put back, where nothing should
  /// stay), files that were left behind. Where the answer is `cannotRename`, a
  /// set-aside throws [_CannotRename] with nothing moved, and a put-back copies,
  /// keeps the source and throws [_IncompleteAttachments] (leftover). A complete
  /// move returns what it did. The notices ([damagedKept], [stillChanging])
  /// are for the caller to post.
  Future<AttachmentCopy> _moveDir(Directory from, Directory to, {required bool fromTrash}) async {
    final copy = AttachmentCopy();
    if (!await from.exists()) return copy;
    var cannotRename = fromTrash ? forcePutBackCannotRenameForTest : forceCopyMoveForTest;
    // The folder a rename lands in is made only where a rename is tried; the
    // copy of a put-back makes its own.
    // A refused coordination (N4, C2) is "busy; try again": nothing is made, and
    // the copy below never runs on it.
    try {
      if (!cannotRename || fromTrash) await createFolderCoordinated(to.parent);
    } on StorageBusy {
      throw _FolderBusy(to.parent.path);
    }
    if (!cannotRename) {
      // One volume: the folder is renamed, or moved file by file (2c's rule,
      // H), under both lock folders (L) or the one lock when they are the
      // same. Nothing is copied or deleted.
      final hydrated = await _hydrateFolder(from, to.path);
      await syncHook?.call('move-dir-before-lock', from.path); // between the caller's gate and the turn
      final damaged = <DamagedKept>[];
      try {
        final r = await _underPair(
          _lockDirOfAssets(from),
          _lockDirOfAssets(to),
          () => _moveFolder(from, to, kept: damaged, hydrated: hydrated, stopOnCannot: true),
        ); // gated in the turn (0184): a hold planted since the caller's `_gateMove` refuses
        copy.damagedKept.addAll(damaged);
        if (r.outcome == MoveOutcome.cannotRename) {
          cannotRename = true;
          if (!fromTrash) {
            // The caller sets the folder aside in place: the folder made for the
            // rename goes again (never recursively; another page's may be in it).
            await _pruneEmptyFolder(to.parent);
          }
        } else {
          var leftover = false;
          for (final l in r.left) {
            final target = '${to.path}${l.substring(from.path.length)}';
            if (FileSystemEntity.typeSync(target, followLinks: false) == FileSystemEntityType.notFound) {
              leftover = true;
            } else {
              copy.differing.add(l);
            }
          }
          if (copy.differing.isNotEmpty) throw _IncompleteAttachments(copy, false, to.path);
          if (leftover) throw _IncompleteAttachments(copy, true, to.path); // a set-aside too: the notice says what stayed
          return copy;
        }
      } on _LockTimeout catch (e) {
        if (!fromTrash) {
          await _pruneEmptyFolder(to.parent); // nothing moved: no empty folder stays
        }
        throw _FolderBusy(e.path);
      } on _BinderUnreadableNow catch (e) {
        if (!fromTrash) await _pruneEmptyFolder(to.parent);
        throw _GateRefused(e.message, from.parent.path);
      } on BinderHeldException catch (e) {
        if (!fromTrash) await _pruneEmptyFolder(to.parent);
        throw _GateRefused(e.message, from.parent.path);
      }
    }
    // Another drive or cloud. A set-aside is not copied: the caller sets the
    // folder aside in place. A put-back (Undo, the delete rollback, the
    // recovery hand-off) copies and keeps the folder it copied from, which the
    // caller keeps (`keepTrash`) and reports. Nothing is deleted.
    if (!fromTrash) throw _CannotRename(from.path);
    try {
      await _copyDir(from, to, into: copy);
    } on FileSystemException catch (e) {
      // Carries what was done so far (a file set aside stays reported).
      throw _IncompleteAttachments(copy, false, to.path, cause: e);
    }
    throw _IncompleteAttachments(
      copy,
      true,
      to.path,
      cause: FileSystemException(
        'the folders are on different drives, so the files were copied and the originals were kept',
        from.path,
      ),
    );
  }

  // The folder whose lock covers an attachments folder (L): the recovery
  // folder or `deleted-attachments` when it is in one, otherwise the page
  // folder that holds it.
  Directory _lockDirOfAssets(Directory d) {
    final k = _key(d.path);
    bool within(String root) => k.startsWith(_key(root).endsWith('/') ? _key(root) : '${_key(root)}/');
    if (within(_deletedAssetsDir.path)) return _deletedAssetsDir;
    final rec = _recovery;
    if (rec != null && within(rec.directory.path)) return rec.directory;
    return d.parent;
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

  /// Makes a move skip the rename, as a move across drives does: a page move
  /// copies and keeps the originals, and a delete's set-aside (via [_moveDir])
  /// answers `cannotRename`, so the folder is set aside in place.
  @visibleForTesting
  static bool forceCopyMoveForTest = false;

  /// Makes a put-back from a set-aside (Undo, the delete rollback, the recovery
  /// hand-off) answer `cannotRename`, as if the two folders were on different
  /// drives: it copies, keeps the set-aside folder and reports.
  @visibleForTesting
  static bool forcePutBackCannotRenameForTest = false;

  /// Pages whose rename answers "another drive or cloud" (`cannotRename`) in a
  /// move, as if their folders were on different volumes.
  @visibleForTesting
  static Set<String> cannotRenamePagesForTest = {};

  /// Files that read as placeholders (not downloaded), marked by their stamp so
  /// a mark follows the file across a rename. A seam: there is no placeholder
  /// provider in tests.
  @visibleForTesting
  static Set<FileStamp> placeholderMarksForTest = {};

  /// Marked files that can't be downloaded: reading one fails, and its mark
  /// stays. Reading any other marked file clears its mark (it hydrated).
  @visibleForTesting
  static Set<FileStamp> unhydratableForTest = {};

  /// Replaces `syncRootOf` (H): which sync root a path is in.
  @visibleForTesting
  static SyncRoot? Function(String path)? syncRootOfForTest;

  // Whether [path] is a cloud placeholder (H). The seam's marks count first.
  static bool _isPlaceholder(String path) {
    if (placeholderMarksForTest.isNotEmpty) {
      final s = fileStamp(path);
      if (s != null && placeholderMarksForTest.contains(s)) return true;
    }
    return placeholderState(path) == PlaceholderState.placeholder;
  }

  // Whether [a] and [b] are in one sync root (H): a placeholder moves by
  // rename only then. Anything not known to be one root is not one.
  static bool _sameSyncRoot(String a, String b) {
    final of = syncRootOfForTest ?? syncRootOf;
    final ra = of(a), rb = of(b);
    return ra != null && ra == rb;
  }

  // Downloads the placeholder at [path] by reading it. True when it is no
  // longer one.
  static Future<bool> _hydrate(String path) async {
    try {
      final s = fileStamp(path);
      if (s != null && unhydratableForTest.contains(s)) return false;
      await File(path).openRead().drain<void>();
      if (placeholderMarksForTest.isNotEmpty && s != null) placeholderMarksForTest.remove(s);
    } on FileSystemException {
      return false;
    }
    return !_isPlaceholder(path);
  }

  // Attachments of [dir] that are placeholders, hydrated by reading before the
  // move's locks, when [other] is not in the same sync root (H). Returns the
  // files that were tried: under the lock, one that is still a placeholder
  // stays where it is. Nothing is read within one root.
  static Future<Set<String>> _hydrateFolder(Directory dir, String other) async {
    final tried = <String>{};
    if (!dir.existsSync() || _sameSyncRoot(dir.path, other)) return tried;
    final List<FileSystemEntity> all;
    try {
      all = dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      return tried;
    }
    for (final e in all) {
      if (e is! File || !_isPlaceholder(e.path)) continue;
      tried.add(e.path);
      await _hydrate(e.path);
    }
    return tried;
  }

  // The paths of the files in [dir], for a coordinated folder move (they are
  // checked with it), or none when the folder isn't under a registered root.
  static List<String> _alsoMovedFor(Directory dir) {
    try {
      if (!underCoordination([dir.path])) return const [];
      return [
        for (final e in dir.listSync(recursive: true, followLinks: false))
          if (e is File) e.path,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  @visibleForTesting
  static Future<void> removeDirForTest(Directory d) => _removeDir(d);

  static Future<void> _removeDir(Directory d) async {
    try {
      if (await d.exists()) await removeFolderCoordinated(d, recursive: true);
    } on StorageBusy catch (e) {
      // Left; the next clean-up tries again.
      debugPrint('The folder is busy; not removing ${d.path}: $e');
    } on FileSystemException catch (e) {
      debugPrint('Removing ${d.path} failed: $e');
    }
  }

  // The notebook is the one that sets the open controller's disallowed box
  // types, so no change site (the page's header, a parent's, the binder file, a
  // move to another binder, a module switched on or off) can be missed, and the
  // set is current with no canvas mounted. Run at every notify and whenever a
  // controller is created.
  void _syncDisallowed() {
    final c = _current;
    if (c == null) return;
    final off = disallowedBoxTypesFor(c.page.id);
    if (!setEquals(c.disallowedTypes, off)) c.disallowedTypes = off;
  }

  @override
  void notifyListeners() {
    _syncDisallowed();
    super.notifyListeners();
  }

  // Makes the open page read-only if its location can't be written, and
  // writable again when it can.
  void _syncReadOnly() {
    _syncDisallowed();
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
            ? pullOnlyMessageFor(_orphanLoc!)
            : "This page's folder isn't available, so it is read-only.";
      } else if (_pullOnly(loc)) {
        why = pullOnlyMessageFor(loc);
      } else if (_binders[loc]?._hold case final h? when h != BinderHold.missing) {
        why = _heldBanner(_binders[loc]!, c.page.id, h);
      } else if (_isLocked(loc)) {
        why = _binders[loc]?.readOnly ?? false
            ? (_binders[loc]?.other != null
                  ? 'This folder now holds another binder, so this page is read-only.'
                  : "This binder's file can't be read, so this page is read-only.")
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
  /// While one createPage is pending for the same place, any concurrent call is
  /// not queued: it joins the pending one and returns its result, so there is
  /// one page.
  Future<String> createPage({
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) {
    final key = '$parentId|$binderPath|$folderPath';
    final pending = _pendingCreates[key];
    if (pending != null) {
      // The page is opened by the pending call; only the title focus is ours.
      return focusTitle ? pending.then((id) {
        requestTitleFocus(id);
        return id;
      }) : pending;
    }
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
      final kept = rec != null && ids.any((p) => rec.entriesOfPage(p).any((e) => _waitingEntry(rec, e)));
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
    if (!asked && rec != null && ids.any((p) => rec.entriesOfPage(p).any((e) => _waitingEntry(rec, e)))) {
      if (!await _ask(UserQuestion.deleteKept, _titleOrUntitled(pageTitleOf(ids.first) ?? ''))) {
        throw const LeaveCancelled();
      }
    }
    // The text each page was read with: the file is deleted only while it still
    // holds exactly that (a version a sync client landed since is kept).
    //
    // Standalone folders share one tree, so a subpage may be stored in another
    // folder than its root: each page is read, set aside and deleted in its own.
    final locs = [for (final p in ids) _loc[p] ?? loc];
    final stores = [for (final l in locs) l == loc ? st : _storeOf(l)];
    String locOf(String p) => locs[ids.indexOf(p)];
    PageStore stOf(String p) => stores[ids.indexOf(p)];
    final texts = [for (var i = 0; i < ids.length; i++) await stores[i].readText(ids[i])];
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
    final records = <String, _AsideRecord>{};
    final trash = Directory('${_deletedAssetsDir.path}${Platform.pathSeparator}${newId()}');
    for (var i = 0; i < ids.length; i++) {
      final p = ids[i];
      final pLoc = locs[i];
      final dir = _assetsDir(pLoc, p);
      if (!await dir.exists()) continue;
      final title = pages[i].meta.title;
      final seen = _asideIdentities(dir);
      _AsideRecord record(Directory at, {required bool inPlace}) =>
          records[p] = _AsideRecord(pageId: p, title: title, loc: pLoc, dir: at, inPlace: inPlace, identities: seen.identities);
      // Not renamed: the folder stays as `<id>.assets`, with no record, so
      // nothing ever removes files from it.
      void notSetAside() {
        if (_notices.isClosed) return;
        _notices.add(
          'The images and files of "${_titleOrUntitled(title)}" could not be set aside, so they stay in the page\'s folder.',
        );
      }

      var inPlace = seen.placeholders; // not downloaded files: never moved out, never read
      if (!inPlace) {
        final to = Directory('${trash.path}${Platform.pathSeparator}${assetsFolderName(p)}');
        try {
          await _gateMove(pLoc);
          _postCopyNotices(await _moveDir(dir, to, fromTrash: false), 'the folder of deleted pages', 'the page');
          stash[p] = to;
          record(to, inPlace: false);
        } on _CannotRename {
          inPlace = true; // another drive or cloud: renamed beside the page instead
        } on FileSystemException catch (e) {
          debugPrint('Setting aside ${dir.path} failed: $e');
          if (e is _IncompleteAttachments) _postIncomplete(e, 'the folder of deleted pages', 'the page');
          // Whatever was moved is what Undo restores; files that stayed in the
          // page folder stay there.
          if (await to.exists()) {
            stash[p] = to;
            record(to, inPlace: false);
          } else if (e is! _IncompleteAttachments) {
            notSetAside(); // refused (the gate, a busy folder): nothing moved
          }
        }
      }
      if (inPlace) {
        try {
          await _gateMove(pLoc);
          final aside = await _setAsideInPlace(dir);
          if (aside == null) {
            notSetAside();
          } else {
            stash[p] = aside;
            record(aside, inPlace: true);
          }
        } on FileSystemException catch (e) {
          debugPrint('Setting aside ${dir.path} in place failed: $e');
          notSetAside(); // the gate refused, or the folder was busy: nothing moved
        }
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
        final r = await _deleteIfUnchanged(locs[i], p, texts[i]);
        if (!r.deleted && r.outcome != DeleteOutcome.absent) {
          keptIds.add(p);
          continue;
        }
        if (r.deleted) deletedNow.add(i);
        _landedProblems.remove(p); // the user deleted it
        _metas.remove(p);
        _heldPlacement.remove(p);
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
          final back = await stores[i].readText(ids[i]);
          var onTop = false;
          if (back != texts[i]) {
            final now = published ? _tryRead(back) : null;
            if (now == null || now.id != ids[i]) return;
            onTop = true;
          }
          await dropOurs(i);
          if (onTop) await _checkFile(stores[i].pathFor(ids[i]));
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
          final k = await _keepRollbackCopy(stores[i], pages[i], null);
          if (k.gen != null) (ours[i] ??= []).add(k.gen!);
          if (k.durable) durable.add(i);
          refreshRisk();
        }
        for (final i in deletedNow) {
          try {
            if (await _restoreText(locs[i], pages[i], texts[i])) {
              _metas[ids[i]] = pages[i].meta;
              _loc[ids[i]] = locs[i];
              safe.add(i);
              refreshRisk();
              await settle(i, published: true);
            } else {
              // A file appeared at its path meanwhile. Unless it holds exactly
              // the deleted version, that version is not in the folder: it is
              // published beside the file as a copy, never over it (0053).
              String? there;
              try {
                there = await stores[i].readText(ids[i]);
              } on Object {
                there = null;
              }
              if (there != texts[i]) {
                inFile.add(i);
                final copy = await _publishConflictCopy(stores[i], pages[i]);
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
                await _checkFile(stores[i].pathFor(ids[i])); // read as any change
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
          await _gateMove(locs[i]);
          _postCopyNotices(
            await _moveDir(dir, _assetsDir(locs[i], ids[i]), fromTrash: true),
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
            final k = await _keepRollbackCopy(stores[i], pages[i], ours[i]?.last);
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
            records: records,
            locations: {for (final i in only) ids[i]: locs[i]},
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
          await syncHook?.call('delete-rollback-check', stOf(p).pathFor(p));
          await _checkFile(stOf(p).pathFor(p));
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
          await _gateMove(locOf(p));
          _postCopyNotices(
            await _moveDir(dir, _assetsDir(locOf(p), p), fromTrash: true),
            'the page',
            'the folder of deleted pages',
          );
        } on FileSystemException catch (e) {
          debugPrint('Putting back the attachments of page $p failed: $e');
          _postKept(e, dir, 'the page', 'the folder of deleted pages');
          keepTrash.add(dir.path); // what is left there is never cleaned up with the trash
        }
      }
      await _checkFile(stOf(p).pathFor(p));
    }
    // What the user chose to delete with the pages goes once they are gone,
    // by exact generation. A page kept because it changed keeps its entries.
    for (final s in {...stores}) {
      await _dropKeptEntries([for (var i = 0; i < ids.length; i++) if (identical(stores[i], s) && !keptIds.contains(ids[i])) ids[i]], s);
    }
    final deleted = DeletedPages._(
      [for (var i = 0; i < ids.length; i++) if (!keptIds.contains(ids[i])) pages[i]],
      openId,
      loc,
      stash,
      keepTrash: keepTrash,
      records: records,
      locations: {for (var i = 0; i < ids.length; i++) ids[i]: locs[i]},
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
        if (victim != null) {
          // Landed text belongs to one generation. It moves only to an exact
          // copy (a fresh slot with the same page and base); a combined
          // generation merges again on replay (0156).
          final landed = _landedText[victim.gen];
          final mark = _consumedCopies[victim.gen];
          if ((landed != null || mark != null) && identical(victim, k.old) && !k.preexisting) {
            final copy = rec.indexEntries.where((x) => x.gen == k.freshGen).firstOrNull;
            if (copy != null && copy.pageText == victim.pageText && copy.baseText == victim.baseText) {
              if (landed != null) _landedText[k.freshGen] = landed;
              // A consumed copy's mark moves with its exact copy; a combined
              // generation is replayed as after a restart.
              if (mark != null) {
                _consumedCopies.remove(victim.gen);
                mark.gen = k.freshGen;
                _consumedCopies[k.freshGen] = mark;
              }
            }
          }
          _landedText.remove(victim.gen);
          _dropConsumed(victim.gen);
          await _deleteEntry(rec, victim);
        }
      } on Object catch (e) {
        debugPrint('Settling the kept changes of page ${k.id} failed: $e');
      }
    }
    keys.clear();
  }
  // Deletes the recovery entries of [pageIds] in the folder of [st], by exact
  // generation (the pages are deleted). A consumed copy's entry stays: Undo
  // may bring the page back, and its re-check decides once the delete is let
  // go (_recheckConsumedCopy).
  Future<void> _dropKeptEntries(List<String> pageIds, PageStore st) async {
    final rec = _recovery;
    if (rec == null) return;
    final folder = _key(_normalizePath(st.directory.path));
    final gens = [
      for (final e in rec.indexEntries)
        if (pageIds.contains(e.pageId) && _key(e.folder) == folder && !_consumedCopies.containsKey(e.gen)) e.gen,
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
      // A consumed copy of a page written back is re-checked against it.
      final ids = {for (final p in deleted.pages) p.id};
      for (final m in _consumedCopies.values) {
        if (!ids.contains(m.pageId)) continue;
        m.since = now();
        m.decideNow = false;
        _armConsumed(m);
      }
    }
  }

  // The folder page [id] of [d] goes back to: its own, or the root's where its
  // own is no longer there (removed from Noted) or can't be written to.
  String _undoLoc(DeletedPages d, String id) {
    final own = d._locationOfPage(id);
    if (own == d._location) return own;
    try {
      _assertWritable(own);
      _storeOf(own);
      return own;
    } on NotebookException {
      return d._location;
    }
  }

  Future<void> _undoDeleteNow(DeletedPages deleted) async {
    final wasHeld = _held.contains(deleted);
    // Where each page goes, worked out once: a folder that goes away during the
    // Undo never splits a page from its attachments.
    final where = {for (final p in deleted.pages) p.id: _undoLoc(deleted, p.id)};
    String whereOf(String id) => where[id] ?? _undoLoc(deleted, id);
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
        await _gateMove(whereOf(id));
        _postCopyNotices(
          await _moveDir(dir, _assetsDir(whereOf(id), id), fromTrash: true),
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
        // The trash folder that held it goes if it is empty; an in-place
        // folder's parent is the page's folder, never touched.
        if (deleted._records[id]?.inPlace ?? false) continue;
        try {
          if (await dir.parent.exists() && await dir.parent.list().isEmpty) await removeFolderCoordinated(dir.parent);
        } on StorageBusy catch (e) {
          debugPrint('The folder is busy; not removing ${dir.parent.path}: $e');
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
        wrote = await _writeNew(whereOf(page.id), page);
      } on Object catch (e) {
        debugPrint('Restoring page ${page.id} failed: $e');
        failedWrite.add(title); // still only in memory
        continue;
      }
      if (wrote) {
        _metas[page.id] = page.meta;
        _loc[page.id] = whereOf(page.id);
        deleted._restored.add(page.id);
        continue;
      }
      PageStore st;
      String? copy;
      try {
        st = _storeOf(whereOf(page.id));
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
      for (final l in {deleted._location, for (final p in deleted.pages) whereOf(p.id)}) {
        _touch(l);
      }
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
      } on StorageBusy catch (e) {
        // A refusal is not a taken name: no further names are tried (C2).
        debugPrint('The folder is busy; not saving the restored page beside its file: $e');
        return null;
      } on FileSystemException catch (e) {
        debugPrint('Saving the restored page beside its file failed: $e');
      } on NotebookException catch (e) {
        // Refused at the folder's turn (its binder file changed): not
        // published; the temp, which is only ours, goes.
        debugPrint('Saving the restored page beside its file was refused: ${e.message}');
        return null;
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

  // The delete set-aside and its expiry ---------------------------------------

  // --- expiry begin (no path here removes a set-aside recursively) ---

  /// How long the expiry of a quit may run, checked between files (0152, 0155).
  @visibleForTesting
  static Duration expiryQuitLimit = const Duration(seconds: 5);

  /// How many runs that keep a set-aside (the page may be back) are made before
  /// its record is dropped and the folder stays.
  static const int _expiryKeptLimit = 3;

  // Set-asides kept by an expiry run, to be tried again after the next check
  // of their location's files.
  final List<_AsideRecord> _asidePending = [];

  // Each file of [dir] (path relative to it, with `/`) and the identity it is
  // known by: an attachment's name is its content hash (0098), so no hash runs.
  // A placeholder, or a name that is no hash, has none. [placeholders]: some file
  // is not downloaded (it is never read).
  ({Map<String, ContentIdentity?> identities, bool placeholders}) _asideIdentities(Directory dir) {
    final out = <String, ContentIdentity?>{};
    var placeholders = false;
    void walk(Directory d, String rel) {
      final List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final e in entries) {
        final name = _baseName(e.path);
        final r = rel.isEmpty ? name : '$rel/$name';
        switch (FileSystemEntity.typeSync(e.path, followLinks: false)) {
          case FileSystemEntityType.directory:
            walk(Directory(e.path), r);
          case FileSystemEntityType.file:
            if (_isPlaceholder(e.path)) {
              placeholders = true;
              out[r] = null;
              continue;
            }
            final hash = attachmentNameHash(name);
            ContentIdentity? id;
            try {
              id = hash == null ? null : ContentIdentity(File(e.path).lengthSync(), hash);
            } on FileSystemException {
              id = null;
            }
            out[r] = id;
          default:
            break; // a link is never followed, and has no identity
        }
      }
    }

    walk(dir, '');
    return (identities: out, placeholders: placeholders);
  }

  static String _hex12() {
    final r = Random.secure();
    return [for (var i = 0; i < 6; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  // Renames `<loc>/<p>.assets` to `<loc>/<p>.deleted-<12 hex>.assets` under the
  // folder's one lock (X2). Null when the rename isn't `moved` (nothing moved).
  // Under a registered coordination root the folder's files are passed along.
  Future<Directory?> _setAsideInPlace(Directory dir) async {
    final name = _baseName(dir.path);
    final stem = name.substring(0, name.length - '.assets'.length);
    final target = Directory('${dir.parent.path}${Platform.pathSeparator}$stem.deleted-${_hex12()}.assets');
    await syncHook?.call('move-dir-before-lock', dir.path);
    try {
      final r = await _underPair(dir.parent, dir.parent, () async {
        final also = _alsoMovedFor(dir);
        var o = MoveOutcome.busy;
        for (var i = 0; i < 3; i++) {
          o = await moveExclusive(dir.path, target.path, alsoMoved: also);
          if (o != MoveOutcome.busy) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return o;
      });
      return r == MoveOutcome.moved ? target : null;
    } on _LockTimeout catch (e) {
      throw _FolderBusy(e.path);
    } on _BinderUnreadableNow catch (e) {
      throw _GateRefused(e.message, dir.parent.path);
    } on BinderHeldException catch (e) {
      throw _GateRefused(e.message, dir.parent.path);
    }
  }

  // Whether page [p] is listed in any location.
  bool _listedAnywhere(String p) => _loc.containsKey(p);

  // Expires what [d] set aside (the delete can no longer be undone). With a
  // [deadline] (a quit) it stops between files once that has passed.
  Future<void> _expireDeleted(DeletedPages d, {DateTime? deadline}) async {
    for (final MapEntry(key: p, value: dir) in d._assets.entries.toList()) {
      if (d._keepTrash.contains(dir.path)) continue; // Undo could not put it back whole
      final rec = d._records[p];
      if (rec == null) continue;
      try {
        if (await _expireRecord(rec, deadline: deadline) == _Expiry.stopped) return;
      } on Object catch (e) {
        debugPrint('Expiring the set-aside folder ${dir.path} failed: $e');
      }
    }
  }

  // One run of the expiry of [rec]: per file, `deleteFileIfMatches` against the
  // identity recorded at delete time, with [_stillRedundant] right before each
  // unlink. A refused check or turn keeps the folder and its record, and the run
  // is made again after the next check of the location (at most
  // [_expiryKeptLimit] kept runs). A page that is listed again gets its folder
  // back as Undo would put it.
  Future<_Expiry> _expireRecord(_AsideRecord rec, {DateTime? deadline}) async {
    if (rec.running) return _Expiry.kept;
    rec.running = true;
    try {
      final r = await _expireRecordNow(rec, deadline);
      if (r == _Expiry.kept) {
        if (++rec.keptRuns >= _expiryKeptLimit) {
          _asidePending.remove(rec);
          debugPrint('The set-aside ${rec.dir.path} is kept: the page may be back.');
        } else if (!_asidePending.contains(rec)) {
          _asidePending.add(rec);
        }
      } else if (r == _Expiry.busy) {
        if (!_asidePending.contains(rec)) _asidePending.add(rec); // looked at after the move or delete
      } else if (r != _Expiry.stopped) {
        _asidePending.remove(rec);
      }
      return r;
    } finally {
      rec.running = false;
    }
  }

  // One turn of [job] under [locDir]'s lock (0184's gate in it). With a deadline
  // the wait for the lock ends at it ([_LockTimeout]).
  Future<T> _expiryTurn<T>(Directory locDir, DateTime? deadline, Future<T> Function() job) {
    if (deadline == null) return _lockRun(locDir, job);
    var left = deadline.difference(now());
    if (left > expiryQuitLimit) left = expiryQuitLimit;
    if (left <= Duration.zero) throw const _LockTimeout('');
    return _lockLimited(locDir, job, limit: left);
  }

  Future<_Expiry> _expireRecordNow(_AsideRecord rec, DateTime? deadline) async {
    final p = rec.pageId;
    if (_disposed) return _Expiry.kept;
    rec
      ..retryOnAnyCheck = true
      ..blockedKey = null;
    // A page being moved or deleted: its folder isn't touched (a restore would
    // rename it into `<p>.assets` in the middle of that work). Looked at again
    // when it ends.
    if (_busy.containsKey(p)) return _Expiry.busy;
    if (_listedAnywhere(p)) {
      // A quit has no time for a restore (its locks and copies have no limit).
      if (deadline != null) return _Expiry.kept;
      return await _restoreSetAside(rec) ? _Expiry.restored : _Expiry.kept;
    }
    final Directory locDir;
    try {
      if (_pullOnly(rec.loc)) return _Expiry.kept; // never written here
      locDir = _storeOf(rec.loc).directory;
    } on Object {
      return _Expiry.kept;
    }
    if (!rec.dir.existsSync()) return _Expiry.done;
    // What a crashed or interrupted delete left aside goes back first (not at a
    // quit: the sweep has no time limit; what it would put back stays).
    if (deadline == null) {
      try {
        await sweepAsideFiles(rec.dir, extension: '');
      } on Object catch (e) {
        debugPrint('Sweeping ${rec.dir.path} failed: $e');
      }
    }
    final List<File> files;
    try {
      files = [for (final e in rec.dir.listSync(recursive: true, followLinks: false)) if (e is File) e];
    } on FileSystemException {
      return _Expiry.kept;
    }
    // The location's page files, stamped once for this run under its lock.
    final Map<String, FileStamp> others;
    try {
      others = await _expiryTurn(locDir, deadline, () async => _otherPageFiles(locDir, p));
    } on _LockTimeout {
      return _Expiry.stopped;
    } on NotebookException {
      return _Expiry.kept;
    }
    var unknown = 0;
    var changed = 0;
    for (final f in files) {
      if (deadline != null && !now().isBefore(deadline)) return _Expiry.stopped;
      if (!f.existsSync()) continue;
      final rel = f.path.substring(rec.dir.path.length + 1).replaceAll(r'\', '/');
      if (!rec.identities.containsKey(rel)) {
        changed++; // new since the folder was set aside
        continue;
      }
      final id = rec.identities[rel];
      if (id == null) {
        unknown++; // a placeholder, or a name that is no hash: kept
        continue;
      }
      var refused = false;
      try {
        await syncHook?.call('expiry-file', f.path);
        final res = await _expiryTurn(locDir, deadline, () async {
          _assertWritable(rec.loc);
          return deleteFileIfMatches(
            f.path,
            identity: id,
            stillRedundant: () {
              var ok = false;
              try {
                ok = _stillRedundant(rec, locDir, others);
              } on Object {
                ok = false;
              }
              if (!ok) refused = true;
              return ok;
            },
            beforeFinalCheck: (path) async => syncHook?.call('expiry-final-check', path),
          );
        });
        if (!res.deleted && res.outcome != DeleteOutcome.absent) changed++;
      } on _LockTimeout {
        return _Expiry.stopped;
      } on NotebookException {
        return _Expiry.kept; // the gate (0184) or a read-only folder refused this turn
      } on StorageBusy catch (e) {
        // The folder's coordination refused: nothing was removed, and a refusal
        // counts as kept, never as done (R5.16, C2).
        debugPrint('The folder is busy; not removing ${f.path} from the set-aside: $e');
        return _Expiry.kept;
      } on FileSystemException catch (e) {
        debugPrint('Removing ${f.path} from the set-aside failed: $e');
        changed++;
      }
      if (refused) return _Expiry.kept;
    }
    // Empty folders go, never one that holds anything.
    try {
      await _expiryTurn(locDir, deadline, () async => _pruneSetAside(rec));
    } on _LockTimeout {
      return _Expiry.stopped;
    } on NotebookException {
      return _Expiry.kept;
    }
    if (rec.dir.existsSync() && !rec.reported && (unknown > 0 || changed > 0) && !_notices.isClosed) {
      rec.reported = true;
      _notices.add(
        'Some images and files of "${_titleOrUntitled(rec.title)}" were not removed: they changed or are not downloaded. '
        'They are in ${rec.dir.path}.',
      );
    }
    return _Expiry.done;
  }

  // The `.canvas` files of [locDir] that are known to be another page's: their
  // stamp is the one last classified, they aren't placeholders, and they are
  // listed as another page. Metadata only (rule P); a failing listing gives
  // none, so every file counts as the page.
  Map<String, FileStamp> _otherPageFiles(Directory locDir, String p) {
    final out = <String, FileStamp>{};
    try {
      for (final e in locDir.listSync(followLinks: false)) {
        if (e is! File || !e.path.toLowerCase().endsWith(PageStore.extension)) continue;
        final key = _key(e.path);
        final s = fileStamp(e.path);
        final id = _pathId[key];
        if (s != null && id != null && id != p && _fileStamps[key] == s && !_isPlaceholder(e.path)) out[key] = s;
      }
    } on FileSystemException {
      return {};
    }
    return out;
  }

  // Synchronous, right before each unlink: whether the files of [rec] are still
  // redundant, that is page [p] is gone. No listed page is [p] or the folder's
  // stem (N10), [p] isn't busy, and the location's names show no file that may be
  // [p]: a name 0150 ties to it (its id), a stub, and any `.canvas` file that
  // isn't known to be another page (new, changed, unstamped, a placeholder, an
  // unreadable one) count as [p]. A listing that fails counts too. Reads no file.
  bool _stillRedundant(_AsideRecord rec, Directory locDir, Map<String, FileStamp> others) {
    final p = rec.pageId;
    if (_disposed || _busy.containsKey(p) || _listedAnywhere(p)) return false;
    final stem = rec.stem;
    if (stem != null && _listedAnywhere(stem)) return false;
    final pl = p.toLowerCase();
    // What the next run waits for: a check that may bring the page (a name that
    // is its, or a file whose check classifies it), not any check of the folder.
    bool no({String? key}) {
      rec
        ..retryOnAnyCheck = false
        ..blockedKey = key;
      return false;
    }

    try {
      for (final e in locDir.listSync(followLinks: false)) {
        if (e is Directory) continue;
        final name = _baseName(e.path);
        final nl = name.toLowerCase();
        if (nl.contains(pl) || nl.endsWith('.icloud')) return no(key: _key(e.path));
        if (nl.endsWith(PageStore.extension)) {
          final key = _key(e.path);
          final s = others[key];
          // The disk's stamp now too: a sync client may have replaced the file
          // since the snapshot.
          if (s == null || _fileStamps[key] != s || fileStamp(e.path) != s) return no(key: key);
          final id = _pathId[key];
          if (id == null || id == p) return no(key: key);
        }
      }
    } on FileSystemException {
      return false;
    }
    return true;
  }

  // Removes the empty folders of [rec] (non-recursively, deepest first) and, for
  // a folder in `deleted-attachments`, its own empty parent.
  Future<void> _pruneSetAside(_AsideRecord rec) async {
    Future<void> prune(Directory d) async {
      final List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final e in entries) {
        if (e is Directory && FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.directory) {
          await prune(e);
        }
      }
      await _pruneEmptyFolder(d); // not empty when files stayed
    }

    await prune(rec.dir);
    if (!rec.inPlace) await _pruneEmptyFolder(rec.dir.parent); // other folders may be in it
  }

  // Removes [d] only if it is empty (never recursively); nothing happens when it
  // holds anything, is gone, or the folder is busy (it stays, and the next
  // clean-up tries again).
  static Future<void> _pruneEmptyFolder(Directory d) async {
    try {
      if (d.listSync(followLinks: false).isNotEmpty) return;
      await removeFolderCoordinated(d);
    } on StorageBusy {
      // Kept: busy.
    } on FileSystemException {
      // Not empty, or already gone.
    }
  }

  // Puts [rec]'s folder back as Undo does (the page is listed again): into the
  // folder of the page's location (under L when the keys differ), or file by file
  // into a taken name. Leftovers are reported and the record ends (kept from the
  // expiry). False when the restore was refused: it counts as kept.
  Future<bool> _restoreSetAside(_AsideRecord rec) async {
    final p = rec.pageId;
    final loc = _loc[p];
    if (loc == null) return false;
    try {
      _assertWritable(loc);
      _storeOf(loc);
      if (!rec.dir.existsSync()) return true;
      try {
        await sweepAsideFiles(rec.dir, extension: '');
      } on Object catch (e) {
        debugPrint('Sweeping ${rec.dir.path} failed: $e');
      }
      try {
        await _gateMove(loc);
      } on FileSystemException {
        return false; // 0184's gate refused this turn: kept, tried again
      }
      _postCopyNotices(
        await _moveDir(rec.dir, _assetsDir(loc, p), fromTrash: true),
        'the page',
        rec.inPlace ? 'the page\'s folder' : 'the folder of deleted pages',
      );
      if (!rec.inPlace) await _pruneSetAside(rec);
      return true;
    } on NotebookException {
      return false; // read-only, pull-only or held: kept
    } on _GateRefused {
      return false; // 0184's gate refused the turn: kept, tried again
    } on _FolderBusy {
      return false; // a lock wasn't got in time, nothing moved: kept, tried again
    } on Object catch (e) {
      debugPrint('Putting back the set-aside ${rec.dir.path} failed: $e');
      if (e is FileSystemException) {
        _postKept(e, rec.dir, 'the page', rec.inPlace ? 'the page\'s folder' : 'the folder of deleted pages');
      }
      return true; // what is left stays under its name, kept from the expiry
    }
  }

  // After a check of a page file: the set-asides kept by an expiry run for its
  // location are tried again, each as its own job (never inside a job that holds
  // the folder's lock: [FolderLocks] isn't re-entrant).
  void _expiryAfterCheck(String path) {
    if (_asidePending.isEmpty || _disposed) return;
    final loc = _locationOf(path);
    if (loc == null) return;
    final key = _key(path);
    final name = _baseName(path).toLowerCase();
    // A run that was kept because of one file, or because a name may be the
    // page's, waits for a check of that; other pages' checks (their events, this
    // notebook's own saves) don't use up its runs.
    bool mayBe(_AsideRecord r) =>
        _listedAnywhere(r.pageId) ||
        name.contains(r.pageId.toLowerCase()) ||
        (_pathId[key] == null && File(path).existsSync());
    final due = [
      for (final r in _asidePending)
        if (r.loc == loc && !r.running && (r.retryOnAnyCheck || r.blockedKey == key || mayBe(r))) r,
    ];
    if (due.isEmpty) return;
    unawaited(
      Future<void>(() async {
        for (final r in due) {
          if (_disposed) return;
          try {
            await _expireRecord(r);
          } on Object catch (e) {
            debugPrint('Expiring ${r.dir.path} again failed: $e');
          }
        }
      }),
    );
  }

  // --- expiry end ---

  /// Drops the in-memory copy of [deleted] (its snack bar went away): its
  /// set-aside folders are emptied by the expiry.
  void discardDeleted(DeletedPages deleted) {
    if (identical(_lastDeleted, deleted)) _lastDeleted = null;
    if (_undoing.containsKey(deleted)) return; // its Undo is copying from the set-aside
    _held.remove(deleted);
    unawaited(_expireDeleted(deleted).catchError((Object e) => debugPrint('Expiring a delete failed: $e')));
    _letGoConsumed(deleted);
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
  Future<bool> moveRelative(String id, String targetId, {required bool after}) =>
      _asUser(() => _moveRelative(id, targetId, after: after));

  Future<bool> _moveRelative(String id, String targetId, {required bool after}) async {
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
    _heldPlacement.remove(id); // a placement of its own supersedes a held one (N8)
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

  // A move by rename ------------------------------------------------------------

  /// How long each lock of a move's pair is waited for before the pair is let
  /// go and tried again (L). Tests shorten it.
  @visibleForTesting
  static Duration pairLockLimit = const Duration(seconds: 5);

  /// The wait before a pair is tried again.
  @visibleForTesting
  static Duration pairRetryDelay = const Duration(milliseconds: 500);

  // [job] under [dir]'s lock, waited for at most [pairLockLimit]: past that the
  // queued job is cancelled (it returns at once if it ever starts) and the
  // caller gets a [_LockTimeout].
  Future<T> _lockLimited<T>(Directory dir, Future<T> Function() job, {bool gate = true, Duration? limit}) {
    final out = Completer<T>();
    var state = 0; // 0 waiting, 1 started, 2 cancelled
    final timer = Timer(limit ?? pairLockLimit, () {
      if (state != 0) return;
      state = 2;
      out.completeError(_LockTimeout(dir.path));
    });
    // The limit is for the wait for the lock only: it ends when the lock is held,
    // before the gate's read of the binder file (G2), which can be slow.
    final run = _lockRunRaw<T>(dir, () async {
      if (state == 2) throw const _LockTimeout('');
      state = 1;
      timer.cancel();
      return gate ? _gated(dir, job) : job();
    });
    _afterLockJob(run);
    run.then<void>(
      (v) {
        if (!out.isCompleted) out.complete(v);
      },
      onError: (Object e, StackTrace s) {
        timer.cancel();
        if (!out.isCompleted) out.completeError(e, s);
      },
    );
    return out.future;
  }

  // [job] under the locks of [a] and [b]: both, in [FolderLocks.keyOf] order,
  // when the keys differ (L), or the one lock when they are equal (X2). Each
  // lock is waited for at most [pairLockLimit]; on a timeout everything held is
  // let go and the pair is tried again after [pairRetryDelay], [tries] times in
  // all. Throws the last [_LockTimeout].
  Future<T> _underPair<T>(Directory a, Directory b, Future<T> Function() job, {int tries = 2, bool gate = true}) async {
    final ka = FolderLocks.keyOf(a), kb = FolderLocks.keyOf(b);
    if (ka == kb) return _lockLimited(a, job, gate: gate);
    final first = ka.compareTo(kb) < 0 ? a : b;
    final second = identical(first, a) ? b : a;
    for (var i = 1; ; i++) {
      try {
        return await _lockLimited(first, () => _lockLimited(second, job, gate: gate), gate: gate);
      } on _LockTimeout {
        if (i >= tries || _disposed) rethrow;
        await Future<void>.delayed(pairRetryDelay);
      }
    }
  }

  // Moves the files under [from] to [to] one at a time (2c): each with
  // `moveExclusive`, `busy` tried three times. A link, a name that is taken and
  // a file that won't move stay. Emptied folders are removed (never one that
  // holds anything). Returns the paths left at [from].
  Future<List<String>> _moveFilesOneByOne(
    Directory from,
    Directory to, {
    List<DamagedKept>? kept,
    Set<String> hydrated = const {},
  }) async {
    final left = <String>[];
    Future<void> walk(Directory s, Directory d) async {
      final List<FileSystemEntity> entries;
      try {
        entries = s.listSync(followLinks: false);
      } on FileSystemException {
        left.add(s.path);
        return;
      }
      for (final e in entries) {
        final name = e.path.split(RegExp(r'[\\/]')).last;
        final target = '${d.path}${Platform.pathSeparator}$name';
        switch (FileSystemEntity.typeSync(e.path, followLinks: false)) {
          case FileSystemEntityType.directory:
            final there = FileSystemEntity.typeSync(target, followLinks: false);
            if (there != FileSystemEntityType.notFound && there != FileSystemEntityType.directory) {
              left.add(e.path);
            } else {
              await walk(Directory(e.path), Directory(target));
            }
          case FileSystemEntityType.file:
            // Hydration was tried and the file is still not downloaded (H): it
            // stays at the source.
            if (hydrated.contains(e.path) && _isPlaceholder(e.path)) {
              left.add(e.path);
              continue;
            }
            var r = MoveOutcome.busy;
            try {
              await createFolderCoordinated(d);
              for (var i = 0; i < 3; i++) {
                r = await moveExclusive(e.path, target);
                if (r != MoveOutcome.busy) break;
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
            } on StorageBusy {
              r = MoveOutcome.busy; // the file stays where it is and is reported
            } on FileSystemException {
              r = MoveOutcome.busy;
            }
            if (r == MoveOutcome.targetExists && kept != null) r = await _takenHashName(e.path, target, kept);
            if (r != MoveOutcome.moved) left.add(e.path);
          default:
            left.add(e.path); // a link or junction is never followed
        }
      }
      try {
        if (s.listSync(followLinks: false).isEmpty) await removeFolderCoordinated(s); // an empty folder only
      } on StorageBusy {
        // Busy: the folder stays.
      } on FileSystemException {
        // Not empty: files stayed.
      }
    }

    await walk(from, to);
    return left;
  }

  // A file of the source folder whose hash name is taken at the target (2c). The
  // source's file is moved in only if it holds its name's hash and the target's
  // file is damaged: that one is renamed to `<name>.damaged-<12 hex>` (never
  // deleted), hashed there, and the source's file takes the freed name. A
  // placeholder is never hashed. Anything else leaves both files and answers
  // `targetExists`. [kept] gets what was set aside.
  Future<MoveOutcome> _takenHashName(String src, String dst, List<DamagedKept> kept) async {
    try {
      final name = dst.split(RegExp(r'[\\/]')).last;
      final hash = attachmentNameHash(name);
      if (hash == null) return MoveOutcome.targetExists;
      if (_isPlaceholder(src) || _isPlaceholder(dst)) {
        return MoveOutcome.targetExists;
      }
      if (FileSystemEntity.typeSync(dst, followLinks: false) != FileSystemEntityType.file) return MoveOutcome.targetExists;
      final srcLength = File(src).lengthSync();
      final mine = await checkAttachmentFile(File(src), hash, 0);
      if (mine.state != AttachmentState.ok) return MoveOutcome.targetExists;
      final theirs = await checkAttachmentFile(File(dst), hash, 0);
      final found = theirs.found;
      if (theirs.state != AttachmentState.damaged || found == null) return MoveOutcome.targetExists;
      final folder = File(dst).parent.path;
      final aside = damagedCopyName(name, found.sha256);
      final asidePath = '$folder${Platform.pathSeparator}$aside';
      await syncHook?.call('move-before-aside', dst);
      if (await moveExclusive(dst, asidePath) != MoveOutcome.moved) return MoveOutcome.targetExists;
      await syncHook?.call('move-after-aside', dst);
      // What was set aside is what was checked; if not, it goes back when it can.
      if (await ContentIdentity.ofFile(asidePath) != found) {
        await moveExclusive(asidePath, dst);
        return MoveOutcome.targetExists;
      }
      final r = await moveExclusive(src, dst);
      final k = DamagedKept(folder: folder, name: name, aside: aside, incomplete: found.length < srcLength);
      k.replaced = r == MoveOutcome.moved;
      kept.add(k);
      return r;
    } on FileSystemException {
      return MoveOutcome.targetExists;
    }
  }

  // Moves page [p]'s images and files folder from [fromLoc] to [toLoc]: the
  // folder is renamed, or, when that isn't `moved`, moved file by file. Returns
  // the paths left behind. [hydrated] are the files hydration was tried on (H).
  Future<List<String>> _moveAssetsByRename(
    String p,
    String fromLoc,
    String toLoc, {
    bool hook = false,
    List<DamagedKept>? kept,
    Set<String> hydrated = const {},
  }) async {
    final src = _assetsDir(fromLoc, p), dst = _assetsDir(toLoc, p);
    if (FileSystemEntity.typeSync(src.path, followLinks: false) == FileSystemEntityType.notFound) return const [];
    if (hook) await syncHook?.call('move-before-assets', src.path);
    if (FileSystemEntity.typeSync(src.path, followLinks: false) != FileSystemEntityType.directory) return [src.path];
    return (await _moveFolder(src, dst, kept: kept, hydrated: hydrated)).left;
  }

  // Renames the folder [src] to [dst]; when that isn't `moved`, moves it file by
  // file (2c's rule). A folder that holds a file hydration was tried on and
  // that is still not downloaded isn't renamed whole (the file stays, H).
  // With [stopOnCannot], `cannotRename` is answered as it is, for a caller
  // that copies; otherwise the files left at [src] are listed.
  Future<({MoveOutcome outcome, List<String> left})> _moveFolder(
    Directory src,
    Directory dst, {
    List<DamagedKept>? kept,
    Set<String> hydrated = const {},
    bool stopOnCannot = false,
  }) async {
    var r = MoveOutcome.busy;
    if (hydrated.any((h) => File(h).existsSync() && _isPlaceholder(h))) {
      r = MoveOutcome.targetExists;
    } else {
      try {
        final also = _alsoMovedFor(src);
        for (var i = 0; i < 3; i++) {
          r = await moveExclusive(src.path, dst.path, alsoMoved: also);
          if (r != MoveOutcome.busy) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      } on FileSystemException {
        r = MoveOutcome.busy;
      }
    }
    if (r == MoveOutcome.moved) return (outcome: r, left: const <String>[]);
    if (stopOnCannot && r == MoveOutcome.cannotRename) return (outcome: r, left: [src.path]);
    return (outcome: r, left: await _moveFilesOneByOne(src, dst, kept: kept, hydrated: hydrated));
  }

  // O. Stray attachments folders ------------------------------------------------

  /// How long a stray folder must be unchanged before it is moved (O).
  @visibleForTesting
  static Duration strayQuiet = const Duration(seconds: 30);

  // The listing signature of a stray folder at its last look, and since when it
  // has been the same.
  final Map<String, ({String sig, DateTime since})> _strayWatch = {};
  // Folders already reported as declined or unfinished (said once).
  final Set<String> _strayReported = {};

  // The locations a stray folder can be in or move to.
  Iterable<String> get _strayLocs sync* {
    yield _standalone;
    for (final b in _binders.values) {
      yield b.path;
    }
    for (final f in _folders.values) {
      yield f.path;
    }
  }

  bool _inTrashRecord(String p) =>
      (_lastDeleted?._assets.containsKey(p) ?? false) || _held.any((h) => h._assets.containsKey(p));

  // Runs O over every location: at load and in each folder check. Never throws.
  Future<void> _strayCheck() async {
    try {
      for (final s in _strayLocs.toList()) {
        if (_disposed) return;
        await _strayCheckLoc(s);
      }
    } on Object catch (e) {
      debugPrint('Checking for stray attachments folders failed: $e');
    }
  }

  Future<void> _strayCheckLoc(String s) async {
    if (_isLocked(s)) return;
    final Directory sDir;
    final List<FileSystemEntity> entries;
    try {
      sDir = _storeOf(s).directory;
      entries = sDir.listSync(followLinks: false);
    } on Object {
      return;
    }
    final names = [for (final e in entries) _baseName(e.path)];
    for (final e in entries) {
      if (_disposed) return;
      if (e is! Directory) continue;
      final name = _baseName(e.path);
      // Only `<p>.assets`: a set-aside `<p>.deleted-<hex>.assets` is never O's.
      if (!name.endsWith('.assets') || name.contains('.deleted-')) continue;
      final p = name.substring(0, name.length - '.assets'.length);
      final d = _loc[p];
      if (d == null || d == s) continue;
      await _strayOne(p, s, d, sDir, e, names);
    }
  }

  // Whether something in [sDir] counts as page [p] by 0150's rule: a file whose
  // name carries the id (a chosen or conflict-copy name, an iCloud stub), a file
  // listed as [p], or an unreadable file. Anything uncertain counts.
  bool _strayCountsAsPage(String p, Directory sDir, List<String> names) {
    final pl = p.toLowerCase();
    for (final n in names) {
      final nl = n.toLowerCase();
      if (nl.endsWith('.assets')) continue;
      if (nl.contains(pl)) return true;
    }
    final sk = _key(sDir.path);
    for (final en in _pathId.entries) {
      if (en.value == p && _key(File(en.key).parent.path) == sk) return true;
    }
    // Any other page file that isn't known to be another page (the expiry's
    // rule): unclassified, unstamped, changed since its stamp or a placeholder
    // may be the page, restored by sync under another name or over another
    // page's file. Metadata only (rule P).
    for (final n in names) {
      if (!n.toLowerCase().endsWith(PageStore.extension)) continue;
      final path = '${sDir.path}${Platform.pathSeparator}$n';
      final key = _key(path);
      final s = fileStamp(path);
      final id = _pathId[key];
      if (s == null || id == null || id == p || _fileStamps[key] != s || _isPlaceholder(path)) return true;
    }
    return unreadable.any((u) => _key(File(u.path).parent.path) == sk);
  }

  String _strayListing(Directory dir) {
    try {
      final b = StringBuffer();
      final all = dir.listSync(recursive: true, followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
      for (final e in all) {
        final st = e.statSync();
        b.write('${e.path}|${st.size}|${st.modified.microsecondsSinceEpoch};');
      }
      return b.toString();
    } on FileSystemException {
      return '?${now().microsecondsSinceEpoch}'; // can't tell: never quiet
    }
  }

  void _strayReport(String key, String p, String s, String why) {
    if (!_strayReported.add(key) || _notices.isClosed) return;
    _notices.add(
      'The images and files folder of "${_titleOrUntitled(_metas[p]?.title ?? '')}" stayed in ${_placeName(s)}: $why.',
    );
  }

  Future<void> _strayOne(String p, String s, String d, Directory sDir, Directory folder, List<String> names) async {
    final key = _key(folder.path);
    // Not stray while the page is also listed at S.
    final sk = _key(sDir.path);
    if (_pathId.entries.any((en) => en.value == p && _key(File(en.key).parent.path) == sk)) return;
    // Transient: left for a later check.
    if (_busy.containsKey(p) || _inTrashRecord(p) || _isLocked(s) || _isLocked(d)) return;
    final Directory dDir;
    try {
      dDir = _storeOf(d).directory;
    } on Object {
      return;
    }
    if (_pullOnly(s) || _pullOnly(d)) {
      _strayReport(key, p, s, 'a folder is read-only here');
      return;
    }
    final sv = fileStamp(sDir.path)?.volume, dv = fileStamp(dDir.path)?.volume;
    if (sv != null && dv != null && sv != dv) {
      _strayReport(key, p, s, 'the page is on another drive');
      return;
    }
    if (_strayCountsAsPage(p, sDir, names)) {
      _strayReport(key, p, s, 'a file there may still be the page');
      return;
    }
    // Quiet: nothing in the folder changed for [strayQuiet].
    final sig = _strayListing(folder);
    final t = now();
    final seen = _strayWatch[key];
    if (seen == null || seen.sig != sig) {
      _strayWatch[key] = (sig: sig, since: t);
      return;
    }
    if (t.difference(seen.since) < strayQuiet) return;
    final dst = _assetsDir(d, p);
    final hydrated = await _hydrateFolder(folder, dst.path);
    final damaged = <DamagedKept>[];
    List<String> left;
    try {
      left = await _underPair(sDir, dDir, () async {
        // Everything is checked again inside the locks.
        if (_busy.containsKey(p) || _loc[p] != d || _isLocked(s) || _isLocked(d)) return const <String>[];
        List<String> namesNow;
        try {
          namesNow = [for (final e in sDir.listSync(followLinks: false)) _baseName(e.path)];
        } on FileSystemException {
          return const <String>[];
        }
        if (_strayCountsAsPage(p, sDir, namesNow) || !folder.existsSync()) return const <String>[];
        return (await _moveFolder(folder, dst, kept: damaged, hydrated: hydrated)).left;
      });
    } on _LockTimeout {
      return; // busy: tried again at the next check
    }
    _strayWatch.remove(key);
    if (damaged.isNotEmpty) {
      _postCopyNotices(AttachmentCopy()..damagedKept.addAll(damaged), _placeName(d), _placeName(s));
    }
    if (left.isNotEmpty) {
      _strayReport(
        key,
        p,
        s,
        '${left.length == 1 ? 'one file' : '${left.length} files'} could not be moved (a name was taken in ${_placeName(d)}, or a file was in use or a link)',
      );
    }
    _attachments?.filesChanged();
  }

  // Gives page [p]'s file in [st] the path [to] (a rename that never replaces),
  // and the store its new path. False when that name is taken or won't move.
  Future<bool> _renameStoreFile(PageStore st, String p, String to) async {
    final cur = st.pathFor(p);
    if (_key(cur) == _key(to)) return true;
    try {
      if (await moveExclusive(cur, to) != MoveOutcome.moved) return false;
    } on FileSystemException {
      return false;
    }
    st.adopt(p, to);
    // The bookkeeping of the file follows its name (a rename keeps its stamp).
    final ok = _key(cur), nk = _key(to);
    if (_pathId[ok] == p) {
      final t = _known[ok];
      final s = _fileStamps[ok];
      _known.remove(ok);
      _pathId.remove(ok);
      _pathId[nk] = p;
      if (t != null) _known[nk] = t;
      _recordStamp(nk, s);
    }
    return true;
  }

  // One page's rename, inside both folders' locks (2a to 2d). [forward] is the
  // move itself; otherwise it is the rollback's return of the page. Never
  // reads the page file. What stays behind is added to [notes].
  Future<_RenameOne> _renameOnePage(
    String p, {
    required PageStore fromStore,
    required PageStore toStore,
    required String fromLoc,
    required String toLoc,
    required bool forward,
    required List<String> notes,
    required Set<String> atDest,
    required Map<String, String> origNames,
    Set<String> hydrated = const {},
  }) async {
    _assertWritable(fromLoc);
    _assertWritable(toLoc);
    if (!fromStore.directory.existsSync() || !toStore.directory.existsSync()) {
      throw NotebookException('${_placeName(forward ? fromLoc : toLoc)} is not available right now.');
    }
    var oldPath = fromStore.pathFor(p);
    final sep = Platform.pathSeparator;
    if (forward) {
      origNames[p] = _folderName(oldPath);
    } else if (origNames[p] case final want? when _folderName(oldPath) != want) {
      // A chosen file goes back under its own name.
      if (!await _renameStoreFile(fromStore, p, '${fromStore.directory.path}$sep$want')) return _RenameOne.taken;
    }
    oldPath = fromStore.pathFor(p);
    final oldKey = _key(oldPath);
    if (forward) await syncHook?.call('move-before-rename', fromStore.directory.path);
    if (forward && cannotRenamePagesForTest.contains(p)) return _RenameOne.cannot;
    // A placeholder moves by rename only within one sync root (H): outside it,
    // a dataless file could lose its only copy.
    if (forward && _isPlaceholder(oldPath) && !_sameSyncRoot(fromStore.directory.path, toStore.directory.path)) {
      return _RenameOne.cannot;
    }
    var r = MoveOutcome.busy;
    try {
      for (var i = 0; i < 3; i++) {
        r = await fromStore.moveTo(p, toStore);
        if (r != MoveOutcome.busy) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on FileSystemException catch (e) {
      throw NotebookException('The page file could not be found or moved.${_osReason(e)}');
    }
    switch (r) {
      case MoveOutcome.targetExists:
        return _RenameOne.taken;
      case MoveOutcome.busy:
        return _RenameOne.busy;
      case MoveOutcome.cannotRename:
        return _RenameOne.cannot;
      case MoveOutcome.moved:
        break;
    }
    if (forward) {
      // A chosen file arrives as the page's own file name when that is free (0149).
      final own = '${toStore.directory.path}$sep$p${PageStore.extension}';
      if (_key(toStore.pathFor(p)) != _key(own) && await _renameStoreFile(toStore, p, own)) toStore.unadopt(p);
      atDest.add(p);
    } else {
      atDest.remove(p);
      // The store the file left forgot its chosen name; the file is back.
      final c = _adoptedFiles[p];
      if (c != null && _key(File(c).parent.path) == _key(toStore.directory.path)) toStore.adopt(p, c);
    }
    if (forward) await syncHook?.call('move-after-rename', toStore.directory.path);
    // 2b: the stamp the page had is compared with the moved file's. A match is
    // the file last classified, carried as it is; anything else changed since
    // and is read by the check after the move.
    final newPath = toStore.pathFor(p);
    final newKey = _key(newPath);
    final carried = _fileStamps[oldKey];
    final knownText = _known[oldKey];
    final nowStamp = fileStamp(newPath);
    final match = carried != null && nowStamp != null && carried == nowStamp;
    // 2d: the bookkeeping, still inside the locks.
    _known.remove(oldKey);
    _movePublish.remove(oldKey); // a page leaving a path it was queued at (a rollback)
    _pathId.remove(oldKey);
    _pathId[newKey] = p;
    if (match && knownText != null) {
      _known[newKey] = knownText;
    } else if (knownText != null) {
      _baseText[newKey] = knownText;
    }
    _recordStamp(newKey, match ? nowStamp : null);
    _loc[p] = toLoc;
    _emitDeleted(oldPath);
    if (match && knownText != null) {
      _emitPublished(newPath, _identityOf(() => knownText), () => knownText);
    } else if (match) {
      // Stamped but never read: not read now either (rule P), so the event
      // carries no identity (0148: the consumer rereads).
      _emitPublishedUnread(newPath);
    } else {
      // The identity comes from the read that step 4 makes of the file (a
      // rollback publishes the source the same way).
      _movePublish[newKey] = newPath;
    }
    // 2c: its images and files.
    final damaged = <DamagedKept>[];
    final left = await _moveAssetsByRename(p, fromLoc, toLoc, hook: forward, kept: damaged, hydrated: hydrated);
    if (damaged.isNotEmpty) {
      final all = AttachmentCopy()..damagedKept.addAll(damaged);
      notes.addAll(_copyNotices(all, _placeName(toLoc), _placeName(fromLoc)));
    }
    if (left.isNotEmpty) {
      notes.add(
        '${left.length == 1 ? 'One file' : '${left.length} files'} of "${_titleOrUntitled(_metas[p]?.title ?? '')}" '
        'stayed in ${_placeName(fromLoc)} (a name was taken there, or a file was in use or a link).',
      );
    }
    return _RenameOne.renamed;
  }

  // Moves [ids] (the page, then its subpages) from [fromLoc] to [toLoc] by
  // rename, page by page, each in both folders' locks. False when the first
  // page can't be renamed (another drive or cloud): nothing was moved, and the
  // caller copies. A failure puts the moved pages back; one that can't go back
  // stays at the target. Throws a NotebookException for every other end that
  // isn't a full move. [atDest] ends with the pages at the target.
  Future<bool> _renameTree(
    List<String> ids, {
    required String fromLoc,
    required String toLoc,
    required PageStore fromStore,
    required PageStore toStore,
    required Set<String> atDest,
    required List<String> notes,
    Set<String> hydrated = const {},
  }) async {
    final origNames = <String, String>{};
    final fromDir = fromStore.directory, toDir = toStore.directory;
    String? failure;
    var wantCopy = false;
    for (var k = 0; k < ids.length && failure == null; k++) {
      final p = ids[k];
      final name = '"${_titleOrUntitled(_metas[p]?.title ?? '')}"';
      try {
        final r = await _underPair(
          fromDir,
          toDir,
          () => _renameOnePage(
            p,
            fromStore: fromStore,
            toStore: toStore,
            fromLoc: fromLoc,
            toLoc: toLoc,
            forward: true,
            notes: notes,
            atDest: atDest,
            origNames: origNames,
            hydrated: hydrated,
          ),
        );
        switch (r) {
          case _RenameOne.renamed:
            break;
          case _RenameOne.cannot:
            if (k == 0) return false;
            failure = '$name can not be renamed into ${_placeName(toLoc)}.';
            wantCopy = true;
          case _RenameOne.taken:
            failure =
                '${_placeName(toLoc)} already has a file for $name, so it was not moved. The existing file '
                'was left as it is. Move or delete the file in ${_placeName(toLoc)} if you want to move the page there.';
          case _RenameOne.busy:
            failure = 'The file of $name is in use by another program, so it was not moved.';
        }
      } on _LockTimeout catch (e) {
        failure = '${_placeName(FolderLocks.keyOf(Directory(e.path)) == FolderLocks.keyOf(toDir) ? toLoc : fromLoc)} is busy; try again.';
      } on NotebookException catch (e) {
        failure = e.message;
      } on Object catch (e) {
        if (_disposed) rethrow;
        debugPrint('Moving page $p failed: $e');
        failure = 'Could not move $name.${_osReason(e)}';
      }
    }
    if (failure == null) return true;
    // Put the moved pages back, last first.
    final stayed = <String>[];
    final order = [for (final p in ids.reversed) if (atDest.contains(p)) p];
    var stalled = false;
    for (var i = 0; i < order.length; i++) {
      final p = order[i];
      var back = _RenameOne.busy;
      try {
        back = await _underPair(
          toDir,
          fromDir,
          () => _renameOnePage(
            p,
            fromStore: toStore,
            toStore: fromStore,
            fromLoc: toLoc,
            toLoc: fromLoc,
            forward: false,
            notes: notes,
            atDest: atDest,
            origNames: origNames,
            hydrated: hydrated,
          ),
          tries: 3,
        );
      } on _LockTimeout {
        stalled = true;
      } on NotebookException catch (e) {
        notes.add(e.message);
      } on Object catch (e) {
        if (_disposed) rethrow;
        debugPrint('Putting page $p back failed: $e');
        notes.add('A page could not be put back.${_osReason(e)}');
      }
      if (back != _RenameOne.renamed) stayed.add(p);
      if (stalled) {
        stayed.addAll(order.skip(i + 1));
        if (!stayed.contains(p)) stayed.add(p);
        break;
      }
    }
    if (stayed.isEmpty && wantCopy) return false;
    final tail = StringBuffer();
    if (stayed.isEmpty) {
      tail.write(order.isEmpty ? ' Nothing was moved.' : ' The pages moved before it were put back.');
    } else {
      tail.write(
        ' ${stayed.length == 1 ? '1 page stayed' : '${stayed.length} pages stayed'} in ${_placeName(toLoc)}'
        '${stalled ? ': ${_placeName(fromLoc)} was busy' : ''}.',
      );
      await _placeStranded(ids, stayed.toSet(), fromLoc, toLoc);
    }
    _touch(fromLoc);
    _touch(toLoc);
    _rebuildTree();
    throw NotebookException(
      '$failure$tail${notes.isEmpty ? '' : ' ${notes.join(' ')}'}',
      needsAction: stayed.isNotEmpty || notes.isNotEmpty,
    );
  }

  // After a rollback that left pages at the target: a page whose parent is in
  // the other location goes to the top level of its own (0124). Standalone
  // folders share one tree and keep theirs. A write that fails only logs.
  Future<void> _placeStranded(List<String> ids, Set<String> stayed, String fromLoc, String toLoc) async {
    if (_isStandaloneLoc(fromLoc) && _isStandaloneLoc(toLoc)) return;
    for (final id in ids) {
      final parent = _metas[id]?.parentId;
      if (parent == null || !ids.contains(parent) || stayed.contains(id) == stayed.contains(parent)) continue;
      final loc = stayed.contains(id) ? toLoc : fromLoc;
      try {
        final next = await _updateClosedPage(
          loc,
          id,
          (page) => page.withMeta(page.meta.withPlacement(parentId: null, order: _treeOf(loc).nextOrder(null))),
        );
        if (next != null) _metas[id] = next.meta;
      } on Object catch (e) {
        debugPrint('Placing page $id at the top level failed: $e');
      }
    }
  }

  // Step 3: the root's place under [parentId]. The write reads the root (the
  // header is in the file); a page that isn't downloaded is not read: its
  // placement is held until it is opened (N8). Throws a NotebookException when
  // the placement fails (the page stays where it was put).
  // [index], when given, is the place among its new siblings: for a held
  // placement it is the held order (no sibling is read to renumber them).
  // Returns true when the placement is held.
  Future<bool> _placeRoot(String toLoc, String root, String? parentId, int order, {int? index}) async {
    _heldPlacement.remove(root);
    final path = _storeOf(toLoc).pathFor(root);
    if (_isPlaceholder(path)) {
      _heldPlacement[root] = (parentId: parentId, order: index ?? order);
      return true;
    }
    final next = await _updateClosedPage(
      toLoc,
      root,
      (page) => page.withMeta(page.meta.withPlacement(parentId: parentId, order: order)),
    );
    if (next != null) _metas[root] = next.meta;
    return false;
  }

  // The copy path (rule 4): [ids] (the page, then its subpages) are copied to
  // [toLoc], each published exclusively and read back, with its images and
  // files. Nothing at [fromLoc] is changed or deleted: the originals stay,
  // listed as duplicates, until [deleteOriginals]. A failure removes only what
  // this copy published, and throws a NotebookException; the sources are then
  // as they were.
  Future<CopiedMove> _copyAcross(
    List<String> ids, {
    required String fromLoc,
    required String toLoc,
    required PageStore fromStore,
    required PageStore toStore,
    required String? parentId,
    required int rootOrder,
    required List<_Rekey> rekeys,
  }) async {
    String nameOf(String p) => '"${_titleOrUntitled(_metas[p]?.title ?? '')}"';
    // Every page is read before anything is written: one that can't be read (a
    // file that isn't downloaded) refuses the copy.
    final copiedText = <String>[];
    final originals = <NotedPage>[];
    final sourcePaths = <String>[];
    for (final p in ids) {
      try {
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
        sourcePaths.add(fromStore.pathFor(p));
      } on FileSystemException catch (e) {
        throw NotebookException(
          '${nameOf(p)} is not downloaded yet, so it can not be copied to ${_placeName(toLoc)}. '
          'Open it once to download it, then try again.${_osReason(e)}',
        );
      }
    }
    // Only the moved page's parent and order change; its subpages keep theirs.
    final moved = [
      for (var i = 0; i < originals.length; i++)
        i == 0
            ? originals[i].withMeta(originals[i].meta.withPlacement(parentId: parentId, order: rootOrder))
            : originals[i],
    ];
    // Only what this copy published: a page file it created (never one that was
    // already there) and the attachment files and folders it created.
    final written = <String>[];
    final writtenText = <String, String>{};
    final copies = <String, AttachmentCopy>{};
    final keptCopies = <String>[];
    // Removes only what this copy published, and only while it still holds
    // exactly that: a file that changed since is kept and reported.
    Future<void> removeCopies() async {
      for (final w in written) {
        try {
          final r = await _deleteIfUnchanged(toLoc, w, writtenText[w]!);
          if (!r.deleted && r.outcome != DeleteOutcome.absent) keptCopies.add('page file of $w');
        } on Object catch (e) {
          debugPrint('Removing copy of page $w failed: $e');
          keptCopies.add('page file of $w');
        }
        if (!await _mayRemoveIn(toLoc) || !await removeCreated(copies[w])) keptCopies.add('attachments of $w');
      }
    }

    String keptFilesNote() {
      final all = AttachmentCopy();
      for (final c in copies.values) {
        all.damagedKept.addAll(c.damagedKept);
        all.stillChanging.addAll(c.stillChanging);
      }
      final lines = _copyNotices(all, _placeName(toLoc), _placeName(fromLoc));
      return lines.isEmpty ? '' : ' ${lines.join(' ')}';
    }

    NotebookException withKept(NotebookException e) {
      final note =
          (keptCopies.isEmpty
              ? ''
              : ' Some of the copies made for the move in ${_placeName(toLoc)} were kept, because they '
                    'changed after they were made or could not be checked; you can delete what you do '
                    'not need.') +
          keptFilesNote();
      return note.isEmpty ? e : NotebookException('${e.message}$note', needsAction: true);
    }

    final identities = <String, ContentIdentity>{}; // by copy path
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
        if (await toStore.readText(p.id) != writePage(p)) {
          throw const NotebookException('A page was not copied correctly, so nothing was moved.');
        }
        // Its images and files go with it, unless the target was held since its
        // page file was written (checked with no await before the copy).
        if (_isLocked(toLoc)) throw NotebookException(_lockedMessage(toLoc));
        final c = copies[p.id] = AttachmentCopy();
        await _copyDir(
          _assetsDir(fromLoc, p.id),
          _assetsDir(toLoc, p.id),
          into: c,
          // A held source folder is only read: its leftovers are not swept.
          sweepSource: !_isLocked(fromLoc),
        );
        for (final f in c.verified) {
          identities[f.target.path] = await ContentIdentity.ofFile(f.target.path);
        }
      }
      // Kept changes go with their pages (the new key is written and read back).
      rekeys.addAll(await _rekeyBegin(ids, fromStore, toStore, fromLoc, toLoc));
    } on Object catch (e) {
      await removeCopies();
      if (e is NotebookException) throw withKept(e);
      debugPrint('Copying the page to its new place failed: $e');
      throw withKept(NotebookException('Could not move the page.${_osReason(e)}'));
    }
    await syncHook?.call('move-rekeyed', toStore.directory.path);

    // The copies are the pages now; each original stays, listed as a duplicate.
    final result = CopiedMove._(fromLoc, toLoc);
    for (var i = 0; i < ids.length; i++) {
      final p = ids[i];
      final oldKey = _key(sourcePaths[i]);
      _known.remove(oldKey);
      _pathId.remove(oldKey);
      _metas[p] = moved[i].meta;
      _loc[p] = toLoc;
      _knownUnreadable(fromLoc, oldKey, sourcePaths[i], 'duplicate page id $p');
      result._pages.add(
        _CopiedPage(
          p,
          _titleOrUntitled(originals[i].meta.title),
          sourcePaths[i],
          copiedText[i],
          writtenText[p]!,
          [
            for (final f in copies[p]?.verified ?? const <CopiedFile>[])
              _CopiedFile(f.source.path, f.target.path, identities[f.target.path]!),
          ],
        ),
      );
    }
    final all = [for (final c in copies.values) c];
    final differing = [for (final c in all) ...c.differing];
    final keptAside = [for (final c in all) ...c.keptAside];
    final damagedKept = [for (final c in all) ...c.damagedKept];
    final stillChanging = [for (final c in all) ...c.stillChanging];
    final attachmentsNote = differing.isEmpty && keptAside.isEmpty && damagedKept.isEmpty && stillChanging.isEmpty
        ? ''
        : ' ${_attachmentsNote(differing, keptAside, _placeName(toLoc), _placeName(fromLoc), damagedKept: damagedKept, stillChanging: stillChanging)}';
    final n = ids.length;
    result._message =
        '${n == 1 ? 'The page was' : '$n pages were'} copied to ${_placeName(toLoc)}, not moved: it is on another '
        'drive or in another cloud, where a file can not be renamed. The original${n == 1 ? '' : 's'} stay in '
        '${_placeName(fromLoc)} until you choose Delete the original.$attachmentsNote';
    return result;
  }

  /// Deletes the originals a copy-path move kept (B2): page by page, the page
  /// file and then its images and files, each only while it is unchanged and
  /// its copy still holds what the move put there, checked at the moment of
  /// deleting. Throws a [NotebookException] saying what was kept; returns what
  /// was done when everything went.
  Future<String> deleteOriginals(CopiedMove move) => _asUser(() => _deleteOriginals(move));

  Future<String> _deleteOriginals(CopiedMove move) async {
    if (move._running) throw const NotebookException('The originals are already being deleted.');
    move._running = true;
    try {
      final from = _placeName(move.fromLoc), to = _placeName(move.toLoc);
      final Directory fromDir, toDir;
      try {
        fromDir = _storeOf(move.fromLoc).directory;
        toDir = _storeOf(move.toLoc).directory;
      } on NotebookException catch (e) {
        throw NotebookException('The originals were kept. ${e.message}', needsAction: true);
      }
      final pending = [
        for (final p in move._pages)
          if (!p.finished) p,
      ];
      if (pending.isEmpty) return 'The originals were already deleted.';
      final kept = <String>[];
      var deleted = 0;
      for (var i = 0; i < pending.length; i++) {
        try {
          final why = await _underPair(fromDir, toDir, () => _deleteOneOriginal(move, pending[i]));
          if (why == null) {
            deleted++;
          } else {
            kept.add(why);
          }
        } on _LockTimeout catch (e) {
          final left = pending.length - i;
          final folder = FolderLocks.keyOf(Directory(e.path)) == FolderLocks.keyOf(toDir) ? to : from;
          kept.add('$folder is busy, so $left original${left == 1 ? ' was' : 's were'} kept.');
          break;
        } on NotebookException catch (e) {
          kept.add(e.message);
        } on Object catch (e) {
          if (_disposed) rethrow;
          debugPrint('Deleting an original failed: $e');
          kept.add('An original could not be deleted.${_osReason(e)}');
        }
      }
      if (kept.isEmpty) return deleted == 1 ? 'The original was deleted.' : 'The originals were deleted.';
      throw NotebookException(
        '${deleted == 0 ? '' : 'Deleted $deleted of ${pending.length}. '}${kept.join(' ')}',
        needsAction: true,
      );
    } finally {
      move._running = false;
    }
  }

  // One page's original and its files' (inside both folders' locks). Null when
  // all of them are gone; otherwise why something was kept.
  Future<String?> _deleteOneOriginal(CopiedMove m, _CopiedPage pg) async {
    _assertWritable(m.fromLoc);
    _assertWritable(m.toLoc);
    final from = _placeName(m.fromLoc), to = _placeName(m.toLoc);
    final dStore = _storeOf(m.toLoc);
    final name = '"${pg.title}"';
    final why = <String>[];
    // Which check kept the original last (a closure's answer can't be thrown).
    var copyProblem = '';

    // True only while [target] (the copy) is a file that holds what the move
    // put there. It catches every error (a throw would leave the original under
    // its drop name) and never hydrates a copy that isn't downloaded.
    bool copyHolds(String target, bool Function(String) holds) {
      try {
        if (_isPlaceholder(target)) {
          copyProblem = "The copy in $to isn't downloaded";
          return false;
        }
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.file || !holds(target)) {
          copyProblem = 'The copy in $to has changed since the move';
          return false;
        }
        return true;
      } on Object {
        copyProblem = 'The copy in $to could not be read';
        return false;
      }
    }

    if (!pg.pageGone) {
      final src = pg.sourcePath;
      if (FileSystemEntity.typeSync(src, followLinks: false) == FileSystemEntityType.notFound) {
        pg.pageGone = true;
      } else {
        await syncHook?.call('originals-before-delete', src);
        final want = utf8.encode(pg.copyText);
        copyProblem = '';
        final DeleteResult r;
        try {
          r = await deleteFileIfMatches(
            src,
            bytes: utf8.encode(pg.sourceText),
            stillRedundant: () => copyHolds(dStore.pathFor(pg.id), (d) => listEquals(File(_obs(d)).readAsBytesSync(), want)),
            beforeFinalCheck: (path) async => syncHook?.call('originals-before-final-check', path),
          );
        } on Object catch (e) {
          debugPrint('Deleting the original of page ${pg.id} failed: $e');
          return '$name: the original in $from could not be deleted, so it was kept.${_osReason(e)}';
        }
        if (r.deleted || r.outcome == DeleteOutcome.absent) {
          pg.pageGone = true;
        } else if (copyProblem.isNotEmpty) {
          return '$copyProblem, so the original of $name in $from was kept.';
        } else {
          return '$name changed in $from since the move, so its original was kept'
              '${r.keptPath == null ? '' : ' (a newer version is at ${r.keptPath})'}.';
        }
      }
      // The original is gone: it is no longer a duplicate.
      final key = _key(src);
      _known.remove(key);
      _pathId.remove(key);
      _dropUnreadable(m.fromLoc, src);
      _emitDeleted(src);
    }
    for (final f in pg.files) {
      if (f.gone) continue;
      if (FileSystemEntity.typeSync(f.source, followLinks: false) == FileSystemEntityType.notFound) {
        f.gone = true;
        continue;
      }
      copyProblem = '';
      try {
        // The check right before the unlink hashes the copy (an lstat-ed regular
        // file) with `ContentIdentity.ofFileSync` and compares it with the identity
        // recorded at the move: a stamp alone is passed by a same-size rewrite
        // with its time put back.
        final r = await deleteFileIfMatches(
          f.source,
          identity: f.identity,
          beforeFinalCheck: (path) async => syncHook?.call('originals-file-before-final-check', path),
          stillRedundant: () => copyHolds(
            f.target,
            (d) => ContentIdentity.ofFileSync(d) == f.identity,
          ),
        );
        if (r.deleted || r.outcome == DeleteOutcome.absent) {
          f.gone = true;
        } else {
          why.add(copyProblem.isNotEmpty ? copyProblem : 'a file changed in $from since the move');
        }
      } on Object catch (e) {
        debugPrint('Deleting the original ${f.source} failed: $e');
        why.add('a file in $from could not be deleted${_osReason(e)}');
      }
    }
    await _pruneEmptyDirs(_assetsDir(m.fromLoc, pg.id));
    if (why.isEmpty) return null;
    return 'The page file of $name was deleted in $from, but ${why.toSet().join('; ')}, so '
        '${why.length == 1 ? 'one image or file was' : '${why.length} images and files were'} kept.';
  }

  // Removes [d] and the empty folders under it. Never a folder that holds a file.
  static Future<void> _pruneEmptyDirs(Directory d) async {
    if (FileSystemEntity.typeSync(d.path, followLinks: false) != FileSystemEntityType.directory) return;
    try {
      for (final e in d.listSync(followLinks: false)) {
        if (e is Directory) await _pruneEmptyDirs(e);
      }
      if (d.listSync(followLinks: false).isEmpty) await removeFolderCoordinated(d);
    } on StorageBusy {
      // Busy: it stays, and the next clean-up tries again.
    } on FileSystemException {
      // Something is in it, or in use: it stays.
    }
  }

  /// Moves [id] and its subpages to another location: each page file is
  /// renamed (never replacing a file), page by page. Where it can't be renamed
  /// (another drive or cloud) the pages are copied and the originals kept, and
  /// the message offers [deleteOriginals]. A taken name stays, reported.
  Future<void> _moveAcross(String id, String toLoc, {String? parentId, int? index}) async {
    final fromLoc = _loc[id]!;
    _heldPlacement.remove(id); // a move of its own supersedes a held placement (N8)
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
    // The files as they were named at the source, for step 4's checks.
    final sourcePaths = [for (final p in ids) fromStore.pathFor(p)];
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
      if (FolderLocks.keyOf(fromStore.directory) == FolderLocks.keyOf(toStore.directory)) {
        throw const NotebookException('These are the same folder.');
      }
      // Step 0, 1: what is checked is memory and file metadata; no page file
      // is read (P).
      try {
        await _landChain;
      } on Object {
        // A failed landing is reported by its own retry.
      }
      for (final p in ids) {
        final path = fromStore.pathFor(p);
        if (_pathId[_key(path)] != p || _loc[p] != fromLoc) {
          throw NotebookException(
            '"${_titleOrUntitled(_metas[p]?.title ?? '')}" is not listed at its file in ${_placeName(fromLoc)}, so nothing was moved.',
          );
        }
        // A chosen file (0149) that isn't the file last scanned, read or saved
        // may be damaged or held as another page's: it isn't moved.
        if (unreadable.any((u) => _key(u.path) == _key(path)) ||
            (_adoptedFiles[p] != null && _fileStamps[_key(path)] != fileStamp(path))) {
          throw NotebookException(
            '"${_titleOrUntitled(_metas[p]?.title ?? '')}" is listed as unreadable in ${_placeName(fromLoc)}, so nothing was moved.',
          );
        }
        // Existence, not the stamp: where no stamp can be taken it only says "read
        // it" (S).
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
          throw NotebookException(
            'The file of "${_titleOrUntitled(_metas[p]?.title ?? '')}" is missing from ${_placeName(fromLoc)}, so nothing was moved.',
          );
        }
      }
      final rootOrder = _treeOf(toLoc).nextOrder(parentId);
      rekeys.addAll(await _rekeyBegin(ids, fromStore, toStore, fromLoc, toLoc));
      await syncHook?.call('move-rekeyed', toStore.directory.path);
      final notes = <String>[];
      // H: attachments that are placeholders are downloaded before the locks
      // when the folders aren't in one sync root; within one root nothing is
      // read. A page that is a placeholder across roots takes the copy path
      // (path decision, step 0).
      final sameRoot = _sameSyncRoot(fromStore.directory.path, toStore.directory.path);
      final hydrated = <String>{};
      if (!sameRoot) {
        for (final p in ids) {
          hydrated.addAll(await _hydrateFolder(_assetsDir(fromLoc, p), toStore.directory.path));
        }
      }
      final pageCopy = !sameRoot && ids.any((p) => _isPlaceholder(fromStore.pathFor(p)));
      if (!forceCopyMoveForTest && !pageCopy && await _renameTree(
        ids,
        fromLoc: fromLoc,
        toLoc: toLoc,
        fromStore: fromStore,
        toStore: toStore,
        atDest: atDest,
        notes: notes,
        hydrated: hydrated,
      )) {
        // Step 3: the root's place. A failure leaves the pages where they are.
        _touch(fromLoc);
        _touch(toLoc);
        _rebuildTree();
        movedFully = true;
        String? placeFailed;
        var held = false;
        try {
          held = await _placeRoot(toLoc, id, parentId, rootOrder, index: index);
        } on Object catch (e) {
          debugPrint('Placing the moved page failed: $e');
          placeFailed = 'it could not be put at that position.${e is NotebookException ? '' : _osReason(e)}';
        }
        _rebuildTree();
        if (placeFailed != null) notes.add(placeFailed);
        // A note that starts with a capital is a sentence of its own; one that
        // doesn't ("it could not be put at that position") continues "but".
        final first = notes.isEmpty ? '' : notes.first;
        notice = notes.isEmpty
            ? null
            : NotebookException(
                'The page was moved${RegExp(r'^[a-z]').hasMatch(first) ? ', but' : '.'} ${notes.join(' ')}',
                needsAction: true,
              );
        if (index != null && placeFailed == null && !held) await move(id, parentId: parentId, index: index);
        if (notice != null) throw notice;
        return;
      }
      // The first page can't be renamed (another drive or cloud): the move
      // copies, and the originals stay until the user deletes them (rule 4).
      await _settleRekeys(rekeys, const {});
      rekeys.clear();
      final copy = await _copyAcross(
        ids,
        fromLoc: fromLoc,
        toLoc: toLoc,
        fromStore: fromStore,
        toStore: toStore,
        parentId: parentId,
        rootOrder: _treeOf(toLoc).nextOrder(parentId),
        rekeys: rekeys,
      );
      atDest.addAll(ids);
      _touch(fromLoc);
      _touch(toLoc);
      _rebuildTree();
      movedFully = true;
      String? placeFailed;
      if (index != null) {
        try {
          await move(id, parentId: parentId, index: index);
        } on Object catch (e) {
          debugPrint('Placing the copied page failed: $e');
          placeFailed = 'it could not be put at that position.${e is NotebookException ? '' : _osReason(e)}';
        }
      }
      await syncHook?.call('move-copy-placed', toStore.directory.path);
      copy._recordCopyText(_known[_key(toStore.pathFor(id))]);
      notice = OriginalsKeptException(
        '${copy._message}${placeFailed == null ? '' : ' Also, $placeFailed'}',
        copy,
      );
      throw notice;
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
      // Step 4: whatever the watchers held back while the pages were busy is
      // looked at now, at both ends. A moved page with a carried stamp isn't read.
      try {
        for (final path in [
          ...sourcePaths,
          for (final p in ids)
            if (_loc[p] case final l?) _storeOf(l).pathFor(p),
        ]) {
          if (_disposed) break;
          await checkFile(path);
        }
      } on Object catch (e) {
        debugPrint('Checking the moved pages failed: $e');
      }
      // A page whose read failed (held by a sync client) still arrived: told
      // without an identity, the consumer reads it.
      // Only a page still listed there, with its file: not one rolled back, nor
      // one whose file sync deleted.
      for (final e in _movePublish.entries) {
        if (_pathId[e.key] != null && File(e.value).existsSync()) _emitPublishedUnread(e.value);
      }
      _movePublish.clear();
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
    } on StorageBusy {
      throw const NotebookException('Could not create the binder: the folder is busy. Try again.');
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
        if (await dir.exists() && await dir.list().isEmpty) await removeFolderCoordinated(dir);
      } on StorageBusy catch (e) {
        debugPrint('The folder is busy; not removing the empty binder folder: ${e.message}');
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
    if (_pullOnly(root)) throw NotebookException(pullOnlyMessageFor(root));
    _assertTested(root);
    final builtin = settings?.defaultBinderFolder == null || _key(root) == _key(builtinBinderFolderPath);
    try {
      if (builtin) {
        await createFolderCoordinated(Directory(root));
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
        await createFolderCoordinated(Directory(path), recursive: false);
        // A bookmark of its own, on record before binders.json lists the binder (R5.3).
        await icloud?.bookmarkCreated(path);
        return path;
      }
    } on StorageBusy {
      throw const NotebookException('Could not create the binder: the folder is busy. Try again.');
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
    final oldPage = s.defaultPageFolder;
    s.defaultPageFolder = normal;
    if (oldPage != null) _cloudReleased(oldPage);
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
    final oldBinders = s.defaultBinderFolder;
    s.defaultBinderFolder = normal;
    if (oldBinders != null) _cloudReleased(oldBinders);
    notifyListeners();
  }

  /// Moves the page [id] and its subpages to the standalone folder [path]
  /// (made a standalone folder in use), as a top-level page there. Uses the
  /// same copy, verify, delete algorithm as other moves; throws a
  /// [NotebookException] on failure with the sources left in place. A binder
  /// folder is refused. Returns false if the page is in that folder already.
  Future<bool> moveToFolder(String id, String path) => _asUser(() => _moveToFolder(id, path));

  Future<bool> _moveToFolder(String id, String path) async {
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
      throw NotebookException(pullOnlyMessageFor(path));
    }
    // Nor in an iCloud root that is not tested yet (R5.9).
    if (!_mayTouch(path) && !await BinderStore(Directory(path)).file.exists()) {
      throw NotebookException(_untestedMessage(path));
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
    final read = await _lockRunUngated(Directory(path), () => _binderStore(Directory(path)).read());
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
      final section = await _openBinder(path, create: !found, createFolder: !found, sweep: !found, expectId: expectId);
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
          ((now.binder != null && now.binder!.id != expectId) ||
              now.other != null ||
              now.status == BinderStatus.unavailable)) {
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
      throw NotebookException(_pullOnly(known) ? pullOnlyMessageFor(known) : 'That folder is not available.');
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
      _heldPlacement.remove(id);
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
    _cloudReleased(path);
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
        _recordStamp(_key(e.path), e.stamp);
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

  // Template work (the listing and its sweep, Save as template into a binder,
  // the assets read for a new page, a delete and its cleanup) runs one step
  // after another, so this device's sweep never takes its own in-flight aside
  // and a page is never made from an assets folder a delete is emptying.
  Future<void> _templateChain = Future<void>.value();

  Future<T> _templateTurn<T>(Future<T> Function() job) {
    final run = _templateChain.then((_) => job());
    _templateChain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Runs at each binder gate of the template work, named by step ('sweep',
  /// 'saveTemplate', 'saveAssets', 'copyAssets', 'delete', 'assetsSweep',
  /// 'assetDelete', 'dirDelete'), just before the gate is checked. For tests.
  @visibleForTesting
  Future<void> Function(String step)? templateStepHook;

  // What a binder's template work started with: the section and the id
  // recorded for its folder.
  _TemplateSnap _templateSnap(String? binderPath) => binderPath == null
      ? (section: null, id: null)
      : (section: _binders[binderPath], id: _binderIds[_key(binderPath)]);

  // Why template work in [binderPath]'s templates folder must not write now,
  // or null. Synchronous: called right before the step it guards, so today's
  // binder state is what is written into. The app-wide folder (null) needs no
  // gate.
  String? _templateGateProblem(String? binderPath, _TemplateSnap snap) {
    if (binderPath == null) return null;
    final s = _binders[binderPath];
    if (s == null || !identical(s, snap.section) || _binderIds[_key(binderPath)] != snap.id) {
      return 'The binder changed; nothing was written.';
    }
    if (!s.available || _isLocked(binderPath)) return _lockedMessage(binderPath);
    return null;
  }

  void _templateGate(String? binderPath, _TemplateSnap snap) {
    final p = _templateGateProblem(binderPath, snap);
    if (p != null) throw NotebookException(p);
  }

  // One mutating step of the template store of [binderPath] (T2): the hook
  // fires first, outside any turn; then, for a binder's store, the step takes
  // its own short turn at the binder's folder, where the binder file is
  // checked (G2), then the template gate, then [job]. The app-wide store
  // (null) runs [job] after the hook.
  Future<T> _templateLocked<T>(String? binderPath, _TemplateSnap snap, String step, Future<T> Function() job) async {
    await templateStepHook?.call(step);
    if (binderPath == null) return job();
    return _lockRun(Directory(binderPath), () async {
      _templateGate(binderPath, snap);
      return job();
    });
  }

  /// The templates of [kind] that can be used in the binder [binderPath]
  /// (null: not in a binder): the binder's own and the app-wide ones. Files
  /// that can't be read are listed apart and never touched. The listing puts
  /// back what a crashed delete left only where it may write (not in a
  /// pull-only, locked or replaced binder).
  Future<TemplateListing> listTemplates(TemplateKind kind, {String? binderPath}) {
    final snap = _templateSnap(binderPath);
    return _templateTurn(() => _listTemplatesNow(kind, binderPath, snap));
  }

  Future<TemplateListing> _listTemplatesNow(TemplateKind kind, String? binderPath, _TemplateSnap snap) async {
    final items = <TemplateItem>[];
    final bad = <UnreadableTemplateItem>[];
    final scopes = <String?>[
      if (binderPath != null && kind == TemplateKind.page) binderPath,
      if (appTemplatesDirectory != null) null,
    ];
    for (final scope in scopes) {
      final dir = _templatesDirFor(scope);
      final sweep = _sweepOff == 0 && !_pullOnly(dir.path) && _mayTouch(dir.path);
      List<TemplateEntry> entries;
      if (sweep && scope != null) {
        // The sweep is decided inside its own turn at the binder's folder; a
        // refused turn lists the store read-only, its leftovers as unreadable.
        try {
          entries = await _templateLocked(scope, snap, 'sweep', () => TemplateStore(dir).scan(sweep: true));
        } on NotebookException {
          entries = await TemplateStore(dir).scan(sweep: false);
        }
      } else {
        entries = await TemplateStore(dir).scan(sweep: sweep);
      }
      for (final e in entries) {
        switch (e) {
          case ReadableTemplate():
            if (e.template.kind == kind) items.add(TemplateItem(e.template, e.path, scope, e.identity, binderId: snap.id));
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
    final into = inBinder ? binder : null;
    final snap = _templateSnap(into);
    if (into == null) return _savePageAsTemplateNow(pageId, loc, name, null, snap);
    return _templateTurn(() => _savePageAsTemplateNow(pageId, loc, name, into, snap));
  }

  Future<NotedTemplate> _savePageAsTemplateNow(
    String pageId,
    String loc,
    String name,
    String? binder,
    _TemplateSnap snap,
  ) async {
    final dir = _templatesDirFor(binder);
    await flush();
    final page = await _loadPage(_storeOf(loc), pageId);
    final title = page.meta.title.trim();
    final template = NotedTemplate.forPage(
      name: name.trim().isNotEmpty ? name.trim() : (title.isEmpty ? 'Untitled page' : title),
      page: page,
    );
    await _templateLocked(binder, snap, 'saveTemplate', () => _saveTemplate(dir, template));
    try {
      // The copy is long, so it runs outside the lock: the binder file is
      // checked at the folder's turn first, then the gate, with no await
      // between that and the copy.
      await templateStepHook?.call('saveAssets');
      if (binder != null && !await _binderGate(binder) && !_isLocked(binder)) {
        throw const NotebookException(binderUnreadableNowMessage);
      }
      _templateGate(binder, snap);
    } on NotebookException catch (e) {
      throw NotebookException('${e.message} The template was saved without its images and files.');
    }
    await _copyDirNotify(
      _assetsDir(loc, pageId),
      _templateAssets(dir, template.id, pageId),
      'the template',
      'the page',
      sourceLoc: loc,
    );
    return template;
  }

  /// Where template [templateId] in [dir] keeps the images and files of its
  /// page [pageId]: `<templateId>.assets/<pageId>/` beside the template file.
  static Directory _templateAssets(Directory dir, String templateId, String pageId) => Directory(
    '${dir.path}${Platform.pathSeparator}$templateId.assets${Platform.pathSeparator}$pageId',
  );

  static final RegExp _plainName = RegExp(r'^[A-Za-z0-9_-]+$');

  // [_templateAssets] only when the names are one plain name each and it
  // resolves to `<dir>/<id>.assets/<page id>`: an id read from a template file
  // is never trusted as a path. Null otherwise.
  static Directory? _safeTemplateAssets(Directory dir, String templateId, String pageId) {
    if (!_plainName.hasMatch(templateId) || !_plainName.hasMatch(pageId)) return null;
    final d = _templateAssets(dir, templateId, pageId);
    return _key(d.parent.parent.absolute.path) == _key(dir.absolute.path) ? d : null;
  }

  /// Copies the images and files of template page [fromId] into the assets
  /// folder of the new page [toId] in [loc]. The template is looked for in
  /// the binder's templates (if [loc] is a binder) and the app-wide ones.
  Future<void> _copyTemplateAssets(NotedTemplate template, String fromId, String loc, String toId) {
    final snap = _templateSnap(_binders.containsKey(loc) ? loc : null);
    return _templateTurn(() async {
      final binder = _binders.containsKey(loc) ? loc : null;
      final dirs = [
        if (binder != null) _templatesDirFor(binder),
        ?appTemplatesDirectory,
      ];
      for (final d in dirs) {
        final src = _safeTemplateAssets(d, template.id, fromId);
        if (src != null && await src.exists()) {
          var sweepSource = true;
          final own = binder != null && d.path == _templatesDirFor(binder).path;
          if (own) await templateStepHook?.call('copyAssets');
          // Into a binder folder: its binder file is checked at the folder's
          // turn, inside this job (a hold set while it waited is seen), and
          // nothing is copied into a held folder.
          if (binder != null && (!await _binderGate(binder) || _isLocked(binder))) {
            throw NotebookException(_isLocked(binder) ? _lockedMessage(binder) : binderUnreadableNowMessage);
          }
          // A binder that changed since is only read, never swept.
          if (own) sweepSource = _templateGateProblem(binder, snap) == null && !_isLocked(binder);
          await _copyDirNotify(src, _assetsDir(loc, toId), 'the new page', 'the template', sweepSource: sweepSource);
          return;
        }
      }
    });
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
      await _copyDirNotify(
        _assetsDir(path, id),
        _templateAssets(dir, template.id, id),
        'the template',
        'the binder',
        sourceLoc: path,
      );
    }
    return template;
  }

  Future<void> _saveTemplate(Directory dir, NotedTemplate template) async {
    try {
      await TemplateStore(dir).save(template);
    } on StorageBusy {
      throw const NotebookException('Could not save the template: the folder is busy. Try again.');
    } on FileSystemException catch (e) {
      throw NotebookException('Could not save the template: ${e.message}');
    }
  }

  /// Deletes a template file found by [listTemplates], only if it is still the
  /// file that was listed, then the files of its assets folder that are
  /// verified attachments, unless another copy of the template may need them.
  Future<void> deleteTemplate(TemplateItem item) async {
    final inBinder = item.binderPath;
    if (inBinder != null && _binders.containsKey(inBinder) && _isLocked(inBinder)) throw NotebookException(_lockedMessage(inBinder));
    if (_pullOnly(File(item.path).parent.path)) throw NotebookException(pullOnlyMessageFor(File(item.path).parent.path));
    final now = _templateSnap(inBinder);
    // What was listed is judged against the binder as it was listed.
    final snap = inBinder == null ? now : (section: now.section, id: item.binderId);
    return _templateTurn(() => _deleteTemplateNow(item, snap));
  }

  Future<void> _deleteTemplateNow(TemplateItem item, _TemplateSnap snap) async {
    final binder = item.binderPath;
    final dir = _templatesDirFor(binder);
    try {
      final r = await _templateLocked(binder, snap, 'delete', () => TemplateStore(dir).delete(item.path, item.identity));
      if (r.outcome == DeleteOutcome.changed || r.outcome == DeleteOutcome.changedKept) {
        throw const NotebookException('The template changed since it was listed; it was not deleted.');
      }
      try {
        await _cleanTemplateAssets(dir, item, binder, snap);
      } on NotebookException {
        // The file is gone and the picker drops it; what is left stays.
        _templateNotice('The template was deleted; the binder changed, so its files were kept.');
      }
    } on FileSystemException catch (e) {
      throw NotebookException('Could not delete the template: ${e.message}');
    }
  }

  void _templateNotice(String text) {
    if (!_notices.isClosed) _notices.add(text);
  }

  static const String _assetsKeptShared =
      'The template was deleted. Its files were kept because another copy of the template may need them.';

  // Whether the assets of template [id] may still be needed after its file
  // was deleted: another readable template with the id, any
  // template file that can't be read (its id can't be established), a
  // set-aside leftover, or any other file named from the id. A fresh scan, no
  // sweep. Fills [known] with the stamp (size and modified time) of every
  // template file, taken before the scan reads them: a file that changes after
  // that no longer matches its stamp.
  Future<bool> _templateAssetsShared(Directory dir, String id, Map<String, String> known) async {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && e.path.endsWith(templateExtension)) known[_key(e.path)] = _stamp(e);
      }
    } on FileSystemException {
      return true;
    }
    for (final e in await TemplateStore(dir).scan()) {
      if (e is UnreadableTemplate) return true;
      if (e is ReadableTemplate && e.template.id == id) return true;
    }
    return _templateSurvivorNow(dir, id, known);
  }

  static String _stamp(File f) {
    final st = f.statSync();
    if (st.type != FileSystemEntityType.file) throw const FileSystemException('not a file');
    return [st.size, st.modified.microsecondsSinceEpoch].join(':');
  }

  // The synchronous listing of the folder: a leftover, a file named from the
  // id (such as `<id>.notedtemplate.tmp`; folders are not files), a template
  // file that was not there at the scan (a copy synced back to the deleted
  // path included) or one whose stamp changed since, or can't be read now: a
  // template replaced by a copy of this one is a survivor too.
  bool _templateSurvivorNow(Directory dir, String id, Map<String, String> known) {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final n = _baseName(e.path);
        if (n.endsWith(asideSuffix) || n.endsWith(verifiedSuffix) || n.startsWith(id)) return true;
        if (n.endsWith(templateExtension)) {
          final was = known[_key(e.path)];
          if (was == null || was != _stamp(e)) return true;
        }
      }
    } on FileSystemException {
      return true; // can't tell: the assets stay
    }
    return false;
  }

  // Removes `<template id>.assets` after the template file is gone: first the
  // leftovers of stopped writes are judged as attachments, then each file
  // named by its hash that still holds it goes through [deleteFileIfMatches]
  // (anything else stays), then the emptied folders, bottom-up and
  // non-recursively. Every step passes the binder gate, and every file delete
  // the survivor check again.
  Future<void> _cleanTemplateAssets(Directory dir, TemplateItem item, String? binder, _TemplateSnap snap) async {
    final id = item.template.id;
    final assets = Directory('${dir.path}${Platform.pathSeparator}$id.assets');
    if (!_plainName.hasMatch(id) || _key(assets.parent.absolute.path) != _key(dir.absolute.path)) return;
    if (!_mayTouch(dir.path)) return; // an iCloud root not yet tested: nothing is swept or deleted
    if (!await assets.exists()) return;
    final known = <String, String>{};
    if (await _templateAssetsShared(dir, id, known)) {
      _templateNotice(_assetsKeptShared);
      return;
    }
    // Each step is its own short turn at the binder's folder (T2): a save of
    // the folder waits for one step at most, and a hold set between steps is
    // seen by the next.
    final dirs = <Directory>[assets];
    await _templateLocked(binder, snap, 'assetsSweep', () => sweepAttachmentLeftovers(assets, AttachmentCopy()));
    await for (final e in assets.list(recursive: true, followLinks: false)) {
      if (e is Directory) dirs.add(e);
    }
    for (final d in dirs.skip(1)) {
      await _templateLocked(binder, snap, 'assetsSweep', () => sweepAttachmentLeftovers(d, AttachmentCopy()));
    }
    final files = <File>[];
    await for (final e in assets.list(recursive: true, followLinks: false)) {
      if (e is File) files.add(e);
    }
    final kept = <String>[];
    var shared = false;
    String shown(File f) => f.path.substring(assets.path.length + 1);
    for (final f in files) {
      final hash = attachmentNameHash(_baseName(f.path));
      if (hash == null) {
        kept.add(shown(f));
        continue;
      }
      final check = await checkAttachmentFile(f, hash, 0);
      if (check.state != AttachmentState.ok) {
        kept.add(shown(f));
        continue;
      }
      final length = await f.length();
      final r = await _templateLocked(binder, snap, 'assetDelete', () async {
        if (_templateSurvivorNow(dir, id, known)) return null;
        return deleteFileIfMatches(f.path, identity: ContentIdentity(length, hash));
      });
      if (r == null) {
        shared = true;
        break;
      }
      if (!r.deleted && r.outcome != DeleteOutcome.absent) kept.add(shown(f));
    }
    if (shared) {
      _templateNotice(_assetsKeptShared);
      return;
    }
    dirs.sort((a, b) => b.path.length.compareTo(a.path.length)); // the deepest first
    for (final d in dirs) {
      await _templateLocked(binder, snap, 'dirDelete', () async {
        try {
          await removeFolderCoordinated(d);
        } on StorageBusy catch (e) {
          // Busy: the folder stays, and the next clean-up tries again.
          debugPrint('The folder is busy; not removing ${d.path}: $e');
        } on FileSystemException {
          // Not empty: what is in it is reported above.
        }
      });
    }
    if (kept.isNotEmpty) {
      _templateNotice('The template was deleted; some of its files were kept: ${kept.join(', ')}.');
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
  }) => _asUser(
    () => _createPageFromTemplate(
      template,
      parentId: parentId,
      binderPath: binderPath,
      folderPath: folderPath,
      focusTitle: focusTitle,
    ),
  );

  Future<String> _createPageFromTemplate(
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
    if (_pullOnly(path)) throw NotebookException(pullOnlyMessageFor(path));
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
    _assertTested(path);
    final dir = Directory(path);
    final binders = BinderStore(dir);
    final made = template.instantiateBinder();
    final pages = storeFactory(dir);
    final written = <NotedPage>[];
    var binderWritten = false;
    try {
      final binderIdentity = _identityOf(() => made.binder.write());
      // C: published without replacing, under the folder's lock.
      final created = await _lockRunUngated(dir, () async {
        if (!await binders.file.exists()) {
          final sw = await binders.sweepLeftovers(restore: false);
          if (sw.copies.any((c) => c.isTemp && c.binder != null)) return null;
        }
        final r = await binders.create(made.binder);
        if (r == BinderCreated.created) {
          _emitPublished(binders.file.path, binderIdentity, () => made.binder.write());
        }
        return r;
      });
      if (created == null) {
        throw const NotebookException(
          'That folder holds a copy of a binder file from an interrupted change. '
          'Open the folder as a binder to put it back first.',
        );
      }
      if (created == BinderCreated.exists) {
        throw const NotebookException(
          'That folder already has a binder. Choose an empty folder for the new binder.',
        );
      }
      binderWritten = true;
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
        final src = _safeTemplateAssets(templates, template.id, template.pages[i].id);
        if (src == null) continue;
        await _copyDirNotify(
          src,
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
          // Under the lock, with its report (C).
          final r = await _lockRunUngated(dir, () async {
            final r = await deleteFileIfUnchanged(binders.file.path, utf8.encode(made.binder.write()));
            if (r.deleted) _emitDeleted(binders.file.path);
            return r;
          });
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
    // Cover changes that aren't written yet go with the binder: asked first,
    // naming them (D3). What the open cover has typed counts.
    if (_coverTypingPath == path) _takeCoverTyping();
    // One bounded try first: only what is still pending is asked about.
    if (_coverPending[_key(path)]?.isNotEmpty ?? false) {
      await _tryCovers(path).timeout(const Duration(seconds: 3), onTimeout: () => false);
      if (_disposed || !identical(_binders[path], section)) return;
    }
    final unsaved = List<CoverChange>.of(_coverPending[_key(path)] ?? const <CoverChange>[]);
    for (final c in unsaved) {
      if (!await _ask(UserQuestion.discardCoverChanges, _coverLabel(section, c))) {
        throw const LeaveCancelled();
      }
      if (_disposed || !identical(_binders[path], section)) return;
    }
    // A held folder's kept changes stay in recovery; the user is told first.
    final keptPages = section._hold != null ? heldPagesFor(path) : 0;
    if (keptPages > 0) {
      if (!await _ask(UserQuestion.removeWithKeptChanges, '$keptPages')) throw const LeaveCancelled();
      if (_disposed || !identical(_binders[path], section)) return;
    }
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
      _heldPlacement.remove(id);
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
    _coverPending.remove(_key(path));
    _coverHalted.remove(_key(path));
    _coverTimers.remove(_key(path))?.cancel();
    _asideTimers.remove(_key(path))?.cancel();
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
    _cloudReleased(path);
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

  /// Changes cover fields of the binder (D1). The change is recorded at once, as
  /// a delta that is written to `noted-binder.json` as it is on disk and kept
  /// until it lands or the user discards it. Only the fields whose text differs
  /// from the comparison base are recorded: [applied], the values the cover's
  /// fields were last brought in line with (or the shown binder when it is not
  /// given), with this folder's unwritten cover changes laid over it. [shownId]
  /// is the id of the binder the cover showed.
  ///
  /// Returns whether nothing is left unwritten for this change.
  Future<bool> updateBinder(
    String path, {
    String? title,
    String? description,
    String? owner,
    String? color,
    CoverText? applied,
    String? shownId,
  }) async {
    final s = _binders[path];
    if (s == null || _pullOnly(path)) return false;
    final key = _key(path);
    final shown = shownId ?? s.saved?.id;
    final shownBinder = s.binder;
    final base = applied ??
        (shownBinder == null
            ? null
            : (title: shownBinder.title, description: shownBinder.description, owner: shownBinder.owner));
    // B: the base with the unwritten cover changes of this binder laid over it.
    final over = <String, String>{};
    for (final c in _coverPending[key] ?? const <CoverChange>[]) {
      if (c.forId == null || shown == null || c.forId == shown) over.addAll(c.fields);
    }
    final fields = <String, String>{};
    void take(String field, String? text, String? from) {
      if (text == null) return;
      if ((over[field] ?? from) != text) fields[field] = text;
    }

    take('title', title, base?.title);
    take('description', description, base?.description);
    take('owner', owner, base?.owner);
    take('color', color, shownBinder?.color);
    if (fields.isEmpty) return !(_coverPending[key]?.isNotEmpty ?? false);
    Binder apply(Binder x) {
      var y = x;
      for (final e in fields.entries) {
        y = switch (e.key) {
          'title' => y.withTitle(e.value),
          'description' => y.withDescription(e.value),
          'owner' => y.withOwner(e.value),
          _ => y.withColor(e.value),
        };
      }
      return y;
    }

    final change = CoverChange(
      BinderDelta(binderId: _binderIds[key] ?? shown, apply: apply, kind: BinderDeltaKind.cover),
      fields,
      shown,
    );
    // Before the first await: no `_save` sees the change gone before it lands.
    (_coverPending[key] ??= []).add(change);
    if (s.saved != null) {
      s.lastEdited = now();
      _recompute(s);
    }
    notifyListeners();
    await _tryCovers(s.path);
    return !(_coverPending[key]?.contains(change) ?? false);
  }

  /// The cover changes of binder [path] that are not written yet, for the
  /// binder shown there.
  List<CoverChange> coverPendingFor(String path) {
    final shown = _binders[path]?.saved?.id;
    return [
      for (final c in _coverPending[_key(path)] ?? const <CoverChange>[])
        if (shown == null || c.forId == null || c.forId == shown) c,
    ];
  }

  /// Whether the cover of [path] has a change that is refused or waiting, and
  /// can be discarded.
  bool coverNotSaved(String path) => (_coverPending[_key(path)] ?? const <CoverChange>[]).any((c) => c.stuck);

  /// Names a cover change for a question: the binder it is for (the section's
  /// when it is that one) and the fields.
  String _coverLabel(BinderSection? s, CoverChange c) {
    final own = s != null && s.saved?.id == c.forId;
    final who = own ? 'binder "${s.title}"' : 'a binder that was in this folder';
    return '$who (${c.what})';
  }

  /// Discard on the cover: asks first, naming the changes, like the other
  /// places that drop them. False if the user chose to keep them.
  Future<bool> confirmDiscardCoverChanges(String path) async {
    final s = _binders[path];
    // The list the user is asked about is the list that goes: a change added
    // while the question is open is kept.
    final asked = List<CoverChange>.of(_coverPending[_key(path)] ?? const <CoverChange>[]);
    for (final c in asked) {
      if (!await _ask(UserQuestion.discardCoverChanges, _coverLabel(s, c))) return false;
    }
    await discardCoverChanges(path, only: asked);
    return true;
  }

  /// Gives up the unwritten cover changes of binder [path] (Discard). The temps
  /// they wrote are removed only while the binder's file is there and readable;
  /// any other stays listed with the copies of the binder file.
  Future<void> discardCoverChanges(String path, {List<CoverChange>? only}) async {
    final key = _key(path);
    // Every unwritten change of the folder goes (or just [only]), also those
    // typed for a binder that was here before: the row that offers Discard says so.
    final drop = List<CoverChange>.of(only ?? _coverPending[key] ?? const <CoverChange>[]);
    if (drop.isEmpty) return;
    final list = _coverPending[key];
    list?.removeWhere(drop.contains);
    if (list != null && list.isEmpty) {
      _coverPending.remove(key);
      _coverHalted.remove(key);
      _coverTimers.remove(key)?.cancel();
      _coverDelay.remove(key);
    }
    final s = _binders[path];
    if (s != null) _recompute(s);
    notifyListeners();
    final store = _binderStore(Directory(path));
    await _lockRunUngated(Directory(path), () async {
      for (final c in drop) {
        await _removeTemps(store, key, c.delta);
      }
      if (s != null) await _listCopiesLocked(s, store);
    });
    if (!_disposed) notifyListeners();
  }

  // Takes the typing of the open cover into the pending changes (D2): D1 against
  // the comparison base, so what is already taken records nothing. Reads the
  // cover synchronously; never closes it.
  void _takeCoverTyping() {
    final read = _coverTyping;
    final path = _coverTypingPath;
    if (read == null || path == null) return;
    final t = read();
    if (t == null) return;
    unawaited(
      updateBinder(
        path,
        title: t.text.title,
        description: t.text.description,
        owner: t.text.owner,
        applied: t.applied,
        shownId: t.shownId,
      ),
    );
  }

  /// Tells the notebook what the open cover [path] has typed and not sent. The
  /// cover calls it with a function that reads its fields at once, and removes
  /// it with [unregisterCoverTyping].
  void registerCoverTyping(String path, CoverTyping? Function() read) {
    _coverTypingPath = path;
    _coverTyping = read;
  }

  void unregisterCoverTyping(String path) {
    if (_coverTypingPath != path) return;
    _coverTypingPath = null;
    _coverTyping = null;
  }

  /// The app is being hidden (on a phone, the last chance): takes what the open
  /// cover has typed, tries each pending cover change once, then writes
  /// unsaved edits as [flush] does.
  Future<void> coverHidden() async {
    _takeCoverTyping();
    _queueCoverTries(force: true);
    await flush();
  }

  // Queues one more try of each folder's pending cover changes. A folder whose
  // last try ended "keeps changing" waits for the app coming back, the binder
  // coming back, quit or hide ([force]); folder events and the folder check don't
  // lift the halt, so the temps it leaves stay few (L8).
  void _queueCoverTries({required bool force}) {
    for (final key in _coverPending.keys.toList()) {
      if (_coverHalted.contains(key)) {
        if (!force) continue;
        _coverHalted.remove(key);
      }
      final s = _binders.values.where((b) => _key(b.path) == key).firstOrNull;
      if (s != null) unawaited(_tryCovers(s.path).then((_) {}, onError: (_) {}));
    }
  }

  /// Tries the pending cover changes again, as the app coming back to the front
  /// does; it lifts a halt after "keeps changing".
  void retryCovers() {
    if (_disposed) return;
    _queueCoverTries(force: true);
  }

  // Tries the cover changes of folder [path] once, on the save chain (L1).
  Future<bool> _tryCovers(String path) =>
      _afterSaves(() => _landCovers(path), what: 'binder cover edit of $path').catchError((Object e) {
        debugPrint('Saving the cover of $path failed: $e');
        return false;
      });

  // Writes the pending cover changes of folder [path], oldest first, while D3's
  // condition holds: the folder's binder is available and has the change's id.
  // A refusal keeps the change and stops. True when none is left.
  Future<bool> _landCovers(String path) async {
    final key = _key(path);
    var reconcile = false;
    var refused = false;
    var halted = false;
    for (final c in List<CoverChange>.of(_coverPending[key] ?? const [])) {
      if (_disposed) return false;
      final s = _binders[path];
      if (s == null || !s.available || _isLocked(path) || s.saved == null) {
        c.stuck = true;
        break;
      }
      final id = c.delta.binderId ?? _binderIds[key] ?? c.delta.temps.firstOrNull?.binderId;
      if (id == null || s.saved!.id != id) {
        c.stuck = true;
        continue;
      }
      c.delta.binderId ??= id;
      final store = _binderStore(Directory(path));
      var stop = false;
      await _lockRunUngated(Directory(path), () async {
        var extraKept = const <String>[];
        final list = _coverPending[key];
        // U0: the same section, available, and still holding this change.
        if (_disposed ||
            !identical(_binders[path], s) ||
            !s.available ||
            _isLocked(path) ||
            list == null ||
            !list.contains(c) ||
            s.saved?.id != id) {
          c.stuck = true;
          stop = true;
          return;
        }
        final r = await store.update(c.delta);
        if (_disposed) return;
        switch (r) {
          case BinderUpdated():
            _written(store, r);
            // One synchronous step: the change leaves the pending list as the
            // saved copy takes its result.
            list.remove(c);
            if (list.isEmpty) _coverPending.remove(key);
            if (s.available) {
              s.saved = r.binder;
              _recompute(s);
            } else {
              reconcile = true; // the file changed under a state that can't take the result
            }
            _coverDelay.remove(key);
            _coverHalted.remove(key);
            notifyListeners();
            extraKept = await _removeTemps(store, key, c.delta);
          case BinderRefused():
            c.stuck = true;
            stop = true;
            refused = true;
            _keepTemps(key, c.delta.temps);
            if (r.kind == BinderRefusal.keepsChanging) halted = true;
            if (r.kind != BinderRefusal.inUse &&
                r.kind != BinderRefusal.keepsChanging &&
                r.kind != BinderRefusal.readOnly &&
                r.kind != BinderRefusal.cantWrite) {
              reconcile = true;
            }
        }
        if (r is BinderRefused || r.kept.isNotEmpty || extraKept.isNotEmpty || s.copies.isNotEmpty) await _listCopiesLocked(s, store);
      });
      if (stop) break;
    }
    if (!_disposed) {
      notifyListeners();
      if (reconcile) {
        unawaited(checkBinderFile(_binderStore(Directory(path)).file.path, force: true));
      } else if (halted) {
        _coverHalted.add(key);
      } else if (refused) {
        _scheduleCoverRetry(path);
      }
    }
    return !(_coverPending[key]?.isNotEmpty ?? false);
  }

  // Tries the pending cover changes of [path] again after 2 s, doubling to a
  // minute while they keep being refused.
  void _scheduleCoverRetry(String path) {
    final key = _key(path);
    if (_coverTimers[key]?.isActive ?? false) return;
    final wait = _coverDelay[key] ?? coverRetryFirst;
    final doubled = wait * 2;
    _coverDelay[key] = doubled > const Duration(seconds: 60) ? const Duration(seconds: 60) : doubled;
    _coverTimers[key] = Timer(wait, () {
      _coverTimers.remove(key);
      if (_disposed || _coverHalted.contains(key) || (_coverPending[key]?.isEmpty ?? true)) return;
      unawaited(_tryCovers(path));
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

  // What a folder holds as its binder, read in one locked job (S, the read, the
  // id check and C).
  Future<BinderSection> _openBinder(
    String path, {
    bool create = false,
    bool createFolder = true,
    bool sweep = true,
    String? expectId,
  }) async {
    BinderSection unavailable(String why, {bool missing = false, List<BinderCopy> copies = const [], bool fileMissing = false}) =>
        BinderSection._(
          path,
          BinderStatus.unavailable,
          reason: why,
          missing: missing,
          copies: copies,
          fileMissing: fileMissing,
        );
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return unavailable('Folder not found. It may be on another device.', missing: true);
      }
      final binders = _binderStore(dir);
      final want = expectId ?? _binderIds[_key(path)];
      // One locked job. Folder locks aren't re-entrant, so the scan of the pages
      // runs afterwards as a job of its own.
      final got = await _lockRunUngated(dir, () async {
        // S: an aside of a replace that was killed is put back (never in a pull-only
        // place, and not while a found add runs); everything else is listed.
        final sw = await binders.sweepLeftovers(restore: sweep && _sweepOff == 0 && !_pullOnly(path) && _mayTouch(path));
        var once = await _readBinderFile(binders);
        var made = false;
        if (once.read is BinderMissing && create && !_pullOnly(path) && _mayTouch(path)) {
          // A complete copy of a binder file is never papered over by a new binder:
          // the user puts it back or deletes it first.
          if (sw.copies.any((c) => c.isTemp && c.binder != null)) {
            return (read: once.read, text: once.text, sweep: sw, refused: true);
          }
          final fresh = Binder.create(
            title: _folderName(path),
            color: binderPalette[_binders.length % binderPalette.length],
          );
          if (await binders.create(fresh) == BinderCreated.created) {
            made = true;
            once = (read: BinderFound(fresh), text: fresh.write());
            _emitPublished(binders.file.path, null, () => fresh.write());
          } else {
            // Another binder file arrived first: that one is read, never replaced.
            once = await _readBinderFile(binders);
          }
        }
        return (read: once.read, text: once.text, sweep: made ? await binders.sweepLeftovers(restore: false) : sw, refused: false);
      });
      final read = got.read;
      final text = got.text;
      if (got.refused) {
        return unavailable(
          'No $binderFileName in this folder.',
          copies: got.sweep.copies,
          fileMissing: true,
        );
      }
      if (read is BinderMissing) {
        if (!create || _pullOnly(path)) {
          return unavailable('No $binderFileName in this folder.', copies: got.sweep.copies, fileMissing: true);
        }
        return unavailable('No $binderFileName in this folder.');
      }
      // A binder whose file can't be read still lists its pages, read-only. So does
      // one whose folder holds another binder than this device recorded: it is
      // never used or written until the user chooses it (I).
      Binder? binder = read is BinderFound ? read.binder : null;
      Binder? other;
      if (binder != null && want != null && binder.id != want) {
        other = binder;
        binder = null;
      }
      await _binderSeam('parsed', path);
      if (text != null) {
        _binderText[_key(path)] = text;
      } else {
        _binderText.remove(_key(path));
      }
      final pages = storeFactory(dir);
      // The scan checks the binder file again in its own turn, and the section
      // is built from what it found: another binder's file there by then holds
      // the folder, read-only. Nothing is swept unless the file is this
      // binder's (another id or an unreadable file sweeps nothing).
      final scanned = await _scanWithVerdict(
        pages,
        createFolder: createFolder,
        sweep: sweep && _sweepOff == 0 && binder != null && _mayTouch(path),
        opening: true,
        expectId: want,
      );
      final entries = scanned.entries;
      final heldOther = scanned.verdict == BinderVerdict.other ? scanned.other : null;
      if (heldOther != null) {
        other = heldOther;
        binder = null;
      }
      var latest = (await binders.file.lastModified());
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      // Conflict copies are merged by writing, which a damaged binder forbids.
      _takeCopies(path, entries, bad, merge: binder != null);
      final section = BinderSection._(
        path,
        binder != null ? BinderStatus.available : BinderStatus.unreadable,
        binder: binder,
        store: pages,
        reason: other != null
            ? 'This folder now holds another binder ("${other.title.trim().isEmpty ? _folderName(path) : other.title.trim()}")'
            : read is BinderUnreadable
            ? read.reason
            : null,
        unreadable: bad,
        other: other,
        copies: got.sweep.copies,
      );
      // Another binder's file holds the folder, at launch too.
      if (other != null) {
        section
          .._hold = BinderHold.otherBinder
          .._heldOther = other;
      }
      for (final e in entries.whereType<ReadablePage>()) {
        if ((_metas.containsKey(e.meta.id) && _loc[e.meta.id] != path) ||
            _otherThanChosen(e.meta.id, e.path)) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        _pathId[_key(e.path)] = e.meta.id;
        _recordStamp(_key(e.path), e.stamp);
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

  // Lists the files beside the binder file whose names start with
  // `noted-binder`, under the folder's lock held by the caller. Never deletes.
  Future<void> _listCopiesLocked(BinderSection s, BinderStore store) async {
    final sw = await store.sweepLeftovers(restore: false);
    if (_disposed) return;
    s.copies = sw.copies;
    notifyListeners();
  }

  /// The files beside binder [path]'s file that hold a copy of it or part of
  /// it: temporary files of interrupted changes, conflict and sync-client copies,
  /// and asides, each with what it is (P). Never deleted on their own.
  List<BinderCopyRow> binderCopyRows(BinderSection s) {
    final key = _key(s.path);
    final saved = s.saved ?? s.binder;
    final savedBytes = saved == null ? null : utf8.encode(saved.write());
    final rows = <BinderCopyRow>[];
    final seen = <String>{};
    String when(DateTime? t) {
      if (t == null) return '';
      final l = t.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
    }

    void add(String path, List<int>? bytes, Binder? binder, DateTime? modified, bool isTemp) {
      if (!seen.add(_key(path))) return;
      final String label;
      if (binder == null) {
        label = "can't be read by this version";
      } else if (savedBytes != null && bytes != null && _sameBytes(bytes, savedBytes)) {
        label = 'same as saved';
      } else if (isTemp) {
        label = 'an interrupted change';
      } else {
        final ai = (binder.aiAccess ?? defaultAiAccess).label;
        label = 'an older copy (${[when(modified), 'AI access $ai'].where((x) => x.isNotEmpty).join(', ')})';
      }
      rows.add(
        BinderCopyRow(
          path: path,
          name: path.split(RegExp(r'[\\/]')).last,
          label: label,
          canPutBack: s.fileMissing && !s.missing && !_pullOnly(s.path) && _copyIsThisBinders(s, binder),
          canDelete: !_pullOnly(s.path),
          forOtherBinder: binder != null && !_copyIsThisBinders(s, binder),
          canReadAsBinder: binder != null,
          bytes: bytes,
        ),
      );
    }

    for (final c in s.copies) {
      add(c.path, c.bytes, c.binder, c.modified, c.isTemp);
    }
    for (final t in _ownKeptTemps[key] ?? const <BinderTemp>[]) {
      if (!File(t.path).existsSync()) continue;
      Binder? parsed;
      try {
        parsed = Binder.parse(utf8.decode(t.bytes));
      } on Object {
        parsed = null;
      }
      add(t.path, t.bytes, parsed, null, true);
    }
    return rows;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Whether [copy] passes the identity check Put back makes: it is a readable
  // binder with the id recorded for this folder (or, with none recorded, one
  // that is not listed at another folder).
  bool _copyIsThisBinders(BinderSection s, Binder? copy) {
    if (copy == null) return false;
    final key = _key(s.path);
    final recorded = _binderIds[key];
    if (recorded != null) return copy.id == recorded;
    return !_binderIds.entries.any((e) => e.key != key && e.value == copy.id);
  }

  // Deletes [path] if it holds [bytes], never throwing.
  Future<void> _quietDelete(String path, List<int> bytes) async {
    try {
      await deleteFileIfMatches(path, bytes: bytes);
    } on Object {
      // Left in place.
    }
  }

  /// Runs in [putBackBinderCopy] between the publish and the removal of the copy.
  @visibleForTesting
  Future<void> Function()? putBackBeforeDeleteHook;

  /// Runs in [putBackBinderCopy] inside the delete of the copy, after the copy
  /// was read again and before it is deleted (the re-check's seam).
  @visibleForTesting
  Future<void> Function(String path)? putBackBeforeFinalCheckHook;

  /// Puts the copy [copyPath] back as binder [path]'s file (P). Only while the
  /// file is missing, only a complete copy of this folder's binder, and never
  /// over anything.
  Future<void> putBackBinderCopy(String path, String copyPath) async {
    _refuseWhileHeld();
    if (_pullOnly(path)) throw NotebookException(pullOnlyMessageFor(path));
    final s = _binders[path];
    if (s == null) return;
    final row = binderCopyRows(s).where((r) => r.path == copyPath).firstOrNull;
    final bytes = row?.bytes;
    if (row == null || bytes == null) throw const NotebookException('That copy is not there any more.');
    final key = _key(path);
    final store = _binderStore(Directory(path));
    Binder copy;
    try {
      copy = Binder.parse(utf8.decode(bytes));
    } on Object {
      throw const NotebookException("That copy can't be read, so it can't be put back.");
    }
    final recorded = _binderIds[key];
    if (recorded != null && copy.id != recorded) {
      throw const NotebookException('That copy belongs to another binder.');
    }
    if (recorded == null && _binderIds.entries.any((e) => e.key != key && e.value == copy.id)) {
      throw const NotebookException('That copy belongs to a binder listed from another folder.');
    }
    await _lockRunUngated(Directory(path), () async {
      if (await store.file.exists()) {
        throw const NotebookException('The binder file is there now, so nothing was put back.');
      }
      final f = File(copyPath);
      if (!await f.exists() || !_sameBytes(await f.readAsBytes(), bytes)) {
        throw const NotebookException('That copy changed, so it was left as it is.');
      }
      // The verified bytes go to a private temp that is published; the copy
      // itself is never moved, and is removed only if it still holds them.
      final tmp = store.newTempFile();
      try {
        await store.writeTemp(tmp, bytes);
      } on FileSystemException {
        // Only our own part-written prefix is removed; anything else stays.
        try {
          final back = await tmp.readAsBytes();
          if (back.length <= bytes.length && _sameBytes(back, bytes.sublist(0, back.length))) {
            await deleteFileIfMatches(tmp.path, bytes: back);
          }
        } on Object {
          // Left for the user; the error below is the one that matters.
        }
        throw const NotebookException("The binder file couldn't be put back: its copy couldn't be written.");
      }
      final bool ok;
      try {
        ok = await publishExclusive(tmp, store.file.path);
      } on Object {
        await _quietDelete(tmp.path, bytes);
        rethrow;
      }
      if (!ok) {
        await _quietDelete(tmp.path, bytes);
        throw const NotebookException('A binder file appeared first, so nothing was put back.');
      }
      final text = utf8.decode(bytes);
      _binderText[key] = text;
      _emitPublished(store.file.path, null, () => text);
      await putBackBeforeDeleteHook?.call();
      var removed = false;
      try {
        // Only while the binder file still holds exactly the restored bytes: the
        // copy may be the only one if sync removed or replaced the file meanwhile,
        // also with another version of the same binder (Codex run-diff-9 R-1).
        final r = await deleteFileIfMatches(
          copyPath,
          bytes: bytes,
          beforeFinalCheck: putBackBeforeFinalCheckHook,
          stillRedundant: () {
            try {
              return listEquals(store.file.readAsBytesSync(), bytes);
            } on FileSystemException {
              return false;
            }
          },
        );
        removed = r.deleted || r.outcome == DeleteOutcome.absent;
      } on StorageBusy {
        removed = false; // the copy stays, and is listed as it is
      } on FileSystemException {
        removed = false;
      }
      if (removed) {
        final kept = _ownKeptTemps[key];
        kept?.removeWhere((t) => t.path == copyPath);
        if (kept != null && kept.isEmpty) _ownKeptTemps.remove(key);
      }
      // A copy that was put back is no longer a pending change's temp: a kept one
      // goes only through its row's Delete, never when that change lands, since
      // the file the change lands on may lack the restored fields.
      for (final c in _coverPending[key] ?? const <CoverChange>[]) {
        c.delta.temps.removeWhere((t) => t.path == copyPath);
      }
      // A copy that changed meanwhile stays, and is listed as it is now.
      await _listCopiesLocked(s, store);
    });
    if (!_disposed) {
      notifyListeners();
      unawaited(checkBinderFile(store.file.path, force: true));
    }
  }

  /// Deletes the copy [copyPath] beside binder [path]'s file, after asking, and
  /// only while it still holds what was listed. Returns false if the user
  /// chose to keep it.
  Future<bool> deleteBinderCopy(String path, String copyPath) async {
    if (_pullOnly(path)) throw NotebookException(pullOnlyMessageFor(path));
    final s = _binders[path];
    if (s == null) return false;
    final row = binderCopyRows(s).where((r) => r.path == copyPath).firstOrNull;
    final bytes = row?.bytes;
    if (row == null || bytes == null) throw const NotebookException('That copy is not there any more.');
    final key = _key(path);
    final store = _binderStore(Directory(path));
    final onlyReadable = row.canReadAsBinder && !_binderFileReadable(store);
    if (!await _ask(onlyReadable ? UserQuestion.deleteOnlyBinderCopy : UserQuestion.deleteBinderCopy, row.name)) {
      return false;
    }
    await _lockRunUngated(Directory(path), () async {
      final r = await deleteFileIfMatches(copyPath, bytes: bytes);
      if (!r.deleted && r.outcome != DeleteOutcome.absent) {
        throw const NotebookException('That copy changed, so it was kept.');
      }
      final kept = _ownKeptTemps[key];
      kept?.removeWhere((t) => t.path == copyPath);
      if (kept != null && kept.isEmpty) _ownKeptTemps.remove(key);
      await _listCopiesLocked(s, store);
    });
    return true;
  }

  // Whether the binder file is there and reads as a binder.
  bool _binderFileReadable(BinderStore store) {
    try {
      Binder.parse(utf8.decode(store.file.readAsBytesSync()));
      return true;
    } on Object {
      return false;
    }
  }

  /// The folder of [path] holds another binder than the one this device recorded
  /// for it. Its pages stay listed, read-only, and nothing is written until the
  /// user chooses that binder (I).
  Future<void> _otherBinder(BinderSection section, Binder other) async {
    final path = section.path;
    if (section.other != null && section.other!.id == other.id) {
      section.other = other;
      return;
    }
    // The open page's pending edits were kept in recovery first (held edits).
    if (_disposed || _binders[path] != section) return;
    // The typing of an open cover is taken before anything changes (D2).
    if (_coverTypingPath == path) _takeCoverTyping();
    final dropped = section.pending.length;
    section
      ..status = BinderStatus.unreadable
      ..reason = 'This folder now holds another binder ("${other.title.trim().isEmpty ? _folderName(path) : other.title.trim()}")'
      ..binder = null
      ..saved = null
      ..other = other;
    for (final c in List<BinderSetting>.of(section.pending)) {
      _dropSetting(section, c);
    }
    if (dropped > 0) {
      _notices.add("Binder ${section.title}: the change wasn't saved. The folder now holds another binder.");
    }
    if (_coverPath == path) _coverPath = null;
    final key = _key(path);
    _pendingCopies.removeWhere((p) => _key(File(p).parent.path) == key);
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    notifyListeners();
  }

  /// The folder of [path] holds another binder; use it from now on (I). Refused
  /// for an id that is listed at another folder (0140) and while the binder list
  /// is held (0146). Cover changes of the old binder that aren't written are
  /// discarded, after asking.
  Future<void> useThisBinder(String path) async {
    _refuseWhileHeld();
    final s = _binders[path];
    final other = s?.other ?? s?.heldOther;
    if (s == null || other == null) return;
    final key = _key(path);
    if (_binderIds.entries.any((e) => e.key != key && e.value == other.id)) {
      throw const NotebookException('That binder is listed from another folder, so it was not added again.');
    }
    final old = _binderIds[key];
    final stale = [
      for (final c in _coverPending[key] ?? const <CoverChange>[])
        if (c.forId != other.id) c,
    ];
    if (stale.isNotEmpty) {
      for (final c in stale) {
        if (!await _ask(UserQuestion.discardCoverChanges, _coverLabel(null, c))) return;
      }
      final list = _coverPending[key];
      list?.removeWhere(stale.contains);
      if (list != null && list.isEmpty) _coverPending.remove(key);
      final store = _binderStore(Directory(path));
      await _lockRunUngated(Directory(path), () async {
        var any = false;
        for (final c in stale) {
          if ((await _removeTemps(store, key, c.delta)).isNotEmpty) any = true;
        }
        final sec = _binders[path];
        if (any && sec != null) await _listCopiesLocked(sec, store);
      });
    }
    if (_disposed || !identical(_binders[path], s)) return;
    if (old != null) _binderIds.remove(key);
    _recordBinderId(path, other);
    await _saveSettings();
    await _reopenBinder(path);
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
  // recorded id stays). An id is recorded only where none is: another binder's
  // file at the path is never adopted (I; only [useThisBinder] changes it), and
  // an id a listed binder has is no longer a removed one. True if anything
  // changed.
  bool _recordBinderId(String path, Binder? binder) {
    if (binder == null) return false;
    final key = _key(path);
    final recorded = _binderIds[key];
    if (recorded != null && recorded != binder.id) return false;
    final changed = recorded != binder.id;
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
      // A save skipped while the start-up load is unfinished is made once it succeeds.
      if (_settingsHeld == _SettingsHold.pending) _saveAfterLoad = true;
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
      await createFolderCoordinated(f.parent);
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
      // Under no registered root today, so it runs directly (N4).
      await coordinated(
        CoordinatedWrite([
          CoordinationIntent(tmp.path, CoordinationKind.move),
          CoordinationIntent(f.parent.path, CoordinationKind.write),
        ]),
        () => tmp.rename(f.path),
      );
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
      await (() async {
        await _loaded.future;
        // A Retry rebuilds the lists with [_loaded] already complete.
        final run = _loadRun;
        if (run != null) {
          try {
            await run;
          } on Object {
            // Recorded in [loadError].
          }
        }
      })().timeout(timeout);
      return _loadError == null && _loadRun == null;
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
  bool aiMergeTypeAllowed(String pageId, String typeId, {NotedPage? page}) => effectiveBoxTypeAllowed(
    typeId,
    page == null ? _metaChain(pageId) : [page.meta, ..._metaChain(pageId).skip(1)],
    binder: _aiBinderOf(pageId),
  ).allowed;

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
    // A type this page doesn't allow behaves as switched off here, and its
    // box is not decoded to find that out (invariant 2).
    final chain = [page.meta, ..._metaChain(page.id).skip(1)];
    if (!effectiveBoxTypeAllowed(box.typeId, chain, binder: _aiBinderOf(page.id)).allowed) {
      return AiLinkCode.notWritable;
    }
    final r = modules.codecs.resolve(box);
    if (r is! LiveBox) return AiLinkCode.notWritable;
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
      PageStore.fileReadObserver?.call(path);
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
        toSave = mergePage(base, mine, theirs, _mergeCodecs(id, [base, mine, theirs]), theirsTime: seen.time).page;
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
      // Landed: this app's own deletes and AI access stand against a later
      // redo of a consumed copy (taken from mine, not from what was written).
      _noteOwnEdits(id, base, mine);
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
    // What the save will hold beyond the file last seen: this app's own edits
    // (a sync revert merged in by _mergeOpen moved the base along, so it isn't).
    if (_current?.page.id == page.id) _noteOwnEdits(page.id, _base, page);
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
          if (e is StorageBusy && e.reason == StorageBusyReason.dataless) {
            // The page file is not downloaded (R5.5): ask for it and keep the
            // edit in recovery (the bar says why). The backoff and the file's
            // change event try the save again.
            for (final p in e.paths) {
              requestDownload?.call(p);
            }
            return await _saveFailed(loc, st, toSave, savedSeq, session, error: e, reason: 'the page file is still downloading');
          }
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
    } on _BinderUnreadableNow {
      // The binder file was half written or locked at the turn: kept, and
      // tried again (the folder is there).
      return await _saveFailed(loc, st, toSave, savedSeq, session, reason: "its binder's file couldn't be read");
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
    final hold = _binders[loc]?._hold;
    if (hold != null && keep.safe && session != null && identical(session, _session) && !session.ended) {
      // A held folder (held edits): the edits are kept, with the kept notice and
      // no failing bar. They land when the folder holds this binder again.
      _announceKept(toSave, reason: _heldReason(hold), promise: _heldPromise(hold));
      _syncReadOnly();
      return SaveResult(SaveEnd.failed, keep);
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

  // Whether [x], the version whose header a same-id merge keeps, is the top of
  // its AI-access chain in [loc]: no binder and no parent (the merged `ai` is
  // the stricter, ranked as in aiAccessRank).
  bool _topOfChain(String loc, NotedPage x) => !_binders.containsKey(loc) && x.meta.parentId == null;

  // The codecs for a merge of page [id]'s [versions]: a type is off if the page
  // disallows it as this device knows it now, or under the header of any
  // version the merge reads (strictest wins), so a merge treats such a box
  // opaquely, as a switched-off module would (0111). The merged header is
  // picked per field, so a codec merge decided under one side's allow-list
  // could land under a header that disallows the type.
  CodecRegistry _mergeCodecs(String id, Iterable<NotedPage?> versions) {
    final vs = versions.whereType<NotedPage>().toList();
    assert(vs.isNotEmpty, 'a merge reads at least one version');
    final off = disallowedBoxTypesFor(id);
    for (final v in vs) {
      final p = v.meta.parentId;
      final known = p != null && (p == currentId || _metas.containsKey(p));
      final parent = known ? p : _treeOf(_loc[id] ?? _standalone).parentIdOf(id);
      final chain = [v.meta, if (parent != null) ..._metaChain(parent)];
      for (final t in switchableBoxTypes) {
        if (!effectiveBoxTypeAllowed(t, chain, binder: _binderOf(id)).allowed) off.add(t);
      }
    }
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
    final foreign = entries.where((e) => !session.own.containsKey(e.gen) && _waitingEntry(rec, e));
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
    // A consumed copy's entry is never replaced: its slot is passed over.
    final consumed = {for (final e in entries) if (_consumedCopies.containsKey(e.gen)) e.gen};
    final replaceable = {
      ...session.own.keys,
      for (final e in entries) if (!consumed.contains(e.gen)) e.gen,
    };
    final written = await tx.write(
      folder: folder,
      page: page,
      baseText: baseText,
      time: time,
      replaceable: replaceable,
      passOver: consumed,
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
    final nb = basePage ?? (baseText == null ? null : _tryRead(baseText));
    var np = page;
    final sorted = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    // A consumed copy's entry is left alone: not folded in, replaced or deleted.
    final consumed = {for (final e in entries) if (_consumedCopies.containsKey(e.gen)) e.gen};
    for (final e in sorted) {
      if (rec.isLanded(e.gen) || consumed.contains(e.gen)) continue; // deleted, never merged
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
        _mergeCodecs(page.id, [eb, e.page, np]),
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
      replaceable: {for (final e in entries) if (!consumed.contains(e.gen)) e.gen},
      passOver: consumed,
    );
    for (final e in entries) {
      if (e.gen == written.gen || e.file.path == written.file.path || consumed.contains(e.gen)) continue;
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
    _clearKeptNotice(saved.id);
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
    // Landed text only for generations that are listed. A listing that could
    // not read an entry leaves its generation out of the index while the entry
    // is still there, so it prunes nothing.
    if (listing.problems.isEmpty && listing.damaged.isEmpty) {
      final liveGens = {for (final e in rec.indexEntries) e.gen};
      _landedText.removeWhere((g, _) => !liveGens.contains(g));
      for (final g in [..._consumedCopies.keys]) {
        if (!liveGens.contains(g)) _dropConsumed(g);
      }
    }
    // Landed leftovers are deleted, never merged (0130).
    if (rec.landedEntries.isNotEmpty) {
      await _deleteGens(rec, [for (final e in rec.landedEntries) e.gen], null);
    }
    // Entries under a key other than the one their page is listed in go
    // first (3.7: the duplicate is dropped while the other key still exists, or
    // re-keyed), then the rest; a second round takes what re-keying wrote.
    bool stale(RecoveryEntry e) {
      final listed = _loc[e.pageId];
      final at = _locOfFolder(e.folder);
      // An entry of a held folder lands only there (N6).
      if (at != null && _keyedOnlyHere(at)) return false;
      return listed != null && at != listed;
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
        // The notice goes once the last kept entry of the page has replayed.
        if (!rec.entriesOfPage(e.pageId).any((x) => x.gen != e.gen && isKeptEdit(x) && !rec.isLanded(x.gen))) {
          _clearKeptNotice(e.pageId);
        }
        return true;
      }
    } on _ReplayFailure catch (ex) {
      debugPrint('Recovered page ${e.pageId} not accepted: ${ex.detail ?? ex.why}');
      _replayProblems[key] = (path: path, why: ex.why, line: null);
      if (!ex.transient) _replayHardFailure.add(e.pageId);
    } on Object catch (ex) {
      // A write failure; the reading failures are _ReplayFailures above.
      debugPrint('Recovering page ${e.pageId} failed: $ex');
      _replayProblems[key] = (
        path: path,
        why:
            'the edits kept for "${_titleOrUntitled(e.page.meta.title)}" could not be saved into '
            'the page file${_osReason(ex)}',
        line: null,
      );
    }
    return false;
  }

  // Deletes the entry of a replay that landed, by its exact generation; one
  // that can't be deleted is marked landed (deleted later, never merged).
  Future<void> _deleteEntry(RecoveryStore rec, RecoveryEntry e) async {
    _landedText.remove(e.gen);
    _dropConsumed(e.gen);
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

  // Consumed conflict copies (R-1 of the 2026-11-16 data-integrity audit) --------
  //
  // A conflict copy that a merge consumed is kept as a recovery entry (a fresh
  // slot, no base, read back) before the copy file is deleted, and the entry is
  // retired only once a later read of the page file shows it still holds what
  // the copy held (consumedCopyHeld). If a sync client put an older file back
  // meanwhile, the merge is done again from the entry.

  // Ends the mark of [gen], if any, and its timer.
  void _dropConsumed(String gen) {
    final m = _consumedCopies.remove(gen);
    m?.timer?.cancel();
    m?.timer = null;
  }

  // Keeps [copy], read from the copy file a merge consumed, in recovery and
  // marks it for its re-check. Throws a FormatException when it can't be kept
  // (no recovery, the lock, a write or read-back that fails): the copy then
  // stays, listed, as any failed merge, so nothing is retired unkept.
  Future<_ConsumedCopy> _keepConsumedCopy(PageStore st, NotedPage copy, int copyTime) async {
    const refused = FormatException('the merged copy could not be kept in recovery');
    final rec = _recovery;
    if (rec == null || _lockProblem() != null) throw refused;
    final String gen;
    try {
      final folder = _normalizePath(st.directory.path);
      final written = await rec.transaction(
        (tx) => tx.write(folder: folder, page: copy, baseText: null, time: DateTime.now(), freshSlot: true),
      );
      gen = written.gen;
      final entry = rec.indexEntries.where((x) => x.gen == gen).firstOrNull;
      if (entry == null || !await rec.transaction((tx) => tx.verify(entry))) throw refused;
    } on Object catch (e) {
      debugPrint('Keeping the merged copy of page ${copy.id} in recovery failed: $e');
      throw refused;
    }
    final m = _consumedCopies[gen] = _ConsumedCopy(gen, copy.id, copyTime, now(), copy.meta.rawAiAccess);
    _armConsumed(m);
    return m;
  }

  // The shortest wait before a mark is looked at again.
  static const Duration _consumedMinWait = Duration(milliseconds: 250);

  // How long until [m] is due; for a mark already due that is waiting (the
  // page open, a delete holding it, a lock problem), [copyRetireAfter] again.
  // At least [_consumedMinWait].
  Duration _consumedWait(_ConsumedCopy m) {
    final left = copyRetireAfter - now().difference(m.since);
    final wait = left > Duration.zero ? left : copyRetireAfter;
    return wait > _consumedMinWait ? wait : _consumedMinWait;
  }

  /// Test seam: runs the re-check of every consumed conflict copy now, as if
  /// it were due, and nothing else (no other entry is replayed).
  @visibleForTesting
  Future<void> recheckConsumedCopiesForTest() async {
    final rec = _recovery;
    if (rec == null) return;
    for (final m in [..._consumedCopies.values]) {
      final e = rec.indexEntries.where((x) => x.gen == m.gen).firstOrNull;
      final loc = e == null ? null : _locOfFolder(e.folder);
      if (e == null || loc == null || _busy.containsKey(m.pageId)) continue;
      m.decideNow = true;
      _busy[m.pageId] = _busyReplaying;
      try {
        await _replayEntry(rec, e, loc);
      } finally {
        _free(m.pageId, _busyReplaying);
      }
    }
  }

  // Arms [m]'s one-shot timer ([copyRetireAfter] unless [after] is given). Not
  // for a parked mark.
  void _armConsumed(_ConsumedCopy m, [Duration? after]) {
    m.timer?.cancel();
    m.timer = null;
    if (_disposed || m.parked) return;
    late final Timer t;
    t = m.timer = Timer(after ?? copyRetireAfter, () {
      if (identical(m.timer, t)) m.timer = null;
      unawaited(_consumedTick(m));
    });
  }

  // [m]'s timer fired: a replay pass at the page's current place. A pass can
  // return before the re-check (a lock problem, a busy page, a folder away), so
  // while the mark stands, isn't parked and no redo armed it, it arms again:
  // after a failed redo or read with the backoff's wait.
  Future<void> _consumedTick(_ConsumedCopy m) async {
    if (_disposed || !identical(_consumedCopies[m.gen], m)) return;
    final e = _recovery?.indexEntries.where((x) => x.gen == m.gen).firstOrNull;
    final loc = _loc[m.pageId] ?? (e == null ? null : _locOfFolder(e.folder));
    try {
      await _recoverPending(onlyLoc: loc);
    } on Object catch (ex) {
      debugPrint('Re-checking the merged copy of page ${m.pageId} failed: $ex');
    }
    if (_disposed || !identical(_consumedCopies[m.gen], m) || m.parked || m.timer != null) return;
    _armConsumed(m, m.failed ? (_backoff.delay ?? backoffFirst) : _consumedWait(m));
  }

  // Whether a delete that Undo can still reach holds page [id] (0143).
  bool _deleteHolds(String id) {
    bool has(DeletedPages d) => d.pages.any((p) => p.id == id);
    final last = _lastDeleted;
    return (last != null && has(last)) || _held.any(has);
  }

  // The re-check of consumed copy [m], kept as [e] (whose folder is [loc]).
  // True once the entry is retired; false while it waits: not due, the copy
  // still being deleted, parked, the page open in any form (a preview too), the
  // place away, a delete holding the page, a page still listed whose file is
  // missing, or a read that failed (looked at again after the backoff's wait).
  // The page file is read at the page's current place under the folder lock:
  // when it holds the copy the entry is retired; when it doesn't, the merge is
  // done again (the entry stays and is re-checked); a page listed nowhere
  // whose file is gone was deleted, and the entry goes.
  Future<bool> _recheckConsumedCopy(RecoveryStore rec, RecoveryEntry e, String loc, _ConsumedCopy m) async {
    final id = e.pageId;
    final due = m.decideNow || now().difference(m.since) >= copyRetireAfter;
    if (!due || m.deleting || m.parked || _current?.page.id == id) return false;
    final at = _loc[id] ?? loc;
    final PageStore st;
    try {
      if (_isLocked(at)) return false;
      st = _storeOf(at);
    } on NotebookException {
      return false;
    }
    // A delete that Undo can still reach holds the page (0143): the entry waits.
    if (_deleteHolds(id)) return false;
    m.decideNow = false;
    final path = st.pathFor(id);
    await syncHook?.call('copy-recheck', path); // a test seam: sync puts a file back here
    final String? text;
    try {
      text = await _underFolderLock(st, () async {
        try {
          PageStore.fileReadObserver?.call(path);
          return await File(path).readAsString();
        } on PathNotFoundException {
          return null;
        }
      });
    } on Object catch (ex) {
      // Held by a sync client, or not text yet.
      debugPrint('Reading page $id to check its merged copy failed: $ex');
      m.failed = true;
      return false;
    }
    if (text == null) {
      // A page still listed may be a sync client's replace in flight. Listed
      // nowhere: the deleting writer's decision stands.
      if (_loc[id] != null) return false;
      m.failed = false;
      await _deleteEntry(rec, e);
      return true;
    }
    NotedPage? disk;
    try {
      disk = readPage(text);
    } on PageFormatException catch (ex) {
      debugPrint('Page $id can not be read to check its merged copy: $ex');
    }
    if (disk == null || disk.id != id) {
      m.failed = true;
      return false;
    }
    // What the file must hold, and what a redo merges: the copy without the
    // nodes this app deleted since and without the conflicts and landed
    // markers the user settled (0120), and with the user's own last AI access
    // when they changed it (after a revert the disk's is the pre-merge one).
    var redo = e.page;
    if (m.touched.isNotEmpty || m.resolved.isNotEmpty || m.dismissed.isNotEmpty) {
      redo = NotedPage.fromParts(redo.top, redo.meta, [
        for (final n in redo.nodes)
          if (!m.touched.contains(n.id)) ?_settledOf(m, n),
      ]);
    }
    if (m.headerTouched) {
      final raw = m.userAi;
      final fields = raw == null ? redo.meta.fields.remove(aiAccessKey) : redo.meta.fields.set(aiAccessKey, raw);
      redo = redo.withMeta(PageMeta.tryRead(fields) ?? redo.meta);
    }
    final missing = consumedCopyHeld(disk, redo, topOfChain: _topOfChain(at, disk));
    if (missing == null) {
      m.failed = false;
      await _deleteEntry(rec, e);
      return true;
    }
    debugPrint('Page $id no longer holds its merged copy ($missing): merging it again');
    final label = '"${_titleOrUntitled(e.page.meta.title)}"';
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          await _mergeConflictCopy(at, null, path, redo, m.copyTime, '');
          break;
        } on _SourceChanged {
          if (attempt >= 4) {
            throw _ReplayFailure(
              'the saved file of $label keeps changing',
              detail: 'the page file changed on every attempt to merge the kept copy into it',
              transient: true,
            );
          }
        }
      }
    } on Object {
      m.failed = true;
      rethrow;
    }
    m.failed = false;
    m.since = now();
    m.rounds++;
    if (m.rounds >= 3) {
      // Sync keeps putting an older file back: no more redos until a change of
      // the file (once) or a restart.
      m.parked = true;
      m.timer?.cancel();
      m.timer = null;
      _replayProblems[_entryKey(e)] = (
        path: _entryPath(e),
        why: 'Sync keeps putting back an older version of $label; the merged copy is kept in recovery',
        // The sidebar says it as two sentences, with no "can't finish": it is kept.
        line: 'Sync keeps putting back an older version of $label. The merged copy is kept in recovery.',
      );
    } else {
      _armConsumed(m);
    }
    return false;
  }

  // The marks parked now whose page's file is at [path]: a change of that file
  // is theirs to take out of parked (see [_unparkConsumed]).
  List<_ConsumedCopy> _parkedAt(String path) {
    if (_consumedCopies.isEmpty) return const [];
    final key = _key(path);
    final found = <_ConsumedCopy>[];
    for (final m in _consumedCopies.values) {
      if (!m.parked || m.unparked) continue;
      // The page's actual file (a chosen or renamed one too), in its folder.
      final at = _loc[m.pageId];
      if (at == null) continue;
      final String file;
      try {
        file = _storeOf(at).pathFor(m.pageId);
      } on NotebookException {
        continue;
      }
      if (_key(file) == key) found.add(m);
    }
    return found;
  }

  // [text] was just read from the page file at [path]: when it is not what this
  // app last wrote or read, someone else changed the file, and its parked marks
  // get their extra round (see [_unparkConsumed]). Called before [_known] is
  // updated or the file is written over.
  void _noteDiskText(String path, String text) {
    final k = _key(path);
    if (_consumedCopies.isEmpty || _known[k] == text || (_known[k] == null && _baseText[k] == text)) return;
    _unparkConsumed(path);
  }

  // A check that finds the file at [path] gone or different from what this app
  // last wrote or read takes the parked marks of its page out of parked, once
  // per mark, for one more round. The redo's own write is known before it
  // parks, so it is no change; a difference seen after is one.
  void _unparkConsumed(String path) {
    for (final m in _parkedAt(path)) {
      if (!m.parked || m.unparked || !identical(_consumedCopies[m.gen], m)) continue;
      m.parked = false;
      m.unparked = true;
      _armConsumed(m, _consumedWait(m));
    }
  }

  // This app changed page [id] from [base] to [mine] (a change of the open
  // page, or a closed save that landed; before mine is merged with the file):
  // a redo of a consumed copy of the page leaves out the nodes it deleted (in
  // [base], not in [mine]) and takes the user's own AI access. A node back in
  // [mine] (an Undo, a discarded change) counts again, and an AI access equal
  // to the copy's again is no longer the user's own change. A box it moved or
  // edited is still required: a revert brings it back in the copy's version.
  void _noteOwnEdits(String id, NotedPage? base, NotedPage mine) {
    if (base == null || !_consumedCopies.values.any((m) => m.pageId == id)) return;
    final kept = {for (final n in mine.nodes) n.id};
    final ids = {
      for (final n in base.nodes)
        if (!kept.contains(n.id)) n.id,
    };
    // Issues the user settled (0120): a recorded version in base's box and
    // not in mine's, unless mine's box is that version (the user took it), and
    // a landed marker base's box has and mine's doesn't. Back in mine: no
    // longer settled.
    final baseBoxes = {for (final n in base.nodes) if (n is BoxRecord) n.id: n};
    final settled = <String, List<BoxConflict>>{};
    final cleared = <String>{};
    final mineBoxes = [for (final n in mine.nodes) if (n is BoxRecord) n];
    for (final n in mineBoxes) {
      final b = baseBoxes[n.id];
      if (b == null) continue;
      if (b.landed != null && n.landed == null) cleared.add(n.id);
      // Only a plain "keep mine" settles a record: the box is still base's
      // version, and no box of mine holds the recorded one (Place both, a
      // merged result or Keep theirs carry it forward, so it stays required:
      // after a revert it may be recorded again, but it is never lost).
      final kept = b.rev != null && n.rev != null ? n.rev == b.rev : _sameBoxContent(n, b);
      if (!kept) continue;
      settled[n.id] = [
        for (final k in b.conflicts)
          if (!n.conflicts.contains(k) && !mineBoxes.any((x) => _recordIsVersion(k, x))) k,
      ];
    }
    final ai = mine.meta.rawAiAccess;
    final header = base.meta.rawAiAccess != ai;
    for (final m in _consumedCopies.values) {
      if (m.pageId != id) continue;
      m.touched
        ..removeAll(kept)
        ..addAll(ids);
      for (final n in mineBoxes) {
        final r = m.resolved[n.id];
        if (r != null) r.removeAll(n.conflicts);
        final s = settled[n.id];
        if (s != null && s.isNotEmpty) (m.resolved[n.id] ??= {}).addAll(s);
        if (m.resolved[n.id]?.isEmpty ?? false) m.resolved.remove(n.id);
        if (n.landed != null) m.dismissed.remove(n.id);
      }
      m.dismissed.addAll(cleared);
      if (!header) continue;
      if (ai == m.copyAi) {
        m.headerTouched = false;
        m.userAi = null;
      } else {
        m.headerTouched = true;
        m.userAi = ai;
      }
    }
  }

  // Whether [b] holds the version recorded in [k] (the same rev, or the same
  // content): the user kept it, in that box.
  static bool _recordIsVersion(BoxConflict k, BoxRecord b) {
    final node = k.node;
    if (node == null || !node.isObject) return false;
    try {
      final x = BoxRecord.tryRead(RawObject.parse(node.text), node);
      if (x == null) return false;
      return (x.rev != null && x.rev == b.rev) || _sameBoxContent(x, b);
    } on FormatException {
      return false;
    }
  }

  static bool _sameBoxContent(BoxRecord x, BoxRecord y) =>
      x.typeId == y.typeId && x.data == y.data && x.snapshotText == y.snapshotText;

  // The copy's node [n] as a consumed copy's re-check requires it, without
  // what the user settled since the merge (0120): null when [n] is itself a
  // version the user resolved away; otherwise [n] without its resolved
  // recorded versions and, when dismissed, its landed marker.
  static CanvasNode? _settledOf(_ConsumedCopy m, CanvasNode n) {
    if (n is! BoxRecord) return n;
    final r = m.resolved[n.id];
    var b = n;
    if (r != null) {
      final own = n.toRaw();
      final bare = n.withConflicts(const []).toRaw();
      if (r.any((k) => k.node == own || k.node == bare)) return null;
      if (n.conflicts.any(r.contains)) {
        b = b.withConflicts([
          for (final k in n.conflicts)
            if (!r.contains(k)) k,
        ]);
      }
    }
    if (m.dismissed.contains(n.id) && b.landed != null) b = b.withoutLanded();
    return b;
  }

  // A delete holding page(s) [d] was let go: their marks are decided by the
  // re-check that follows, with a read of the file (no file retires them).
  void _letGoConsumed(DeletedPages d) {
    final ids = {for (final p in d.pages) p.id};
    var any = false;
    for (final m in _consumedCopies.values) {
      if (!ids.contains(m.pageId)) continue;
      m.decideNow = true;
      any = true;
    }
    if (any && !_disposed) unawaited(_recoverPending(onlyLoc: d._location));
  }

  // At quit, the delete [d] is let go: the marked entries of its pages whose
  // file a read under the folder lock finds absent are retired. One whose file
  // is there, or whose read can't be made within [leaveSaveLimit], stays for
  // the replay at the next start.
  Future<void> _retireConsumedOfDeleted(DeletedPages d) async {
    final rec = _recovery;
    if (rec == null) return;
    final ids = {for (final p in d.pages) p.id};
    for (final m in [..._consumedCopies.values]) {
      if (!ids.contains(m.pageId) || _disposed) continue;
      final e = rec.indexEntries.where((x) => x.gen == m.gen).firstOrNull;
      if (e == null) continue;
      try {
        final at = _loc[m.pageId] ?? d._location;
        // A held folder's entry is never retired by the hold: it waits.
        if (_heldAt(at)) continue;
        final st = _storeOf(at);
        final path = st.pathFor(m.pageId);
        final gone = await _underFolderLock(st, () async => !await File(path).exists()).timeout(leaveSaveLimit);
        if (gone && _loc[m.pageId] == null) await _deleteEntry(rec, e);
      } on Object catch (ex) {
        debugPrint('Retiring the merged copy of deleted page ${m.pageId} failed: $ex');
      }
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
    // An entry of a held folder (or one whose binder file is missing) is never
    // re-keyed or dropped: it lands in its own folder (N6).
    if (_keyedOnlyHere(loc)) return false;
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
  // applied, and then it stays. Once the page has landed (the publish went
  // through over exactly what was merged against) the entry is not merged
  // again, since a page someone has changed since could get back what they
  // deleted. It is settled instead (_settleLanded): the file is read back, and
  // what another writer's overwrite lost of the entry's edits is put right or
  // recorded as a version conflict. The entry is deleted only once a read shows
  // its edits are held (0130, 0124). Its kept files are landed apart
  // (_landKeptAssets, 0098); a re-replay after an interruption before the
  // retire is harmless: step 5 (settledInFile) takes what the file already
  // records, and the merge of a page with itself changes nothing.
  Future<bool> _recoverEntry(
    RecoveryStore rec,
    RecoveryEntry e,
    String loc,
  ) async {
    final mine = e.page;
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
    // A consumed conflict copy is re-checked, not replayed (it is merged again
    // only when the file no longer holds it).
    final mark = _consumedCopies[e.gen];
    if (mark != null) return _recheckConsumedCopy(rec, e, loc, mark);
    final base = e.baseText == null
        ? NotedPage.create(mine.meta)
        : _readForReplay(e.baseText!, 'the copy kept with the edits for $label');
    // The page is where the entry says, or the entry is re-keyed (3.7).
    final moved = await _twoKeys(rec, e, loc);
    if (moved != null) return moved;
    final path = st.pathFor(id);
    final file = File(path);
    // Landed before and not settled yet (a read that kept failing, a write that
    // threw): not merged again, only settled.
    final landed = _landedText[e.gen];
    if (landed != null) {
      final merged = _readForReplay(landed.out, 'the page kept for $label');
      return _settleLanded(rec, e, loc, st, path, base, mine, landed.theirs, merged, landed.out, label);
    }
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
          theirsText = utf8.decode(await File(_obs(file.path)).readAsBytes());
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
      // Otherwise what the file learned since the base (a recorded conflict)
      // is taken as it is, so a repeat replay over it changes nothing.
      final noBase = e.baseText == null;
      final settled = theirs == null || noBase ? null : settledInFile(base, mine, theirs);
      final merged = theirs == null
          ? mine
          : noBase
          ? mergeConflictCopy(
              theirs,
              mine,
              _mergeCodecs(id, [theirs, mine]),
              copyTime: e.time.millisecondsSinceEpoch,
              topOfChain: _topOfChain(loc, theirs),
              forRecovery: true,
            ).page
          : mergePage(
              base,
              settled!,
              theirs,
              _mergeCodecs(id, [base, settled, theirs]),
              theirsTime: time,
              markLanded: false,
            ).page;
      final out = writePage(merged);
      if (out != theirsText) {
        await syncHook?.call('recover-before-publish', path);
        final published = theirsText == null
            ? await _writeNew(loc, merged)
            : await _writeIfUnchanged(loc, merged, theirsText);
        if (!published) continue; // the file changed since it was read
        // The page has landed (the publish only succeeds over exactly what was
        // merged against). Kept in memory from here, before anything is read
        // back, so a retry settles instead of merging again.
        _landedText[e.gen] = (out: out, theirs: theirs);
        await syncHook?.call('recover-published', path);
        return _settleLanded(rec, e, loc, st, path, base, mine, theirs, merged, out, label);
      }
      // Nothing of ours was written: the merge changed nothing. Read back; the
      // file must still be what was merged.
      String? back;
      for (var read = 0; back == null; read++) {
        try {
          back = await st.readText(id);
        } on FileSystemException {
          if (read < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue; // a lock may pass; a few tries
          }
          rethrow;
        }
      }
      if (back != out) {
        // The file changed since it was read.
        if (attempt < 4) continue;
        throw _ReplayFailure(
          'the saved file of $label keeps changing',
          detail: 'the page file changed on every attempt to merge into it',
        );
      }
      final result = _readForReplay(back, 'the saved file of $label');
      final why = theirs != null && noBase
          ? verifyConflictCopyMerge(result, theirs, mine, topOfChain: _topOfChain(loc, theirs), forRecovery: true)
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

  // After a replay's write has landed: reads the file back and puts right what
  // another writer's overwrite lost of the entry's edits, until a read shows
  // every edit is there or recorded as a conflict (recordLostEdits). Only then
  // is the entry deleted. A file that can't be read as a page gets the merged
  // page beside it as a conflict copy (3a); one that can't be read or written
  // just now keeps the entry, listed and retried (3b); one that is gone gets the
  // page back (3c). [theirs] is the file the merge was made against, if any.
  Future<bool> _settleLanded(
    RecoveryStore rec,
    RecoveryEntry e,
    String loc,
    PageStore st,
    String path,
    NotedPage base,
    NotedPage mine,
    NotedPage? theirs,
    NotedPage merged,
    String out,
    String label,
  ) async {
    final id = e.pageId;
    final key = _key(path);
    final noBase = e.baseText == null;
    // Not settled yet: the entry stays and is listed, and the backoff tries it
    // again (start-up replay and _replayEntry don't schedule one).
    Never wait(String why, String detail) {
      if (!_disposed) _backoff.schedule();
      throw _ReplayFailure(why, detail: detail, transient: true);
    }

    for (var round = 0; round < 5; round++) {
      String? back;
      String? invalid;
      var absent = false;
      Object? readError;
      for (var read = 0; back == null && invalid == null; read++) {
        try {
          back = await st.readText(id);
        } on FormatException {
          invalid = 'not valid UTF-8 text';
        } on FileSystemException catch (ex) {
          if (read < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue; // a lock may pass; a few tries
          }
          absent = !await File(path).exists();
          readError = ex;
          if (!absent) {
            // The store reports text that isn't UTF-8 as a failed read too.
            try {
              utf8.decode(await File(_obs(path)).readAsBytes());
            } on FormatException {
              invalid = 'not valid UTF-8 text';
              readError = null;
            } on FileSystemException {
              // Locked: not settled yet.
            }
          }
          break;
        }
      }
      if (readError != null) {
        if (!absent) wait("the saved page of $label can't be checked just now", '$readError');
        // 3c: the file is gone. The page comes back with its edits, by an
        // exclusive publish (a file that arrives meanwhile is not overwritten).
        try {
          await _writeNew(loc, merged);
        } on Object catch (ex) {
          wait("the saved page of $label can't be written back just now", '$ex');
        }
        continue;
      }
      NotedPage? now;
      String? unreadable = invalid;
      if (back != null) {
        try {
          now = readPage(back);
          if (now.id != id) unreadable = 'it holds a different page';
        } on PageFormatException catch (ex) {
          unreadable = ex.message;
        }
      }
      if (unreadable != null || now == null) {
        // 3a: the merged page is published beside the file; the file is listed
        // as a page that can't be opened, like any file that turns unreadable.
        final copy = await _publishConflictCopy(st, merged);
        if (copy == null) wait("the saved page of $label can't be copied beside its file", 'copy not published');
        final name = copy.split(RegExp(r'[\\/]')).last;
        final notice = 'The edits kept for $label were saved, but the page was then changed and can no longer '
            'be read ($unreadable). They are kept in $name';
        if (now != null) {
          _known.remove(key);
        } else if (back != null) {
          _known[key] = back;
        }
        _landedProblems[id] = (path: path, why: notice);
        await _deleteEntry(rec, e);
        _knownUnreadable(loc, key, path, notice);
        return true;
      }
      if (back == out) {
        // The page reads back as written: it must pass the check too. If not,
        // the entry is merged again (0124's "landed and verified").
        final why = theirs != null && noBase
            ? verifyConflictCopyMerge(now, theirs, mine, topOfChain: _topOfChain(loc, theirs), forRecovery: true)
            : verifyRecoveredPage(base: base, mine: mine, theirs: theirs, result: now);
        if (why != null) {
          _landedText.remove(e.gen);
          throw _ReplayFailure(_notAllKept(label), detail: why);
        }
      }
      var at = DateTime.now().millisecondsSinceEpoch;
      try {
        at = (await File(path).lastModified()).millisecondsSinceEpoch;
      } on FileSystemException {
        // The time of now.
      }
      final r = recordLostEdits(base, mine, merged, now, at: at, structure: !noBase);
      if (identical(r.page, now)) {
        await _applyClosed(now, loc, key, path);
        if (r.foreignBack) {
          _landedProblems[id] = (path: path, why: _landedThenChanged(label));
        }
        await _deleteEntry(rec, e);
        return true;
      }
      await syncHook?.call('recover-conflict-before-publish', path);
      var published = false;
      try {
        published = await _writeIfUnchanged(loc, r.page, back);
      } on Object catch (ex) {
        wait("the saved page of $label can't be written just now", '$ex');
      }
      if (published) await syncHook?.call('recover-conflict-published', path);
    }
    wait('the saved file of $label keeps changing', 'the page file changed on every attempt to settle the edits');
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
      if (_busy.containsKey(id)) continue; // moving, deleting or replaying: landed at a later check (R5)
      if (_isLocked(loc) || (onlyLoc != null && loc != onlyLoc)) continue;
      try {
        final to = _assetsDir(loc, id);
        final done = <_LandedFile>[];
        final copy = AttachmentCopy();
        // A held binder folder gets nothing (checked at the folder's turn).
        if (!await _binderGate(loc) || _isLocked(loc)) {
          // Refused for now (the binder file unreadable a moment): tried again.
          if (!_isLocked(loc)) retry = true;
          continue;
        }
        try {
          await _landFiles(kept, to, done, copy);
        } finally {
          // What a landing kept as damaged is said, as a move says it (0132).
          if (copy.damagedKept.isNotEmpty) {
            _postCopyNotices(AttachmentCopy()..damagedKept.addAll(copy.damagedKept), _placeName(loc), 'the recovery folder');
          }
          if (copy.keptAside.isNotEmpty) {
            final note = _attachmentsNote(const [], copy.keptAside, _placeName(loc), 'the recovery folder');
            _templateNotice('${note.substring(0, 1).toUpperCase()}${note.substring(1)}');
          }
        }
        for (final f in done) {
          if (!await _holdsContent(f.source, f.name, f.target)) {
            throw FileSystemException('The kept file ${f.name} did not land with its content');
          }
        }
        await keptLandedHook?.call(kept.path);
        // The folder that holds the landed files must still be this binder's:
        // otherwise the kept files stay, and land again at L.
        if (!await _binderGate(loc) || _isLocked(loc)) {
          retry = true;
          continue;
        }
        // Only what was verified is deleted, one file at a time; whatever else
        // is in the folder (an incomplete temp file, a file that arrived
        // meanwhile) keeps the folder.
        for (final f in done) {
          // One coordinated call: the file goes, and its folder is written (N4).
          await coordinated(
            CoordinatedWrite([
              CoordinationIntent(f.source.path, CoordinationKind.delete),
              CoordinationIntent(f.source.parent.path, CoordinationKind.write),
            ]),
            () => f.source.delete(),
          );
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
      } on StorageBusy catch (e) {
        // The folder's coordination refused: nothing was written another way
        // (C2); the landing is tried again.
        debugPrint('The folder is busy; not moving the kept files of page $id: $e');
        _keptProblems[kept.path] =
            'The files kept for "${_titleOrUntitled(_metas[id]?.title ?? '')}" could not be moved into place: the folder is busy.';
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
      final settled = _readHold == null &&
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

  // Copies the files of the kept folder [from] into [to]. A target named by
  // its hash goes through [copyAttachmentFile], the attachment copy's per-file
  // path: a target that doesn't hold its hash is never replaced, it is kept as
  // `.damaged-<12 hex>` (0132) and the verified copy is published exclusively;
  // the outcome is in [r]. Any other name that differs is someone's file that
  // only shares the name, and is never replaced. Which names land is
  // [attachmentNameToTake]'s rule (a `<hash>.tmp` attachment keeps its name; a
  // complete `<hash>.<ext>.tmp` lands without `.tmp`). Leftover unique temp
  // names of a stopped write (`<name>.<micros>-<n>.tmp`) are first put back,
  // when complete, under their own name in [from] and land with the rest; the
  // others stay and keep the folder. Every file that is in place with verified
  // content is added to [done].
  // Removes a landing temp (`<target>.landing.tmp`, a fixed name) as one
  // coordinated call: delete the file, write its folder (N4). A StorageBusy
  // propagates; the landing is tried again.
  static Future<void> _removeLandingTemp(File tmp) async {
    if (!await tmp.exists()) return;
    await coordinated(
      CoordinatedWrite([
        CoordinationIntent(tmp.path, CoordinationKind.delete),
        CoordinationIntent(tmp.parent.path, CoordinationKind.write),
      ]),
      () => tmp.delete(),
    );
  }

  static Future<void> _landFiles(Directory from, Directory to, List<_LandedFile> done, AttachmentCopy r) async {
    await createFolderCoordinated(to);
    await sweepAttachmentLeftovers(from, r);
    await for (final e in from.list()) {
      final raw = _baseName(e.path);
      final sep = Platform.pathSeparator;
      if (e is Directory) {
        await _landFiles(e, Directory('${to.path}$sep$raw'), done, r);
        continue;
      }
      if (e is! File) continue;
      final name = await attachmentNameToTake(e, raw);
      if (name == null) continue;
      final target = File('${to.path}$sep$name');
      final isHash = _hashName.firstMatch(name) != null;
      final collision = FileSystemException('a different $name is already there; both are kept', target.path);
      if (isHash) {
        // The source against its own name first: the copy hashes the source
        // only when a target exists.
        if (!await _holdsContent(e, name, e)) {
          throw FileSystemException('The copy of $name differs from the kept file', e.path);
        }
        await copyAttachmentFile(e, target.path, name, r);
        if (r.verified.any((c) => c.target.path == target.path)) {
          // A landing temp left by an earlier version goes only while it holds the
          // source's bytes (length and hash); anything else, or an error, keeps it.
          try {
            final stale = '${target.path}.landing.tmp';
            if (await FileSystemEntity.type(stale, followLinks: false) == FileSystemEntityType.file) {
              await deleteFileIfMatches(stale, identity: ContentIdentity(await e.length(), _hashName.firstMatch(name)!.group(1)!));
            }
          } on StorageBusy {
            rethrow; // the landing is tried again (C2)
          } on FileSystemException {
            // Only a leftover; the landing goes on.
          }
          done.add(_LandedFile(e, name, target));
        } else if (r.stillChanging.contains(target.path)) {
          throw FileSystemException('$name is still changing in the page folder', target.path);
        } else {
          throw collision;
        }
        continue;
      }
      final tmp = File('${target.path}.landing.tmp');
      if (await _holdsContent(e, name, target)) {
        await _removeLandingTemp(tmp); // left by an earlier try
        done.add(_LandedFile(e, name, target));
        continue;
      }
      if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw collision;
      }
      await _removeLandingTemp(tmp);
      try {
        // The temp has a fixed name, so its creation is a coordinated write too.
        await coordinated(
          CoordinatedWrite([CoordinationIntent(to.path, CoordinationKind.write)]),
          () => e.copy(tmp.path),
        );
        if (!await _holdsContent(e, name, tmp)) {
          throw FileSystemException('The copy of $name differs from the kept file', e.path);
        }
        // Never replaces: a different file that arrived since the check
        // above stays as it is, and the kept source stays too.
        if (!await publishExclusive(tmp, target.path, beforeOsCall: landBeforePublishHook)) throw collision;
      } catch (_) {
        try {
          await _removeLandingTemp(tmp);
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
      await removeFolderCoordinated(d);
    } on StorageBusy {
      rethrow; // not "not empty": the landing is tried again (C2)
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
    FileStamp? pubStamp;
    final published = await _underFolderLock(st, () async {
      // Checked again inside the lock: the location may have gone while this waited.
      await _assertCanWrite(loc);
      if (!await st.saveNewText(page, text, beforePublish: beforePublish, onPublishStamp: (s) => pubStamp = s)) return false;
      _emitPublished(path, identity, () => text);
      return true;
    });
    if (!published) return false;
    _known[key] = text;
    _pathId[key] = page.id;
    _recordStamp(key, pubStamp);
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
      _noteDiskText(st.pathFor(id), text);
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
    FileStamp? pubStamp;
    final published = await _underFolderLock(st, () async {
      // Checked again inside the lock: the location may have gone while this waited.
      await _assertCanWrite(loc);
      if (!await st.saveNew(page, beforePublish: beforePublish, onPublishStamp: (s) => pubStamp = s)) return false;
      _emitPublished(path, identity, () => writePage(page));
      return true;
    });
    if (!published) return false;
    _known[key] = writePage(page);
    _pathId[key] = page.id;
    _recordStamp(key, pubStamp);
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
    onPageContent?.call(loc, page);
    return true;
  }

  // PageStore.scan puts back what an interrupted compare-and-swap replace
  // left aside, so it must not run while one is in flight on the same folder
  // (0128). Both go through _underFolderLock: one at a time per folder. The job
  // is a single store call, never another locked call, so they can't wait on
  // each other.
  Future<T> _underFolderLock<T>(PageStore st, Future<T> Function() job, {bool gate = true}) =>
      _lockRun(st.directory, job, gate: gate);

  // How long a read of a page file waits for its folder's other jobs.
  static const Duration _readLockWait = Duration(milliseconds: 500);

  // A single read of a page file, taking its turn with the writes and scans of
  // [folder] (they are short, so the turn comes at once). A job that has the
  // folder for longer than [_readLockWait] is hung (a stalled write holds its
  // lock until it ends, and the reads of that folder must not wait for it), and
  // the read goes ahead without the lock, as it did before reads took turns.
  // Not queued at all when the caller already runs inside a job on the folder,
  // which would wait on itself.
  Future<T> _readUnderFolderLock<T>(
    Directory folder,
    Future<T> Function() read, {
    void Function()? onAbandoned,
  }) async {
    if (FolderLocks.isHeld(folder)) return read();
    final started = Completer<void>();
    var abandoned = false;
    final job = folderLocks.run<T?>(folder, () async {
      if (abandoned) return null;
      started.complete();
      return read();
    });
    // What the read's hold requested starts when the job is done (G1).
    _afterLockJob(job);
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
    onAbandoned?.call();
    try {
      return await read();
    } finally {
      // Read outside the lock: what it requested starts now.
      _startRequested();
    }
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

  Future<List<PageEntry>> _scan(PageStore st, {bool createFolder = true, bool sweep = true}) async =>
      (await _scanWithVerdict(st, createFolder: createFolder, sweep: sweep)).entries;

  // A scan, which writes no page itself; its sweep (which can put back asides
  // and publish copies) runs only on this binder's own file, checked in the
  // scan's own turn: another binder's file holds the folder (G2, without
  // throwing) and the pages are listed read-only; a file that isn't there or
  // can't be read sweeps nothing. [expectId]: the id a binder being opened
  // must have (its section is not listed yet); the verdict then holds nothing.
  Future<({List<PageEntry> entries, BinderVerdict verdict, Binder? other})> _scanWithVerdict(
    PageStore st, {
    bool createFolder = true,
    bool sweep = true,
    bool opening = false,
    String? expectId,
  }) {
    // A store made again (a binder opened again) is told which files were chosen.
    final dir = _key(st.directory.path);
    for (final e in _adoptedFiles.entries) {
      if (_key(File(e.value).parent.path) == dir) st.adopt(e.key, e.value);
    }
    return _underFolderLock(st, gate: false, () async {
      var verdict = BinderVerdict.none;
      Binder? other;
      final s = _sectionAt(st.directory.path);
      if (opening) {
        (verdict: verdict, other: other) = await _readVerdictLocked(st.directory.path, expectId);
      } else if (s != null) {
        verdict = await _classifyLocked(s);
        if (verdict == BinderVerdict.other) other = s._heldOther;
      }
      final mayWrite = verdict == BinderVerdict.own || verdict == BinderVerdict.none;
      // No scan sweeps while a found add runs: set-aside files may belong to a
      // write another device has under way.
      // A pull-only folder is never created by a read (G2).
      final entries = await st.scan(
        createFolder: createFolder && !_pullOnly(st.directory.path),
        stamps: true,
        sweep: sweep && _sweepOff == 0 && mayWrite && _mayTouch(st.directory.path) && (opening || !_heldAt(s?.path ?? '')),
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
      return (entries: entries, verdict: verdict, other: other);
    });
  }

  // The binder file of folder [dir] as a binder being opened finds it, inside
  // a turn at the folder, with no side effects: [want] null takes any readable
  // binder as its own.
  Future<({BinderVerdict verdict, Binder? other})> _readVerdictLocked(String dir, String? want) async {
    if (_pullOnly(dir)) return (verdict: BinderVerdict.none, other: null);
    final r = await _readBinderText(_binderStore(Directory(dir)).file);
    final text = r.text;
    if (text == null) {
      _recheckLater(dir); // the watcher looks again soon
      return (verdict: BinderVerdict.unreadable, other: null);
    }
    try {
      final b = Binder.parse(text);
      if (want != null && b.id != want) return (verdict: BinderVerdict.other, other: b);
      return (verdict: BinderVerdict.own, other: null);
    } on BinderFormatException {
      _recheckLater(dir);
      return (verdict: BinderVerdict.unreadable, other: null);
    }
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
    FileStamp? pubStamp;
    // The check is made inside the lock, right before the replace.
    final result = await _underFolderLock(st, () async {
      await _assertCanWrite(loc);
      final path = st.pathFor(page.id);
      if (onlyAtPath != null && _key(path) != _key(onlyAtPath)) {
        pathMoved = true;
        return null;
      }
      final r = await st.saveIfUnchanged(page, expectedText, onPublishStamp: (s) => pubStamp = s);
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
    _recordStamp(key, pubStamp);
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
    onPageContent?.call(loc, page);
    // A file the aside's final check kept (a version a sync client wrote into
    // the set-aside copy) is a conflict copy of this page: merge it now, on every
    // platform. Not awaited: checkFile waits for the save chain to be idle, and
    // this save runs on it.
    if (!_disposed) {
      for (final kept in [if (result.keptPath != null) result.keptPath!, ...result.alsoKept]) {
        unawaited(checkFile(kept));
      }
    }
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
      _noteDiskText(path, text);
      final merged = mergePage(basePage, mine, remotePage, _mergeCodecs(id, [basePage, mine, remotePage]), theirsTime: time).page;
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
    final merged = mergePage(basePage, c.page, remotePage, _mergeCodecs(id, [basePage, c.page, remotePage]), theirsTime: time).page;
    final changed = writePage(merged) != writePage(c.page);
    if (changed) {
      c.applyExternal(merged); // not an undo step
      _syncDisallowed(); // the merged header may disallow a type
    }
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
    if (_isBinderCopyFile(path)) {
      final dir = File(path).parent.path;
      final k = 'copies:${_key(dir)}';
      _debounce[k]?.cancel();
      _debounce[k] = Timer(watchDebounce, () {
        _debounce.remove(k);
        unawaited(refreshBinderCopies(dir));
      });
      return;
    }
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

  // A temporary file, conflict copy or aside beside a binder file.
  bool _isBinderCopyFile(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.startsWith('noted-binder') && name != binderFileName;
  }

  /// Lists the copies beside the binder file of the folder [dir] again, as when
  /// a copy arrives or goes while the app runs; rows of removed copies go.
  Future<void> refreshBinderCopies(String dir) async {
    if (_disposed) return;
    final key = _key(dir);
    final s = _binders.values.where((b) => _key(b.path) == key).firstOrNull;
    if (s == null) return;
    final store = _binderStore(Directory(s.path));
    await _lockRunUngated(Directory(s.path), () => _listCopiesLocked(s, store));
  }

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
      if (_disposed) return;
      await _checkFile(path);
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
    if (_isBinderCopyFile(path)) {
      await refreshBinderCopies(File(path).parent.path);
      return;
    }
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
  /// changed by someone else. The file is read under the folder's lock, so this
  /// notebook's own replace of it is never seen half way.
  ///
  /// Does nothing if the file still holds exactly what this app last wrote or
  /// read (unless [force] is true). A changed cover is taken over (the sidebar
  /// and the cover update). A file that is damaged or from a newer app marks the
  /// binder unreadable. A deleted one makes the binder unavailable at once,
  /// unless a set-aside copy of it stands in the folder (a replace is under
  /// way): then it is looked at again soon. The file is never written in either
  /// case. The same binder's file readable again opens the binder afresh and
  /// brings back the page that was open. A file of another binder than the one
  /// this device recorded for the folder lists the binder read-only.
  Future<void> checkBinderFile(String path, {bool force = false}) {
    final job = _checking.then((_) async {
      await _chain.idle;
      if (!_disposed) await _checkBinderFile(path, force: force);
    }).catchError((Object e) {
      debugPrint('Checking $path failed: $e');
    });
    _checking = job;
    return job;
  }

  // Looks again at the binder file of folder [path] in a moment.
  void _recheckLater(String path) {
    final key = _key(path);
    _asideTimers.remove(key)?.cancel();
    _asideTimers[key] = Timer(binderRecheckDelay, () {
      _asideTimers.remove(key);
      if (_disposed) return;
      unawaited(checkBinderFile(_binderStore(Directory(path)).file.path));
    });
  }

  Future<void> _checkBinderFile(String path, {bool force = false}) async {
    if (!_isBinderFile(path)) return;
    final dirKey = _key(File(path).parent.path);
    final section = _binders.values.where((b) => _key(b.path) == dirKey).firstOrNull;
    if (section == null) return;
    if (section.missing) return; // checkFolders brings a returned folder back
    final dir = Directory(section.path);
    var abandoned = false;
    // G1: what the read found holds the folder (or clears its hold) before the
    // lock is released.
    var held = false;
    var cleared = false;
    final got = await _readUnderFolderLock(
      dir,
      () async {
        final r = await _readBinderText(File(path));
        if (!_disposed && identical(_binders[section.path], section)) {
          (held: held, cleared: cleared) = await _classifyWatched(section, r, abandoned: abandoned);
        }
        return r;
      },
      onAbandoned: () => abandoned = true,
    );
    final text = got.text;
    String? unreadable = got.damaged;
    if (got.failure != null) {
      // Locked or offline for now: not missing and not damaged. Look again later;
      // only a folder that is gone is dealt with.
      if (!_disposed && !await Directory(section.path).exists()) await _binderGone(section);
      return;
    }
    if (_disposed || !identical(_binders[section.path], section)) return;
    if (held || cleared) {
      await _heldRead(section, text, unreadable, available: section.available, status: section.status);
      return;
    }
    if (text == null && unreadable == null) {
      // The file is not there (W).
      if (!await dir.exists()) {
        // The folder is gone, not just the file.
        if (_disposed) return;
        await _binderGone(section);
        return;
      }
      if (_disposed) return;
      // A read that ran after its lock wait was given up may have caught our own
      // replace half done: it decides nothing.
      if (abandoned) {
        _recheckLater(section.path);
        return;
      }
      if (section.status == BinderStatus.unavailable) return;
      if (await _holdsBinderAside(section.path)) {
        // A replace is under way (or was killed): look again soon, and put the
        // aside back once it has stood for [asideRestoreAfter] with no file.
        if (_pullOnly(section.path)) return;
        section.asideSince ??= now();
        if (now().difference(section.asideSince!) >= asideRestoreAfter) {
          section.asideSince = null;
          await _restoreAside(section);
        }
        _recheckLater(section.path);
        return;
      }
      section.asideSince = null;
      _binderText.remove(dirKey);
      if (_pullOnly(section.path)) {
        // Its pages stay listed and its open page stays open (G6).
        await _binderGone(section);
        return;
      }
      await _disableBinder(
        section,
        BinderStatus.unavailable,
        'No $binderFileName in this folder.',
        fileMissing: true,
      );
      return;
    }
    section.asideSince = null;
    // While a hold is set the same text still counts.
    if (!force && section._hold == null && text != null && _binderText[dirKey] == text) {
      if (section.available && _coverPending.containsKey(dirKey)) _queueCoverTries(force: false);
      return;
    }
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
      final want = _binderIds[dirKey];
      if (want != null && binder.id != want) {
        // Another binder's file (I): listed read-only, never written, never used
        // by AI, until the user chooses it.
        if (section.available) {
          await _otherBinder(section, binder);
        } else if (section.other?.id != binder.id) {
          // Its pages are listed again, read-only.
          await _reopenBinder(section.path);
        }
        return;
      }
      if (section.available) {
        await _takeOwnBinder(section, binder);
      } else {
        await _reopenBinder(section.path);
      }
      if (!_disposed && _coverPending.containsKey(dirKey)) _queueCoverTries(force: false);
      return;
    }
    if (section.available) {
      await _damageBinder(section, unreadable ?? 'unreadable');
    } else if (section.status == BinderStatus.unavailable) {
      // The folder was unusable and now holds a damaged file: list its pages.
      await _reopenBinder(section.path);
    } else if (section.reason != unreadable || section.other != null) {
      section
        ..reason = unreadable
        ..other = null
        ..fileMissing = false;
      notifyListeners();
    }
  }

  // An available binder's own file, read again: the screen takes it.
  Future<void> _takeOwnBinder(BinderSection section, Binder binder) async {
    // Another binder taking the place of the one shown (no id was recorded to
    // tell them apart): what the open cover has typed is taken first (D2).
    if (section.saved != null && section.saved!.id != binder.id && _coverTypingPath == section.path) {
      _takeCoverTyping();
    }
    section.saved = binder;
    _recompute(section);
    section.lastEdited = now();
    notifyListeners();
    // The id is recorded only where none is (I).
    // A found add of this folder saves (or undoes) it itself: a save here could
    // list the folder with another id before the add looks at it.
    if (_recordBinderId(section.path, binder) && !_foundAdds.containsKey(_key(section.path))) {
      await _saveSettings();
    }
    await _binderSeam('adopted', section.path);
  }

  // The rest of a watcher read that set or cleared a hold (G1). The hold's
  // own work runs first (steps 3 and 4, or L, which reopens an unavailable
  // binder); then what is left acts on the state the read found
  // ([available], [status]): an available binder whose own file was read takes
  // it, and a binder that was not available is listed again for another
  // binder's file or a damaged one, as before.
  Future<void> _heldRead(
    BinderSection section,
    String? text,
    String? unreadable, {
    required bool available,
    required BinderStatus status,
  }) async {
    final dirKey = _key(section.path);
    section.asideSince = null;
    await _awaitHold(section.path);
    if (_disposed) return;
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
    final same = identical(_binders[section.path], section);
    if (binder == null && unreadable == null) return; // missing: the hold disabled it
    if (binder != null) {
      final want = _binderIds[dirKey];
      if (want != null && binder.id != want) {
        if (!available && same && section.other?.id != binder.id) await _reopenBinder(section.path);
        return;
      }
      // This binder's own file: L has landed (and reopened a binder that was
      // not available).
      if (available && same && section.available) await _takeOwnBinder(section, binder);
      if (!_disposed && _coverPending.containsKey(dirKey)) _queueCoverTries(force: false);
      return;
    }
    if (available || !same) return;
    if (status == BinderStatus.unavailable) {
      await _reopenBinder(section.path);
    } else if (section.reason != unreadable || section.other != null) {
      section
        ..reason = unreadable
        ..other = null
        ..fileMissing = false;
      notifyListeners();
    }
  }

  // G1, inside the watcher's locked read of [s]'s binder file: another id
  // holds the folder ([BinderHold.otherBinder]), a file that can't be parsed
  // [BinderHold.damaged], and no file (the folder there, no aside of a
  // replace, a read under the lock) [BinderHold.missing]. This binder's own
  // readable file clears a hold. Only synchronous state changes: the rest
  // runs in [_afterHold].
  Future<({bool held, bool cleared})> _classifyWatched(
    BinderSection s,
    ({String? text, bool missing, String? damaged, String? failure}) r, {
    required bool abandoned,
  }) async {
    const none = (held: false, cleared: false);
    if (r.failure != null || s.missing || _pullOnly(s.path)) return none;
    if (r.missing) {
      if (abandoned || (s.status == BinderStatus.unavailable && s._hold == null)) return none;
      if (!await Directory(s.path).exists() || await _holdsBinderAside(s.path)) return none;
      if (_disposed || !identical(_binders[s.path], s)) return none;
      _setHold(s, BinderHold.missing);
      return (held: true, cleared: false);
    }
    Binder? b;
    var problem = r.damaged;
    final text = r.text;
    if (text != null) {
      try {
        b = Binder.parse(text);
      } on BinderFormatException catch (e) {
        problem = e.message;
      }
    }
    if (b == null) {
      _setHold(s, BinderHold.damaged, reason: problem ?? 'unreadable');
      return (held: true, cleared: false);
    }
    final want = _binderIds[_key(s.path)];
    if (want != null && b.id != want) {
      _setHold(s, BinderHold.otherBinder, other: b);
      return (held: true, cleared: false);
    }
    if (s._hold != null) {
      _clearHold(s);
      return (held: false, cleared: true);
    }
    return none;
  }

  // Waits for the work of binder folder [path]'s hold that a read started,
  // unless this runs inside that work.
  Future<void> _awaitHold(String path) async {
    final key = _key(_normalizePath(path));
    final inside = Zone.current[_holdRunKey];
    if (inside is _HoldRun && inside.active && inside.key == key) return;
    _startRequested();
    final run = _holdRuns[key];
    if (run != null) await run;
  }

  // Puts back the asides of a replace that stalled (S, under the lock), then
  // lists what is there.
  Future<void> _restoreAside(BinderSection section) async {
    final store = _binderStore(Directory(section.path));
    await _lockRunUngated(Directory(section.path), () async {
      await store.sweepLeftovers(restore: _mayTouch(section.path));
      await _listCopiesLocked(section, store);
    });
  }

  /// The binder file of an available binder can't be read any more. The binder
  /// stays in the sidebar with its pages, which turn read-only: the open
  /// page's unsaved edits were kept in recovery by the hold. Neither the binder file
  /// nor any page of the binder is written until the file is readable again.
  Future<void> _damageBinder(BinderSection section, String reason) async {
    final path = section.path;
    // The open page's pending edits were kept in recovery first (held edits).
    if (_disposed || _binders[path] != section) return;
    // What the open cover has typed is taken before anything changes (D2).
    if (_coverTypingPath == path) _takeCoverTyping();
    section
      ..status = BinderStatus.unreadable
      ..reason = reason
      ..binder = null
      ..saved = null
      ..other = null
      ..fileMissing = false;
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    notifyListeners();
  }

  /// Takes the pages of the binder out of the notebook and marks it unusable.
  /// Its files, binder file included, are not touched. The page that was open
  /// is remembered, to open again when the same binder's file is read again.
  Future<void> _disableBinder(
    BinderSection section,
    BinderStatus status,
    String reason, {
    bool fileMissing = false,
  }) async {
    section.missing = false;
    final path = section.path;
    // What the open cover has typed is taken before anything changes (D2).
    if (_coverTypingPath == path) _takeCoverTyping();
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId);
    if (openHere) section.returnTo = currentId;
    // Saves while the store still works. A page whose edits are safe nowhere
    // stays open, read-only, under the warning (3.5).
    var left = true;
    if (openHere) left = await _leaveOpenPage(stayIfUnsafe: true);
    if (openHere && left) _disposeCurrent();
    for (final id in ids) {
      _metas.remove(id);
      _heldPlacement.remove(id);
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
    if (_coverTypingPath == path) _takeCoverTyping();
    section
      ..status = status
      ..reason = reason
      ..binder = null
      ..saved = null
      ..other = null
      ..fileMissing = fileMissing
      ..store = null
      ..unreadable = const []
      ..tree = PageTree.build(const []);
    if (_coverPath == path) _coverPath = null;
    _rebuildTree();
    _syncWatchers();
    if (openHere && left) {
      await _openFallback(_standalone);
      section.fallbackId = currentId;
    } else if (openHere) {
      _orphanLoc = path;
      _syncReadOnly();
    }
    if (fileMissing && !_disposed) {
      // The copies of the binder file there are listed at once.
      final store = _binderStore(Directory(path));
      await _lockRunUngated(Directory(path), () => _listCopiesLocked(section, store));
    }
  }

  /// Reads binder [path] afresh, as when its file is readable again.
  @visibleForTesting
  Future<void> reopenForTest(String path) => _reopenBinder(path);

  /// Marks binder [path] unreadable at once, without waiting for the save
  /// chain, as a state change that overtakes a queued write would.
  @visibleForTesting
  void markDamagedForTest(String path) {
    _binders[path]
      ?..status = BinderStatus.unreadable
      ..binder = null
      ..saved = null;
  }

  /// How many cover changes are not written yet in folder [path], whichever
  /// binder they are for.
  @visibleForTesting
  int coverPendingCountForTest(String path) => _coverPending[_key(path)]?.length ?? 0;

  /// Forgets the binder id recorded for [path], as a list written before ids
  /// were recorded has none.
  @visibleForTesting
  void forgetBinderIdForTest(String path) => _binderIds.remove(_key(path));

  /// A binder whose file is readable again: reads the folder afresh.
  //
  // A held folder that is not this binder's again stays held; with this
  // binder's own file, what the hold kept lands (L): the open page is merged
  // and saved, then the closed entries replay.
  Future<void> _reopenBinder(String path) async {
    reopenCountForTest++;
    final old = _binders[path];
    // Pages left over from a binder that was listed read-only are read again;
    // the open one stays, so its view isn't torn down.
    for (final e in _loc.entries.where((e) => e.value == path && e.key != currentId).toList()) {
      _forgetPage(e.key);
    }
    final fresh = await _openBinder(path);
    if (_disposed) return;
    fresh
      ..returnTo = old?.returnTo
      ..fallbackId = old?.fallbackId;
    if (old != null && old._hold != null && fresh._hold == null && !fresh.available) {
      fresh
        .._hold = old._hold
        .._heldOther = old._heldOther
        .._holdReason = old._holdReason;
    }
    _binders[path] = fresh;
    final changed = _recordBinderId(path, fresh.binder);
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    if (changed) await _saveSettings();
    await _promoteReleased();
    await _mergePendingCopies(inQueue: true);
    if (!fresh.available || _disposed) return;
    await _afterResume(await _resumeOpenPage(path, force: true));
    await _recoverPending(onlyLoc: path);
    if (!_disposed && identical(_binders[path], fresh)) await _returnToPage(fresh);
  }

  // The same binder's file is back: the page that was open when it went away
  // opens again, unless the user has chosen another page since.
  Future<void> _returnToPage(BinderSection section) async {
    final id = section.returnTo;
    if (id == null) return;
    final path = section.path;
    final fallback = section.fallbackId;
    section
      ..returnTo = null
      ..fallbackId = null;
    if (_loc[id] != path) return; // the page is not in the binder any more
    try {
      if (_orphanLoc == path && currentId == id) {
        // The read-only view it left still shows it: resumed in place.
        await _afterResume(await _resumeOpenPage(path, force: true));
      } else if (fallback != null && currentId == fallback && fallback != id) {
        await open(id);
      }
    } on Object catch (e) {
      debugPrint('Opening page $id again failed: $e');
    }
  }

  // Drops what the notebook knows of page [id] (not its file).
  void _forgetPage(String id) {
    _metas.remove(id);
    _heldPlacement.remove(id);
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
    try {
      return await _checkFileNow(path);
    } finally {
      _expiryAfterCheck(path);
    }
  }

  Future<bool> _checkFileNow(String path) async {
    if (!path.endsWith(PageStore.extension)) return false;
    final loc = _locationOf(path);
    if (loc == null) return false;
    await syncHook?.call('check-start', path);
    final key = _key(path);
    // A page being moved is looked at again when the move ends (2d).
    if (_pathId[key] case final moving? when _busy[moving] == _busyMoving) return false;
    // A file that is not downloaded (or a stub with no file) is not read, which
    // would download it, and is not gone: nothing is learned from it now. The
    // download is asked for, and the file is looked at again on its change
    // event. An open page's save meets the same file and keeps its edit (R5.5).
    if (isDataless(path)) {
      requestDownload?.call(path);
      return false;
    }
    final file = File(path);
    final openId = _current?.page.id;
    // Decided by path, not by _pathId: that entry is dropped when the file is
    // deleted, and a sync client often deletes first and renames the new file in.
    final isOpen = openId != null && _preview == null && _isOpenFile(loc, key);
    String? text;
    FileStamp? readStamp; // the file's stamp, if it didn't change during the read
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
      //
      // A file whose stamp is the one last classified is not read (rule P, S): the
      // open page's file and a blocked page are always read.
      Future<({String text, int time, FileStamp? stamp, bool skip})> read() => _readUnderFolderLock(file.parent, () async {
        final before = fileStamp(path);
        if (!isOpen && _diskBlockId == null && before != null && _fileStamps[key] == before) {
          return (text: '', time: 0, stamp: before, skip: true);
        }
        if (before != null) await syncHook?.call('check-read', path);
        if (before != null || file.existsSync()) PageStore.fileReadObserver?.call(path);
        final s = await file.readAsString();
        final t = (await file.lastModified()).millisecondsSinceEpoch;
        // Unchanged across the read, and not a link (a link is read through).
        final stable = before != null && before == fileStamp(path) && !FileSystemEntity.isLinkSync(path);
        return (text: s, time: t, stamp: stable ? before : null, skip: false);
      });

      final got = isOpen ? await _whileBusy(read) : await read();
      if (got.skip) return false;
      if (_pathId[key] case final moving? when _busy[moving] == _busyMoving) return false;
      text = got.text;
      time = got.time;
      readStamp = got.stamp;
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
      _unparkConsumed(path);
      _fileGone(loc, key, path);
      return false;
    }
    if (_movePublish.remove(key) != null) _emitPublished(path, null, () => text!);
    if (conflictCopyOriginalNames(path.split(RegExp(r'[\\/]')).last).isNotEmpty) {
      if (_pullOnly(loc)) {
        // Never merged here: a copy with a same-id original is listed as a
        // duplicate, also for the open page; any other file is handled as usual.
        if (await _listPullOnlyCopy(loc, key, path, text)) return false;
      } else if (!_isLocked(loc) && await _tryConflictCopy(loc, key, path, text, time)) {
        return false;
      }
    }
    if (_known[key] == text && !wasBlocked) {
      if (_pathId[key] != null) _recordStamp(key, readStamp);
      return false;
    }
    final moveBase = _known[key] == null ? _baseText[key] : null;
    if (moveBase == text && !wasBlocked) {
      // A moved file that holds what it held when it was moved: not a change.
      _known[key] = text;
      if (_pathId[key] != null) _recordStamp(key, readStamp);
      return false;
    }
    _unparkConsumed(path);
    final previous = _known[key];
    _known[key] = text;
    final NotedPage page;
    var saveAfterMerge = false;
    try {
      page = readPage(text);
      // Held until opened; dropped only by text that differs from one known
      // (N8). With none known, the read places it below.
      if ((previous ?? moveBase) != null && _heldPlacement.remove(page.id) != null) {
        _notices.add('"${_titleOrUntitled(page.meta.title)}" was changed elsewhere, so it was not placed.');
      }
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
      if (!isOpen && !_pullOnly(loc) && conflictCopyOriginalNames(_folderName(path)).isEmpty) {
        // Another file that holds the open page's id (another page's file that
        // took a moved page's name, a copy): while the page's own file is there it
        // is a duplicate, as a scan lists it, never merged into the page.
        final own = _storeOf(loc).pathFor(page.id);
        if (_key(own) != key && File(own).existsSync()) {
          _known.remove(key);
          _knownUnreadable(loc, key, path, 'duplicate page id ${page.id}');
          return false;
        }
      }
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
      // Recorded only where this read was applied (N4).
      if (_known[key] == text && _pathId[key] == page.id) _recordStamp(key, readStamp);
      if (_heldPlacement.containsKey(page.id)) await _applyHeldPlacement(page.id);
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
    final original = await PageStore.findConflictOriginal(path, copy, preferred: _adoptedFiles[copy.id]);
    if (original == null) return false;
    if (_disposed) return true;
    if (_pathId[key] == copy.id && copy.id != currentId) {
      // This copy is the file listed for the page (it was alone, or reported
      // before its original): the page is handed to the original, not evicted.
      NotedPage? op;
      try {
        op = readPage(await File(_obs(original)).readAsString());
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
    var originalPath = await PageStore.findConflictOriginal(path, copy, preferred: _adoptedFiles[copy.id]);
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
            PageStore.fileReadObserver?.call(path);
            text = await File(path).readAsString();
            time = (await File(path).lastModified()).millisecondsSinceEpoch;
          } on FileSystemException {
            if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) rethrow;
            break; // the copy is gone: nothing left to merge or delete
          }
          copy = readPage(text);
          originalPath = await PageStore.findConflictOriginal(path, copy, preferred: _adoptedFiles[copy.id]);
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

  // [consumed] is the text of the copy that [copy] was read from. Once the
  // merge is verified, the copy is kept in recovery (_keepConsumedCopy) and only
  // then deleted; the entry goes once a later read shows the file still holds
  // it (_recheckConsumedCopy). A null [copyPath] is that re-check's redo: the
  // entry is the copy, so the merge is all there is to do.
  Future<void> _mergeConflictCopy(
    String loc,
    String? copyPath,
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
      final top = _topOfChain(loc, original);
      final merged = mergeConflictCopy(
        original,
        copy,
        _mergeCodecs(id, [original, copy]),
        copyTime: time,
        topOfChain: top,
      ).page;
      if (writePage(merged) != writePage(original)) {
        c.applyExternal(merged);
        _syncDisallowed();
      }
      await flush();
      return verifyConflictCopyMerge(readPage(await st.readText(id)), original, copy, topOfChain: top);
    }

    // The page is closed: one chain job from the read of the original to
    // `_applyClosed`, so an open of the page can't run between the read and the
    // write and install the page as it was before. [open] is set when the page
    // turned out to be open after all (checked first, inside the job).
    Future<({bool open, String? failure})> closedBranch() async {
      if (openHere()) return (open: true, failure: null);
      PageStore.fileReadObserver?.call(originalPath);
      final text = await File(originalPath).readAsString();
      _noteDiskText(originalPath, text);
      final original = readPage(text);
      final top = _topOfChain(loc, original);
      final merged = mergeConflictCopy(
        original,
        copy,
        _mergeCodecs(id, [original, copy]),
        copyTime: time,
        topOfChain: top,
      ).page;
      final out = writePage(merged);
      if (out == text) {
        return (open: false, failure: verifyConflictCopyMerge(readPage(text), original, copy, topOfChain: top));
      }
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
      final failure = verifyConflictCopyMerge(readPage(back), original, copy, topOfChain: top);
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
        await syncHook?.call('conflict-copy-closed', copyPath ?? originalPath);
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
    if (copyPath == null) return; // a redo: the entry is the copy
    // Delete the copy only if it is still exactly what was merged.
    await syncHook?.call('copy-merged', copyPath);
    final String current;
    try {
      current = await File(_obs(copyPath)).readAsString();
    } on FileSystemException {
      if (await FileSystemEntity.type(copyPath) == FileSystemEntityType.notFound) return;
      rethrow;
    } on FormatException {
      throw const _SourceChanged();
    }
    if (current != consumed) throw const _SourceChanged();
    // Kept before it is deleted: a sync client may put the pre-merge original
    // back after the check above, and then the copy's content would be in no
    // file. Also when the merge wrote nothing (it may have been written before
    // a crash or a refusal here). The re-check waits until the delete is over.
    final mark = await _keepConsumedCopy(st, copy, time);
    final DeleteResult deleted;
    try {
      // Deleted only if it still holds exactly the text that was merged, checked
      // at the moment of deleting (0128); a copy that changed since is merged
      // again (with an entry of its own; this one is re-checked on its own).
      deleted = await _underFolderLock(st, () async {
        final r = await deleteFileIfUnchanged(copyPath, utf8.encode(consumed));
        if (r.deleted) _emitDeleted(copyPath);
        return r;
      });
    } finally {
      mark.deleting = false;
    }
    if (deleted.deleted) await syncHook?.call('copy-deleted', copyPath);
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
    _heldPlacement.remove(id);
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
        back = readPage(await File(_obs(path)).readAsString());
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
        _heldPlacement.remove(id);
        _loc.remove(id);
        _conflicts.remove(id);
        _touch(at);
        _rebuildTree();
      }
      await _promoteReleased();
      // Another device's delete: a consumed copy of the page is retired by the
      // re-check's read when it finds no file (the confirmation alone doesn't).
      var marked = false;
      for (final m in _consumedCopies.values) {
        if (m.pageId != id) continue;
        m.decideNow = true;
        marked = true;
      }
      if (marked && !_disposed) unawaited(_recoverPending(onlyLoc: loc));
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
        // A file that is a sync client's conflict copy of a file that exists
        // is merged, not chosen; a copy-shaped name without its original is a
        // page file like any other.
        if (conflictCopyOriginalNames(name).isNotEmpty) {
          NotedPage? page;
          try {
            page = readPage(await File(_obs(u.path)).readAsString());
          } on Object {
            page = null;
          }
          if (page != null && page.id == id && await PageStore.findConflictOriginal(u.path, page) != null) continue;
        }
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
          page = readPage(await File(_obs(u.path)).readAsString());
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
      _heldPlacement.remove(id);
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
      if (_key(st.pathFor(id)) != key && await st.directory.exists()) await _scan(st, sweep: _sweepOff == 0 && _mayTouch(st.directory.path));
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
    final result = mergePage(base, c.page, theirs, _mergeCodecs(c.page.id, [base, c.page, theirs]), theirsTime: time);
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
    final read = await _lockRunUngated(Directory(to), () => _binderStore(Directory(to)).read());
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
      fresh = await _openBinder(to, createFolder: false, sweep: false, expectId: id);
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
      final bytes = await File(_obs(path)).readAsBytes();
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

  // Folder access (R5.3) -------------------------------------------------------

  Future<void> _cloudWork = Future<void>.value();

  /// Completes when the folder-access pruning and releases started so far are done.
  @visibleForTesting
  Future<void> get cloudAccessIdle => _cloudWork;

  // Every storage location the notebook keeps: the binder folders, the standalone
  // folders (binders.json), the default page and binder folders (settings.json).
  // The folder access of a location, or of an ancestor of one, is never pruned.
  List<String> _retainedLocations() => [
    ..._binders.keys,
    ..._folders.keys,
    ..._readFolderPaths().map(_normalizePath),
    ?settings?.defaultPageFolder,
    ?settings?.defaultBinderFolder,
  ];

  // Only with `binders.json` read (no hold) and `settings.json` read.
  Future<void> _pruneCloudAccess() async {
    final access = icloud;
    if (access == null || _disposed || _settingsHeld != null) return;
    if (settings != null && !settings!.canRememberNotes) return;
    try {
      await access.prune(_retainedLocations);
    } on Object catch (e) {
      debugPrint('Pruning the folder access failed: $e');
    }
  }

  // A folder left the notebook's lists: its access goes unless it is still kept.
  void _cloudReleased(String path) {
    final access = icloud;
    if (access == null) return;
    // As the prune: nothing is released while settings.json can't be read.
    if (settings != null && !settings!.canRememberNotes) return;
    _cloudWork = _cloudWork
        .then((_) => access.released(path, _retainedLocations))
        .catchError((Object e) => debugPrint('Releasing folder access failed: $e'));
  }

  // Folders that come and go -------------------------------------------------

  void _startFolderTimer() {
    _folderTimer?.cancel();
    _folderTimer = null;
    if (!watchFiles || _disposed || folderCheckInterval <= Duration.zero) return;
    _folderTimer = Timer.periodic(folderCheckInterval, (_) {
      _discoveryTick();
      if (icloud != null) unawaited(icloud!.retryBusy());
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
    // Cover changes that were refused are tried again with each folder check.
    if (!_disposed && _coverPending.isNotEmpty) _queueCoverTries(force: false);
    // Kept files that failed to land are tried again, also for the open page.
    final rec = _recovery;
    if (_keptRetry && rec != null && !_disposed) {
      await _landKeptAssets(rec);
      if (!_disposed) notifyListeners();
    }
    if (!_disposed) await _strayCheck(); // O
  }

  // Whether the folder [dir] holds a binder file, or an aside of one that a
  // killed replace left (which counts as holding it, as for the engine).
  Future<bool> _holdsBinderFile(String dir) async {
    try {
      if (!await Directory(dir).exists()) return false;
      if (await File('$dir${Platform.pathSeparator}$binderFileName').exists()) return true;
    } on FileSystemException {
      return true; // can't tell: not gone
    }
    return _holdsBinderAside(dir);
  }

  // Whether the folder [dir] holds a set-aside copy of the binder file (named
  // exactly as a replace names it, [isBinderFileAsideName]): a replace is under
  // way, or was killed. The asides of temporary files and conflict copies don't
  // count.
  Future<bool> _holdsBinderAside(String dir) async {
    try {
      if (!await Directory(dir).exists()) return false;
      await for (final f in Directory(dir).list(followLinks: false)) {
        if (f is File && isBinderFileAsideName(f.path.split(RegExp(r'[\\/]')).last)) return true;
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
    // What the open cover has typed is taken before anything changes (D2).
    if (_coverTypingPath == path) _takeCoverTyping();
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
      await _disableBinder(old, BinderStatus.unavailable, fresh.reason ?? '', fileMissing: fresh.fileMissing);
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
    if (!_disposed && _coverPending.containsKey(_key(path))) retryCovers();
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
      final page = readPage(utf8.decode(await File(_obs(path)).readAsBytes()));
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
        PageStore.fileReadObserver?.call(path);
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
      _noteDiskText(path, text);
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
  void _announceKept(NotedPage page, {String? reason, String? promise}) {
    if (_disposed || !_told.add(page.id)) return;
    reason ??= _trouble.pageId == page.id && _trouble.reason.isNotEmpty ? _trouble.reason : 'it could not be saved';
    _keptNotices.add(
      KeptNotice(pageId: page.id, title: _titleOrUntitled(page.meta.title), reason: reason, promise: promise),
    );
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
      // A consumed copy's entry is not an edit waiting: the page opens editable.
      final pending = rec == null ? 0 : entries.where((e) => _waitingEntry(rec, e)).length;
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
          [for (final x in entries) if (_waitingEntry(rec!, x)) x],
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
          [for (final x in entries) if (_waitingEntry(rec!, x)) x],
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
          : [for (final e in rec.entriesFor(folder, id)) if (_waitingEntry(rec, e)) e];
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
    _noteDiskText(st.pathFor(id), text);
    final fileKey = _key(st.pathFor(id));
    final stamped = _fileStamps[fileKey];
    final hadText = _known[fileKey];
    _known[fileKey] = text;
    // A file that was classified at a stamp and is unchanged since was read as it
    // was: opening it keeps its stamp (it is read once, not again after closing).
    if (stamped != null && hadText == null && fileStamp(st.pathFor(id)) == stamped) _recordStamp(fileKey, stamped);
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
    if (text != null) {
      _noteDiskText(st.pathFor(id), text);
      _known[_key(st.pathFor(id))] = text;
    }
    _base = page;
    _metas[id] = shown.meta;
    var merged = shown;
    String? unlandable = unreadable;
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
            _mergeCodecs(id, [merged, e.page]),
            copyTime: e.time.millisecondsSinceEpoch,
            topOfChain: _topOfChain(loc, merged),
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
        _mergeCodecs(id, [eb, e.page, merged]),
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
        if (e.pageId == p.id && _waitingEntry(rec, e)) e,
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
    _clearKeptNotice(p.id);
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
        _clearKeptNotice(id);
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
    if (_pullOnly(dir.path)) throw NotebookException(pullOnlyMessageFor(dir.path));
    _assertTested(dir.path);
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
    // Into a binder folder: its binder file is checked at the folder's turn
    // first, and nothing is copied into a held one.
    final intoBinder = _sectionAt(dir.path)?.path;
    if (intoBinder != null && (!await _binderGate(intoBinder) || _isLocked(intoBinder))) {
      throw NotebookException(
        _isLocked(intoBinder) ? _lockedMessage(intoBinder) : binderUnreadableNowMessage,
      );
    }
    try {
      await createFolderCoordinated(dir);
      for (final src in sources) {
        try {
          // A missing folder copies nothing; a pull-only source is not swept,
          // nor the page's folder while it can't be written (a held binder).
          final pageSource = identical(src, sources.first) && loc != null;
          await _copyDir(
            src,
            targetAssets,
            into: result,
            sweepSource: !_pullOnly(src.path) && !(pageSource && _isLocked(loc)),
          );
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
    } on StorageBusy {
      throw const NotebookException("Couldn't save the copy: the folder is busy. Try again.", needsAction: true);
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
    // Before anything else: what the open cover has typed and not sent is taken
    // (the cover sends only on focus loss, Enter or when it closes). After a
    // Cancel the cover stays open and its later typing is recorded as usual.
    _takeCoverTyping();
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
    // One more try of each cover change that is not written yet.
    _queueCoverTries(force: true);
    // Other queued writes get the same time; what hangs is left behind.
    var stuck = false;
    await _chain.idle.timeout(bound, onTimeout: () => stuck = true);
    if (stuck) _chain.detach();
    // A cover change still not written would be lost: asked, never silently.
    for (final key in _coverPending.keys.toList()) {
      final s = _binders.values.where((b) => _key(b.path) == key).firstOrNull;
      for (final c in List<CoverChange>.of(_coverPending[key] ?? const [])) {
        if (!await _ask(UserQuestion.leaveCoverUnsaved, _coverLabel(s, c))) return false;
      }
    }
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
          _assertWritable(_undoLoc(d, page.id)); // a read-only place gets no file
          final st = _storeOf(_undoLoc(d, page.id));
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
    for (final t in _waitTimers) {
      t.cancel();
    }
    _waitTimers.clear();
    _holdRequests.clear();
    _folderWaiters = 0;
    _waitingForFolder.value = false;
    _waitingForFolder.dispose();
    _aiMerge?.dispose();
    _saveTimer?.cancel();
    for (final m in _consumedCopies.values) {
      m.timer?.cancel();
      m.timer = null;
    }
    _backoff.dispose();
    unawaited(_keptNotices.close());
    unawaited(_keptCleared.close());
    _folderTimer?.cancel();
    _settingsTimer?.cancel();
    for (final t in [..._coverTimers.values, ..._asideTimers.values]) {
      t.cancel();
    }
    _coverTimers.clear();
    _asideTimers.clear();
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

// One running [Notebook._afterHold] of a folder (by key); inactive once it
// ends, so work it started that outlives it is not "inside" it.
class _HoldRun {
  _HoldRun(this.key);
  final String key;
  bool active = true;
}

// A conflict copy that a merge consumed and that is kept as recovery entry
// [gen] until a read of its page file shows the merge holds (copy retire).
class _ConsumedCopy {
  _ConsumedCopy(this.gen, this.pageId, this.copyTime, this.since, this.copyAi);

  String gen; // moves with the entry when a move re-keys it
  final String pageId;
  final RawJson? copyAi; // the copy's own `ai` field, as written
  final int copyTime; // the copy's time, for the conflicts a redo records
  DateTime since; // the merge or the last redo: due [copyRetireAfter] after
  int rounds = 0; // redos made
  bool parked = false; // sync kept putting an older file back: no timer
  bool unparked = false; // a change of the file took it out of parked once
  bool deleting = true; // the copy file is still to be deleted
  bool failed = false; // the last redo or read failed: retried at the backoff
  bool decideNow = false; // due at once: a delete of the page was let go, or confirmed
  // This app's own changes of the page since the merge: the ids of nodes it
  // deleted, and the AI access the user chose ([userAi], raw; null: none, the
  // page follows its parent). A redo leaves them as they are.
  final Set<String> touched = {};
  bool headerTouched = false;
  RawJson? userAi;
  // The issues the user settled since the merge (0120), by box id: recorded
  // versions they resolved away, and landed markers they dismissed. A redo
  // and "held" leave them out, as for [touched].
  final Map<String, Set<BoxConflict>> resolved = {};
  final Set<String> dismissed = {};
  Timer? timer;
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

// A user action in flight; cleared when it ends (see Notebook._asUser).
class _UserAction {
  bool active = true;
  int counted = 0; // waits under this marker the note is counting
}
