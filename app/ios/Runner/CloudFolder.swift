// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Apple side of the iCloud Drive driver (design R5.1-R5.16). This file is
// identical in ios/Runner and macos/Runner.
//
// Channel `noted/cloud_folder` (a FlutterMethodChannel, standard codec).
// Every call takes one map argument and returns the shape listed; paths are
// absolute file system paths, bookmarks are base64 strings.
//
// Dart -> Swift
//   pick()                          iOS only. -> {path, bookmark} or null when
//                                   cancelled. A folder that is not in iCloud
//                                   Drive is refused with the error code
//                                   "notUbiquitous". Access to the folder is
//                                   started and kept (as after resolve).
//                                   macOS answers "not implemented".
//   bookmark({path})                -> bookmark (macOS: security-scoped).
//   resolve({bookmark})             -> {path, stale, access}. path is the real path
//                                   (symlinks resolved, standardized). Starts
//                                   access and presenting (events below); access
//                                   is what startAccessingSecurityScopedResource
//                                   returned, and stopAccess stops it only when
//                                   it was true. Dart renews a stale bookmark
//                                   with bookmark(path) only if the path is the
//                                   same.
//   isUbiquitous({path})            -> bool (isUbiquitousItemKey; never stored).
//   stopAccess({path})              -> null. Stops access and presenting.
//   reset()                         -> null. Releases every coordination hold.
//   coordinate({id, intents})       -> null at once. id is an int; intents is a
//                                   list of {path, kind}, kind one of "write",
//                                   "move", "delete". The answer is one event:
//                                   go, pending or failed (below). Dart then sends
//                                   done({id}), or cancel({id}) after its
//                                   timeout. A hold ends on done, cancel, reset
//                                   or engine detach. A hold over 60 s is
//                                   logged (NSLog) and kept.
//   done({id}), cancel({id})        -> null. Unknown ids are ignored.
//   versions({path, known?})        -> one entry per unresolved conflict version:
//                                   {id, tmpPath}, or {id, error} with no tmpPath
//                                   for a version that could not be copied.
//                                   known is a list of version ids (absent means
//                                   none; present and not a list of strings is
//                                   the error code "arguments"). A version that
//                                   matches a known id is not copied and not
//                                   counted against the deadline: its entry is
//                                   {id: the first matching known string,
//                                   known: true}. The match is the one of
//                                   resolveVersion (an id is a string that
//                                   names a version by its encoded identifier
//                                   or by the identifier it decodes to), and
//                                   "" matches a version with no identifier.
//                                   The whole call has one 60 s deadline;
//                                   versions not reached (or in progress) at
//                                   the deadline come back {id, error:
//                                   "timeout"}. Their temps may still appear
//                                   later; Dart's leftover-temp rule handles
//                                   them. tmpPath is an
//                                   exclusively created
//                                   `.<name>.noted-version-<16 hex>.tmp` in the
//                                   target's folder; it holds a copy of the
//                                   version made with a coordinated read of the
//                                   version and a coordinated write of the
//                                   folder. id is an opaque string.
//   resolveVersion({path, id})      -> bool: true if a matching unresolved
//                                   version was found and its isResolved set
//                                   (inside a coordinated write of the item);
//                                   false if none matched. A coordination
//                                   failure or a 60 s timeout is the error code
//                                   "coordination". Never removeOtherVersions.
//   withVersions({items})           -> {path: {fresh, shrank}}. items is a list of
//                                   {path: String, known: [String]}; a missing or
//                                   mistyped field is the error code "arguments".
//                                   For each path, the unresolved versions are
//                                   listed (none for nil): fresh holds the ids
//                                   ("" for a nil identifier) of those that match
//                                   no known id, shrank is true when a known id
//                                   matches no version. Only paths with a fresh
//                                   id or shrank true are in the answer, each
//                                   under the path string of the request. This
//                                   reads metadata only: nothing is coordinated,
//                                   copied or held.
//   startDownloading({path})        -> null (startDownloadingUbiquitousItem).
//
// Swift -> Dart (invokeMethod, always from the main thread, never awaited)
//   go({id})                        the coordination block has started.
//   failed({id})                    the coordination was cancelled or failed
//                                   before its block started; nothing is held.
//                                   (Also sent for an id Dart already
//                                   cancelled; Dart ignores unknown ids.)
//   failed({id, reason: "moved", paths})
//                                   an item named by an intent was at another
//                                   path when the block started (it moved while
//                                   the call waited). paths are the requested
//                                   paths whose URL changed. Nothing is held
//                                   and no go is sent; Dart treats it as
//                                   StorageBusy (coordination) and retries after
//                                   the folder's next check.
//   pending({id, paths})            a move or delete intent names files that
//                                   have unresolved versions (paths: those
//                                   files). The block is released at once.
//   changed({path, to?, version?})  the presenter saw a change. `to` is set for
//                                   presentedSubitem(at:didMoveTo:): path is the
//                                   old path and to the new one. `version` is
//                                   true for presentedSubitem(at:didGain:), a
//                                   version the item gained. A call that
//                                   spans two roots is made with the presenter of
//                                   the longest root matching its first path, so
//                                   the other root may echo changed events for
//                                   Dart's own writes; Dart ignores its echoes.
//
// Holds are released on cancel, done, reset, and when the app terminates or the
// CloudFolder is deallocated (there is no FlutterPlugin detach hook here).
// Paths Swift returns or sends (resolve, pick, changed) are realpaths, equal to
// Dart's resolveSymbolicLinks (so /private/var, not /var); a missing path is
// the realpath of its nearest existing ancestor plus the tail. Every lookup
// normalizes the same way.
//
// versions and resolveVersion take their own coordinated access, so Dart never
// calls them inside a coordinate hold.

import Foundation

#if os(iOS)
import Flutter
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

/// One coordinated call that Dart holds open.
final class CoordinationHold {
  let id: Int
  let semaphore = DispatchSemaphore(value: 0)
  /// Cancels the platform's coordination while its block has not started.
  var cancelAction: (() -> Void)?
  private let lock = NSLock()
  private var released = false

  init(id: Int) { self.id = id }

  /// Lets the accessor return. Safe to call more than once.
  func release() {
    lock.lock()
    defer { lock.unlock() }
    if released { return }
    released = true
    semaphore.signal()
  }

  /// Cancels the coordination if it is still waiting, then lets go.
  func cancel() {
    cancelAction?()
    release()
  }

  /// Blocks until released (a release that came first returns at once).
  /// `onLong` is called once, with the id, when `slice` seconds have passed.
  func holdUntilReleased(slice: TimeInterval = 60, onLong: (Int) -> Void) {
    var reported = false
    while semaphore.wait(timeout: .now() + slice) == .timedOut {
      if !reported {
        reported = true
        onLong(id)
      }
    }
  }
}

/// The holds that are open, by id.
final class HoldRegistry {
  private let lock = NSLock()
  private var holds: [Int: CoordinationHold] = [:]

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return holds.count
  }

  func add(_ hold: CoordinationHold) {
    lock.lock()
    holds[hold.id] = hold
    lock.unlock()
  }

  func hold(for id: Int) -> CoordinationHold? {
    lock.lock()
    defer { lock.unlock() }
    return holds[id]
  }

  /// Forgets `hold`, unless another one took its id.
  func remove(_ hold: CoordinationHold) {
    lock.lock()
    if holds[hold.id] === hold { holds.removeValue(forKey: hold.id) }
    lock.unlock()
  }

  /// `done`: lets the accessor return. An unknown id is ignored.
  func done(_ id: Int) { hold(for: id)?.release() }

  /// `cancel`: cancels the coordination if it is waiting, then lets go. An
  /// unknown id is ignored. The block's own exit forgets the hold.
  func cancel(_ id: Int) { hold(for: id)?.cancel() }

  /// `reset` and detach: every hold is cancelled and released, and forgotten.
  func releaseAll() {
    lock.lock()
    let all = Array(holds.values)
    holds.removeAll()
    lock.unlock()
    for h in all { h.cancel() }
  }
}

/// What the platform's coordination block does once it starts.
enum CoordinationOutcome: Equatable {
  /// Cancelled or failed before the block started.
  case failed
  /// An item named by an intent was at another path (the requested paths).
  case moved([String])
  /// A move or delete intent names files with unresolved versions (R5.8).
  case pending([String])
  /// The write may run.
  case go
}

/// Reports changes under one folder. It never waits on Dart.
final class FolderPresenter: NSObject, NSFilePresenter {
  let url: URL
  let queue = OperationQueue()
  private let emit: (String, String?, Bool) -> Void

  init(url: URL, emit: @escaping (String, String?, Bool) -> Void) {
    self.url = url
    self.emit = emit
    queue.maxConcurrentOperationCount = 1
    super.init()
  }

  var presentedItemURL: URL? { return url }
  var presentedItemOperationQueue: OperationQueue { return queue }

  func presentedItemDidChange() { emit(url.path, nil, false) }
  func presentedSubitemDidAppear(at url: URL) { emit(url.path, nil, false) }
  func presentedSubitemDidChange(at url: URL) { emit(url.path, nil, false) }
  func presentedSubitem(at url: URL, didGain version: NSFileVersion) { emit(url.path, nil, true) }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    emit(oldURL.path, newURL.path, false)
  }
}

#if os(iOS)
/// Presents the folder picker and answers once.
private final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private let completion: (URL?) -> Void

  init(completion: @escaping (URL?) -> Void) { self.completion = completion }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    completion(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    completion(nil)
  }
}
#endif

final class CloudFolder: NSObject {
  private let channel: FlutterMethodChannel
  private let lock = NSLock()
  private let holds = HoldRegistry()
  private var roots: [String: (url: URL, presenter: FolderPresenter, started: Bool)] = [:]
  private var terminateObserver: NSObjectProtocol?
  #if os(iOS)
  private var pickerDelegate: FolderPickerDelegate?
  #endif

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "noted/cloud_folder", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result)
    }
    #if os(iOS)
    let terminate = UIApplication.willTerminateNotification
    #elseif os(macOS)
    let terminate = NSApplication.willTerminateNotification
    #endif
    terminateObserver = NotificationCenter.default.addObserver(
      forName: terminate, object: nil, queue: nil
    ) { [weak self] _ in self?.detach() }
  }

  deinit {
    if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
    detach()
  }

  /// App termination or deallocation: no Dart code is writing now, so every
  /// hold is released. Presenters are removed.
  func detach() {
    channel.setMethodCallHandler(nil)
    holds.releaseAll()
    lock.lock()
    let all = roots
    roots = [:]
    lock.unlock()
    for (_, root) in all { NSFileCoordinator.removeFilePresenter(root.presenter) }
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pick":
      pick(result)
    case "bookmark":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      do {
        result(try makeBookmark(URL(fileURLWithPath: path)))
      } catch {
        result(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
      }
    case "resolve":
      guard let b = args["bookmark"] as? String else { return bad(result, "bookmark") }
      do {
        result(try resolve(b))
      } catch {
        result(FlutterError(code: "resolve", message: error.localizedDescription, details: nil))
      }
    case "isUbiquitous":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      result(isUbiquitous(URL(fileURLWithPath: path)))
    case "stopAccess":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      stopAccess(path)
      result(nil)
    case "reset":
      holds.releaseAll()
      result(nil)
    case "coordinate":
      guard let id = args["id"] as? Int, let list = args["intents"] as? [[String: Any]] else {
        return bad(result, "id, intents")
      }
      var intents: [(path: String, kind: String)] = []
      for item in list {
        guard let p = item["path"] as? String, let k = item["kind"] as? String,
          k == "write" || k == "move" || k == "delete"
        else { return bad(result, "intents") }
        intents.append((p, k))
      }
      coordinate(id: id, intents: intents)
      result(nil)
    case "done":
      if let id = args["id"] as? Int { holds.done(id) }
      result(nil)
    case "cancel":
      if let id = args["id"] as? Int { holds.cancel(id) }
      result(nil)
    case "versions":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      var known: [String] = []
      if let raw = args["known"] {
        guard let list = raw as? [String] else { return bad(result, "known") }
        known = list
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let out = self.copyVersions(path: path, known: known)
        DispatchQueue.main.async { result(out) }
      }
    case "withVersions":
      guard let list = args["items"] as? [[String: Any]] else { return bad(result, "items") }
      var items: [(path: String, known: [String])] = []
      for item in list {
        guard let p = item["path"] as? String, let k = item["known"] as? [String] else {
          return bad(result, "items")
        }
        items.append((p, k))
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let out = self.versionChanges(items)
        DispatchQueue.main.async { result(out) }
      }
    case "resolveVersion":
      guard let path = args["path"] as? String, let id = args["id"] as? String else {
        return bad(result, "path, id")
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let out = self.resolveVersion(path: path, id: id)
        DispatchQueue.main.async { result(out) }
      }
    case "startDownloading":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      do {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
        result(nil)
      } catch {
        result(FlutterError(code: "download", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func bad(_ result: FlutterResult, _ what: String) {
    result(FlutterError(code: "arguments", message: "Missing or invalid: \(what)", details: nil))
  }

  private func send(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(method, arguments: args)
    }
  }

  // MARK: Access and bookmarks

  private func isUbiquitous(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
    return values?.isUbiquitousItem ?? false
  }

  private func makeBookmark(_ url: URL) throws -> String {
    #if os(macOS)
    let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    let options: URL.BookmarkCreationOptions = []
    #endif
    let data = try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    return data.base64EncodedString()
  }

  /// Starts access to `url` and presents it. The first call for a path wins.
  @discardableResult
  private func present(_ url: URL) -> Bool {
    let key = CloudFolder.normalize(url.path)
    lock.lock()
    defer { lock.unlock() }
    if let existing = roots[key] { return existing.started }
    let started = url.startAccessingSecurityScopedResource()
    let presenter = FolderPresenter(url: url) { [weak self] path, to, version in
      var args: [String: Any] = ["path": CloudFolder.normalize(path)]
      if let to = to { args["to"] = CloudFolder.normalize(to) }
      if version { args["version"] = true }
      self?.send("changed", args)
    }
    NSFileCoordinator.addFilePresenter(presenter)
    roots[key] = (url, presenter, started)
    return started
  }

  /// The realpath, as Dart's resolveSymbolicLinks gives it. For a path that does
  /// not exist, the realpath of the nearest existing ancestor plus the tail.
  static func normalize(_ path: String) -> String {
    let standard = URL(fileURLWithPath: path).standardizedFileURL
    var url = standard
    var tail: [String] = []
    while url.path != "/" && !url.path.isEmpty {
      if let real = realPath(url.path) {
        var out = URL(fileURLWithPath: real)
        for part in tail.reversed() { out.appendPathComponent(part) }
        return out.path
      }
      tail.append(url.lastPathComponent)
      url.deleteLastPathComponent()
    }
    return standard.path
  }

  private static func realPath(_ path: String) -> String? {
    guard let r = Darwin.realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
  }

  private func resolve(_ b64: String) throws -> [String: Any] {
    guard let data = Data(base64Encoded: b64) else {
      throw NSError(domain: "noted.cloud_folder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The bookmark is not valid base64."])
    }
    #if os(macOS)
    let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    let options: URL.BookmarkResolutionOptions = []
    #endif
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: options, relativeTo: nil,
      bookmarkDataIsStale: &stale)
    let access = present(url)
    return ["path": CloudFolder.normalize(url.path), "stale": stale, "access": access]
  }

  private func stopAccess(_ path: String) {
    lock.lock()
    let root = roots.removeValue(forKey: CloudFolder.normalize(path))
    lock.unlock()
    guard let root = root else { return }
    NSFileCoordinator.removeFilePresenter(root.presenter)
    if root.started { root.url.stopAccessingSecurityScopedResource() }
  }

  #if os(iOS)
  private func pick(_ result: @escaping FlutterResult) {
    if pickerDelegate != nil {
      result(FlutterError(code: "busy", message: "A folder picker is already open.", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.allowsMultipleSelection = false
    let delegate = FolderPickerDelegate { [weak self] url in
      guard let self = self else { return }
      self.pickerDelegate = nil
      guard let url = url else {
        result(nil)
        return
      }
      // The picked URL is security-scoped; access stays started on success.
      let started = url.startAccessingSecurityScopedResource()
      defer { if started { url.stopAccessingSecurityScopedResource() } }
      if !self.isUbiquitous(url) {
        result(FlutterError(
          code: "notUbiquitous", message: "Choose a folder in iCloud Drive", details: nil))
        return
      }
      do {
        let bookmark = try self.makeBookmark(url)
        self.present(url)  // takes its own access before ours ends
        result(["path": CloudFolder.normalize(url.path), "bookmark": bookmark])
      } catch {
        result(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
      }
    }
    picker.delegate = delegate
    pickerDelegate = delegate
    guard var top = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?.rootViewController
    else {
      pickerDelegate = nil
      result(FlutterError(code: "noWindow", message: "No window to present from.", details: nil))
      return
    }
    while let next = top.presentedViewController { top = next }
    top.present(picker, animated: true)
  }
  #else
  private func pick(_ result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
  #endif

  // MARK: Coordination

  /// The longest of the root keys that is `path` or contains it.
  static func longestRoot<S: Sequence>(containing path: String, among keys: S) -> String?
  where S.Element == String {
    var best: String?
    for root in keys where path == root || path.hasPrefix(root + "/") {
      if best == nil || root.count > best!.count { best = root }
    }
    return best
  }

  /// The presenter of the registered root that contains `path`, so our own
  /// writes don't call our presenter back.
  private func presenter(containing path: String) -> FolderPresenter? {
    let path = CloudFolder.normalize(path)
    lock.lock()
    defer { lock.unlock() }
    return CloudFolder.longestRoot(containing: path, among: roots.keys).flatMap {
      roots[$0]?.presenter
    }
  }

  /// The decision of the coordination block, in the order that matters: a
  /// failed call holds nothing; an item that moved is refused before its
  /// versions are looked at (go would let the write run on the wrong path); a
  /// move or delete of a file with unresolved versions is `pending` (R5.8); a
  /// write never is. `granted` are the URLs the platform coordinated, one per
  /// requested intent.
  static func outcome(
    failed: Bool,
    requested: [(path: String, kind: String)],
    granted: [URL],
    hasUnresolvedVersions: (URL) -> Bool
  ) -> CoordinationOutcome {
    if failed { return .failed }
    var moved: [String] = []
    for (i, url) in granted.enumerated()
    where CloudFolder.normalize(url.path) != CloudFolder.normalize(requested[i].path) {
      moved.append(requested[i].path)
    }
    if !moved.isEmpty { return .moved(moved) }
    var pending: [String] = []
    for (i, url) in granted.enumerated() where requested[i].kind != "write" {
      if hasUnresolvedVersions(url) { pending.append(url.path) }
    }
    if !pending.isEmpty { return .pending(pending) }
    return .go
  }

  /// What the block does for an outcome: one event to Dart, and for `go` the
  /// hold, kept until `done`, `cancel`, `reset` or detach (the body is local
  /// file IO and letting go early would run it uncoordinated).
  static func runBlock(
    hold: CoordinationHold,
    outcome: CoordinationOutcome,
    send: (String, [String: Any]) -> Void,
    slice: TimeInterval = 60,
    onLong: (Int) -> Void
  ) {
    let id = hold.id
    switch outcome {
    case .failed:
      send("failed", ["id": id])
    case .moved(let paths):
      send("failed", ["id": id, "reason": "moved", "paths": paths])
    case .pending(let paths):
      send("pending", ["id": id, "paths": paths])
    case .go:
      send("go", ["id": id])
      hold.holdUntilReleased(slice: slice, onLong: onLong)
    }
  }

  private func coordinate(id: Int, intents: [(path: String, kind: String)]) {
    let hold = CoordinationHold(id: id)
    let coordinator = NSFileCoordinator(filePresenter: presenter(containing: intents.first?.path ?? ""))
    hold.cancelAction = { coordinator.cancel() }
    holds.add(hold)

    var accessIntents: [NSFileAccessIntent] = []
    for item in intents {
      let url = URL(fileURLWithPath: item.path)
      switch item.kind {
      case "move":
        accessIntents.append(NSFileAccessIntent.writingIntent(with: url, options: .forMoving))
      case "delete":
        accessIntents.append(NSFileAccessIntent.writingIntent(with: url, options: .forDeleting))
      default:
        accessIntents.append(NSFileAccessIntent.writingIntent(with: url, options: []))
      }
    }

    // One queue (so one thread) per call, never shared: a hold must not block
    // another call.
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated

    coordinator.coordinate(with: accessIntents, queue: queue) { [weak self] error in
      guard let self = self else { return }
      defer { self.holds.remove(hold) }
      let outcome = CloudFolder.outcome(
        failed: error != nil,  // cancelled or failed before the block started
        requested: intents,
        granted: accessIntents.map { $0.url },
        hasUnresolvedVersions: { url in
          let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url)
          return !(versions ?? []).isEmpty
        })
      CloudFolder.runBlock(
        hold: hold, outcome: outcome,
        send: { self.send($0, $1) },
        onLong: { NSLog("CloudFolder: coordination %d has been held for over 60 s", $0) })
    }
  }

  // MARK: Versions

  private func versionId(_ version: NSFileVersion) -> String? {
    guard
      let data = try? NSKeyedArchiver.archivedData(
        withRootObject: version.persistentIdentifier, requiringSecureCoding: false)
    else { return nil }
    return data.base64EncodedString()
  }

  private func decodeIdentifier(_ id: String) -> Any? {
    guard let data = Data(base64Encoded: id),
      let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    else { return nil }
    unarchiver.requiresSecureCoding = false
    let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    unarchiver.finishDecoding()
    return object
  }

  private func copyVersions(path: String, known: [String]) -> [[String: Any]] {
    let url = URL(fileURLWithPath: path)
    guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return [] }
    let deadline = Date().addingTimeInterval(60)
    let wanted = known.map { self.decodeIdentifier($0) }
    return CloudFolder.collectVersions(
      versions,
      remaining: { deadline.timeIntervalSinceNow },
      idOf: { self.versionId($0) },
      knownOf: { version in
        for (i, k) in known.enumerated() {
          if CloudFolder.matches(
            version, id: k, wanted: wanted[i],
            idOf: { self.versionId($0) }, identifierOf: { $0.persistentIdentifier })
          {
            return k
          }
        }
        return nil
      },
      copy: { self.copyVersion($0, of: url, timeout: $1) })
  }

  /// Metadata only: for each item, the ids of the unresolved versions that match
  /// no known id (`fresh`) and whether a known id matches none (`shrank`). Only
  /// the paths with a fresh id or `shrank` are in the answer, under the path
  /// string of the request.
  private func versionChanges(_ items: [(path: String, known: [String])]) -> [String: Any] {
    var out: [String: Any] = [:]
    for item in items {
      let versions =
        NSFileVersion.unresolvedConflictVersionsOfItem(at: URL(fileURLWithPath: item.path)) ?? []
      let change = CloudFolder.changes(
        versions, known: item.known,
        idOf: { self.versionId($0) },
        identifierOf: { $0.persistentIdentifier },
        decode: { self.decodeIdentifier($0) })
      if !change.fresh.isEmpty || change.shrank {
        out[item.path] = ["fresh": change.fresh, "shrank": change.shrank]
      }
    }
    return out
  }

  /// Whether `version` is the one `id` names: its encoded id equals `id`, or its
  /// identifier equals the decoded `wanted`. An empty `id` matches only a
  /// version with no encoded id.
  static func matches<V>(
    _ version: V, id: String, wanted: Any?,
    idOf: (V) -> String?, identifierOf: (V) -> Any
  ) -> Bool {
    let own = idOf(version)
    if id.isEmpty { return own == nil }
    if own == id { return true }
    if let wanted = wanted { return (identifierOf(version) as AnyObject).isEqual(wanted) }
    return false
  }

  /// The ids ("" for none) of the versions that match no id of `known`, and
  /// whether an id of `known` matches no version.
  static func changes<V>(
    _ versions: [V], known: [String],
    idOf: (V) -> String?, identifierOf: (V) -> Any, decode: (String) -> Any?
  ) -> (fresh: [String], shrank: Bool) {
    let wanted = known.map { decode($0) }
    var seen = [Bool](repeating: false, count: known.count)
    var fresh: [String] = []
    for version in versions {
      var hit = false
      for (i, k) in known.enumerated() {
        if matches(version, id: k, wanted: wanted[i], idOf: idOf, identifierOf: identifierOf) {
          seen[i] = true
          hit = true
        }
      }
      if !hit { fresh.append(idOf(version) ?? "") }
    }
    return (fresh, seen.contains(false))
  }

  /// One entry per version, in order: `{id, tmpPath}`, or `{id, error}` for a
  /// version with no identifier (`id` empty), one not reached before the
  /// deadline (`remaining` is zero or less: error "timeout", not copied) or one
  /// whose copy failed. A version that `knownOf` names (a known id it matches)
  /// is `{id: that string, known: true}`: not copied, not counted against the
  /// deadline.
  static func collectVersions<V>(
    _ versions: [V],
    remaining: () -> TimeInterval,
    idOf: (V) -> String?,
    knownOf: (V) -> String? = { _ in nil },
    copy: (V, TimeInterval) -> (path: String?, error: String?)
  ) -> [[String: Any]] {
    var out: [[String: Any]] = []
    for version in versions {
      if let k = knownOf(version) {
        out.append(["id": k, "known": true])
        continue
      }
      guard let id = idOf(version) else {
        out.append(["id": "", "error": "The version has no identifier."])
        continue
      }
      let left = remaining()
      if left <= 0 {
        out.append(["id": id, "error": "timeout"])
        continue
      }
      let made = copy(version, left)
      if let tmp = made.path {
        out.append(["id": id, "tmpPath": tmp])
      } else {
        out.append(["id": id, "error": made.error ?? "The copy failed."])
      }
    }
    return out
  }

  /// Copies one version into an exclusively created temp beside `target`, with
  /// a coordinated read of the version and a coordinated write of the folder.
  private func copyVersion(_ version: NSFileVersion, of target: URL, timeout: TimeInterval)
    -> (path: String?, error: String?)
  {
    let folder = target.deletingLastPathComponent()
    let name = target.lastPathComponent
    let coordinator = NSFileCoordinator(filePresenter: presenter(containing: target.path))
    let read = NSFileAccessIntent.readingIntent(with: version.url, options: [])
    let write = NSFileAccessIntent.writingIntent(with: folder, options: [])
    let queue = OperationQueue()
    let done = DispatchSemaphore(value: 0)
    let box = NSLock()
    var abandoned = false
    var tmpPath: String?
    coordinator.coordinate(with: [read, write], queue: queue) { error in
      defer { done.signal() }
      if error != nil { return }
      box.lock()
      let skip = abandoned
      box.unlock()
      if skip { return }
      let made = CloudFolder.exclusiveCopy(from: read.url, toFolder: write.url, name: name)
      box.lock()
      tmpPath = made
      box.unlock()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      box.lock()
      abandoned = true
      box.unlock()
      coordinator.cancel()
      return (nil, "timeout")
    }
    box.lock()
    defer { box.unlock() }
    return (tmpPath, tmpPath == nil ? "The copy failed." : nil)
  }

  /// Copies `source` to `.<name>.noted-version-<16 hex>.tmp` in `folder`, made
  /// with O_EXCL: a file that is already there is never opened or replaced (the
  /// next name is tried, eight times) and its path is returned; nil if the
  /// source can't be read or no name was free. `random` is for tests.
  static func exclusiveCopy(
    from source: URL, toFolder folder: URL, name: String,
    random: () -> UInt64 = { UInt64.random(in: 0...UInt64.max) }
  ) -> String? {
    guard let data = try? Data(contentsOf: source) else { return nil }
    for _ in 0..<8 {
      let hex = String(format: "%016llx", random())
      let path = folder.appendingPathComponent(".\(name).noted-version-\(hex).tmp").path
      let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      if fd < 0 {
        if errno == EEXIST { continue }
        return nil
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        return path
      } catch {
        try? handle.close()
        unlink(path)
        return nil
      }
    }
    return nil
  }

  /// Marks every version that is the one asked for: its encoded id equals `id`,
  /// or its identifier equals the decoded `wanted`. True if any was. Nothing
  /// else is touched, and no version is removed.
  static func resolveMatching<V>(
    _ versions: [V], id: String, wanted: Any?,
    idOf: (V) -> String?, identifierOf: (V) -> Any, resolve: (V) -> Void
  ) -> Bool {
    var any = false
    for version in versions {
      if CloudFolder.matches(
        version, id: id, wanted: wanted, idOf: idOf, identifierOf: identifierOf)
      {
        resolve(version)
        any = true
      }
    }
    return any
  }

  /// Runs on a background queue, inside a coordinated write of the item.
  /// Returns a Bool, or a FlutterError when the coordination failed or timed out.
  private func resolveVersion(path: String, id: String) -> Any {
    // "" stands for a version with no identifier: there is nothing to match it by.
    if id.isEmpty { return false }
    let url = URL(fileURLWithPath: path)
    let coordinator = NSFileCoordinator(filePresenter: presenter(containing: path))
    let wanted = decodeIdentifier(id)
    let intent = NSFileAccessIntent.writingIntent(with: url, options: [])
    let queue = OperationQueue()
    let done = DispatchSemaphore(value: 0)
    let box = NSLock()
    var abandoned = false
    var failed = false
    var found = false
    coordinator.coordinate(with: [intent], queue: queue) { error in
      defer { done.signal() }
      box.lock()
      let skip = abandoned
      if error != nil { failed = true }
      box.unlock()
      if skip || error != nil { return }
      guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: intent.url) else {
        return
      }
      let any = CloudFolder.resolveMatching(
        versions, id: id, wanted: wanted,
        idOf: { self.versionId($0) },
        identifierOf: { $0.persistentIdentifier },
        resolve: { $0.isResolved = true })
      box.lock()
      found = any
      box.unlock()
    }
    let err = FlutterError(
      code: "coordination", message: "The item could not be coordinated.", details: nil)
    if done.wait(timeout: .now() + 60) == .timedOut {
      box.lock()
      abandoned = true
      box.unlock()
      coordinator.cancel()
      return err
    }
    box.lock()
    defer { box.unlock() }
    return failed ? err : found
  }
}
