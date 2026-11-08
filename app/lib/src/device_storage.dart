// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_sync/noted_sync.dart' show safePathPart, syncStateDir;
import 'package:path_provider/path_provider.dart' as pp;

/// Test-only: `flutter test` reports Android as the platform, which would run
/// every test on the mobile path. `test/flutter_test_config.dart` sets this so
/// tests run as desktop unless one picks a platform with
/// [debugDefaultTargetPlatformOverride]. Only [isMobilePlatform] reads it.
@visibleForTesting
bool testsDefaultToDesktop = false;

/// Whether this is a phone or tablet build (iOS, iPadOS, Android; 0129). The
/// one test every mobile adaptation uses. It follows
/// [debugDefaultTargetPlatformOverride], so a test can pick either side.
/// With no override, tests count as desktop (see [testsDefaultToDesktop]).
bool get isMobilePlatform {
  if (kIsWeb) return false;
  final override = debugDefaultTargetPlatformOverride;
  if (override == null && testsDefaultToDesktop) return false;
  final p = override ?? defaultTargetPlatform;
  return p == TargetPlatform.iOS || p == TargetPlatform.android;
}

Directory? _documents;
Directory? _cache;
Directory? _support;

/// Finds the app's own folders on a device. Call once at startup, before
/// anything reads a default path. On desktop it does nothing, so the
/// defaults there are unchanged. [documents], [cache] and [support] replace
/// the platform lookups (for tests).
Future<void> initDeviceStorage({
  Future<Directory> Function()? documents,
  Future<Directory> Function()? cache,
  Future<Directory> Function()? support,
}) async {
  if (!isMobilePlatform) return;
  _documents = await (documents ?? pp.getApplicationDocumentsDirectory)();
  _cache = await (cache ?? pp.getApplicationCacheDirectory)();
  _support = await (support ?? pp.getApplicationSupportDirectory)();
}

/// Forgets the folders found by [initDeviceStorage] (for tests).
@visibleForTesting
void resetDeviceStorage() {
  _documents = null;
  _cache = null;
  _support = null;
}

String get _sep => Platform.pathSeparator;

/// The default pages folder on a device, `<documents>/Noted/pages`; null on
/// desktop (or before [initDeviceStorage] has run). Binders sit next to it,
/// under `<documents>/Noted`; settings and recovery are in
/// [deviceSupportDirectory].
Directory? devicePagesDirectory() {
  final d = _documents;
  if (!isMobilePlatform || d == null) return null;
  return Directory('${d.path}${_sep}Noted${_sep}pages');
}

/// Where settings and recovery live on a device, `<support>/Noted` (0129);
/// null on desktop, before [initDeviceStorage] has run, or when
/// `NOTED_PAGES_DIR` moves the pages (then they stay next to the pages, as on
/// desktop).
Directory? deviceSupportDirectory() {
  final s = _support;
  if (!isMobilePlatform || s == null) return null;
  if (const String.fromEnvironment('NOTED_PAGES_DIR').isNotEmpty) return null;
  return Directory('${s.path}${_sep}Noted');
}

/// The default cache folder on a device, `<cache>/Noted`; null on desktop (or
/// before [initDeviceStorage] has run). It is inside the app's cache folder,
/// which is all Android's paste file provider shares.
Directory? deviceCacheDirectory() {
  final c = _cache;
  if (!isMobilePlatform || c == null) return null;
  return Directory('${c.path}${_sep}Noted');
}

/// The prefix of a stored path inside the documents folder (mobile only).
const String documentsMarker = '@documents';

/// Whether [stored] is in the `@documents/` form (also `/@documents/...`, which
/// an older build may write back after normalising the path against `/`).
bool isDocumentsForm(String stored) => _docsRel(stored) != null;

// The segments after `@documents`, or null if [s] is not in that form.
List<String>? _docsRel(String s) {
  final t = s.replaceAll(r'\', '/');
  final u = t.startsWith('/') ? t.substring(1) : t;
  if (u != documentsMarker && !u.startsWith('$documentsMarker/')) return null;
  return [
    for (final seg in u.substring(documentsMarker.length).split('/'))
      if (seg.isNotEmpty && seg != '.') seg,
  ];
}

// The segments of an absolute path, with a leading `/private` removed.
List<String> _segs(String p, bool windows) {
  final all = [
    for (final s in p.replaceAll(r'\', '/').split('/'))
      if (s.isNotEmpty) s,
  ];
  if (p.replaceAll(r'\', '/').startsWith('/') && all.isNotEmpty && _eq(all.first, 'private', windows)) {
    return all.sublist(1);
  }
  return all;
}

bool _eq(String a, String b, bool windows) => windows ? a.toLowerCase() == b.toLowerCase() : a == b;

bool _isAbsolute(String p) => p.startsWith('/') || p.startsWith(r'\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

/// The form of [absolute] that is saved in `binders.json`, `settings.json` and
/// recovery entries: on a phone or tablet, a path equal to or under the
/// documents folder is `@documents/<relative path>` (forward slashes), so it
/// survives a change of the app container. Everything else, and every path on
/// desktop, is returned unchanged. [windows] and [documents] are for tests; they
/// default to the platform and the folder found by [initDeviceStorage].
String storedPath(String absolute, {bool? windows, String? documents}) {
  final d = documents ?? _documents?.path;
  if (!isMobilePlatform || d == null) return absolute;
  if (isDocumentsForm(absolute) || !_isAbsolute(absolute)) return absolute;
  final win = windows ?? Platform.isWindows;
  final ds = _segs(d, win);
  final a = _segs(absolute, win);
  if (a.length < ds.length) return absolute;
  for (var i = 0; i < ds.length; i++) {
    if (!_eq(a[i], ds[i], win)) return absolute;
  }
  final rel = a.sublist(ds.length);
  if (rel.contains('..') || rel.contains('.')) return absolute;
  return '$documentsMarker/${rel.join('/')}';
}

/// The absolute path for a stored one: the inverse of [storedPath]. An
/// `@documents/` path is joined to the documents folder (a `..` segment is
/// refused: the string is returned as written). An absolute path under an old
/// app container (the container changed on a reinstall) is moved to the
/// current one; see the rule inline. Everything else, and every path on
/// desktop, is returned unchanged.
String resolveStoredPath(String stored, {bool? windows, String? documents, bool Function(String)? exists}) {
  final d = documents ?? _documents?.path;
  if (!isMobilePlatform || d == null) return stored;
  final win = windows ?? Platform.isWindows;
  final sep = win ? r'\' : '/';
  final rel = _docsRel(stored);
  if (rel != null) {
    if (rel.contains('..')) return stored;
    final base = d.endsWith('/') || d.endsWith(r'\') ? d.substring(0, d.length - 1) : d;
    return rel.isEmpty ? base : '$base$sep${rel.join(sep)}';
  }
  if (!_isAbsolute(stored)) return stored;
  final ds = _segs(d, win);
  final a = _segs(stored, win);
  final n = ds.length;
  if (n == 0 || a.length <= n) return stored;
  var differ = 0;
  for (var i = 0; i < n; i++) {
    if (!_eq(a[i], ds[i], win)) differ++;
  }
  if (differ == 0) return stored; // under the current container
  if (differ > 1 || !_eq(a[n - 1], ds[n - 1], win) || !_eq(a[n], 'Noted', win)) return stored;
  final gone = exists == null ? FileSystemEntity.typeSync(stored) == FileSystemEntityType.notFound : !exists(stored);
  if (!gone) return stored;
  final base = d.endsWith('/') || d.endsWith(r'\') ? d.substring(0, d.length - 1) : d;
  return '$base$sep${a.sublist(n).join(sep)}';
}

/// The folder that holds the OneDrive working copies on a device,
/// `<documents>/Noted/onedrive`; null on desktop (or before
/// [initDeviceStorage] has run). Everything under it is read-only on this
/// device while the sync only pulls (OneDrive sync stage 3, G1).
Directory? deviceOneDriveRoot() {
  final d = _documents;
  if (!isMobilePlatform || d == null) return null;
  return Directory('${d.path}${_sep}Noted${_sep}onedrive');
}

/// The working copy of one OneDrive folder, `root/account key/root item
/// id`. Both parts come from the server, so each goes through
/// [safePathPart] (G8). [root] is [deviceOneDriveRoot].
Directory oneDriveWorkingCopy(Directory root, String accountKey, String rootItemId) =>
    Directory([root.path, safePathPart(accountKey), safePathPart(rootItemId)].join(_sep));

/// The state folder of one OneDrive folder (journal, `tmp/`, `base/`):
/// `<support>/onedrive/<account key>/<root item id>`, outside the working copy
/// (G10). [support] is the folder that holds settings, [deviceSupportDirectory].
Directory oneDriveStateDir(Directory support, String accountKey, String rootItemId) =>
    syncStateDir(support, accountKey, rootItemId);

/// The file that remembers which OneDrive folder an account chose,
/// `<support>/onedrive/<account key>/chosen.json`.
File oneDriveChosenFile(Directory support, String accountKey) =>
    File([support.path, 'onedrive', safePathPart(accountKey), 'chosen.json'].join(_sep));
