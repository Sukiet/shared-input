#ifndef SHARED_INPUT_SCREEN_LAYOUT_H_
#define SHARED_INPUT_SCREEN_LAYOUT_H_
#include <algorithm>
#include <cmath>

namespace shared_input {
enum class ScreenEdge { right, left, top, bottom };
inline ScreenEdge OppositeEdge(ScreenEdge edge) {
  switch (edge) {
    case ScreenEdge::right: return ScreenEdge::left;
    case ScreenEdge::left: return ScreenEdge::right;
    case ScreenEdge::top: return ScreenEdge::bottom;
    case ScreenEdge::bottom: return ScreenEdge::top;
  }
  return ScreenEdge::left;
}
inline const char* EdgeName(ScreenEdge edge) {
  switch (edge) {
    case ScreenEdge::right: return "right";
    case ScreenEdge::left: return "left";
    case ScreenEdge::top: return "top";
    case ScreenEdge::bottom: return "bottom";
  }
  return "left";
}
inline bool HorizontalEdge(ScreenEdge edge) { return edge == ScreenEdge::left || edge == ScreenEdge::right; }
inline double OutwardMotion(ScreenEdge edge, double dx, double dy) {
  switch (edge) {
    case ScreenEdge::right: return dx;
    case ScreenEdge::left: return -dx;
    case ScreenEdge::top: return -dy;
    case ScreenEdge::bottom: return dy;
  }
  return 0;
}
inline bool OnEdge(ScreenEdge edge, double x, double y, double left, double top, double width, double height) {
  switch (edge) {
    case ScreenEdge::left: return x >= left - 1 && x <= left + 1 && y >= top && y < top + height;
    case ScreenEdge::right: return x >= left + width - 2 && x <= left + width && y >= top && y < top + height;
    case ScreenEdge::top: return y >= top - 1 && y <= top + 1 && x >= left && x < left + width;
    case ScreenEdge::bottom: return y >= top + height - 2 && y <= top + height && x >= left && x < left + width;
  }
  return false;
}
struct ScreenLayout {
  ScreenEdge side = ScreenEdge::right;
  double controller_width = 1, controller_height = 1, remote_width = 1, remote_height = 1, offset = 0;
  double ControllerSpan() const { return HorizontalEdge(side) ? controller_height : controller_width; }
  double RemoteSpan() const { return HorizontalEdge(side) ? remote_height : remote_width; }
  bool Valid() const {
    for (double size : {controller_width, controller_height, remote_width, remote_height}) {
      if (!std::isfinite(size) || size <= 0 || size > 10000) return false;
    }
    return std::isfinite(offset) && offset < ControllerSpan() && offset + RemoteSpan() > 0;
  }
  bool ToRemote(double local, double& remote) const {
    remote = (local * ControllerSpan() - offset) / RemoteSpan();
    return remote >= 0 && remote <= 1;
  }
  bool ToController(double remote, double& local) const {
    local = (offset + remote * RemoteSpan()) / ControllerSpan();
    return local >= 0 && local <= 1;
  }
};
}  // namespace shared_input
#endif
