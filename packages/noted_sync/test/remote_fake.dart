// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a test needs from a fake remote store, whichever store it is. Paths
/// are relative to the account's top, so a test's synced folder is e.g.
/// `Noted`, and `Other/x.canvas` is outside it. The engine tests that don't
/// depend on a provider are written against this, and run once per fake.
abstract class RemoteFake {
  String addFolder(String path);

  String addFile(String path, List<int> bytes);

  /// Changes a file's content; [newId] is what a delete plus create by a sync
  /// client looks like.
  String replaceFile(
    String path,
    List<int> bytes, {
    bool newId = false,
    bool withName = true,
  });

  /// Deletes an item and everything below it.
  void delete(String path, {bool withName = false});

  void rename(String path, String newName);

  void move(String path, String newParentPath);

  /// The item's id as the provider's listing gives it.
  String idOf(String path);

  /// Every request served so far.
  int get requestCount;

  /// Called before each request is answered (to look at the engine then).
  set onAnyRequest(void Function()? f);

  /// Content requests served so far.
  int get downloadCount;

  /// The next listing request is cut off.
  void loseNextListing();

  /// The next [times] downloads get [status] (with `Retry-After` when given),
  /// or the connection is cut when [lose].
  void failDownloads({
    int status = 503,
    String? retryAfter,
    bool lose = false,
    int times = 1,
  });

  Future<void> close();
}
