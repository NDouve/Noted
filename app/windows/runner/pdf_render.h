// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef RUNNER_PDF_RENDER_H_
#define RUNNER_PDF_RENDER_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

// The channel "noted/document_render": PDF pages as PNG images, with
// Windows.Data.Pdf (no dependency).
//
//   open({bytes})                       -> {handle, pageCount}; the error code
//                                          "password" for a PDF that needs a
//                                          password, "invalid" for one that
//                                          can't be read.
//   render({handle, index, maxW, maxH}) -> PNG bytes of page `index` (from 0),
//                                          at 150 dpi, scaled down so that
//                                          neither side is over maxW or maxH
//                                          and the page is at most 16
//                                          megapixels; null if a side would be
//                                          under 1 px; the error code "render"
//                                          if the page can't be drawn.
//   close({handle})                     -> null.
//
// The work runs on a thread-pool thread. Replies are queued and sent on the
// platform thread: the window calls DrainReplies() when it gets
// kReplyMessage. Every open document is closed when this is destroyed.
class PdfRender {
 public:
  // Posted to the window when a reply is waiting.
  static constexpr UINT kReplyMessage = WM_APP + 0x50;

  // What the pool threads share with this object (defined in the .cpp).
  struct State;

  PdfRender(flutter::BinaryMessenger* messenger, HWND window);
  ~PdfRender();

  PdfRender(const PdfRender&) = delete;
  PdfRender& operator=(const PdfRender&) = delete;

  // Sends the replies that are waiting. Platform thread only.
  void DrainReplies();

 private:
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PDF_RENDER_H_
