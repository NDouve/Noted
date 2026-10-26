// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A Box API version.
///
/// While the major version is 0 the API is unstable, and a module must target
/// the host's exact version. From 1.0, a module runs on any host with the same
/// major version and an equal or newer minor version.
final class BoxApiVersion {
  const BoxApiVersion(this.major, this.minor);

  final int major;
  final int minor;

  /// Whether a host at this version can run a module built for [module].
  bool canHost(BoxApiVersion module) {
    if (major != module.major) return false;
    return major == 0 ? minor == module.minor : minor >= module.minor;
  }

  @override
  bool operator ==(Object other) =>
      other is BoxApiVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

/// The Box API version this core implements (0034).
///
/// 0.2 added canvas tools (on the Flutter side) and [BoxEdit]; 0.3 added
/// the theme to `ToolContext`. See `BOX_API_CHANGELOG.md` in this package.
const BoxApiVersion boxApiVersion = BoxApiVersion(0, 3);

/// How a box's size relates to its content.
enum BoxSizing {
  /// The box grows to fit its content (plain note boxes, 0015).
  growsWithContent,

  /// The box keeps the size the user gives it and scrolls internally (0005).
  fixed,
}

/// The outcome of merging two edits made from the same base revision.
sealed class MergeResult<D> {
  const MergeResult();
}

final class Merged<D> extends MergeResult<D> {
  const Merged(this.data);

  final D data;
}

/// The edits can't be merged automatically; the box is marked conflicted
/// (0020).
final class Conflicted<D> extends MergeResult<D> {
  const Conflicted();
}

/// What an AI may see of a box (0028).
sealed class AiExposure {
  const AiExposure();
}

final class AiText extends AiExposure {
  const AiText(this.text);

  final String text;
}

/// The AI sees that a box exists, but not its content (0009).
final class AiPlaceholder extends AiExposure {
  const AiPlaceholder(this.label);

  final String label;
}

/// The AI doesn't see the box at all.
final class AiHidden extends AiExposure {
  const AiHidden();
}

/// A permission a box type needs, for example network access (0034).
final class BoxPermission {
  const BoxPermission(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is BoxPermission && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The data side of a box type: everything that doesn't need Flutter.
///
/// A pure-Dart process such as the future MCP server can use a codec without
/// loading any UI code. [D] is the module's own in-memory data type. The core
/// never sees [D]: it stores only the JSON that [encode] returns.
abstract class BoxCodec<D> {
  const BoxCodec();

  /// A stable, namespaced type id, for example `noted.note`. Permanent once
  /// boxes of the type exist (0005).
  String get typeId;

  /// The current version of this type's data schema. Bump it when [encode]'s
  /// output changes shape. [decode] must accept every older version.
  int get dataVersion;

  /// The Box API version this module was written against.
  BoxApiVersion get apiVersion;

  BoxSizing get sizing;

  /// Data for a newly created, empty box.
  D create();

  /// Decodes stored data. [json] is what [encode] returned when the box was
  /// saved at [storedVersion], which is never newer than [dataVersion]. Throw
  /// if the data is unreadable; the box is then shown from its snapshot.
  D decode(Object? json, int storedVersion);

  /// Encodes data as JSON-compatible values (maps, lists, strings, numbers,
  /// booleans, null). This is the only path by which box content reaches the
  /// page model.
  Object? encode(D data);

  /// The read-only text snapshot (0035). Image snapshots are produced on the
  /// Flutter side, by the box module.
  String snapshotText(D data);

  /// Whether the box holds nothing worth keeping. An empty box is removed
  /// when it loses focus, so a stray click doesn't leave clutter.
  bool isEmpty(D data) => false;

  /// What an AI may see of this box. There is no default: every box type
  /// decides for itself.
  AiExposure aiExposure(D data);

  /// Merges concurrent edits (0020). The default marks the box conflicted.
  MergeResult<D> merge(D base, D mine, D theirs) => Conflicted<D>();

  /// Permissions the box type needs.
  Set<BoxPermission> get permissions => const {};
}

/// A module's own undoable change to a box's data, kept in page history as a
/// diff instead of a copy of the box's content (for example: strokes added
/// or removed). The core never looks inside it; it only replays it.
abstract interface class BoxEdit {
  /// Applies this edit to [data], the box's decoded data. Returns the new
  /// data and the edit that reverses this one.
  (Object? data, BoxEdit inverse) apply(Object? data);
}
