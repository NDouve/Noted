// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "pdf_render.h"

#include <unknwn.h>

#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;
using SharedResult = std::shared_ptr<Result>;
using winrt::Windows::Data::Pdf::PdfDocument;
using winrt::Windows::Data::Pdf::PdfPageRenderOptions;
using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::DataWriter;
using winrt::Windows::Storage::Streams::InMemoryRandomAccessStream;

constexpr double kDpi = 150.0;
constexpr double kMaxPixels = 16.0 * 1000 * 1000;
constexpr int64_t kMaxPageCount = 100000;

bool GetInt(const EncodableMap& m, const char* key, int64_t* out) {
  auto it = m.find(EncodableValue(key));
  if (it == m.end()) return false;
  if (const auto* i = std::get_if<int32_t>(&it->second)) {
    *out = *i;
    return true;
  }
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    *out = *l;
    return true;
  }
  return false;
}

// The size in pixels of a page of |width| by |height| DIPs (1/96 inch) at
// 150 dpi, scaled down to |max_w|, |max_h| and 16 megapixels. False if a side
// would be under 1 px.
bool FitPixels(double width, double height, int64_t max_w, int64_t max_h,
               uint32_t* out_w, uint32_t* out_h) {
  double w = width * kDpi / 96.0;
  double h = height * kDpi / 96.0;
  if (!(w > 0) || !(h > 0) || std::isinf(w) || std::isinf(h)) return false;
  double s = std::min(1.0, std::min(static_cast<double>(max_w) / w,
                                    static_cast<double>(max_h) / h));
  s = std::min(s, std::sqrt(kMaxPixels / (w * h)));
  double pw = std::floor(w * s);
  double ph = std::floor(h * s);
  if (pw * ph > kMaxPixels) {
    double f = std::sqrt(kMaxPixels / (pw * ph));
    pw = std::floor(pw * f);
    ph = std::floor(ph * f);
  }
  if (pw < 1 || ph < 1) return false;
  *out_w = static_cast<uint32_t>(pw);
  *out_h = static_cast<uint32_t>(ph);
  return true;
}

// Runs |work| on a thread-pool thread. False if it could not be queued.
bool RunOnPool(std::function<void()> work) {
  auto* heap = new std::function<void()>(std::move(work));
  const bool queued =
      QueueUserWorkItem(
          [](PVOID p) -> DWORD {
            std::unique_ptr<std::function<void()>> f(
                static_cast<std::function<void()>*>(p));
            (*f)();
            return 0;
          },
          heap, WT_EXECUTEDEFAULT) != FALSE;
  if (!queued) delete heap;
  return queued;
}

}  // namespace

struct PdfRender::State {
  std::mutex mutex;
  std::map<int64_t, PdfDocument> documents;
  int64_t next_handle = 1;
  std::deque<std::function<void()>> replies;
  HWND window = nullptr;
  bool closed = false;

  // Queues |reply| for the platform thread.
  void Post(std::function<void()> reply) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (closed) return;
      replies.push_back(std::move(reply));
    }
    PostMessage(window, kReplyMessage, 0, 0);
  }

  void PostError(const SharedResult& result, const char* code,
                 const std::string& message) {
    Post([result, code, message]() { result->Error(code, message); });
  }

  PdfDocument Find(int64_t handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it = documents.find(handle);
    return it == documents.end() ? nullptr : it->second;
  }
};

namespace {

void Open(const std::shared_ptr<PdfRender::State>& state,
          const SharedResult& result, std::shared_ptr<std::vector<uint8_t>> data) {
  try {
    InMemoryRandomAccessStream stream;
    DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(*data));
    writer.StoreAsync().get();
    writer.DetachStream();
    stream.Seek(0);
    PdfDocument doc = PdfDocument::LoadFromStreamAsync(stream).get();
    const int64_t count = doc.PageCount();
    if (count > kMaxPageCount) {
      state->PostError(result, "invalid", "Too many pages.");
      return;
    }
    int64_t handle;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->closed) return;
      handle = state->next_handle++;
      state->documents.emplace(handle, doc);
    }
    state->Post([result, handle, count]() {
      EncodableMap m;
      m[EncodableValue("handle")] = EncodableValue(handle);
      m[EncodableValue("pageCount")] = EncodableValue(count);
      result->Success(EncodableValue(std::move(m)));
    });
  } catch (const winrt::hresult_error& e) {
    // ERROR_WRONG_PASSWORD (0x8007052B): a document that needs a password.
    const bool password = e.code() == HRESULT_FROM_WIN32(ERROR_WRONG_PASSWORD);
    state->PostError(result, password ? "password" : "invalid",
                     winrt::to_string(e.message()));
  } catch (...) {
    state->PostError(result, "invalid", "The document can't be read.");
  }
}

void Render(const std::shared_ptr<PdfRender::State>& state,
            const SharedResult& result, PdfDocument doc, int64_t index,
            int64_t max_w, int64_t max_h) {
  try {
    if (index >= static_cast<int64_t>(doc.PageCount())) {
      state->PostError(result, "render", "No such page.");
      return;
    }
    auto page = doc.GetPage(static_cast<uint32_t>(index));
    auto size = page.Size();
    uint32_t w = 0, h = 0;
    if (!FitPixels(size.Width, size.Height, max_w, max_h, &w, &h)) {
      state->Post([result]() { result->Success(); });
      return;
    }
    PdfPageRenderOptions options;
    options.DestinationWidth(w);
    options.DestinationHeight(h);
    options.BackgroundColor(winrt::Windows::UI::Color{255, 255, 255, 255});
    options.BitmapEncoderId(
        winrt::Windows::Graphics::Imaging::BitmapEncoder::PngEncoderId());
    InMemoryRandomAccessStream out;
    page.RenderToStreamAsync(out, options).get();
    const uint64_t length = out.Size();
    if (length == 0 || length > 0x7FFFFFFFull) {
      state->PostError(result, "render", "The page could not be drawn.");
      return;
    }
    out.Seek(0);
    DataReader reader(out);
    reader.LoadAsync(static_cast<uint32_t>(length)).get();
    auto png = std::make_shared<std::vector<uint8_t>>(static_cast<size_t>(length));
    reader.ReadBytes(winrt::array_view<uint8_t>(*png));
    state->Post([result, png]() { result->Success(EncodableValue(std::move(*png))); });
  } catch (const winrt::hresult_error& e) {
    state->PostError(result, "render", winrt::to_string(e.message()));
  } catch (...) {
    state->PostError(result, "render", "The page could not be drawn.");
  }
}

}  // namespace

PdfRender::PdfRender(flutter::BinaryMessenger* messenger, HWND window)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "noted/document_render",
      &flutter::StandardMethodCodec::GetInstance());
  std::shared_ptr<State> state = state_;
  channel_->SetMethodCallHandler(
      [state](const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<Result> unique_result) {
        SharedResult result(std::move(unique_result));
        const auto* args = std::get_if<EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "Expected a map.");
          return;
        }
        const std::string& method = call.method_name();

        if (method == "open") {
          auto it = args->find(EncodableValue("bytes"));
          const auto* bytes =
              it == args->end() ? nullptr
                                : std::get_if<std::vector<uint8_t>>(&it->second);
          if (bytes == nullptr) {
            result->Error("bad_args", "bytes is required.");
            return;
          }
          auto data = std::make_shared<std::vector<uint8_t>>(*bytes);
          if (!RunOnPool([state, result, data]() { Open(state, result, data); })) {
            result->Error("busy", "The work could not be queued.");
          }
        } else if (method == "render") {
          int64_t handle = 0, index = 0, max_w = 0, max_h = 0;
          if (!GetInt(*args, "handle", &handle) ||
              !GetInt(*args, "index", &index) ||
              !GetInt(*args, "maxW", &max_w) ||
              !GetInt(*args, "maxH", &max_h) || index < 0 || max_w < 1 ||
              max_h < 1) {
            result->Error("bad_args",
                          "handle, index, maxW and maxH are required.");
            return;
          }
          PdfDocument doc = state->Find(handle);
          if (doc == nullptr) {
            result->Error("closed", "The document is not open.");
            return;
          }
          if (!RunOnPool([state, result, doc, index, max_w, max_h]() {
                Render(state, result, doc, index, max_w, max_h);
              })) {
            result->Error("busy", "The work could not be queued.");
          }
        } else if (method == "close") {
          int64_t handle = 0;
          if (GetInt(*args, "handle", &handle)) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->documents.erase(handle);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

PdfRender::~PdfRender() {
  channel_ = nullptr;
  std::map<int64_t, PdfDocument> open;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closed = true;
    state_->replies.clear();
    open.swap(state_->documents);
  }
  // |open| goes out of scope here: every document is closed. Work still
  // running holds its own reference and ends by itself.
}

void PdfRender::DrainReplies() {
  std::deque<std::function<void()>> now;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    now.swap(state_->replies);
  }
  for (auto& reply : now) reply();
}
