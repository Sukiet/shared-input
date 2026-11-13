#include "../../windows/runner/clipboard_image.h"
#include <objbase.h>
#include <cstdlib>
#include <cstring>
#include <iostream>
void Check(bool value, const char* label) {
  if (!value) { std::cerr << label << '\n'; std::exit(1); }
}
int main() {
  Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)), "COM initialization");
  shared_input::ClipboardPixels source;
  source.width = source.height = 2;
  source.bgra = {0, 0, 255, 255, 0, 255, 0, 128, 255, 0, 0, 0, 10, 20, 30, 255};
  std::vector<uint8_t> encoded;
  Check(shared_input::EncodeClipboardPng(source, encoded), "WIC PNG encoding");
  shared_input::ClipboardPixels decoded;
  Check(shared_input::DecodeClipboardImage(encoded, decoded), "WIC PNG decoding");
  Check(decoded.width == 2 && decoded.height == 2 && decoded.bgra == source.bgra,
    "PNG round trip preserves BGRA, transparency and orientation");
  const auto dib = shared_input::ClipboardDibV5(decoded);
  BITMAPV5HEADER header{};
  Check(dib.size() == sizeof(header) + source.bgra.size(), "DIB size");
  std::memcpy(&header, dib.data(), sizeof(header));
  Check(header.bV5Width == 2 && header.bV5Height == -2 && header.bV5AlphaMask == 0xff000000,
    "DIBV5 is top down with explicit alpha mask");
  Check(std::equal(source.bgra.begin(), source.bgra.end(), dib.begin() + sizeof(header)), "DIB pixel order");
  Check(!shared_input::DecodeClipboardImage({1, 2, 3, 4}, decoded), "malformed image rejected");
  Check(!shared_input::ValidClipboardSize(0, 100) &&
    !shared_input::ValidClipboardSize(100000, 100000), "dimensions limited before allocation");
  source.bgra.clear();
  Check(!shared_input::EncodeClipboardPng(source, encoded) &&
    shared_input::ClipboardDibV5(source).empty(), "incomplete pixel buffer rejected");
  CoUninitialize();
  std::cout << "Clipboard PNG/DIBV5 conversion passed.\n";
}
