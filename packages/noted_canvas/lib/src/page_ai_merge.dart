// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The page AI's help with a conflict (run 2026-11-01-04).
///
/// The canvas only asks; the app decides whether a page AI is connected and
/// how the request reaches it. A null [PageAiMerge] on the canvas means the
/// option is never shown.
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

/// What the page AI proposed for a conflicted box. Nothing changes until the
/// user accepts it.
final class AiMergeProposal {
  const AiMergeProposal({
    required this.markdown,
    required this.data,
    required this.dataVersion,
    this.by,
  });

  /// The label of the AI connection that answered, if known.
  final String? by;

  /// What the AI proposed, as markdown (shown beside both versions).
  final String markdown;

  /// The box's new data if accepted: the typed data of the box's codec (what
  /// `codec.decode` returns), ready to be committed through it.
  final Object? data;
  final int dataVersion;
}
