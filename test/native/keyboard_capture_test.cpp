#include "../../windows/runner/keyboard_capture.h"
#include <cstdlib>
#include <iostream>

void Check(bool condition, const char* description) {
  if (!condition) { std::cerr << description << '\n'; std::exit(1); }
}
int main() {
  RAWKEYBOARD key{};
  key.VKey = VK_LWIN;
  auto normalized = shared_input::NormalizeKeyboardScanCode(key);
  Check(normalized.code == 0x5b && normalized.extended, "left Win must produce E0-5B");
  const int left_id = normalized.HeldId();
  key.Flags = RI_KEY_BREAK;
  Check(shared_input::NormalizeKeyboardScanCode(key).HeldId() == left_id, "Win release must match its held ID");
  key.VKey = VK_RWIN;
  normalized = shared_input::NormalizeKeyboardScanCode(key);
  Check(normalized.code == 0x5c && normalized.extended, "right Win must produce E0-5C");
  Check(normalized.HeldId() != left_id, "left and right Win must remain distinct");
  key.VKey = 'A'; key.MakeCode = 0x1e; key.Flags = 0;
  normalized = shared_input::NormalizeKeyboardScanCode(key);
  Check(normalized.code == 0x1e && !normalized.extended, "ordinary raw keys must remain unchanged");
  key.VKey = VK_CONTROL; key.MakeCode = 0x1d; key.Flags = RI_KEY_E0;
  Check(shared_input::NormalizeKeyboardScanCode(key).extended, "right Control retains its E0 prefix");
  key.VKey = 'A'; key.MakeCode = 0; key.Flags = 0;
  Check(shared_input::NormalizeKeyboardScanCode(key).code != 0, "missing make code must have a VK fallback");
  std::cout << "Keyboard capture normalization passed.\n";
}
