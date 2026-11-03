// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' as pp;

/// Whether this is a phone or tablet build (iOS, iPadOS, Android; 0129). The
/// one test every mobile adaptation uses. It follows
/// [debugDefaultTargetPlatformOverride], so a test can pick either side.
bool get isMobilePlatform {
  if (kIsWeb) return false;
  final p = debugDefaultTargetPlatformOverride ?? defaultTargetPlatform;
  return p == TargetPlatform.iOS || p == TargetPlatform.android;
}

Directory? _documents;
Directory? _cache;

/// Finds the app's own folders on a device. Call once at startup, before
/// anything reads a default path. On desktop it does nothing, so the
/// defaults there are unchanged. [documents] and [cache] replace the
/// platform lookups (for tests).
Future<void> initDeviceStorage({
  Future<Directory> Function()? documents,
  Future<Directory> Function()? cache,
}) async {
  if (!isMobilePlatform) return;
  _documents = await (documents ?? pp.getApplicationDocumentsDirectory)();
  _cache = await (cache ?? pp.getApplicationCacheDirectory)();
}

/// Forgets the folders found by [initDeviceStorage] (for tests).
@visibleForTesting
void resetDeviceStorage() {
  _documents = null;
  _cache = null;
}

String get _sep => Platform.pathSeparator;

/// The default pages folder on a device, `<documents>/Noted/pages`; null on
/// desktop (or before [initDeviceStorage] has run). Binders, settings, AI
/// data and recovery sit next to it, under `<documents>/Noted`.
Directory? devicePagesDirectory() {
  final d = _documents;
  if (!isMobilePlatform || d == null) return null;
  return Directory('${d.path}${_sep}Noted${_sep}pages');
}

/// The default cache folder on a device, `<cache>/Noted`; null on desktop (or
/// before [initDeviceStorage] has run). It is inside the app's cache folder,
/// which is all Android's paste file provider shares.
Directory? deviceCacheDirectory() {
  final c = _cache;
  if (!isMobilePlatform || c == null) return null;
  return Directory('${c.path}${_sep}Noted');
}
