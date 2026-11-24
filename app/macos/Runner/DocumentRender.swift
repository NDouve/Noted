// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// PDF pages as PNG images, with PDFKit (no dependency). This file is
// identical in ios/Runner and macos/Runner.
//
// Channel `noted/document_render` (a FlutterMethodChannel, standard codec).
//
//   open({bytes})                        -> {handle, pageCount}. The error code
//                                           "password" for a PDF that needs a
//                                           password, "invalid" for one that
//                                           can't be read.
//   render({handle, index, maxW, maxH})  -> PNG bytes of page `index` (from 0)
//                                           at 150 dpi, scaled down so that
//                                           neither side is over maxW or maxH
//                                           and the page is at most 16
//                                           megapixels; null if a side would
//                                           be under 1 px; the error code
//                                           "render" if the page can't be
//                                           drawn.
//   close({handle})                      -> null.
//
// Opening happens on a global queue; each open document renders on its own
// serial queue. Replies are sent on the main thread. Every open document is
// closed when the app terminates or this object is deallocated (there is no
// FlutterPlugin detach hook here).

import Foundation
import ImageIO
import PDFKit
#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

final class DocumentRender: NSObject {
  private static let dpi = 150.0
  private static let maxPixels = 16.0 * 1000 * 1000

  private final class Document {
    let pdf: PDFDocument
    let queue: DispatchQueue
    init(pdf: PDFDocument, handle: Int) {
      self.pdf = pdf
      self.queue = DispatchQueue(label: "noted.document_render.\(handle)")
    }
  }

  private let channel: FlutterMethodChannel
  private let lock = NSLock()
  private var documents: [Int: Document] = [:]
  private var nextHandle = 1
  private var terminateObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "noted/document_render", binaryMessenger: messenger)
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

  /// Closes every open document.
  func detach() {
    channel.setMethodCallHandler(nil)
    lock.lock()
    documents = [:]
    lock.unlock()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "bytes is required", details: nil))
        return
      }
      open(bytes.data, result)
    case "render":
      guard let handle = args["handle"] as? Int, let index = args["index"] as? Int,
        let maxW = args["maxW"] as? Int, let maxH = args["maxH"] as? Int, index >= 0, maxW >= 1, maxH >= 1
      else {
        result(FlutterError(code: "bad_args", message: "handle, index, maxW and maxH are required", details: nil))
        return
      }
      render(handle, index, maxW, maxH, result)
    case "close":
      if let handle = args["handle"] as? Int {
        lock.lock()
        documents[handle] = nil
        lock.unlock()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func open(_ data: Data, _ result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      guard let pdf = PDFDocument(data: data) else {
        self.reply(result, FlutterError(code: "invalid", message: "The document can't be read", details: nil))
        return
      }
      if pdf.isEncrypted && pdf.isLocked {
        self.reply(result, FlutterError(code: "password", message: "The document needs a password", details: nil))
        return
      }
      self.lock.lock()
      let handle = self.nextHandle
      self.nextHandle += 1
      self.documents[handle] = Document(pdf: pdf, handle: handle)
      self.lock.unlock()
      self.reply(result, ["handle": handle, "pageCount": pdf.pageCount])
    }
  }

  /// The size in pixels of a page of `width` by `height` points at 150 dpi,
  /// scaled down to `maxW`, `maxH` and 16 megapixels; nil if a side would be
  /// under 1 px.
  static func fitPixels(_ width: Double, _ height: Double, _ maxW: Int, _ maxH: Int) -> (Int, Int)? {
    let w = width * dpi / 72.0
    let h = height * dpi / 72.0
    guard w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
    let s = min(1.0, min(Double(maxW) / w, Double(maxH) / h), (maxPixels / (w * h)).squareRoot())
    var pw = (w * s).rounded(.down)
    var ph = (h * s).rounded(.down)
    if pw * ph > maxPixels {
      let f = (maxPixels / (pw * ph)).squareRoot()
      pw = (pw * f).rounded(.down)
      ph = (ph * f).rounded(.down)
    }
    guard pw >= 1, ph >= 1 else { return nil }
    return (Int(pw), Int(ph))
  }

  private func render(_ handle: Int, _ index: Int, _ maxW: Int, _ maxH: Int, _ result: @escaping FlutterResult) {
    lock.lock()
    let doc = documents[handle]
    lock.unlock()
    guard let doc = doc else {
      result(FlutterError(code: "closed", message: "The document is not open", details: nil))
      return
    }
    doc.queue.async { [weak self] in
      guard let self = self else { return }
      guard index < doc.pdf.pageCount, let page = doc.pdf.page(at: index) else {
        self.reply(result, FlutterError(code: "render", message: "No such page", details: nil))
        return
      }
      let box = page.bounds(for: .cropBox)
      // The crop box is in unrotated page space; the image is the rotated page.
      let turned = page.rotation % 180 != 0
      let pageW = turned ? box.height : box.width
      let pageH = turned ? box.width : box.height
      guard let (w, h) = DocumentRender.fitPixels(Double(pageW), Double(pageH), maxW, maxH) else {
        self.reply(result, nil)
        return
      }
      let space = CGColorSpaceCreateDeviceRGB()
      guard
        let ctx = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        self.reply(result, FlutterError(code: "render", message: "The page could not be drawn", details: nil))
        return
      }
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      ctx.scaleBy(x: CGFloat(w) / pageW, y: CGFloat(h) / pageH)
      // Rotation and the crop box's origin.
      page.transform(ctx, for: .cropBox)
      page.draw(with: .cropBox, to: ctx)
      guard let image = ctx.makeImage() else {
        self.reply(result, FlutterError(code: "render", message: "The page could not be drawn", details: nil))
        return
      }
      let out = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
        self.reply(result, FlutterError(code: "render", message: "The page could not be encoded", details: nil))
        return
      }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest) else {
        self.reply(result, FlutterError(code: "render", message: "The page could not be encoded", details: nil))
        return
      }
      self.reply(result, FlutterStandardTypedData(bytes: out as Data))
    }
  }
}
