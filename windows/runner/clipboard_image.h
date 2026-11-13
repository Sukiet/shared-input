#ifndef SHARED_INPUT_CLIPBOARD_IMAGE_H_
#define SHARED_INPUT_CLIPBOARD_IMAGE_H_
#include <windows.h>
#include <cstdint>
#include <vector>
namespace shared_input {
constexpr size_t kClipboardImageLimit = 32u * 1024 * 1024;
constexpr size_t kClipboardTextLimit = 1024u * 1024;
constexpr uint64_t kClipboardPixelLimit = 32u * 1024 * 1024;
struct ClipboardPixels {
  UINT width = 0, height = 0;
  std::vector<uint8_t> bgra;
};
bool ValidClipboardSize(UINT width, UINT height);
bool DecodeClipboardImage(const std::vector<uint8_t>& encoded, ClipboardPixels& pixels);
bool EncodeClipboardPng(const ClipboardPixels& pixels, std::vector<uint8_t>& encoded);
bool ReadClipboardPixels(ClipboardPixels& pixels);
std::vector<uint8_t> ClipboardDibV5(const ClipboardPixels& pixels);
}
#endif
