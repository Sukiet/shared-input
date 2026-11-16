# Windows 控制过程中意外返回本机：排查与修复交接报告

- 日期：2026-11-16
- 代码基线：`ff2cdda868175fc63085410cdd56e2ea1a91e0c2`（本地 master）
- 场景：Windows 为控制端，macOS 为被控端；用户持续操作鼠标，未按断开快捷键，鼠标仍偶发返回 Windows。
- 范围：静态代码检查与修复建议。本次未修改业务代码、未运行两机采样或复现测试。下述时间竞态是代码中存在的风险，尚未证实为用户这次现象的根因。请先核对 Windows 实际运行版本是否包含相同代码。

## 1. 结论

“鼠标回到 Windows”不等同于 TCP 连接断开。控制端有多条主动释放输入的路径，其中部分仅结束当前控制会话，保留两机连接。

优先处理 Windows 端两处无符号时间减法的并发竞态，其次处理退出原因可能被其他消息抢先归类的问题。不能仅根据此现象认定 UDP 丢包，也不建议先放宽或关闭安全超时。

## 2. 现有退出条件

以下路径主要由 Windows 原生层发起，`Stop()` 先释放输入拦截/鼠标约束，再发送 `stopped` 给 Dart；Dart 随后调用 `endCapture()` 通知 Mac。

| 原因 | 条件 | 作用范围及现有提示 |
| --- | --- | --- |
| `edge` | 边缘控制模式；进入控制至少 200ms；最近 250ms 有朝返回边缘的移动；Mac 反馈指针在该边缘约 1 个坐标单位范围；反馈序号确认了向外手势；未按住键或按钮 | 结束控制，通常保留连接；“已切回 Windows。” |
| `pointer_timeout` | 后台拦截期间，1 秒未收到有效 Mac 指针反馈；看门狗约每 50ms 检查 | 结束控制，通常保留连接；“Mac 指针反馈中断，已恢复 Windows 输入。” |
| `hook_lost` | 处理对应输入时，鼠标/键盘钩子最后活动时间距当前达到 250ms；或后台拦截已释放而会话仍 active | 结束控制，通常保留连接；“后台输入拦截中断，已恢复 Windows 输入。” |
| `shake` | 单设备、任一轴在固定 1.2 秒统计窗口内至少 6 次有效换向，反向距离门槛 600 raw counts，总行程门槛 4800 raw counts | 结束控制，通常保留连接；“已通过晃动鼠标退出。” 检测在所选鼠标过滤前执行，其他相对鼠标也可触发，但不同设备不合并计数 |
| `shortcut` | 检测到配置的紧急快捷键；同样不受所选键盘过滤限制 | 结束控制，通常保留连接；“已通过快捷键退出。” |
| `heartbeat` | Windows 原生层连续 3 秒收不到 Flutter 心跳；Flutter 正常每 500ms 发送 | 结束控制，通常保留连接；“界面响应中断，已释放鼠标。” |
| `device_removed` | 所选键盘或鼠标收到设备移除事件 | “所选设备已断开，已退出。” |
| `focus_lost` | 窗口内控制模式失焦，或前台窗口/捕获窗口焦点检查失败 | 后台边缘控制不因普通窗口失焦退出；“窗口失焦，已退出。” |
| `window_changed` | 窗口内控制的移动、大小、DPI 等变化；显示配置变化则后台控制也退出 | “窗口位置或大小变化，已退出。” |
| `input_overflow` | 待发送离散输入事件队列已达 256，再入队时停止 | 不是累计 256 次移动就退出；纯移动不经过该队列。当前 UI 无专用原因文案，显示“已停止控制。” |
| `manual` / `shutdown` | 停止操作、重新配置等路径，或窗口/程序关闭 | 人工或生命周期退出 |
| `timeout` | 本地测试达到 30 秒上限 | 远程控制不受该 30 秒限制 |

实现位置：`windows/runner/input_bridge.cpp` 的 `ProcessInput()`、`RemotePointer()`、`HandleMessage()`、`Watchdog()`、`QueueInput()`；`windows/runner/edge_policy.h`；`windows/runner/safety_policy.h`。提示映射在 `lib/main.dart` 的 `_reason()`。

以下路径还可能真正关闭网络连接：

- `lib/remote/lan_session.dart`：每 400ms 检查控制连接；距离上次收到并解码 TCP 控制消息超过 1800ms 时调用 `_lost('连接超时')`。实际触发时刻受定时器调度影响。
- TCP 读写、解密、消息解析/校验、原生回调或输入注入失败，可能进入 `_lost()`。Mac 指针轮询失败也会进入 `_lost('指针反馈中断')`。
- `lib/remote/wire.dart`：发送排队超过 512 项时关闭连接。
- 对端主动结束当前控制会话时，Windows 的 `onCaptureEnded` 也会停止本地控制；该路径本身不要求关闭 TCP。
- Mac 原生层 `RemoteInputBridge.swift`：1.5 秒未收到输入或接收心跳，会停止接收并释放按键。后续 `receiverHeartbeat` 返回 `receiver_stopped` 或输入调用报错，可能进一步导致连接关闭。

持续移动鼠标不能保证这些条件不触发：Windows 到 Mac 的鼠标数据、Mac 到 Windows 的指针反馈、Flutter 到原生层的心跳是不同链路。少量 UDP 丢包本身没有直接的“丢包即断开”分支。

## 3. 优先问题 A：钩子活动检查存在无符号下溢竞态

位置：

- `windows/runner/background_hooks.cpp:67–68`：`MouseFresh()` / `KeyboardFresh()`。
- 同文件钩子回调在独立线程更新 `mouse_seen_` / `keyboard_seen_`。
- `windows/runner/input_bridge.cpp:546、548、592`：输入线程先读取 `now`，再调用上述检查；返回 false 即 `Stop("hook_lost")`。

当前逻辑：

```cpp
bool MouseFresh(uint64_t now) const {
  return now - mouse_seen_.load() < 250;
}
```

允许出现的时序（示例，未实机复现）：

1. 输入线程取得 `now = 10000`。
2. 钩子线程处理新输入并写入 `mouse_seen_ = 10001`。
3. 输入线程执行无符号 `10000 - 10001`，结果变成极大值。
4. 将刚活动过的钩子判断为不新鲜，立即退出控制。

这里的 atomic 只保证单次读写，不保证两个时间点的先后关系。增加 atomic 内存序也不能单独解决此问题。

建议：先快照读取钩子时间，再采样当前单调时间；或者显式将 `lastSeen > now` 视作年龄为 0，并独立处理从未观察到事件的状态。不要把“未来时间”当作钩子过期。

此外，应核查长时间静止后首个 Raw Input 与鼠标钩子回调的交付顺序。目前单次不新鲜即退出，可能把短暂事件顺序差异当作失效；该点尚未确认，需要 Windows 端结合输入链路验证。

## 4. 优先问题 B：指针反馈看门狗存在同类竞态

位置：

- `windows/runner/input_bridge.cpp:688`：`RemotePointer()` 在主线程更新 `pointer_received_`。
- `windows/runner/input_bridge.cpp:836–840`：独立看门狗先取 `now`，随后读取该 atomic 并相减。

当前逻辑：

```cpp
const auto now = GetTickCount64();
if (background_.Blocking() && now - pointer_received_.load() >= 1000) {
  ReleaseInputCapture();
  PostMessage(owner_, kWatchdogMessage, 3, generation_.load());
}
```

如果 `RemotePointer()` 在采样 `now` 之后写入更新的时间，无符号减法同样可能下溢，导致“刚收到反馈却判断超过 1 秒”，直接释放 Windows 输入。

看门狗虽持有 `cursor_lease_`，但 `RemotePointer()` 更新反馈时间并未持有该锁，不能依靠现有锁排除此交错。

建议：先读取反馈时间快照，再采样当前时间；过期判断显式满足 `now >= received` 且差值达到门槛。保留现有 1 秒保护及会话 generation 校验，先修正计算顺序和边界行为。

## 5. 退出原因可能被抢先归类

位置：`windows/runner/input_bridge.cpp:755–783` 及 `Stop()`。

看门狗先 `ReleaseInputCapture()`，再向主线程投递 `kWatchdogMessage`。如果主线程先处理统计定时器，发现会话仍 active、但 `background_.Blocking()` 已为 false，就先执行 `Stop("hook_lost")`。

真正的看门狗消息随后执行 `Stop("pointer_timeout")` 或 `Stop("heartbeat")` 时，`was_active` 已为 false，函数不会再次发送停止原因。快捷键线程先释放、再投递停止消息，也存在类似归类竞争。

因此，“后台输入拦截中断”目前不一定证明最初故障来自钩子；也可能是其他释放路径被统计检查抢先归类。此问题影响定位，不能仅按 UI 文案认定根因。

建议由首次触发释放的一方保存“会话 generation + 原始原因 + 触发时刻”的不可覆盖记录，再由主线程完成停止与通知。记录应在释放前或与释放作为同一受保护操作完成，并在新会话开始时重置；后续路径读取首次原因。避免简单取消提前释放，原有设计需要保证主线程阻塞时也能恢复本机输入。

## 6. Windows 端建议处理顺序与验收

1. 修正两处时间判断，不调整现有超时阈值，不关闭保护。
2. 保存每个会话首次释放原因，补充 `input_overflow` 文案；将“控制结束”与“连接断开”分别呈现。
3. 为时间判断补充确定性原生测试：`last == now`、略旧、恰好门槛、超过门槛、`last > now`、从未收到事件。钩子新鲜度在 250ms 时为 false；指针超时在 1000ms 时为 true；不能因未来时间下溢误退。
4. 为原因保留补充消息交错测试：看门狗/快捷键先释放，统计定时器先处理，最终仍报告首次原因；旧 generation 的消息不能停止或污染新会话。
5. Windows 实机核验持续移动、静止后继续移动、纯移动与键鼠混合操作；真实断网、界面阻塞、钩子失效时仍应正常释放。模拟测试通过不能代替真实设备验证。

如需补充定位记录，建议只在释放时保存一次有界快照：首次原因、generation、时间及反馈/钩子/心跳年龄、控制模式、连接状态；`edge` 再记录返回边缘及序号。无需高频逐包日志或键盘内容。本报告不要求重新开展网络数据采样。

边缘返回本身没有驻留时间门槛；快速碰到返回边缘并满足向外移动条件即可退出。若修复竞态后仍发生，且首次原因确认为 `edge`，再讨论增加边缘驻留/越界意图门槛，避免混入本次修复。

## 7. 相关历史与本次交付

- `docs/issues/mouse-shake-exit-unresolved.md` 记录的是“晃动无法退出”的历史未解决问题，不能据此认定本次为晃动误触发。
- 当前预测反馈会将预测状态的序号置为 `-1`，Windows 边缘返回要求序号非负；已有防止预测点直接触发返回的逻辑，见 `RemoteInputBridge.swift`、`LanSession._sendPointer()` 与 `edge_policy.h`。
- 本次仅交付本文档；未修改、构建或重启程序，未提交或 push。
