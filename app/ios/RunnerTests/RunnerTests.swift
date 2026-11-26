// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Flutter
import UIKit
import XCTest

@testable import Runner

// Behaviour of the iCloud driver's Swift logic (CloudFolder.swift), tested
// without the platform's iCloud: holds, the coordination block's decisions,
// the version bookkeeping with a fake version source (an NSFileVersion can't be
// made for a conflict in a test), exclusive copying with temp folders, and the
// presenter's events. This file is the same in ios/RunnerTests and
// macos/RunnerTests, but for its imports.

private final class Recorder<T> {
  private let lock = NSLock()
  private var items: [T] = []

  func add(_ item: T) {
    lock.lock()
    items.append(item)
    lock.unlock()
  }

  var all: [T] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

private struct Sent {
  let method: String
  let args: [String: Any]
}

/// A stand-in for a conflict version, with the two identities a version has.
private final class FakeVersion {
  let id: String?
  let identifier: String
  var resolved = false

  init(id: String?, identifier: String) {
    self.id = id
    self.identifier = identifier
  }
}

private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.01)
  }
  return condition()
}

class RunnerTests: XCTestCase {

  private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("noted-cloud-folder-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// The real path (so /private/var, not /var), as the platform gives it.
  private func realPath(_ url: URL) -> String {
    guard let r = Darwin.realpath(url.path, nil) else { return url.path }
    defer { free(r) }
    return String(cString: r)
  }

  private func write(_ text: String, to url: URL) throws {
    try text.data(using: .utf8)!.write(to: url)
  }

  private func read(_ url: URL) -> String? {
    return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
  }

  private func names(in folder: URL) -> [String] {
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  // MARK: Holds: release, cancel, reset

  func testReleaseIsSafeToRepeatAndTheHoldReturnsAtOnceWhenReleasedFirst() {
    let hold = CoordinationHold(id: 1)
    hold.release()
    hold.release()
    let long = Recorder<Int>()
    hold.holdUntilReleased(slice: 0.05) { long.add($0) }  // returns at once
    XCTAssertTrue(long.all.isEmpty)
    // The second release did not signal again: a second wait would block.
    XCTAssertEqual(hold.semaphore.wait(timeout: .now() + 0.1), .timedOut)
  }

  func testAHoldBlocksUntilDoneAndReportsALongHoldOnce() {
    let registry = HoldRegistry()
    let hold = CoordinationHold(id: 7)
    registry.add(hold)
    let long = Recorder<Int>()
    let returned = Recorder<Bool>()
    DispatchQueue.global().async {
      hold.holdUntilReleased(slice: 0.05) { long.add($0) }
      returned.add(true)
    }
    XCTAssertTrue(waitUntil { long.all.count == 1 }, "the long hold is reported")
    Thread.sleep(forTimeInterval: 0.2)  // several more slices
    XCTAssertEqual(long.all, [7], "reported once, with the id")
    XCTAssertTrue(returned.all.isEmpty, "still held: the body is still running")
    registry.done(7)
    XCTAssertTrue(waitUntil { returned.all.count == 1 }, "done lets the accessor return")
  }

  func testDoneForAnUnknownIdIsIgnored() {
    let registry = HoldRegistry()
    let hold = CoordinationHold(id: 1)
    registry.add(hold)
    registry.done(2)
    registry.cancel(2)
    XCTAssertEqual(registry.count, 1)
    XCTAssertEqual(hold.semaphore.wait(timeout: .now() + 0.05), .timedOut, "the hold is untouched")
  }

  func testCancelCancelsTheCoordinationThenReleases() {
    let registry = HoldRegistry()
    let hold = CoordinationHold(id: 3)
    let cancelled = Recorder<Int>()
    hold.cancelAction = { cancelled.add(3) }
    registry.add(hold)
    registry.cancel(3)
    XCTAssertEqual(cancelled.all, [3])
    let long = Recorder<Int>()
    hold.holdUntilReleased(slice: 0.05) { long.add($0) }  // already released
    XCTAssertTrue(long.all.isEmpty)
  }

  func testCancelBeforeTheBlockStartsStillSendsGoAndReturnsAtOnce() {
    // Dart's timeout sends cancel; a go that comes after it gets done at once.
    let hold = CoordinationHold(id: 4)
    hold.cancel()
    let sent = Recorder<Sent>()
    CloudFolder.runBlock(
      hold: hold, outcome: .go, send: { sent.add(Sent(method: $0, args: $1)) }, slice: 0.05,
      onLong: { _ in XCTFail("nothing is held") })
    XCTAssertEqual(sent.all.map { $0.method }, ["go"])
  }

  func testResetCancelsAndReleasesEveryHoldAndForgetsThem() {
    let registry = HoldRegistry()
    let cancelled = Recorder<Int>()
    var all: [CoordinationHold] = []
    for id in 1...3 {
      let hold = CoordinationHold(id: id)
      hold.cancelAction = { cancelled.add(id) }
      registry.add(hold)
      all.append(hold)
    }
    registry.releaseAll()
    XCTAssertEqual(registry.count, 0)
    XCTAssertEqual(cancelled.all.sorted(), [1, 2, 3])
    for hold in all {
      let long = Recorder<Int>()
      hold.holdUntilReleased(slice: 0.05) { long.add($0) }  // each is released
      XCTAssertTrue(long.all.isEmpty)
    }
    registry.done(1)  // forgotten: ignored
  }

  func testRemoveForgetsOnlyTheHoldThatWasAdded() {
    let registry = HoldRegistry()
    let first = CoordinationHold(id: 1)
    let second = CoordinationHold(id: 1)
    registry.add(first)
    registry.add(second)  // the same id was reused
    registry.remove(first)
    XCTAssertTrue(registry.hold(for: 1) === second)
    registry.remove(second)
    XCTAssertNil(registry.hold(for: 1))
  }

  // MARK: The coordination block: what it sends, and in which order

  func testGoIsSentBeforeTheHoldAndTheHoldEndsOnlyOnDone() {
    let hold = CoordinationHold(id: 9)
    let order = Recorder<String>()
    DispatchQueue.global().async {
      CloudFolder.runBlock(
        hold: hold, outcome: .go,
        send: { method, args in
          XCTAssertEqual(args["id"] as? Int, 9)
          order.add(method)
        },
        slice: 0.05, onLong: { _ in })
      order.add("returned")
    }
    XCTAssertTrue(waitUntil { order.all == ["go"] })
    Thread.sleep(forTimeInterval: 0.15)
    XCTAssertEqual(order.all, ["go"], "the block does not return before done")
    hold.release()
    XCTAssertTrue(waitUntil { order.all == ["go", "returned"] })
  }

  func testPendingFailedAndMovedSendOneEventAndHoldNothing() {
    for outcome: CoordinationOutcome in [.failed, .moved(["/a/x"]), .pending(["/a/y", "/a/z"])] {
      let hold = CoordinationHold(id: 5)
      let sent = Recorder<Sent>()
      CloudFolder.runBlock(
        hold: hold, outcome: outcome, send: { sent.add(Sent(method: $0, args: $1)) }, slice: 0.05,
        onLong: { _ in XCTFail("nothing is held") })  // would block forever if it held
      XCTAssertEqual(sent.all.count, 1)
      let event = sent.all[0]
      XCTAssertEqual(event.args["id"] as? Int, 5)
      switch outcome {
      case .failed:
        XCTAssertEqual(event.method, "failed")
        XCTAssertNil(event.args["reason"])
      case .moved(let paths):
        XCTAssertEqual(event.method, "failed")
        XCTAssertEqual(event.args["reason"] as? String, "moved")
        XCTAssertEqual(event.args["paths"] as? [String], paths)
      case .pending(let paths):
        XCTAssertEqual(event.method, "pending")
        XCTAssertEqual(event.args["paths"] as? [String], paths)
      case .go:
        XCTFail("not in the list")
      }
    }
  }

  func testAFailedCoordinationHoldsNothingWhateverTheVersionsSay() {
    let outcome = CloudFolder.outcome(
      failed: true, requested: [(path: "/a/x.canvas", kind: "move")],
      granted: [URL(fileURLWithPath: "/a/x.canvas")], hasUnresolvedVersions: { _ in true })
    XCTAssertEqual(outcome, .failed)
  }

  func testAMoveOrDeleteOfAFileWithUnresolvedVersionsIsPending() throws {
    let folder = try makeFolder()
    let a = folder.appendingPathComponent("a.canvas")
    let b = folder.appendingPathComponent("b.canvas")
    let c = folder.appendingPathComponent("c.canvas")
    for url in [a, b, c] { try write("x", to: url) }
    // The fake version source: b and c have unresolved versions.
    let unresolved: Set<String> = [b.path, c.path]
    let asked = Recorder<String>()
    let outcome = CloudFolder.outcome(
      failed: false,
      requested: [
        (path: a.path, kind: "write"), (path: b.path, kind: "move"), (path: c.path, kind: "delete"),
      ],
      granted: [a, b, c],
      hasUnresolvedVersions: { url in
        asked.add(url.path)
        return unresolved.contains(url.path)
      })
    XCTAssertEqual(outcome, .pending([b.path, c.path]))
    XCTAssertFalse(asked.all.contains(a.path), "a write never asks for versions")
  }

  func testAWriteIsNeverPendingAndNoVersionsMeansGo() throws {
    let folder = try makeFolder()
    let a = folder.appendingPathComponent("a.canvas")
    let b = folder.appendingPathComponent("b.canvas")
    for url in [a, b] { try write("x", to: url) }
    let withVersions = CloudFolder.outcome(
      failed: false, requested: [(path: a.path, kind: "write")], granted: [a],
      hasUnresolvedVersions: { _ in true })
    XCTAssertEqual(withVersions, .go)
    let without = CloudFolder.outcome(
      failed: false,
      requested: [(path: a.path, kind: "write"), (path: b.path, kind: "delete")],
      granted: [a, b], hasUnresolvedVersions: { _ in false })
    XCTAssertEqual(without, .go)
  }

  func testAnItemThatMovedIsRefusedBeforeItsVersionsAreLookedAt() throws {
    let folder = try makeFolder()
    let asked = folder.appendingPathComponent("asked.canvas")
    let now = folder.appendingPathComponent("now.canvas")
    try write("x", to: now)
    let looked = Recorder<String>()
    let outcome = CloudFolder.outcome(
      failed: false, requested: [(path: asked.path, kind: "move")], granted: [now],
      hasUnresolvedVersions: { url in
        looked.add(url.path)
        return true
      })
    XCTAssertEqual(outcome, .moved([asked.path]))
    XCTAssertTrue(looked.all.isEmpty)
  }

  func testAPathThroughALinkIsNotTakenForAMove() throws {
    let folder = try makeFolder()
    let file = folder.appendingPathComponent("a.canvas")
    try write("x", to: file)
    // The path Dart has is through a link; the platform gives the real one.
    let link = try makeFolder().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let through = link.appendingPathComponent("a.canvas")
    XCTAssertNotEqual(through.path, realPath(file))
    let real = URL(fileURLWithPath: realPath(file))
    let outcome = CloudFolder.outcome(
      failed: false, requested: [(path: through.path, kind: "move")], granted: [real],
      hasUnresolvedVersions: { _ in false })
    XCTAssertEqual(outcome, .go)
  }

  // MARK: Paths

  func testNormalizeGivesTheRealPathAndKeepsTheTailOfAMissingOne() throws {
    let folder = try makeFolder()
    let real = realPath(folder)
    XCTAssertEqual(CloudFolder.normalize(folder.path), real)
    XCTAssertEqual(
      CloudFolder.normalize(folder.appendingPathComponent("gone/deeper/x.canvas").path),
      real + "/gone/deeper/x.canvas")
    XCTAssertEqual(
      CloudFolder.normalize(folder.appendingPathComponent("a/../b.canvas").path), real + "/b.canvas")
    // A path through a link is the real one.
    let link = try makeFolder().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    XCTAssertEqual(
      CloudFolder.normalize(link.appendingPathComponent("b.canvas").path), real + "/b.canvas")
  }

  func testTheLongestRootThatContainsAPathIsChosen() {
    let keys = ["/d", "/d/Notes", "/d/Notes2", "/other"]
    XCTAssertEqual(CloudFolder.longestRoot(containing: "/d/Notes/p.canvas", among: keys), "/d/Notes")
    XCTAssertEqual(CloudFolder.longestRoot(containing: "/d/Notes", among: keys), "/d/Notes")
    XCTAssertEqual(CloudFolder.longestRoot(containing: "/d/Notes2/p.canvas", among: keys), "/d/Notes2")
    XCTAssertEqual(CloudFolder.longestRoot(containing: "/d/Notesy/p.canvas", among: keys), "/d")
    XCTAssertNil(CloudFolder.longestRoot(containing: "/elsewhere/p.canvas", among: keys))
  }

  // MARK: Versions

  func testCollectVersionsReportsEachVersionAsACopyOrAnError() {
    let versions = [
      FakeVersion(id: "a", identifier: "A"), FakeVersion(id: nil, identifier: "B"),
      FakeVersion(id: "c", identifier: "C"), FakeVersion(id: "d", identifier: "D"),
    ]
    let out = CloudFolder.collectVersions(
      versions, remaining: { 30 }, idOf: { $0.id },
      copy: { version, _ in
        switch version.identifier {
        case "A": return (path: "/f/.p.canvas.noted-version-1.tmp", error: nil)
        case "C": return (path: nil, error: "No space left.")
        default: return (path: nil, error: nil)
        }
      })
    XCTAssertEqual(out.count, 4)
    XCTAssertEqual(out[0]["id"] as? String, "a")
    XCTAssertEqual(out[0]["tmpPath"] as? String, "/f/.p.canvas.noted-version-1.tmp")
    XCTAssertNil(out[0]["error"])
    XCTAssertEqual(out[1]["id"] as? String, "")
    XCTAssertEqual(out[1]["error"] as? String, "The version has no identifier.")
    XCTAssertEqual(out[2]["error"] as? String, "No space left.")
    XCTAssertNil(out[2]["tmpPath"])
    XCTAssertEqual(out[3]["error"] as? String, "The copy failed.")
  }

  func testVersionsNotReachedBeforeTheDeadlineComeBackAsTimeoutAndAreNotCopied() {
    let versions = [
      FakeVersion(id: "a", identifier: "A"), FakeVersion(id: "b", identifier: "B"),
      FakeVersion(id: "c", identifier: "C"),
    ]
    let left = Recorder<TimeInterval>()
    let times: [TimeInterval] = [12, 0, -3]
    var index = 0
    let copied = Recorder<String>()
    let out = CloudFolder.collectVersions(
      versions,
      remaining: {
        defer { index += 1 }
        return times[index]
      },
      idOf: { $0.id },
      copy: { version, remaining in
        left.add(remaining)
        copied.add(version.identifier)
        return (path: "/f/tmp", error: nil)
      })
    XCTAssertEqual(copied.all, ["A"])
    XCTAssertEqual(left.all, [12], "the copy gets what is left of the deadline")
    XCTAssertEqual(out[0]["tmpPath"] as? String, "/f/tmp")
    XCTAssertEqual(out[1]["error"] as? String, "timeout")
    XCTAssertEqual(out[1]["id"] as? String, "b")
    XCTAssertEqual(out[2]["error"] as? String, "timeout")
  }

  func testResolvingMarksOnlyTheVersionAskedFor() {
    let versions = [
      FakeVersion(id: "a", identifier: "A"), FakeVersion(id: "b", identifier: "B"),
      FakeVersion(id: "c", identifier: "C"),
    ]
    let found = CloudFolder.resolveMatching(
      versions, id: "b", wanted: nil, idOf: { $0.id }, identifierOf: { $0.identifier },
      resolve: { $0.resolved = true })
    XCTAssertTrue(found)
    XCTAssertEqual(versions.map { $0.resolved }, [false, true, false])
  }

  func testResolvingFindsAVersionByItsDecodedIdentifierToo() {
    // The encoded id differs (another archive of the same identifier).
    let versions = [FakeVersion(id: "encoded-1", identifier: "A"), FakeVersion(id: "x", identifier: "B")]
    let found = CloudFolder.resolveMatching(
      versions, id: "encoded-2", wanted: "A", idOf: { $0.id }, identifierOf: { $0.identifier },
      resolve: { $0.resolved = true })
    XCTAssertTrue(found)
    XCTAssertEqual(versions.map { $0.resolved }, [true, false])
  }

  func testResolvingAVersionThatIsNotThereResolvesNothingAndSaysSo() {
    let versions = [FakeVersion(id: "a", identifier: "A"), FakeVersion(id: nil, identifier: "B")]
    XCTAssertFalse(
      CloudFolder.resolveMatching(
        versions, id: "zzz", wanted: "nope", idOf: { $0.id }, identifierOf: { $0.identifier },
        resolve: { $0.resolved = true }))
    XCTAssertFalse(
      CloudFolder.resolveMatching(
        versions, id: "zzz", wanted: nil, idOf: { $0.id }, identifierOf: { $0.identifier },
        resolve: { $0.resolved = true }))
    XCTAssertEqual(versions.map { $0.resolved }, [false, false])
  }

  // MARK: Copying a version: exclusive, never replacing

  func testACopyIsMadeExclusivelyBesideTheTargetWithTheVersionsBytes() throws {
    let folder = try makeFolder()
    let source = try makeFolder().appendingPathComponent("version")
    try write("their bytes", to: source)
    let path = try XCTUnwrap(
      CloudFolder.exclusiveCopy(from: source, toFolder: folder, name: "p1.canvas", random: { 0xAB }))
    XCTAssertEqual(path, folder.appendingPathComponent(".p1.canvas.noted-version-00000000000000ab.tmp").path)
    XCTAssertEqual(read(URL(fileURLWithPath: path)), "their bytes")
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(names(in: folder), [".p1.canvas.noted-version-00000000000000ab.tmp"])
  }

  func testACopyNeverReplacesAFileThatIsAlreadyThere() throws {
    let folder = try makeFolder()
    let source = try makeFolder().appendingPathComponent("version")
    try write("theirs", to: source)
    let taken = folder.appendingPathComponent(".p1.canvas.noted-version-0000000000000001.tmp")
    try write("someone else's file", to: taken)
    let draws = Recorder<UInt64>()
    let path = try XCTUnwrap(
      CloudFolder.exclusiveCopy(
        from: source, toFolder: folder, name: "p1.canvas",
        random: {
          // The first name is the taken one.
          let next: UInt64 = draws.all.isEmpty ? 1 : 2
          draws.add(next)
          return next
        }))
    XCTAssertEqual(draws.all, [1, 2])
    XCTAssertEqual(path, folder.appendingPathComponent(".p1.canvas.noted-version-0000000000000002.tmp").path)
    XCTAssertEqual(read(taken), "someone else's file", "the file that was there is untouched")
    XCTAssertEqual(read(URL(fileURLWithPath: path)), "theirs")
  }

  func testACopyGivesUpAfterEightTakenNamesAndLeavesThemAlone() throws {
    let folder = try makeFolder()
    let source = try makeFolder().appendingPathComponent("version")
    try write("theirs", to: source)
    let taken = folder.appendingPathComponent(".p1.canvas.noted-version-0000000000000005.tmp")
    try write("keep me", to: taken)
    let tries = Recorder<Int>()
    let path = CloudFolder.exclusiveCopy(
      from: source, toFolder: folder, name: "p1.canvas",
      random: {
        tries.add(1)
        return 5
      })
    XCTAssertNil(path)
    XCTAssertEqual(tries.all.count, 8)
    XCTAssertEqual(read(taken), "keep me")
    XCTAssertEqual(names(in: folder).count, 1)
  }

  func testACopyOfAnUnreadableVersionMakesNothing() throws {
    let folder = try makeFolder()
    let missing = folder.appendingPathComponent("no-such-version")
    let path = CloudFolder.exclusiveCopy(from: missing, toFolder: folder, name: "p1.canvas")
    XCTAssertNil(path)
    XCTAssertEqual(names(in: folder), [])
  }

  func testTwoCopiesOfTheSameFileGetDifferentNames() throws {
    let folder = try makeFolder()
    let source = try makeFolder().appendingPathComponent("version")
    try write("theirs", to: source)
    let one = try XCTUnwrap(CloudFolder.exclusiveCopy(from: source, toFolder: folder, name: "p1.canvas"))
    let two = try XCTUnwrap(CloudFolder.exclusiveCopy(from: source, toFolder: folder, name: "p1.canvas"))
    XCTAssertNotEqual(one, two)
    XCTAssertEqual(names(in: folder).count, 2)
  }

  // MARK: The presenter's events

  func testThePresenterReportsChangesAndBothPathsOfAMove() {
    let folder = URL(fileURLWithPath: "/d/Notes")
    let seen = Recorder<[String?]>()
    let presenter = FolderPresenter(url: folder) { path, to, _ in seen.add([path, to]) }
    XCTAssertEqual(presenter.presentedItemURL, folder)
    presenter.presentedItemDidChange()
    presenter.presentedSubitemDidAppear(at: URL(fileURLWithPath: "/d/Notes/new.canvas"))
    presenter.presentedSubitemDidChange(at: URL(fileURLWithPath: "/d/Notes/p.canvas"))
    presenter.presentedSubitem(
      at: URL(fileURLWithPath: "/d/Notes/old.canvas"),
      didMoveTo: URL(fileURLWithPath: "/d/Notes/moved.canvas"))
    let all = seen.all
    XCTAssertEqual(all.count, 4)
    XCTAssertEqual(all[0], ["/d/Notes", nil])
    XCTAssertEqual(all[1], ["/d/Notes/new.canvas", nil])
    XCTAssertEqual(all[2], ["/d/Notes/p.canvas", nil])
    XCTAssertEqual(all[3], ["/d/Notes/old.canvas", "/d/Notes/moved.canvas"])
  }
}
