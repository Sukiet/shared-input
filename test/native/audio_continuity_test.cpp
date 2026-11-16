#include "../../windows/runner/audio_packet.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

using namespace shared_input;
void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
void Simulate(size_t quantum, double ppm, int seconds, size_t render_frames = 480, int buffer_ms = 40) {
  AudioJitterBuffer buffer(buffer_ms);
  AudioSamples packet{};
  for (size_t frame = 0; frame < kAudioFrames; ++frame) {
    packet[frame * 2] = 10000; packet[frame * 2 + 1] = -10000;
  }
  std::vector<int16_t> output(render_frames * 2);
  uint64_t sequence = 0, burst = 0;
  size_t residual = 0, silent = 0;
  const double period = static_cast<double>(quantum) * 1000000 / (48000 * (1 + ppm / 1000000));
  auto arrival = [&] { return static_cast<int64_t>(burst * period) + static_cast<int64_t>((burst * 7) % 9) * 1000; };
  for (int64_t now = 0; now < static_cast<int64_t>(seconds) * 1000000; now += 1000) {
    while (arrival() <= now) {
      residual += quantum; ++burst;
      while (residual >= kAudioFrames) {
        Check(buffer.Push(++sequence, packet), "valid ordered stream accepted");
        residual -= kAudioFrames;
      }
    }
    if (now % (render_frames * 1000000 / 48000) == 0) {
      buffer.Fill(output.data(), render_frames);
      if (now > std::max<int64_t>(200000, (buffer_ms + 100) * 1000)) {
        for (size_t frame = 0; frame < render_frames; ++frame) {
          if (output[frame * 2] < 9000) ++silent;
          Check(output[frame * 2] == -output[frame * 2 + 1], "stereo phase and channel separation preserved");
        }
      }
    }
  }
  std::cout << "quantum=" << quantum << " ppm=" << ppm << " duration=" << seconds
            << "s silent_frames=" << silent << " corrections_ppm=" << buffer.RatePpm() << '\n';
  Check(silent == 0, "burst delivery and independent sample clocks must not create periodic silence");
  Check(buffer.Underruns() == 0 && buffer.OverflowDrops() == 0 && buffer.MissingPackets() == 0,
      "continuous stream must not hide underruns, packet drops or rebuffering");
  Check(buffer.BufferedFrames() < static_cast<size_t>(buffer_ms + 100) * 48, "clock drift cannot accumulate unbounded latency");
}
int main() {
  Check(AudioJitterBuffer(-1).TargetMs() == 10 && AudioJitterBuffer(1000).TargetMs() == 200,
      "native target bounds enforced");
  Simulate(1024, 0, 20);
  Simulate(512, -1000, 180);
  Simulate(1024, 1000, 180);
  Simulate(2048, -200, 30);
  Simulate(1024, -1000, 180, 960);
  Simulate(512, 1000, 180, 960);
  Simulate(1024, -1000, 180, 960, 200);
}
