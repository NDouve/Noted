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
//   resolve({bookmark})             -> {path, stale}. Starts access and starts
//                                   presenting the folder (events below).
//                                   Dart renews a stale bookmark with
//                                   bookmark(path) only if the path is the same.
//   isUbiquitous({path})            -> bool (isUbiquitousItemKey; never stored).
//   stopAccess({path})              -> null. Stops access and presenting.
//   reset()                         -> null. Releases every coordination hold.
//   coordinate({id, intents})       -> null at once. id is an int; intents is a
//                                   list of {path, kind}, kind one of "write",
//                                   "move", "delete". The answer is one event,
//                                   go or pending (below). Dart then sends
//                                   done({id}), or cancel({id}) after its
//                                   timeout. A hold ends on done, cancel, reset
//                                   or engine detach. A hold over 60 s is
//                                   logged (NSLog) and kept.
//   done({id}), cancel({id})        -> null. Unknown ids are ignored.
//   versions({path})                -> [{id, tmpPath}], one per unresolved
//                                   conflict version. tmpPath is an exclusively
//                                   created `.<name>.noted-version-<16 hex>.tmp`
//                                   in the target's folder; it holds a copy of
//                                   the version made with a coordinated read of
//                                   the version and a coordinated write of the
//                                   folder. id is an opaque string.
//   resolveVersion({path, id})      -> null. Sets isResolved on that version. A
//                                   version that is no longer unresolved is
//                                   already done, so this succeeds. Never
//                                   removeOtherVersions.
//   startDownloading({path})        -> null (startDownloadingUbiquitousItem).
//
// Swift -> Dart (invokeMethod, always from the main thread, never awaited)
//   go({id})                        the coordination block has started.
//   pending({id, paths})            a move or delete intent names files that
//                                   have unresolved versions (paths: those
//                                   files). The block is released at once.
//   changed({path, to?})            the presenter saw a change. `to` is set for
//                                   presentedSubitem(at:didMoveTo:): path is the
//                                   old path and to the new one.
//
// Dart waits up to 60 s for go or pending; a coordination that fails to start
// sends neither, and Dart's timeout reports it as busy.

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
private final class CoordinationHold {
  let id: Int
  let semaphore = DispatchSemaphore(value: 0)
  var coordinator: NSFileCoordinator?
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
}

/// Reports changes under one folder. It never waits on Dart.
private final class FolderPresenter: NSObject, NSFilePresenter {
  let url: URL
  let queue = OperationQueue()
  private let emit: (String, String?) -> Void

  init(url: URL, emit: @escaping (String, String?) -> Void) {
    self.url = url
    self.emit = emit
    queue.maxConcurrentOperationCount = 1
    super.init()
  }

  var presentedItemURL: URL? { return url }
  var presentedItemOperationQueue: OperationQueue { return queue }

  func presentedItemDidChange() { emit(url.path, nil) }
  func presentedSubitemDidAppear(at url: URL) { emit(url.path, nil) }
  func presentedSubitemDidChange(at url: URL) { emit(url.path, nil) }
  func presentedSubitem(at url: URL, didGain version: NSFileVersion) { emit(url.path, nil) }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    emit(oldURL.path, newURL.path)
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
  private var holds: [Int: CoordinationHold] = [:]
  private var roots: [String: (url: URL, presenter: FolderPresenter)] = [:]
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

  /// Engine detach or app termination: no Dart code is writing now, so every
  /// hold is released. Presenters are removed.
  func detach() {
    channel.setMethodCallHandler(nil)
    releaseAllHolds()
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
      releaseAllHolds()
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
      if let id = args["id"] as? Int { holdFor(id)?.release() }
      result(nil)
    case "cancel":
      if let id = args["id"] as? Int, let h = holdFor(id) {
        h.coordinator?.cancel()
        h.release()
      }
      result(nil)
    case "versions":
      guard let path = args["path"] as? String else { return bad(result, "path") }
      DispatchQueue.global(qos: .userInitiated).async {
        let out = self.copyVersions(path: path)
        DispatchQueue.main.async { result(out) }
      }
    case "resolveVersion":
      guard let path = args["path"] as? String, let id = args["id"] as? String else {
        return bad(result, "path, id")
      }
      resolveVersion(path: path, id: id)
      result(nil)
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
  private func present(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    if roots[url.path] != nil { return }
    _ = url.startAccessingSecurityScopedResource()
    let presenter = FolderPresenter(url: url) { [weak self] path, to in
      var args: [String: Any] = ["path": path]
      if let to = to { args["to"] = to }
      self?.send("changed", args)
    }
    NSFileCoordinator.addFilePresenter(presenter)
    roots[url.path] = (url, presenter)
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
    present(url)
    return ["path": url.path, "stale": stale]
  }

  private func stopAccess(_ path: String) {
    lock.lock()
    let root = roots.removeValue(forKey: path)
    lock.unlock()
    guard let root = root else { return }
    NSFileCoordinator.removeFilePresenter(root.presenter)
    root.url.stopAccessingSecurityScopedResource()
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
        result(["path": url.path, "bookmark": bookmark])
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

  private func holdFor(_ id: Int) -> CoordinationHold? {
    lock.lock()
    defer { lock.unlock() }
    return holds[id]
  }

  private func releaseAllHolds() {
    lock.lock()
    let all = Array(holds.values)
    lock.unlock()
    for h in all {
      h.coordinator?.cancel()
      h.release()
    }
  }

  /// The presenter of the registered root that contains `path`, so our own
  /// writes don't call our presenter back.
  private func presenter(containing path: String) -> FolderPresenter? {
    lock.lock()
    defer { lock.unlock() }
    for (root, entry) in roots where path == root || path.hasPrefix(root + "/") {
      return entry.presenter
    }
    return nil
  }

  private func coordinate(id: Int, intents: [(path: String, kind: String)]) {
    let hold = CoordinationHold(id: id)
    let coordinator = NSFileCoordinator(filePresenter: presenter(containing: intents.first?.path ?? ""))
    hold.coordinator = coordinator
    lock.lock()
    holds[id] = hold
    lock.unlock()

    var accessIntents: [NSFileAccessIntent] = []
    var kinds: [String] = []
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
      kinds.append(item.kind)
    }

    // One queue (so one thread) per call, never shared: a hold must not block
    // another call.
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated

    coordinator.coordinate(with: accessIntents, queue: queue) { [weak self] error in
      guard let self = self else { return }
      defer {
        self.lock.lock()
        self.holds.removeValue(forKey: id)
        self.lock.unlock()
      }
      if error != nil { return }  // cancelled or failed: Dart's timeout reports it

      // R5.8: a move or delete never starts on a file with unresolved versions.
      var pending: [String] = []
      for (i, intent) in accessIntents.enumerated() where kinds[i] != "write" {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: intent.url)
        if let versions = versions, !versions.isEmpty { pending.append(intent.url.path) }
      }
      if !pending.isEmpty {
        self.send("pending", ["id": id, "paths": pending])
        return
      }

      self.send("go", ["id": id])
      // Hold until done, cancel, reset or detach: the body is local file IO
      // and letting go early would run it uncoordinated.
      var reported = false
      while hold.semaphore.wait(timeout: .now() + 60) == .timedOut {
        if !reported {
          reported = true
          NSLog("CloudFolder: coordination %d has been held for over 60 s", id)
        }
      }
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

  private func copyVersions(path: String) -> [[String: Any]] {
    let url = URL(fileURLWithPath: path)
    guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return [] }
    var out: [[String: Any]] = []
    for version in versions {
      guard let id = versionId(version),
        let tmp = copyVersion(version, of: url)
      else { continue }
      out.append(["id": id, "tmpPath": tmp])
    }
    return out
  }

  /// Copies one version into an exclusively created temp beside `target`, with
  /// a coordinated read of the version and a coordinated write of the folder.
  private func copyVersion(_ version: NSFileVersion, of target: URL) -> String? {
    let folder = target.deletingLastPathComponent()
    let name = target.lastPathComponent
    let coordinator = NSFileCoordinator(filePresenter: presenter(containing: target.path))
    let read = NSFileAccessIntent.readingIntent(with: version.url, options: [])
    let write = NSFileAccessIntent.writingIntent(with: folder, options: [])
    let queue = OperationQueue()
    let done = DispatchSemaphore(value: 0)
    var tmpPath: String?
    coordinator.coordinate(with: [read, write], queue: queue) { error in
      defer { done.signal() }
      if error != nil { return }
      tmpPath = CloudFolder.exclusiveCopy(from: read.url, toFolder: write.url, name: name)
    }
    done.wait()
    return tmpPath
  }

  private static func exclusiveCopy(from source: URL, toFolder folder: URL, name: String) -> String? {
    guard let data = try? Data(contentsOf: source) else { return nil }
    for _ in 0..<8 {
      let hex = String(format: "%016llx", UInt64.random(in: 0...UInt64.max))
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

  private func resolveVersion(path: String, id: String) {
    let url = URL(fileURLWithPath: path)
    guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return }
    let wanted = decodeIdentifier(id)
    for version in versions {
      var same = versionId(version) == id
      if !same, let wanted = wanted {
        same = (version.persistentIdentifier as AnyObject).isEqual(wanted)
      }
      if same { version.isResolved = true }
    }
  }
}
