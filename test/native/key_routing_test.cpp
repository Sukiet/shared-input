#include "../../windows/runner/key_routing.h"
#include <cstdlib>
#include <iostream>

void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
int main() {
  using namespace shared_input;
  KeyRouting keys;
  constexpr unsigned volume = 0xaf, letter = 0x41;
  Check(ValidLocalKey(volume) && ValidLocalKey(0xad), "volume and mute are valid local keys");
  Check(!ValidLocalKey(0) && !ValidLocalKey(255) && !ValidLocalKey(0xe7), "invalid and packet keys rejected");
  Check(!keys.Remote(volume, true, true, true), "excepted volume down passes to Windows");
  Check(!keys.Remote(volume, true, true, true), "volume auto-repeat remains local");
  Check(!keys.Remote(volume, false, true, true), "volume up passes to Windows");
  Check(keys.Remote(letter, true, true, false), "ordinary key down goes remote");
  Check(keys.Remote(letter, true, false, true), "remote repeat after exit cannot leak to Windows");
  Check(keys.Remote(letter, false, false, true), "remote key release drains after exit");
  Check(!keys.Remote(letter, true, false, false), "next local press works after remote drain");
  Check(!keys.Remote(letter, false, true, false), "a local press cannot change ownership on capture start");
  Check(!keys.Remote(volume, true, true, true), "begin local volume press");
  Check(!keys.Remote(volume, false, true, false), "removing exception while held preserves its local release");
  Check(keys.Remote(volume, true, true, false), "future press follows updated routing");
  Check(keys.Remote(volume, false, true, true), "adding exception while held preserves remote release");
  Check(keys.Remote(0x77, true, true, false), "exit chord can override exception on first down");
  Check(keys.Remote(0x77, false, false, true), "exit key release cannot leak after exiting");
  keys.Reset();
  for (unsigned key = 8; key < 255; ++key) {
    Check(!keys.Remote(key, true, true, true), "all excepted single keys remain local");
    Check(!keys.Remote(key, false, false, false), "all local releases survive capture exit");
  }
  std::cout << "Local/remote ownership, repeats, paired releases, preference changes and exit priority passed.\n";
}
