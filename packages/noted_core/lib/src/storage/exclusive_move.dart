// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'coordination.dart';
import 'dataless.dart';
import 'exclusive_publish.dart'
    show
        checkWindowsName,
        debugLinkCalls,
        debugLinkErrno,
        debugPublishAsAndroid,
        nonLinkPublisher,
        windowsPath;
import 'file_stamp.dart';
import 'folder_walk.dart';
import 'stored_read.dart' show DownloadAsk, askSafely;

/// What [moveExclusive] did.
enum MoveOutcome {
  /// The file or folder is now at the target; nothing is at the source.
  moved,

  /// Something is at the target (before the call, or the call failed and
  /// something is there now). Both are untouched.
  targetExists,

  /// The source or target is in use, or the call failed for a reason that may
  /// pass. Nothing moved. The caller may retry.
  busy,

  /// The platform can't rename this pair: another volume, or a cloud file
  /// system that refuses it. Nothing moved; the caller copies instead.
  cannotRename,
}

/// How [moveExclusive] makes the call on POSIX. A seam for tests: set
/// [debugMoveStrategy] to force one.
enum MoveStrategy {
  /// The platform's no-replace rename (`renameat2` or `renamex_np`).
  native,

  /// Linux: `syscall(SYS_renameat2, ...)`, as when libc has no `renameat2`.
  linuxSyscall,

  /// `rename(2)` after an lstat that finds no target (Android below API 30,
  /// where `renameat2` is missing and the raw syscall may be killed by
  /// seccomp). The caller holds the lock that makes the pair safe. Forcing it
  /// uses the platform's own rename, on any platform.
  lstatRename,
}

/// A test seam: forces the way [moveExclusive] renames. Null in production.
/// Not exported by `noted_core.dart`; tests import this file. (No
/// `@visibleForTesting`: `package:meta` is not a dependency of this package.)
MoveStrategy? debugMoveStrategy;

/// A test seam: makes the no-replace rename call
/// (every strategy but [MoveStrategy.lstatRename]) fail with this errno
/// without calling. Null in production. Not exported by `noted_core.dart`.
int? debugNoReplaceErrno;

/// Moves the file or folder [from] to [to] only if nothing is at [to] at the
/// moment of moving: it never replaces and never deletes. Both must be on one
/// volume for a rename to work; another volume gives
/// [MoveOutcome.cannotRename].
///
/// Before the call, [to] is lstat-ed: a present target is
/// [MoveOutcome.targetExists] and no call is made. On a failure it is lstat-ed
/// again (a present target is the reason), and otherwise the OS error decides
/// (see [moveOutcomeForErrorCode]).
///
/// Throws a [FileSystemException] when [from] is missing, when [to]'s folder
/// is missing, for a Windows name that can't be used (see `publishExclusive`),
/// and when the platform can't make the call.
///
/// [beforeOsCall] runs immediately before the OS call; it is a seam for tests.
///
/// Windows: `MoveFileExW` without a replace flag. Linux: `renameat2` with
/// `RENAME_NOREPLACE`, through `syscall` when libc lacks it. macOS, iOS:
/// `renamex_np` with `RENAME_EXCL`. Android: `renameat2` when libc has it
/// (API 30+), otherwise `rename(2)` after the lstat. Link + unlink is not used
/// (a sync client can take the name between the calls), nor is plain
/// `rename(2)` where a no-replace call exists (it replaces an empty folder).
///
/// This blocks the calling isolate for one short file system call.
///
/// One coordinated call (see `coordination.dart`), made in the caller's
/// isolate: a move of [from] and of each of [alsoMoved] (the files inside a
/// folder being moved, so their versions are checked too), and a write on
/// [to]'s folder. A [StorageBusy], for any reason, is [MoveOutcome.busy] with
/// nothing moved. Code that runs the move in another isolate calls
/// [moveExclusiveUncoordinated] there, after this call's coordination.
///
/// Apple (see [appleMode]): a folder is never renamed while anything in it is
/// not downloaded (a rename may make the kernel download it, or refuse). The
/// folder is walked by name ([walk], or [folderWalk] when none is given), and on
/// any hit [ask] is called for each such path and the answer is
/// [MoveOutcome.busy], without an OS call. A source or a folder on another
/// volume is [MoveOutcome.cannotRename] before the call. The rename itself then
/// runs in another isolate, so a slow one does not block the caller; [beforeOsCall]
/// runs in the calling isolate just before it. A file that is not downloaded is
/// [MoveOutcome.busy] and [ask] is called for it.
Future<MoveOutcome> moveExclusive(
  String from,
  String to, {
  void Function()? beforeOsCall,
  List<String> alsoMoved = const [],
  DownloadAsk? ask,
  FolderWalk? walk,
}) async {
  try {
    return await coordinated(
      CoordinatedWrite([
        CoordinationIntent(from, CoordinationKind.move),
        for (final p in alsoMoved) CoordinationIntent(p, CoordinationKind.move),
        CoordinationIntent(folderOf(to), CoordinationKind.write),
      ]),
      () async {
        try {
          if (appleMode() &&
              FileSystemEntity.typeSync(from, followLinks: false) == FileSystemEntityType.directory) {
            return await _moveFolderApple(from, to, beforeOsCall, ask, walk);
          }
          return moveExclusiveUncoordinated(from, to, beforeOsCall: beforeOsCall);
        } on StorageBusy catch (e) {
          if (e.reason == StorageBusyReason.dataless) {
            for (final p in e.paths) {
              askSafely(p, ask);
            }
          }
          rethrow;
        }
      },
    );
  } on StorageBusy {
    return MoveOutcome.busy;
  }
}

/// A test seam: the delay the folder rename of an Apple-mode move waits in its
/// isolate before the OS call. Null in production. Not exported by
/// `noted_core.dart`.
Duration? debugRenameDelay;

/// A test seam: the volume (`st_dev`) of a path, instead of its stamp's. Null
/// in production. Not exported by `noted_core.dart`.
int? Function(String path)? debugMoveVolumeOf;

int? _volumeOf(String path) {
  final f = debugMoveVolumeOf;
  if (f != null) return f(path);
  try {
    return fileStamp(path)?.volume;
  } catch (_) {
    return null;
  }
}

// The folder rename of Apple mode: every dataless check runs here, in the
// calling isolate; the isolate does the rename and nothing else.
Future<MoveOutcome> _moveFolderApple(
  String from,
  String to,
  void Function()? beforeOsCall,
  DownloadAsk? ask,
  FolderWalk? walk,
) async {
  if (isDataless(from)) {
    askSafely(from, ask);
    return MoveOutcome.busy;
  }
  final w = walk ?? folderWalk(from);
  if (w.hasNotDownloaded) {
    for (final p in w.notDownloaded) {
      askSafely(p, ask);
    }
    return MoveOutcome.busy;
  }
  if (Platform.isWindows) checkWindowsName(to);
  if (_taken(to)) return MoveOutcome.targetExists;
  final a = _volumeOf(from), b = _volumeOf(folderOf(to));
  if (a != null && b != null && a != b) return MoveOutcome.cannotRename;
  beforeOsCall?.call();
  final strategy = debugMoveStrategy;
  final errno = debugNoReplaceErrno;
  final delay = debugRenameDelay;
  final r = await Isolate.run(() => _renameOffIsolate(from, to, strategy, errno, delay));
  final message = r.message;
  if (message != null) throw FileSystemException(message, r.path);
  return r.outcome!;
}

typedef _IsolateResult = ({MoveOutcome? outcome, String? message, String? path});

// Runs in a spawned isolate: no dataless check, no coordinator. A failure comes
// back as a value.
_IsolateResult _renameOffIsolate(
  String from,
  String to,
  MoveStrategy? strategy,
  int? errno,
  Duration? delay,
) {
  try {
    debugMoveStrategy = strategy;
    debugNoReplaceErrno = errno;
    if (delay != null) sleep(delay);
    final (outcome, _) = _moveExclusiveCode(from, to, null, null, false);
    return (outcome: outcome, message: null, path: null);
  } on FileSystemException catch (e) {
    return (outcome: null, message: e.message, path: e.path);
  }
}

/// [moveExclusive] without the coordination hook: one OS call, synchronous,
/// for a spawned isolate (where no coordinator is registered) or a caller
/// already inside its coordinated call. Not exported by the package's
/// libraries.
MoveOutcome moveExclusiveUncoordinated(
  String from,
  String to, {
  void Function()? beforeOsCall,
}) => _moveExclusiveCode(from, to, beforeOsCall).$1;

/// [moveExclusiveUncoordinated] with the OS error code that decided the
/// outcome (0 for [MoveOutcome.moved]; the code of the failed call otherwise,
/// -1 when it couldn't be read). [force] overrides [debugMoveStrategy].
(MoveOutcome, int) _moveExclusiveCode(
  String from,
  String to,
  void Function()? hook, [
  MoveStrategy? force,
  bool checkDataless = true,
]) {
  // A file that is not downloaded, or a stub with no file, stays where it is:
  // never "missing".
  if (checkDataless) _requireDownloaded(from);
  if (_isAbsent(from)) {
    throw FileSystemException('The source is missing', from);
  }
  if (Platform.isWindows) checkWindowsName(to);
  if (_taken(to)) return (MoveOutcome.targetExists, _eexist);
  final int code;
  try {
    code = _callOs(from, to, hook, force ?? debugMoveStrategy);
  } on FileSystemException {
    rethrow;
  } catch (e) {
    // FFI unavailable or a symbol is missing: fail safe, never replace.
    throw FileSystemException('Exclusive move failed: $e', to);
  }
  if (code == 0) return (MoveOutcome.moved, 0);
  if (_taken(to)) return (MoveOutcome.targetExists, code);
  if (_isAbsent(from)) {
    if (checkDataless) _requireDownloaded(from);
    throw FileSystemException('The source is missing', from);
  }
  if (_isNotFound(code)) {
    throw FileSystemException('The target folder is missing', to);
  }
  if (code == _unknownError) return (_outcomeWithoutCode(from, to), code);
  return (moveOutcomeForErrorCode(code), code);
}

/// The call failed and the error code couldn't be read (it was 0: the runtime
/// can overwrite it between the call and the read). Another volume is
/// [MoveOutcome.cannotRename], anything else [MoveOutcome.busy].
MoveOutcome _outcomeWithoutCode(String from, String to) {
  try {
    final a = fileStamp(from)?.volume;
    final b = fileStamp(folderOf(to))?.volume;
    if (a != null && b != null && a != b) return MoveOutcome.cannotRename;
  } catch (_) {}
  return MoveOutcome.busy;
}

/// Something is at [path], or only its stub is (a stubbed name is taken).
bool _taken(String path) => !_isAbsent(path) || hasStub(path);

void _requireDownloaded(String path) {
  if (isDataless(path)) {
    throw StorageBusy(StorageBusyReason.dataless, [path]);
  }
}

bool _isAbsent(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.notFound;

bool _isNotFound(int code) => Platform.isWindows
    ? (code == 2 || code == 3)
    : code == 2; // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND; ENOENT

/// The outcome for a failed move with OS error [code] (`GetLastError` on
/// Windows, `errno` elsewhere), after the target is known to be absent.
/// [windows] picks the table (default: this platform).
///
/// The Cloud Files range (`ERROR_CLOUD_FILE_*`, 358 to 426) is
/// [MoveOutcome.cannotRename]; which codes a provider really returns is
/// *unverified*.
MoveOutcome moveOutcomeForErrorCode(int code, {bool? windows}) {
  if (windows ?? Platform.isWindows) {
    if (code == 5 || code == 32 || code == 33) return MoveOutcome.busy;
    if (code == 17 || (code >= 358 && code <= 426)) {
      return MoveOutcome.cannotRename;
    }
    return MoveOutcome.busy;
  }
  // EPERM, EACCES, EBUSY, ETXTBSY (same numbers on Linux, Android, Apple).
  if (code == 1 || code == 13 || code == 16 || code == 26) {
    return MoveOutcome.busy;
  }
  // EXDEV, EINVAL always; ENOSYS and ENOTSUP differ.
  if (code == 18 || code == 22) return MoveOutcome.cannotRename;
  if (Platform.isMacOS || Platform.isIOS) {
    if (code == 78 || code == 45) return MoveOutcome.cannotRename;
  } else if (code == 38 || code == 95) {
    return MoveOutcome.cannotRename;
  }
  return MoveOutcome.busy;
}

/// Makes the call; returns 0 for success, else the OS error code.
int _callOs(
  String from,
  String to,
  void Function()? hook,
  MoveStrategy? forced,
) {
  if (forced == MoveStrategy.lstatRename) return _lstatRename(from, to, hook);
  final fake = debugNoReplaceErrno;
  if (fake != null) {
    hook?.call();
    return fake;
  }
  if (Platform.isWindows) {
    return _moveWindows(windowsPath(from), windowsPath(to), hook);
  }
  if (Platform.isMacOS || Platform.isIOS) return _moveApple(from, to, hook);
  if (Platform.isLinux || Platform.isAndroid) {
    return _moveLinux(from, to, hook, forced);
  }
  throw FileSystemException('Exclusive move is not supported here', to);
}

// --- Windows ---------------------------------------------------------------

typedef _MoveFileExC = Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32);
typedef _MoveFileExD = int Function(Pointer<Uint16>, Pointer<Uint16>, int);
typedef _LastErrorC = Uint32 Function();
typedef _LastErrorD = int Function();

int _moveWindows(String from, String to, void Function()? hook) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  // The move is a normal call; the error reader is a leaf call, read right after.
  final move = k32.lookupFunction<_MoveFileExC, _MoveFileExD>('MoveFileExW');
  final lastError = k32.lookupFunction<_LastErrorC, _LastErrorD>(
    'GetLastError',
    isLeaf: true,
  );
  final a = allocWide(from);
  final b = allocWide(to);
  lastError(); // warm up the call, so nothing is compiled between move and read
  try {
    // Flags 0: no MOVEFILE_REPLACE_EXISTING and no MOVEFILE_COPY_ALLOWED, so
    // an existing target fails and another volume fails with error 17.
    hook?.call();
    if (move(a, b, 0) != 0) return 0;
    final e = lastError();
    return e == 0 ? _unknownError : e;
  } finally {
    freeNative(a.cast());
    freeNative(b.cast());
  }
}

// --- POSIX -----------------------------------------------------------------

typedef _Rename2C = Int32 Function(
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Uint32,
);
typedef _Rename2D = int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _RenameXC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _RenameXD = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _SyscallC = IntPtr Function(
  IntPtr,
  VarArgs<(Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Uint32)>,
);
typedef _SyscallD = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

const int _atFdCwd = -100;
const int _renameNoReplace = 1;
const int _renameExcl = 4;

// Resolved before the call; the read of errno is inline right after the call.
_ErrnoD _errnoReader(DynamicLibrary libc) {
  final name = Platform.isMacOS || Platform.isIOS
      ? '__error'
      : (libc.providesSymbol('__errno_location')
            ? '__errno_location'
            : '__errno');
  return libc.lookupFunction<_ErrnoC, _ErrnoD>(name, isLeaf: true);
}

int _moveApple(String from, String to, void Function()? hook) {
  final libc = DynamicLibrary.process();
  final rename = libc.lookupFunction<_RenameXC, _RenameXD>('renamex_np');
  final errno = _errnoReader(libc);
  final a = allocCString(from);
  final b = allocCString(to);
  try {
    hook?.call();
    if (rename(a, b, _renameExcl) == 0) return 0;
    final e = errno().value;
    return e == 0 ? _unknownError : e;
  } finally {
    freeNative(a);
    freeNative(b);
  }
}

int _moveLinux(
  String from,
  String to,
  void Function()? hook,
  MoveStrategy? forced,
) {
  final libc = DynamicLibrary.process();
  final hasCall = libc.providesSymbol('renameat2');
  if (Platform.isAndroid && !hasCall && forced != MoveStrategy.linuxSyscall) {
    // API below 30: never the raw syscall (seccomp may kill the app).
    return _lstatRename(from, to, hook);
  }
  final errno = _errnoReader(libc);
  final a = allocCString(from);
  final b = allocCString(to);
  try {
    if (hasCall && forced != MoveStrategy.linuxSyscall) {
      final rename = libc.lookupFunction<_Rename2C, _Rename2D>('renameat2');
      hook?.call();
      if (rename(_atFdCwd, a, _atFdCwd, b, _renameNoReplace) == 0) return 0;
      final e = errno().value;
      return e == 0 ? _unknownError : e;
    }
    final syscall = libc.lookupFunction<_SyscallC, _SyscallD>('syscall');
    final number = _sysRenameat2();
    hook?.call();
    if (syscall(number, _atFdCwd, a, _atFdCwd, b, _renameNoReplace) == 0) {
      return 0;
    }
    final e = errno().value;
    return e == 0 ? _unknownError : e;
  } finally {
    freeNative(a);
    freeNative(b);
  }
}

int _sysRenameat2() {
  final abi = Abi.current();
  if (abi == Abi.linuxX64) return 316;
  if (abi == Abi.linuxArm64 || abi == Abi.linuxRiscv64) return 276;
  if (abi == Abi.linuxIA32) return 353;
  if (abi == Abi.linuxArm) return 382;
  throw UnsupportedError('no renameat2 system call number for $abi');
}

/// The fallback where no no-replace call exists: lstat the target, then the
/// platform's own rename. Not atomic against another writer; the caller holds
/// the lock that makes Noted the only writer there.
int _lstatRename(String from, String to, void Function()? hook) {
  hook?.call();
  if (_taken(to)) return _eexist;
  try {
    final type = FileSystemEntity.typeSync(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(from).renameSync(to);
    } else if (type == FileSystemEntityType.link) {
      Link(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
    return 0;
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode ?? 0;
    return code == 0 ? _unknownError : code;
  }
}

// --- Android's publish (no hard link) ----------------------------------------

/// Registers [publishByRename] as the publisher of `publishExclusive` when
/// this is Android (or [debugPublishAsAndroid] says so). Called once at start,
/// before any storage is read or written. Elsewhere it does nothing.
void useRenamePublishOnAndroid() {
  if (debugPublishAsAndroid ?? Platform.isAndroid) {
    nonLinkPublisher = publishByRename;
  }
}

typedef _LinkC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _LinkD = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _UnlinkC = Int32 Function(Pointer<Uint8>);
typedef _UnlinkD = int Function(Pointer<Uint8>);

const int _eperm = 1;
const int _eacces = 13;
const int _eexistErrno = 17;

/// Android's `publishExclusive`: moves the finished file [from] to [to] only
/// if nothing is there, without replacing anything. True when published
/// ([from] is then gone); false when something is at [to]; a
/// [FileSystemException] otherwise. In order:
///
/// 1. `link(from, to)`, then `unlink(from)` (tried twice). [hook] runs once,
///    immediately before this call. EEXIST, or a target that is present, is
///    false. EACCES and EPERM (SELinux refuses the call) go to 2. Any other
///    errno is a [FileSystemException].
/// 2. `renameat2(RENAME_NOREPLACE)` where bionic exports it (API 30): the
///    kernel decides atomically. A refusal that is not EEXIST (ENOSYS, EINVAL)
///    goes to 3; a busy file is a [FileSystemException].
/// 3. An lstat, then `rename(2)`, in this same synchronous call: no other Dart
///    code in the isolate runs between them, and Noted is the only writer in
///    its private storage (a second process is refused by the recovery lock, a
///    second engine by the activity guard). A target of any kind, a stub or a
///    dangling link counts as taken, so it never replaces. [hook] is not run a
///    second time.
///
/// The message names the outcome and the OS error code. Registered through
/// [useRenamePublishOnAndroid]; not exported by `noted_core.dart`.
bool publishByRename(String from, String to, void Function()? hook) {
  final linked = _linkOnce(from, to, hook);
  if (linked == 0) return true;
  if (linked == _eexistErrno || _taken(to)) return false;
  if (linked != _eacces && linked != _eperm) {
    throw FileSystemException(
      'Exclusive publish failed: link (errno $linked)',
      to,
    );
  }
  var (outcome, code) = _moveExclusiveCode(from, to, null);
  if (outcome == MoveOutcome.cannotRename &&
      debugMoveStrategy != MoveStrategy.lstatRename) {
    (outcome, code) = _moveExclusiveCode(
      from,
      to,
      null,
      MoveStrategy.lstatRename,
    );
  }
  switch (outcome) {
    case MoveOutcome.moved:
      return true;
    case MoveOutcome.targetExists:
      return false;
    case MoveOutcome.busy:
    case MoveOutcome.cannotRename:
      throw FileSystemException(
        'Exclusive publish failed: ${outcome.name} (errno $code)',
        to,
      );
  }
}

/// One `link` attempt: 0 when it linked (and [from] is unlinked), else the
/// errno ([_unknownError] when it couldn't be read).
int _linkOnce(String from, String to, void Function()? hook) {
  final forced = debugLinkErrno;
  if (forced != null) {
    hook?.call();
    debugLinkCalls++;
    return forced;
  }
  final libc = DynamicLibrary.process();
  final link = libc.lookupFunction<_LinkC, _LinkD>('link');
  final unlink = libc.lookupFunction<_UnlinkC, _UnlinkD>('unlink');
  final errno = _errnoReader(libc);
  final a = allocCString(from);
  final b = allocCString(to);
  try {
    hook?.call();
    debugLinkCalls++;
    if (link(a, b) == 0) {
      // The target has the full content; drop the temp name (twice if it
      // fails, as `publishExclusive` does).
      if (unlink(a) != 0) unlink(a);
      return 0;
    }
    final e = errno().value;
    return e == 0 ? _unknownError : e;
  } finally {
    freeNative(a);
    freeNative(b);
  }
}

// Reported when a failure has no usable OS code. The target check, then a
// comparison of volumes, decide (see `_outcomeWithoutCode`).
const int _unknownError = -1;
const int _eexist = -2; // lstatRename found the target

// --- Placeholders and sync roots (H) ----------------------------------------

/// Whether a file's data is on this device.
enum PlaceholderState {
  /// Present: not a placeholder.
  notPlaceholder,

  /// A cloud placeholder (Windows `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`,
  /// `RECALL_ON_OPEN` or `OFFLINE`; Apple `SF_DATALESS`). Reading it would
  /// download it.
  placeholder,

  /// Missing, or the attributes couldn't be read. Callers treat this as the
  /// cautious case.
  unknown,
}

/// The placeholder state of the file or folder at [path], from its attributes;
/// no data access.
PlaceholderState placeholderState(String path) {
  try {
    if (appleMode()) {
      // One dataless check (a stub counts as the file).
      if (isDataless(path)) return PlaceholderState.placeholder;
      return _isAbsent(path)
          ? PlaceholderState.unknown
          : PlaceholderState.notPlaceholder;
    }
    final info = rawFileInfo(path);
    if (info == null) return PlaceholderState.unknown;
    return info.placeholder
        ? PlaceholderState.placeholder
        : PlaceholderState.notPlaceholder;
  } catch (_) {
    return PlaceholderState.unknown;
  }
}

/// A sync root: the folder tree a cloud provider manages.
final class SyncRoot {
  const SyncRoot(this.volume, this.rootId);

  /// The volume serial of the path.
  final int volume;

  /// Windows `SyncRootFileId`.
  final int rootId;

  @override
  bool operator ==(Object other) =>
      other is SyncRoot && other.volume == volume && other.rootId == rootId;

  @override
  int get hashCode => Object.hash(volume, rootId);

  @override
  String toString() => 'SyncRoot($volume, $rootId)';
}

typedef _SyncRootC = Int32 Function(
  Pointer<Uint16>,
  Int32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
);
typedef _SyncRootD = int Function(
  Pointer<Uint16>,
  int,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
);

/// The sync root that holds [path] (or, if it doesn't exist yet, its nearest
/// existing folder), or null when it is in none or this can't be told.
///
/// Windows: `CfGetSyncRootInfoByPath` (`CF_SYNC_ROOT_INFO_BASIC`) and the
/// path's volume serial. Two paths are in one root when their values are
/// equal. Apple's file-provider domains are *unverified* and not detected: it
/// returns null there, which counts as "not one root" (the cautious case).
SyncRoot? syncRootOf(String path) {
  if (!Platform.isWindows) return null;
  try {
    var p = path;
    var info = rawFileInfo(p);
    for (var i = 0; info == null && i < 64; i++) {
      final parent = File(p).parent.path;
      if (parent == p) return null;
      p = parent;
      info = rawFileInfo(p);
    }
    final volume = info?.stamp?.volume;
    if (volume == null) return null;
    final cldapi = DynamicLibrary.open('cldapi.dll');
    final get = cldapi.lookupFunction<_SyncRootC, _SyncRootD>(
      'CfGetSyncRootInfoByPath',
    );
    final name = allocWide(windowsPath(p));
    final buf = allocNative(16);
    final returned = allocNative(8);
    try {
      // CF_SYNC_ROOT_INFO_BASIC (0): one LARGE_INTEGER, SyncRootFileId.
      final hr = get(name, 0, buf.cast(), 8, returned.cast());
      if (hr != 0) return null; // not in a sync root, or no cloud API
      final id = ByteData.sublistView(buf.asTypedList(8))
          .getInt64(0, Endian.little);
      return SyncRoot(volume, id);
    } finally {
      freeNative(name.cast());
      freeNative(buf);
      freeNative(returned);
    }
  } catch (_) {
    return null;
  }
}
