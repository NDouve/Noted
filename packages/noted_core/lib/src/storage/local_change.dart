// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'replace_if_unchanged.dart';

enum LocalChangeKind { published, deleted }

/// A page or binder file the notebook wrote or deleted. Delivered in the
/// folder lock's order for locked writes.
class LocalChange {
  const LocalChange(this.kind, this.path, [this.identity]);

  final LocalChangeKind kind;

  /// The absolute path of the file.
  final String path;

  /// The identity of what was written; null for a delete.
  final ContentIdentity? identity;

  @override
  String toString() => 'LocalChange($kind, $path, $identity)';
}

enum RemoteMergeOutcome { merged, changed, refused }

/// What [Notebook.mergeRemote] did. On anything but [RemoteMergeOutcome.merged]
/// nothing was written by it.
class RemoteMergeResult {
  const RemoteMergeResult.merged(this.identity, {required this.wrote})
    : outcome = RemoteMergeOutcome.merged,
      reason = null;

  const RemoteMergeResult.changed()
    : outcome = RemoteMergeOutcome.changed,
      identity = null,
      wrote = false,
      reason = null;

  const RemoteMergeResult.refused(this.reason)
    : outcome = RemoteMergeOutcome.refused,
      identity = null,
      wrote = false;

  final RemoteMergeOutcome outcome;

  /// The identity of what the file holds now (merged only; may be null when
  /// nothing was written and the file was not read back).
  final ContentIdentity? identity;

  /// Whether the merge changed the file.
  final bool wrote;

  final String? reason;

  bool get isMerged => outcome == RemoteMergeOutcome.merged;

  @override
  String toString() => 'RemoteMergeResult($outcome, $identity, wrote: $wrote, $reason)';
}
