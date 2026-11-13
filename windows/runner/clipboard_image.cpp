#include "clipboard_image.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <cstring>
#include <limits>

namespace shared_input {
using Microsoft::WRL::ComPtr;
bool ValidClipboardSize(UINT width, UINT height) {
  return width && height && static_cast<uint64_t>(width) * height <= kClipboardPixelLimit;
}
namespace {
ComPtr<IWICImagingFactory> Factory() {
  ComPtr<IWICImagingFactory> factory;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  return factory;
}
}
bool DecodeClipboardImage(const std::vector<uint8_t>& encoded, ClipboardPixels& pixels) {
  if (encoded.empty() || encoded.size() > kClipboardImageLimit) return false;
  auto factory = Factory();
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  if (!factory || FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(encoded.data()), static_cast<DWORD>(encoded.size()))) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&pixels.width, &pixels.height)) ||
      !ValidClipboardSize(pixels.width, pixels.height) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
        nullptr, 0, WICBitmapPaletteTypeCustom))) return false;
  pixels.bgra.resize(static_cast<size_t>(pixels.width) * pixels.height * 4);
  return SUCCEEDED(converter->CopyPixels(nullptr, pixels.width * 4,
    static_cast<UINT>(pixels.bgra.size()), pixels.bgra.data()));
}
bool EncodeClipboardPng(const ClipboardPixels& pixels, std::vector<uint8_t>& encoded) {
  if (!ValidClipboardSize(pixels.width, pixels.height) ||
      pixels.bgra.size() != static_cast<size_t>(pixels.width) * pixels.height * 4) return false;
  auto factory = Factory();
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (!factory || FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, &properties)) ||
      FAILED(frame->Initialize(properties.Get())) ||
      FAILED(frame->SetSize(pixels.width, pixels.height))) return false;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format)) || !IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA) ||
      FAILED(frame->WritePixels(pixels.height, pixels.width * 4, static_cast<UINT>(pixels.bgra.size()),
        const_cast<BYTE*>(pixels.bgra.data()))) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) return false;
  STATSTG stats{};
  HGLOBAL memory = nullptr;
  if (FAILED(stream->Stat(&stats, STATFLAG_NONAME)) || stats.cbSize.QuadPart > kClipboardImageLimit ||
      FAILED(GetHGlobalFromStream(stream.Get(), &memory))) return false;
  const auto bytes = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!bytes) return false;
  encoded.assign(bytes, bytes + static_cast<size_t>(stats.cbSize.QuadPart));
  GlobalUnlock(memory);
  return !encoded.empty();
}

// Clipboard is already open. Preserve explicit alpha masks for DIBV5; for
// legacy bitmap formats, use the system conversion and treat unused alpha as opaque.
bool ReadClipboardPixels(ClipboardPixels& pixels) {
  const HANDLE dib = GetClipboardData(CF_DIBV5);
  if (dib && GlobalSize(dib) >= sizeof(BITMAPV5HEADER)) {
    const auto data = static_cast<const uint8_t*>(GlobalLock(dib));
    if (data) {
      BITMAPV5HEADER header{};
      std::memcpy(&header, data, sizeof(header));
      const int64_t height = header.bV5Height;
      const uint64_t absolute_height = height < 0 ? static_cast<uint64_t>(-height) : static_cast<uint64_t>(height);
      const uint64_t bytes = static_cast<uint64_t>(header.bV5Width > 0 ? header.bV5Width : 0) * absolute_height * 4;
      const bool valid = header.bV5Size >= sizeof(header) && header.bV5Width > 0 &&
        absolute_height <= std::numeric_limits<UINT>::max() &&
        ValidClipboardSize(static_cast<UINT>(header.bV5Width), static_cast<UINT>(absolute_height)) &&
        header.bV5Planes == 1 && header.bV5BitCount == 32 && header.bV5Compression == BI_BITFIELDS &&
        header.bV5RedMask == 0x00ff0000 && header.bV5GreenMask == 0x0000ff00 &&
        header.bV5BlueMask == 0x000000ff && header.bV5AlphaMask == 0xff000000 &&
        static_cast<uint64_t>(header.bV5Size) + bytes <= GlobalSize(dib);
      if (valid) {
        pixels.width = static_cast<UINT>(header.bV5Width);
        pixels.height = static_cast<UINT>(absolute_height);
        pixels.bgra.resize(static_cast<size_t>(bytes));
        const size_t stride = static_cast<size_t>(pixels.width) * 4;
        for (UINT row = 0; row < pixels.height; ++row) {
          const UINT source = height < 0 ? row : pixels.height - 1 - row;
          std::memcpy(pixels.bgra.data() + row * stride,
            data + header.bV5Size + source * stride, stride);
        }
      }
      GlobalUnlock(dib);
      if (valid) return true;
    }
  }
  const auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  BITMAP details{};
  if (!bitmap || !GetObjectW(bitmap, sizeof(details), &details) ||
      details.bmWidth <= 0 || details.bmHeight <= 0 ||
      !ValidClipboardSize(static_cast<UINT>(details.bmWidth), static_cast<UINT>(details.bmHeight))) return false;
  pixels.width = static_cast<UINT>(details.bmWidth); pixels.height = static_cast<UINT>(details.bmHeight);
  pixels.bgra.resize(static_cast<size_t>(pixels.width) * pixels.height * 4);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = details.bmWidth; info.bmiHeader.biHeight = -details.bmHeight;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  const HDC dc = GetDC(nullptr);
  if (!dc) return false;
  const int rows = GetDIBits(dc, bitmap, 0, pixels.height, pixels.bgra.data(), &info, DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  if (rows != static_cast<int>(pixels.height)) return false;
  for (size_t i = 3; i < pixels.bgra.size(); i += 4) pixels.bgra[i] = 255;
  return true;
}
std::vector<uint8_t> ClipboardDibV5(const ClipboardPixels& pixels) {
  if (!ValidClipboardSize(pixels.width, pixels.height) ||
      pixels.bgra.size() != static_cast<size_t>(pixels.width) * pixels.height * 4) return {};
  BITMAPV5HEADER header{};
  header.bV5Size = sizeof(header);
  header.bV5Width = static_cast<LONG>(pixels.width); header.bV5Height = -static_cast<LONG>(pixels.height);
  header.bV5Planes = 1; header.bV5BitCount = 32; header.bV5Compression = BI_BITFIELDS;
  header.bV5SizeImage = static_cast<DWORD>(pixels.bgra.size());
  header.bV5RedMask = 0x00ff0000; header.bV5GreenMask = 0x0000ff00;
  header.bV5BlueMask = 0x000000ff; header.bV5AlphaMask = 0xff000000;
  header.bV5CSType = LCS_sRGB; header.bV5Intent = LCS_GM_IMAGES;
  std::vector<uint8_t> result(sizeof(header) + pixels.bgra.size());
  std::memcpy(result.data(), &header, sizeof(header));
  std::memcpy(result.data() + sizeof(header), pixels.bgra.data(), pixels.bgra.size());
  return result;
}
}
