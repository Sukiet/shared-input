#include "../../windows/runner/audio_packet.h"
#include <cstdlib>
#include <fstream>
#include <iostream>

using namespace shared_input;
void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
int main(int argc, char** argv) {
  Check(argc == 2, "fixture path required");
  std::ifstream input(argv[1]);
  std::string key, hex; input >> key >> hex;
  std::vector<uint8_t> packet;
  for (size_t i = 0; i + 1 < hex.size(); i += 2)
    packet.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
  AudioPacketCipher cipher(key);
  uint64_t sequence = 0; AudioSamples decoded{};
  Check(cipher.Decode(packet.data(), packet.size(), sequence, decoded) && sequence == 7, "independent AES-GCM fixture decrypts");
  const auto* pcm = reinterpret_cast<const uint8_t*>(decoded.data());
  for (size_t i = 0; i < kAudioPcmBytes; ++i) Check(pcm[i] == i % 256, "PCM unchanged");
  for (size_t offset : {size_t(4), size_t(15), size_t(17), packet.size() - 1}) {
    packet[offset] ^= 1;
    Check(!cipher.Decode(packet.data(), packet.size(), sequence, decoded), "tampered header, payload and tag rejected");
    packet[offset] ^= 1;
  }
  Check(!cipher.Decode(packet.data(), packet.size() - 1, sequence, decoded), "truncated rejected");
  AudioPacketCipher wrong(std::string(64, '0'));
  Check(!wrong.Decode(packet.data(), packet.size(), sequence, decoded), "wrong key rejected");
  AudioJitterBuffer jitter;
  auto samples = [](int16_t value) { AudioSamples data{}; data.fill(value); return data; };
  AudioSamples output{};
  Check(jitter.Push(2, samples(2)) && jitter.Push(1, samples(1)), "out of order accepted");
  jitter.Fill(output.data(), kAudioFrames);
  Check(output.front() == 0, "pre-roll reserves audio beyond the pending render write");
  for (uint64_t i = 3; i <= 10; ++i) jitter.Push(i, samples(static_cast<int16_t>(i)));
  for (int16_t i = 1; i <= 3; ++i) {
    jitter.Fill(output.data(), kAudioFrames);
    Check(output.back() == i, "packets reordered with initial fade");
  }
  Check(!jitter.Push(2, samples(9)), "consumed replay rejected");
  for (int i = 0; i < 10; ++i) jitter.Fill(output.data(), kAudioFrames);
  Check(output.front() == 0, "underrun yields silence");
  Check(jitter.Underruns() == 1, "underrun tracked once until rebuffered");
  for (uint64_t i = 20; i <= 52; ++i) jitter.Push(i, samples(static_cast<int16_t>(i)));
  Check(jitter.Queued() == 12 && jitter.OverflowDrops() == 21, "overflow drops stale backlog");
  jitter.Fill(output.data(), kAudioFrames);
  Check(output.back() == 41, "overflow resumes recent audio");
  Check(!jitter.Push(40, samples(40)), "discarded replay rejected");
  std::cout << "Audio authentication, wire compatibility, reorder, replay and latency bounds passed.\n";
}
