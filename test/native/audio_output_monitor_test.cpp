#include "../../windows/runner/audio_output_monitor.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>

void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
  HWND owner = CreateWindowExW(0, L"STATIC", L"AudioOutputReadOnlyProbe", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  Check(owner != nullptr, "message-only owner created");
  {
    AudioOutputMonitor monitor(owner);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    auto state = monitor.Snapshot();
    while (state.status == "loading" && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      state = monitor.Snapshot();
    }
    Check(state.status != "loading", "Core Audio query completes asynchronously");
    Check(state.status == "ready" || state.status == "none" || state.status == "error",
        "query has an explicit outcome, including headless and audio-service-off systems");
    if (state.status == "ready") Check(!state.name.empty(), "default device has display text");
    if (state.status == "error") Check(!state.error.empty(), "failure retains error code");
    const auto revision = state.revision;
    for (int i = 0; i < 20; ++i) monitor.Refresh();
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    Check(monitor.Snapshot().revision >= revision, "refresh never rolls the snapshot backwards");
    std::cout << "Audio output: " << state.status << ", name=" << state.name
              << ", automatic=" << state.automatic << ", error=" << state.error << '\n';
  }
  DestroyWindow(owner);
  std::cout << "Read-only audio monitor and shutdown checks passed.\n";
}
