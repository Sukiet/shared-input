# Windows 长时间闲置后后台输入未就绪

基线 `6f03f1c`，分支 `feature-drag-objects`。用户反馈控制机经常显示“Bad state: 后台输入拦截未就绪，请松开按键并移动鼠标后重试”，重启应用可恢复；通常数小时没有跨屏，期间可能锁屏或睡眠。

## 定位

旧 `edgeState.ready` 依赖历史回调 `Observed`、钩子缓存按住状态和 Windows 异步状态；Dart 在 ready 为 false 时直接退出。原生 Begin 同样先检查缓存无按下才允许 RefreshHooks。缓存漏掉一个 up 时无法进入刷新路径，重启清空缓存才恢复。普通键盘没有缓存校正，鼠标校正也仅在拖拽测试中覆盖左右键。系统锁屏/唤醒没有专门重新建立状态。

Windows 还可能静默移除超时的低级钩子，消息线程活着不等于 HHOOK 仍有效。直接清空所有缓存也不正确：本机探针实测已拦截的 F24 down 在钩子中为按住、GetAsyncKeyState 却为 0，不能把远端归属的实际按住误当成已松开。

## 修正

- 每次准备进入后台控制，在原生钩子线程先刷新钩子并校正状态，再做按住检查；新安装成功的钩子不再等待历史 Observed 标记。准备失败不会返回旧的 ready=true。
- 在既有 50 ms 消息泵校正 Windows 实际接收过的键盘和五个鼠标按钮，普通模式也启用。仅查询已知按住项，有 100 ms 异步状态更新宽限；空闲未按下时不扫描全部按键，不增加定时器。不凭 Windows 异步零值清除远控归属的按下。
- 后台增加键盘 Raw Input 只读观察，与鼠标一起独立补齐真实释放。远端键的 up 丢失时可补发一次；晚到的钩子 up 只作排空，不重复发送。比较原始事件时间和最新 down/repeat 时间，拒绝旧包及同一时刻的歧义包，避免抹掉新按下。
- 后台键盘仍仅由钩子消息转发，硬件 Raw Input 不发送第二份。明确区分两种输入来源，钩子构造的输入也不再回流成原始输入修复事件。
- 原始输入到达、对应钩子回调却失去活跃时，限速发起原生重建；正在控制时发现钩子失效先释放输入再退出。活动输入桌面不可用时不做全零采样，等桌面恢复再重建。
- 注册会话和电源通知：锁屏、会话断开、睡眠先释放控制，解锁和唤醒重新安装并按当前 Windows 状态建立基线；真实仍按住的 Windows 键仍会阻止进入。通知继续交给 Flutter 和插件，不截断它们的电源恢复处理。
- 请求等待最多 250 ms。使用共享请求保留超时后的生命周期，超时取消的 Begin 即使迟到也不能启动拦截。
- 忽略 IME 虚拟 bookkeeping 按键的物理按住计数。界面区分“真实按住”和“拦截正在恢复”，使用 PlatformException，不再给这类提示加 Bad state 前缀。日志单独标记锁屏和睡眠。

## 验证

Flutter 分析通过，97 项 Flutter 测试、14 项 Windows 原生测试通过，Windows Debug 构建通过。

`hook_key_state_test` 覆盖本地漏 up、远端按住不得用异步零值清除、Raw up 补齐、旧包/重复包/毫秒计时回绕、恢复后的新输入归属、唤醒时保留实际按住及中键/侧键校正。

桌面探针 `hook_async_state_probe` 实际输出：

```text
stale_state_and_removed_hooks_recovered=1
remote_hold_preserved=1
raw_up_recovered=1
resume_reset=1
bounded_wait=1
raw_triggered_hook_repair=1
cancelled_late_begin=1
async_down_while_intercepted=0
```

故障注入仅编译在 native-test DLL，应用 DLL 不包含测试入口。探针隐藏消息窗口，不改变前台，使用相反的一像素移动及被拦截的 F24 配对测试；SendInput 不生成硬件 WM_INPUT，原始观察恢复部分向同一个生产 RawMouse 入口提交模拟观察，再确认真实低级回调恢复。短暂停顿用于验证取消的 Begin 不会迟到激活，未让电脑实际锁屏或休眠。

没有完成“数小时真实闲置 → 实际锁屏/睡眠 → 再跨屏”的长时间复测；仍需正常使用确认。此次仅修改 Windows 及界面状态处理，不要求 Mac 更新。

参考：[微软低级键盘钩子说明](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)、[GetAsyncKeyState 的桌面与状态限制](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getasynckeystate)。
