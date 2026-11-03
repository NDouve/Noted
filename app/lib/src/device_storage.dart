// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
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
