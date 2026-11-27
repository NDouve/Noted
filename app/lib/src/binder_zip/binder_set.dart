// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

/// The limits of a binder `.zip`, the same both ways (design t6 §2).
abstract final class BinderZipLimits {
  static const int entries = 20000;
  static const int archiveBytes = 1024 * 1024 * 1024;
  static const int totalBytes = 2 * 1024 * 1024 * 1024;
  static const int fileBytes = 256 * 1024 * 1024;
}

/// The name of the templates folder inside a binder folder.
const String binderTemplatesFolder = 'templates';

final RegExp _pageStoreTemp = RegExp(r'\.\d+-\d+\.tmp$');
final RegExp _setAsideAssets = RegExp(r'\.deleted-[0-9a-f]{12}\.assets$');

/// Whether [name] is one of Noted's own temporary files (A1): a page or
/// template temp `<file>.<µs>-<n>.tmp`, a hidden `.*.noted-*` staging file,
/// or an aside `*.cas-old` / `*.cas-verified`. An attachment named `x.tmp` is
/// not one.
bool isNotedTemp(String name) =>
    _pageStoreTemp.hasMatch(name) ||
    (name.startsWith('.') && name.contains('.noted-')) ||
    name.endsWith(asideSuffix) ||
    name.endsWith(verifiedSuffix);

/// Whether [name] is a cloud conflict copy of the binder file (the 0171
/// names, with `.json` kept): not the binder file itself, nor one of its
/// temporaries or asides.
bool isBinderFileCopyName(String name) {
  if (name == binderFileName || !name.startsWith('noted-binder') || !name.endsWith('.json')) return false;
  if (isBinderTempName(name) || isBinderFileAsideName(name) || isNotedTemp(name)) return false;
  final stem = name.substring(0, name.length - '.json'.length);
  return conflictCopyOriginalStems(stem).contains('noted-binder');
}

/// What a top-level name of a binder folder is to the binder set (A1).
enum BinderSetTop {
  /// `noted-binder.json`.
  binderFile,

  /// A conflict copy of the binder file.
  binderCopy,

  /// A `*.canvas` file (a page or a page's conflict copy).
  page,

  /// A `*.assets` folder that is not a set-aside one.
  assets,

  /// `templates/`.
  templates,

  /// Not in the set.
  none,
}

/// What the top-level entry [name] is ([folder]: it is a folder).
BinderSetTop binderSetTop(String name, {required bool folder}) {
  if (folder) {
    if (name == binderTemplatesFolder) return BinderSetTop.templates;
    if (name.endsWith('.assets') && name != '.assets' && !_setAsideAssets.hasMatch(name)) return BinderSetTop.assets;
    return BinderSetTop.none;
  }
  if (name == binderFileName) return BinderSetTop.binderFile;
  if (isBinderFileCopyName(name)) return BinderSetTop.binderCopy;
  if (name.endsWith(PageStore.extension) && name != PageStore.extension && !isNotedTemp(name)) {
    return BinderSetTop.page;
  }
  return BinderSetTop.none;
}

/// Whether the file at [relative] (components below the binder folder) is in
/// the binder set: a top-level binder file, copy or page, or a file inside an
/// `*.assets` folder or `templates/` that is not one of Noted's temporaries.
bool inBinderSet(List<String> relative) {
  if (relative.isEmpty) return false;
  if (relative.length == 1) return binderSetTop(relative.single, folder: false) != BinderSetTop.none;
  final top = binderSetTop(relative.first, folder: true);
  if (top == BinderSetTop.none) return false;
  return !isNotedTemp(relative.last);
}

/// Whether the folder at [relative] is inside the binder set (it, or the
/// top-level folder holding it, is an `*.assets` folder or `templates/`).
bool folderInBinderSet(List<String> relative) =>
    relative.isNotEmpty && binderSetTop(relative.first, folder: true) != BinderSetTop.none;

/// Whether the file at [relative] is one of Noted's own files, which a share
/// reads in a short job on the binder folder's lock (design t6 §3.3): the
/// binder file and its copies, each `.canvas`, each file under `templates/`.
/// Attachments are not.
bool isNotedOwnFile(List<String> relative) {
  if (relative.isEmpty) return false;
  if (relative.length == 1) return true;
  return relative.first == binderTemplatesFolder;
}
