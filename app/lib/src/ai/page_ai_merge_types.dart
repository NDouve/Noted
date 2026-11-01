// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// TODO(PM): temporary copy of the two types the issue-UI task adds to
// packages/noted_canvas (section F of the run's design brief). At merge,
// delete this file and import them from `package:noted_canvas/noted_canvas.dart`
// instead; the shapes are identical.

/// The page AI's help with a conflict (run 2026-11-01-04).
abstract interface class PageAiMerge {
  /// Whether a page AI can be asked to merge [boxId]'s conflict on [pageId] now
  /// (only note and AI boxes; access Open/Privileged; a connected page code).
  bool available(String pageId, String boxId);

  /// Asks the page AI. Completes with its proposal, or with an error
  /// (timeout after 10 minutes, cancelled, or the AI declined).
  Future<AiMergeProposal> ask(String pageId, String boxId);

  /// Withdraws a pending request (the user chose something else or closed).
  void cancel(String pageId, String boxId);
}

final class AiMergeProposal {
  const AiMergeProposal({required this.markdown, required this.data, required this.dataVersion, this.by});

  /// The label of the code that answered (for the dialog: "Claude Code
  /// suggests"); null when unknown.
  final String? by;

  /// What the AI proposed, as markdown (shown beside both versions).
  final String markdown;

  /// The box's new data if accepted (already encoded for the box type).
  final Object? data;
  final int dataVersion;
}
