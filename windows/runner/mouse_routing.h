#ifndef SHARED_INPUT_MOUSE_ROUTING_H_
#define SHARED_INPUT_MOUSE_ROUTING_H_
namespace shared_input {
// Hook-thread only. A button held on Mac has no corresponding Windows async
// down, even after capture returns. Track that distinction until its real up.
class MouseRouting {
 public:
  bool Remote(unsigned button, bool down, bool blocking, bool local_source) {
    const unsigned mask = 1u << button;
    const bool remote = !local_source && (blocking || (remote_ & mask) != 0);
    if (down && remote) remote_ |= mask;
    if (!down) remote_ &= ~mask;
    if (down && !remote) windows_ |= mask;
    else if (!down || remote) windows_ &= ~mask;
    return remote;
  }
  void TransferToLocal(unsigned buttons) { remote_ &= ~buttons; }
  unsigned ReconcileCandidates(unsigned held, unsigned local, bool blocking) const {
    return (blocking ? local : (held & ~remote_)) & windows_ & 3u;
  }
 private:
  unsigned remote_ = 0, windows_ = 0;
};
}  // namespace shared_input
#endif
